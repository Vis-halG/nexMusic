part of 'music_controller.dart';

extension MusicListeningActions on MusicController {
  String _accountKey(String name) =>
      _auth == null ? name : 'user:$_accountUid:$name';
  void _initPersonal(String account) {
    _accountUid = account;
    library = MediaLibrary(
      _prefs,
      namespace: _auth == null ? '' : 'user:$account',
    )..addListener(notifyListeners);
    personal = PersonalMusic(
      _prefs,
      uid: account,
      firestore: _firestore,
      legacy: _auth == null,
    )..addListener(notifyListeners);
    if (_firestore != null && account != 'guest') {
      social = MusicSocial(firestore: _firestore, uid: account)
        ..addListener(notifyListeners);
      social!.playbackState = () =>
          (song: current, playing: playing, position: position);
    }
    personal.onCloudLike = (song, value) {
      if (value) {
        liked.add(song.id);
      } else {
        liked.remove(song.id);
      }
      library.applyCloudLike(song, value);
      unawaited(
        _prefs.setStringList(_accountKey('likedSongIds'), liked.toList()),
      );
    };
    personal.onCloudActivity = () {
      for (final row in personal.activity.values) {
        final song = readSongs([row['song']]).firstOrNull;
        if (song != null) {
          library.applyCloudPlay(
            song,
            (row['lastPlayed'] as num? ?? 0).toInt(),
          );
        }
      }
    };
    downloads = MusicDownloads(
      prefs: _prefs,
      storageKey: _accountKey('offlineSongs'),
      paths: offlineSongs,
      tracks: personal.offlineTracks,
      settings: () => personal.settings,
      resolve: (song) => resolvedPlayableUrl(song, downloading: true),
      headers: playbackHeadersFor,
      onSaved: () {
        personal.changed();
        notifyListeners();
      },
      onProgress: (job) {
        final id = 5000 + (job.song.id.hashCode.abs() % 1000);
        if (job.status == MusicDownloadStatus.complete) {
          unawaited(
            phone?.showDone(id, title: 'Downloaded', text: job.song.title),
          );
        } else if (job.status == MusicDownloadStatus.downloading) {
          unawaited(
            phone?.showProgress(
              id,
              title: 'Downloading',
              text: job.song.title,
              percent: (job.progress * 100).round(),
            ),
          );
        } else {
          unawaited(
            phone?.showDone(
              id,
              title: job.status == MusicDownloadStatus.failed
                  ? 'Download failed'
                  : job.status == MusicDownloadStatus.cancelled
                  ? 'Download cancelled'
                  : 'Download waiting',
              text: job.error ?? job.song.title,
            ),
          );
        }
      },
    )..addListener(_downloadStateChanged);
  }

  void _downloadStateChanged() {
    songDownloads
      ..clear()
      ..addEntries(
        downloads.jobs.values
            .where(
              (j) =>
                  j.status == MusicDownloadStatus.downloading ||
                  j.status == MusicDownloadStatus.queued,
            )
            .map((j) => MapEntry(j.song.id, j.progress)),
      );
    notifyListeners();
  }

  void _initPlayback() {
    playback = ListeningPlayer(
      player: _audio,
      resolve: (song) async {
        if (personal.settings.downloadedOnly &&
            !song.isLocal &&
            !isSongDownloaded(song)) {
          throw StateError('Track is not downloaded.');
        }
        if (song.url.startsWith('device:') && !song.isPrivate) {
          throw StateError('Track is on another device.');
        }
        final url = await resolvedPlayableUrl(song);
        return AudioSource.uri(
          Uri.parse(url),
          headers: audioHeadersFor(song, url),
          tag: song,
        );
      },
      settings: () => personal.settings,
      onTrack: (song) {
        current = song;
        if (song.isProvider) _recordStreamSong(song);
        library.recordSongPlay(song);
        personal.recordPlay(song);
        duration = Duration(milliseconds: song.durationMs);
        _audioHandler?.mediaItem.add(_mediaItem(song));
        unawaited(phone?.setSessionActive(true));
        notifyListeners();
      },
      onListening: (song, ms, {bool skipped = false, bool completed = false}) {
        personal.recordListening(
          song,
          ms,
          skipped: skipped,
          completed: completed,
        );
        _saveQueue();
        if (song.isLongform) {
          personal.resumePositions[song.id] = position.inMilliseconds;
          personal.changed();
        }
      },
      onError: announce,
      onPlayerChanged: (player) {
        _audio = player;
        _audioHandler?.bindPlayer(player);
      },
      onQueueSaved: _saveQueue,
      onAudioSession: (id) {
        if (MusicDevice.android) {
          unawaited(
            MusicDevice.equalizer(
              id,
            ).catchError((Object _) => <String, dynamic>{}),
          );
        }
      },
      onQueueEnd: () async {
        if (_randomScope == MusicRandomScope.library) return;
        final seed = current, account = personal;
        if (seed == null ||
            !seed.isProvider ||
            account.settings.downloadedOnly) {
          return;
        }
        final tracks = await fetchRadioForSong(
          seed,
          limit: 20,
          excludeIds: playback.queue.tracks.map((s) => s.id).toSet(),
        );
        if (account != personal || seed.id != current?.id) return;
        for (final track in tracks.where(
          (s) =>
              account.accepts(s) &&
              !playback.queue.tracks.any(
                (queued) => sameMusicRecording(queued, s),
              ),
        )) {
          playback.queue.add(track);
        }
      },
    );
    playback.addListener(_playerChanged);
    playback.position.addListener(_positionChanged);
    _restoreQueue();
    _audioHandler
      ?..onPlay = playback.resume
      ..onPause = pauseAudio
      ..onSeek = seek
      ..onStop = playback.stop
      ..onPlayMediaId = (id) async {
        final song = songById(id);
        if (song != null) await play(song, from: allMusic);
      }
      ..onBrowse = _browseForCar;
  }

  List<Song> get allMusic => {
    for (final s in [
      ...songs,
      ...providerSongs,
      ...personal.localTracks.values,
      ...personal.longformTracks.values,
      ...personal.offlineTracks.values,
      ...library.entries.map((e) => e.song),
    ])
      s.id: s,
  }.values.toList();

  List<Song> randomSongsFor(MusicRandomScope scope) {
    final libraryTracks = <Song>[
      ...songs,
      ...likedSongs,
      ...downloadedSongs,
      ...personal.localTracks.values,
      for (final playlist in personal.playlists) ...playlist.tracks,
      for (final item in savedMedia.where((m) => m.kind == 'audio'))
        Song(
          id: '$privateSongPrefix${item.id}',
          title: item.title,
          kind: 'audio',
          url: 'device:${item.id}',
          ownerUid: personal.uid,
        ),
    ];
    final candidates = switch (scope) {
      MusicRandomScope.home => [...allMusic, ...libraryTracks],
      MusicRandomScope.stream => [
        ...streamRandomTracks,
        ...providerSongs,
        ...allMusic.where((s) => s.isProvider),
      ],
      MusicRandomScope.library => libraryTracks,
    };
    return {
      for (final song in candidates.where(
        (s) =>
            !s.isVideo &&
            !s.isLongform &&
            (scope != MusicRandomScope.stream || s.isProvider) &&
            (!s.url.startsWith('device:') || s.isPrivate) &&
            (!personal.settings.downloadedOnly ||
                s.isLocal ||
                isSongDownloaded(s)),
      ))
        song.id: song,
    }.values.toList();
  }

  Future<void> playRandom(MusicRandomScope scope, {math.Random? random}) async {
    var pool = randomSongsFor(scope);
    if (pool.isEmpty && scope != MusicRandomScope.library) {
      await loadDiscoveryHome();
      pool = randomSongsFor(scope);
    }
    if (pool.isEmpty) {
      announce(
        scope == MusicRandomScope.library
            ? 'No playable songs in your library. Save music or add a playlist first.'
            : 'No songs available. Refresh Stream and try again.',
      );
      return;
    }
    final choices = pool.length > 1
        ? pool.where((s) => s.id != current?.id).toList()
        : pool;
    final selected = choices[(random ?? math.Random()).nextInt(choices.length)];
    playback.queue.setShuffle(true);
    await play(selected, from: pool, randomScope: scope);
  }

  List<MusicArtistCategory> get artistCategories => groupSongsByArtist(
    [
      ...songs,
      ...allMusic,
      for (final playlist in personal.playlists) ...playlist.tracks,
    ].map(
      (song) => personal.songArtists.containsKey(song.id)
          ? song.copyWith(artist: personal.songArtists[song.id])
          : song,
    ),
  );

  void setSongArtist(Song song, String artist) {
    final value = artist.trim();
    personal.songArtists[song.id] = value.length > 160
        ? value.substring(0, 160)
        : value;
    personal.changed(sync: false);
  }

  Future<List<MediaItem>> _browseForCar(String parent) async {
    if (!signedIn && !guestMode) return [];
    if (parent == 'root') {
      return [
        const MediaItem(id: 'liked', title: 'Liked songs', playable: false),
        const MediaItem(
          id: 'downloads',
          title: 'Downloaded music',
          playable: false,
        ),
        const MediaItem(id: 'local', title: 'Device music', playable: false),
        for (final p in personal.playlists)
          MediaItem(id: 'playlist:${p.id}', title: p.name, playable: false),
      ];
    }
    final tracks = switch (parent) {
      'liked' => likedSongs,
      'downloads' => downloadedSongs,
      'local' => personal.localTracks.values.toList(),
      _ =>
        personal.playlist(parent.replaceFirst('playlist:', ''))?.tracks ??
            <Song>[],
    };
    return tracks.where((s) => !s.isVideo).map(_mediaItem).toList();
  }

  void _playerChanged() {
    current = playback.queue.current;
    queue = List.of(playback.queue.tracks);
    shuffle = playback.queue.shuffled;
    repeat = playback.queue.repeat != MusicRepeat.off;
    playing = playback.playing;
    loading = playback.loading;
    duration = playback.duration;
    _audioHandler?.queue.add(queue.map(_mediaItem).toList());
    notifyListeners();
  }

  void _positionChanged() {
    position = playback.position.value;
    positionListenable.value = position;
  }

  void _saveQueue() {
    unawaited(
      _prefs.setString(
        _accountKey('playback_queue_v1'),
        jsonEncode({
          ...playback.queue.toJson(),
          'positionMs': playback.position.value.inMilliseconds,
          'randomScope': _randomScope?.name,
        }),
      ),
    );
  }

  void _restoreQueue() {
    try {
      final saved = jsonDecode(
        _prefs.getString(_accountKey('playback_queue_v1')) ?? '{}',
      );
      playback.queue.restore(saved);
      _randomScope = MusicRandomScope.values
          .where((s) => s.name == saved['randomScope'])
          .firstOrNull;
      playback.restoredPosition = saved is Map
          ? Duration(milliseconds: (saved['positionMs'] as num? ?? 0).toInt())
          : Duration.zero;
      playback.position.value = playback.restoredPosition;
    } catch (_) {}
    queue = List.of(playback.queue.tracks);
    current = playback.queue.current;
    shuffle = playback.queue.shuffled;
    repeat = playback.queue.repeat != MusicRepeat.off;
    if (current != null) _audioHandler?.mediaItem.add(_mediaItem(current!));
  }

  Future<void> _switchAccount(String account) {
    return _accountSwitch = _accountSwitch
        .catchError((Object _) {})
        .then((_) => _performAccountSwitch(account));
  }

  Future<void> _performAccountSwitch(String account) async {
    if (_accountUid == account) return;
    streamRandomTracks = const [];
    _randomScope = null;
    final generation = ++_accountGeneration;
    await playback.stop();
    downloads
      ..removeListener(_downloadStateChanged)
      ..dispose();
    await personal.saved;
    personal
      ..removeListener(notifyListeners)
      ..dispose();
    await social?.leave();
    social
      ?..removeListener(notifyListeners)
      ..dispose();
    social = null;
    library
      ..removeListener(notifyListeners)
      ..dispose();
    await migrateMusicAccount(_prefs, account);
    if (generation != _accountGeneration) return;
    liked.clear();
    recentSongIds.clear();
    _recentStreamSongs.clear();
    offlineSongs = {};
    offlinePaths = {};
    songDownloads.clear();
    _initPersonal(account);
    liked.addAll(_prefs.getStringList(_accountKey('likedSongIds')) ?? []);
    recentSongIds.addAll(
      _prefs.getStringList(_accountKey('recentSongIds')) ?? [],
    );
    for (final row
        in _prefs.getStringList(_accountKey('recent_stream_history')) ??
            <String>[]) {
      try {
        final track = Song.fromJson(
          Map<String, dynamic>.from(jsonDecode(row) as Map),
        );
        if (track != null) _recentStreamSongs.add(track);
      } catch (_) {}
    }
    try {
      offlineSongs.addAll(
        Map<String, String>.from(
          jsonDecode(_prefs.getString(_accountKey('offlineSongs')) ?? '{}')
              as Map,
        ),
      );
    } catch (_) {}
    try {
      offlinePaths.addAll(
        Map<String, String>.from(
          jsonDecode(_prefs.getString(_accountKey('offlineMedia')) ?? '{}')
              as Map,
        ),
      );
    } catch (_) {}
    _restoreQueue();
    notifyListeners();
  }

  Future<void> scanDeviceMusic() async {
    final account = personal;
    try {
      final tracks = await MusicDevice.scan();
      if (account != personal) return;
      account.localTracks
        ..removeWhere((_, s) => s.url.startsWith('content:'))
        ..addEntries(tracks.map((s) => MapEntry(s.id, s)));
      library.rememberSongs(tracks);
      account.changed();
      announce('${tracks.length} device tracks found');
    } catch (e) {
      announce('Could not scan music: $e');
    }
  }

  void enterGuestMode() {
    guestMode = true;
    notifyListeners();
  }

  Future<Map<String, dynamic>> identifyRecording(
    String path, {
    bool humming = false,
  }) async {
    final token = await _auth?.currentUser?.getIdToken();
    if (token == null) throw StateError('Sign in again to identify music.');
    final bytes = await File(path).readAsBytes();
    if (bytes.length > 2 * 1024 * 1024) {
      throw StateError('Recording is too long. Try a shorter sample.');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.postUrl(
        Uri.parse(
          '$pushWorkerUrl/recognize?mode=${humming ? 'humming' : 'music'}',
        ),
      );
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.contentType = ContentType('audio', 'wav');
      request.contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close().timeout(
        const Duration(seconds: 45),
      );
      final result = jsonDecode(await utf8.decoder.bind(response).join());
      if (response.statusCode != 200 || result is! Map) {
        throw StateError(
          result is Map
              ? '${result['error'] ?? 'Recognition is unavailable.'}'
              : 'Recognition is unavailable.',
        );
      }
      return Map<String, dynamic>.from(result);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> addToQueue(Song song, {bool next = false}) async {
    playback.queue.add(song, next: next);
    await playback.queueChanged();
    announce(next ? 'Playing next: ${song.title}' : 'Added to queue');
  }

  Future<void> addSongsToQueue(
    Iterable<Song> songs, {
    bool next = false,
  }) async {
    final tracks = {
      for (final s in songs.where((s) => !s.isVideo)) s.id: s,
    }.values.toList();
    if (tracks.isEmpty) return;
    // Inserting every track directly after the current one reverses the batch.
    for (final song in next ? tracks.reversed : tracks) {
      playback.queue.add(song, next: next);
    }
    await playback.queueChanged();
    announce(
      next ? 'Selected songs will play next' : 'Selected songs added to queue',
    );
  }

  Future<void> playSelectedSongs(
    List<Song> songs, {
    bool shuffle = false,
  }) async {
    final tracks = {
      for (final s in songs.where((s) => !s.isVideo)) s.id: s,
    }.values.toList();
    if (tracks.isEmpty) return;
    if (shuffle) tracks.shuffle();
    playback.queue.setShuffle(shuffle);
    await play(tracks.first, from: tracks);
  }

  void setSongsLiked(Iterable<Song> songs, bool value) {
    final tracks = {
      for (final song in songs.where((s) => isLiked(s) != value)) song.id: song,
    }.values.toList();
    if (tracks.isEmpty) return;
    for (final song in tracks) {
      if (value) {
        liked.add(song.id);
      } else {
        liked.remove(song.id);
      }
    }
    unawaited(
      _prefs.setStringList(_accountKey('likedSongIds'), liked.toList()),
    );
    library.setSongsLiked(tracks, value);
    personal.recordLikes(tracks, value);
    notifyListeners();
  }

  Future<void> removeFromQueue(String id) async {
    playback.queue.remove(id);
    await playback.queueChanged();
  }

  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    playback.queue.reorder(oldIndex, newIndex);
    await playback.queueChanged();
  }

  Future<void> clearQueue() async {
    playback.queue.tracks.removeWhere((s) => s.id != current?.id);
    await playback.queueChanged();
  }

  void setSleepTimer(Duration? duration, {bool afterTrack = false}) =>
      playback.setSleep(duration, afterTrack: afterTrack);
  Future<void> setListeningSetting(String key, Object value) async {
    personal.setSetting(key, value);
    if ({
      'crossfade',
      'gapless',
      'wifiQuality',
      'mobileQuality',
      'downloadQuality',
    }.contains(key)) {
      playback.invalidateSources();
      await playback.queueChanged();
    }
    if (key == 'wifiOnly') unawaited(downloads.resume());
    if (key == 'smartDownloads' && value == true) {
      unawaited(runSmartDownloads());
    }
  }

  Future<void> runSmartDownloads() async {
    if (!personal.settings.smartDownloads) return;
    final picks = [
      ...likedSongs,
      ...recentSongs,
    ].where((s) => !s.isVideo && !s.isLocal).take(25);
    try {
      await downloads.enqueue(picks);
    } catch (e) {
      announce('$e');
    }
  }

  Future<void> searchAllMusic(String query) async {
    final request = ++_providerRequest;
    providerQuery = query.trim();
    providerLoading = providerQuery.isNotEmpty;
    providerError = null;
    if (providerQuery.isEmpty) {
      providerSongs = [];
      notifyListeners();
      return;
    }
    notifyListeners();
    final result = await discovery.browse(query: providerQuery);
    if (request != _providerRequest) return;
    providerSongs = rankForListener(result.songs);
    library.rememberSongs(providerSongs);
    providerLoading = false;
    providerError = result.songs.isEmpty
        ? 'No online results. Try another search.'
        : null;
    notifyListeners();
  }
}

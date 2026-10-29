part of 'music_ui.dart';

Future<void> _featureTask(
  BuildContext context,
  Future<void> Function() task,
) async {
  try {
    await task();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

Future<void> _shareMusic(
  BuildContext context,
  String text, {
  String? file,
}) async {
  final render = context.findRenderObject();
  final origin = render is RenderBox
      ? render.localToGlobal(Offset.zero) & render.size
      : const Rect.fromLTWH(0, 0, 1, 1);
  await SharePlus.instance.share(
    ShareParams(
      text: text,
      files: file == null ? null : [XFile(file)],
      sharePositionOrigin: origin,
    ),
  );
}

String _songShareLink(Song song) {
  if (song.providerId.startsWith('yt')) {
    return 'https://music.youtube.com/watch?v=${Uri.encodeComponent(song.sourceId)}';
  }
  return '$pushWorkerUrl/share/track?data=${base64Url.encode(utf8.encode(jsonEncode(trackJson(song, cloud: true))))}';
}

List<Widget> _listeningSongActions(
  BuildContext context,
  BuildContext sheet,
  Song song,
) {
  final music = context.read<MusicController>();
  Widget action(IconData icon, String title, VoidCallback tap) => ListTile(
    leading: Icon(icon),
    title: Text(title),
    onTap: () {
      Navigator.pop(sheet);
      tap();
    },
  );
  return [
    if (!song.isVideo)
      action(
        Icons.playlist_play_rounded,
        'Play next',
        () => unawaited(music.addToQueue(song, next: true)),
      ),
    if (!song.isVideo)
      action(
        Icons.queue_music_rounded,
        'Add to queue',
        () => unawaited(music.addToQueue(song)),
      ),
    action(
      Icons.playlist_add_rounded,
      'Add to playlist',
      () => unawaited(_choosePlaylist(context, song)),
    ),
    if (song.isProvider)
      action(
        music.isLiked(song) ? Icons.favorite : Icons.favorite_border,
        music.isLiked(song) ? 'Unlike' : 'Like',
        () => music.toggleLike(song),
      ),
    if (song.artist.isNotEmpty)
      action(
        Icons.person_outline,
        'View artist',
        () => _push(context, ArtistAlbumScreen(song: song)),
      ),
    if (song.album.isNotEmpty)
      action(
        Icons.album_outlined,
        'View album',
        () => _push(context, ArtistAlbumScreen(song: song, album: true)),
      ),
    if (!song.isVideo && !song.isLongform)
      action(Icons.badge_outlined, 'Set artist tag', () async {
        final account = music.personal;
        final value = await _nameDialog(
          context,
          title: 'Artist names (comma separated)',
          action: 'Save',
          initialValue: account.songArtists[song.id] ?? song.artist,
        );
        if (value != null && context.mounted && account == music.personal) {
          music.setSongArtist(song, value);
          music.announce('Artist tag saved on this device');
        }
      }),
    if (!song.isPrivate && !song.isLocal)
      action(
        Icons.share_outlined,
        'Share song',
        () => unawaited(
          _featureTask(
            context,
            () => _shareMusic(
              context,
              '${song.title}${song.artist.isEmpty ? '' : ' — ${song.artist}'}\n${_songShareLink(song)}',
            ),
          ),
        ),
      ),
    action(Icons.visibility_off_outlined, 'Hide from recommendations', () {
      music.personal.hide(song);
      music.announce('Hidden from recommendations');
    }),
    if (song.artist.isNotEmpty)
      action(Icons.person_off_outlined, 'Hide artist', () {
        music.personal.hide(song, artist: true);
        music.announce('Artist hidden from recommendations');
      }),
  ];
}

Future<void> _choosePlaylist(BuildContext context, Song song) async {
  final music = context.read<MusicController>();
  await _sheet(
    context,
    title: 'Add to playlist',
    (sheet) => [
      ListTile(
        leading: const Icon(Icons.add),
        title: const Text('New playlist'),
        onTap: () async {
          Navigator.pop(sheet);
          final name = await _nameDialog(
            context,
            title: 'New playlist',
            action: 'Create',
          );
          if (name != null && context.mounted) {
            await _featureTask(context, () async {
              music.personal.createPlaylist(name, tracks: [song]);
              music.announce('Playlist created');
            });
          }
        },
      ),
      for (final p in music.personal.playlists.where(
        (p) => p.canEdit(music.personal.uid),
      ))
        ListTile(
          leading: Text(p.cover, style: const TextStyle(fontSize: 24)),
          title: Text(p.name),
          subtitle: Text('${p.tracks.length} tracks'),
          onTap: () {
            Navigator.pop(sheet);
            _featureTask(context, () async {
              music.personal.addToPlaylist(p, song);
              music.announce('Added to ${p.name}');
            });
          },
        ),
    ],
  );
}

class PersonalLibraryPanel extends StatelessWidget {
  const PersonalLibraryPanel({super.key});
  @override
  Widget build(BuildContext context) {
    final music = context.watch<MusicController>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _NavRow(
          icon: Icons.folder_open,
          title: 'Music on this device',
          trailing: '${music.personal.localTracks.length}',
          onTap: () => _push(context, const DeviceMusicScreen()),
        ),
        _NavRow(
          icon: Icons.download_outlined,
          title: 'Download manager',
          onTap: () => _push(context, const MusicDownloadsScreen()),
        ),
        _NavRow(
          icon: Icons.groups_outlined,
          title: 'Listen with friends',
          onTap: () => _push(context, const SocialMusicScreen()),
        ),
      ],
    );
  }
}

class MusicArtistsScreen extends StatefulWidget {
  const MusicArtistsScreen({super.key});
  @override
  State<MusicArtistsScreen> createState() => _MusicArtistsScreenState();
}

class _MusicArtistsScreenState extends State<MusicArtistsScreen> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final music = context.watch<MusicController>();
    final artists = music.artistCategories
        .where((a) => a.key.contains(query.trim().toLowerCase()))
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Artists')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Search artists',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) => setState(() => query = value),
            ),
          ),
          Expanded(
            child: artists.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No artists found. Add music or search for songs in Stream.',
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: artists.length,
                    itemBuilder: (_, i) {
                      final artist = artists[i];
                      return ListTile(
                        leading: CircleAvatar(
                          child: Icon(
                            artist.unknown
                                ? Icons.person_search_outlined
                                : Icons.person_outline,
                          ),
                        ),
                        title: Text(artist.name),
                        subtitle: Text(
                          '${artist.tracks.length} song${artist.tracks.length == 1 ? '' : 's'}',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _push(
                          context,
                          SongListScreen(
                            title: artist.name,
                            emptyText: 'No songs from this artist.',
                            select: (m) =>
                                m.artistCategories
                                    .where((a) => a.key == artist.key)
                                    .firstOrNull
                                    ?.tracks ??
                                [],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

Widget _playlistCover(String cover, {double size = 48}) => Container(
  width: size,
  height: size,
  decoration: BoxDecoration(
    color: NexMusic.violet.withValues(alpha: 0.15),
    borderRadius: BorderRadius.circular(10),
  ),
  alignment: Alignment.center,
  child: Text(cover, style: TextStyle(fontSize: size / 2)),
);

class PlaylistScreen extends StatelessWidget {
  const PlaylistScreen({super.key, required this.id});
  final String id;
  @override
  Widget build(BuildContext context) {
    final music = context.watch<MusicController>(),
        p = music.personal.playlist(id);
    if (p == null || p.deleted) {
      return Scaffold(
        appBar: AppBar(title: const Text('Playlist')),
        body: const Center(child: Text('This playlist is unavailable.')),
      );
    }
    final edit = p.canEdit(music.personal.uid);
    return _SongSelectionScaffold(
      songs: p.tracks,
      playlistId: p.id,
      appBar: AppBar(
        title: Text(p.name),
        actions: [
          IconButton(
            tooltip: 'Playlist options',
            icon: const Icon(Icons.more_vert),
            onPressed: () => _sheet(
              context,
              title: p.name,
              (sheet) => [
                if (edit)
                  ListTile(
                    leading: const Icon(Icons.edit_outlined),
                    title: const Text('Rename'),
                    onTap: () async {
                      Navigator.pop(sheet);
                      final name = await _nameDialog(
                        context,
                        title: 'Rename playlist',
                        action: 'Save',
                        initialValue: p.name,
                      );
                      if (name != null && context.mounted) {
                        await _featureTask(context, () async {
                          music.personal.updatePlaylist(
                            p,
                            (p) => p.name = name.trim(),
                          );
                        });
                      }
                    },
                  ),
                if (edit)
                  ListTile(
                    leading: const Icon(Icons.palette_outlined),
                    title: const Text('Change cover'),
                    onTap: () {
                      Navigator.pop(sheet);
                      _sheet(
                        context,
                        title: 'Playlist cover',
                        (coverSheet) => [
                          Wrap(
                            children: [
                              for (final emoji in [
                                '🎧',
                                '🎵',
                                '🔥',
                                '🌧️',
                                '🚗',
                                '💪',
                                '🌙',
                                '💜',
                                '🎸',
                                '🪷',
                              ])
                                IconButton(
                                  tooltip: emoji,
                                  icon: Text(
                                    emoji,
                                    style: const TextStyle(fontSize: 28),
                                  ),
                                  onPressed: () {
                                    music.personal.updatePlaylist(
                                      p,
                                      (p) => p.cover = emoji,
                                    );
                                    Navigator.pop(coverSheet);
                                  },
                                ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.copy),
                  title: const Text('Duplicate playlist'),
                  onTap: () {
                    Navigator.pop(sheet);
                    final duplicate = music.personal.duplicate(p);
                    _push(context, PlaylistScreen(id: duplicate.id));
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.file_download_outlined),
                  title: const Text('Export playlist JSON'),
                  onTap: () {
                    Navigator.pop(sheet);
                    _featureTask(context, () async {
                      final folder = await getTemporaryDirectory();
                      final file = File(
                        '${folder.path}/nexMusic-playlist-${p.id}.json',
                      );
                      await file.writeAsString(exportPlaylist(p));
                      if (context.mounted) {
                        await _shareMusic(context, p.name, file: file.path);
                      }
                    });
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.table_chart_outlined),
                  title: const Text('Export playlist CSV'),
                  onTap: () {
                    Navigator.pop(sheet);
                    _featureTask(context, () async {
                      final dir = await getTemporaryDirectory();
                      final file = await File(
                        '${dir.path}/nexMusic-${p.id}.csv',
                      ).writeAsString(exportPlaylistCsv(p));
                      if (context.mounted) {
                        await _shareMusic(context, p.name, file: file.path);
                      }
                    });
                  },
                ),
                if (music.personal.cloudAvailable &&
                    p.ownerUid == music.personal.uid)
                  ListTile(
                    leading: const Icon(Icons.group_add_outlined),
                    title: const Text('Invite collaborators'),
                    onTap: () {
                      Navigator.pop(sheet);
                      _invitePlaylist(context, p);
                    },
                  ),
                if (music.personal.cloudAvailable &&
                    p.ownerUid == music.personal.uid)
                  ListTile(
                    leading: const Icon(Icons.manage_accounts),
                    title: const Text('Manage collaborators'),
                    onTap: () {
                      Navigator.pop(sheet);
                      _manageCollaborators(context, p);
                    },
                  ),
                if (music.personal.cloudAvailable &&
                    p.ownerUid == music.personal.uid)
                  ListTile(
                    leading: const Icon(Icons.link_off),
                    title: const Text('Revoke invite links'),
                    onTap: () async {
                      Navigator.pop(sheet);
                      final confirmed = await _confirm(
                        context,
                        title: 'Revoke invite links?',
                        body:
                            'Existing invitation links will stop working. Current collaborators stay in the playlist.',
                        action: 'Revoke',
                      );
                      if (confirmed && context.mounted) {
                        await _featureTask(
                          context,
                          () => music.social!.revokePlaylistInvites(p),
                        );
                      }
                    },
                  ),
                if (music.personal.cloudAvailable &&
                    p.ownerUid == music.personal.uid)
                  SwitchListTile(
                    title: const Text('Public playlist'),
                    subtitle: const Text('Anyone with its link can view it'),
                    value: p.public,
                    onChanged: (value) {
                      music.personal.updatePlaylist(p, (p) => p.public = value);
                      Navigator.pop(sheet);
                    },
                  ),
                if (p.public)
                  ListTile(
                    leading: const Icon(Icons.share_outlined),
                    title: const Text('Share playlist'),
                    onTap: () {
                      Navigator.pop(sheet);
                      _shareMusic(
                        context,
                        '${p.name}\n$pushWorkerUrl/share/playlist/${p.id}',
                      );
                    },
                  ),
                if (p.ownerUid == music.personal.uid)
                  ListTile(
                    leading: const Icon(Icons.delete_outline),
                    title: const Text('Delete playlist'),
                    onTap: () async {
                      Navigator.pop(sheet);
                      final ok = await _confirm(
                        context,
                        title: 'Delete playlist?',
                        body: 'Your tracks and downloads will be kept.',
                        action: 'Delete',
                      );
                      if (ok) {
                        music.personal.deletePlaylist(p);
                        if (context.mounted) Navigator.pop(context);
                      }
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                _playlistCover(p.cover, size: 76),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${p.tracks.length} tracks',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        p.members.length > 1
                            ? '${p.members.length} collaborators'
                            : 'Personal playlist',
                      ),
                      if (music.personal.syncError != null)
                        Text(
                          music.personal.syncError!,
                          style: const TextStyle(fontSize: 12),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: p.tracks.where((s) => !s.isVideo).isEmpty
                      ? null
                      : () => music.play(
                          p.tracks.firstWhere((s) => !s.isVideo),
                          from: p.tracks,
                        ),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play'),
                ),
                OutlinedButton.icon(
                  onPressed: p.tracks.isEmpty
                      ? null
                      : () => _featureTask(
                          context,
                          () => music.downloads.enqueue(p.tracks),
                        ),
                  icon: const Icon(Icons.download),
                  label: const Text('Download'),
                ),
                if (edit)
                  OutlinedButton.icon(
                    onPressed: () =>
                        _push(context, PlaylistAddScreen(id: p.id)),
                    icon: const Icon(Icons.add),
                    label: const Text('Add songs'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: p.tracks.isEmpty
                ? const Center(
                    child: Text('Add songs from their ⋮ menu or search.'),
                  )
                : ReorderableListView.builder(
                    padding: const EdgeInsets.only(bottom: 80),
                    itemCount: p.tracks.length,
                    buildDefaultDragHandles: false,
                    onReorderItem: (oldIndex, newIndex) {
                      if (!edit) return;
                      music.personal.updatePlaylist(p, (p) {
                        p.tracks.insert(newIndex, p.tracks.removeAt(oldIndex));
                      });
                    },
                    itemBuilder: (context, index) {
                      final song = p.tracks[index];
                      return SongTile(
                        key: ValueKey('${song.id}:$index'),
                        song: song,
                        queue: p.tracks,
                        trailing: edit
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: 'Remove from playlist',
                                    icon: const Icon(
                                      Icons.remove_circle_outline,
                                    ),
                                    onPressed: () =>
                                        music.personal.updatePlaylist(
                                          p,
                                          (p) => p.tracks.removeAt(index),
                                        ),
                                  ),
                                  ReorderableDragStartListener(
                                    index: index,
                                    child: const Padding(
                                      padding: EdgeInsets.all(12),
                                      child: Icon(Icons.drag_handle),
                                    ),
                                  ),
                                ],
                              )
                            : null,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class PlaylistAddScreen extends StatefulWidget {
  const PlaylistAddScreen({super.key, required this.id});
  final String id;
  @override
  State<PlaylistAddScreen> createState() => _PlaylistAddScreenState();
}

class _PlaylistAddScreenState extends State<PlaylistAddScreen> {
  final input = TextEditingController();
  List<Song> results = [];
  bool busy = false;
  int request = 0;
  Timer? debounce;
  Future<void> search(String value) async {
    final generation = ++request;
    setState(() => busy = true);
    final music = context.read<MusicController>();
    final local = music.allMusic
        .where(
          (s) => '${s.title} ${s.artist}'.toLowerCase().contains(
            value.toLowerCase(),
          ),
        )
        .toList();
    final online = value.trim().isEmpty
        ? <Song>[]
        : (await music.discovery.browse(query: value)).songs;
    if (!mounted || generation != request) return;
    setState(() {
      results = {
        for (final s in [...local, ...online]) s.id: s,
      }.values.toList();
      busy = false;
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => search(''));
  }

  @override
  void dispose() {
    debounce?.cancel();
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final music = context.watch<MusicController>(),
        playlist = music.personal.playlist(widget.id);
    return Scaffold(
      appBar: AppBar(title: const Text('Add songs')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: input,
              decoration: const InputDecoration(
                hintText: 'Search songs or artists',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (v) {
                debounce?.cancel();
                debounce = Timer(
                  const Duration(milliseconds: 500),
                  () => search(v),
                );
              },
            ),
          ),
          if (busy) const LinearProgressIndicator(),
          Expanded(
            child: ListView.builder(
              itemCount: results.length,
              itemBuilder: (_, i) {
                final song = results[i];
                final added =
                    playlist?.tracks.any((s) => s.id == song.id) ?? false;
                return ListTile(
                  title: Text(song.title),
                  subtitle: Text(song.artist),
                  trailing: IconButton(
                    tooltip: added ? 'Added' : 'Add song',
                    icon: Icon(added ? Icons.check : Icons.add),
                    onPressed: added || playlist == null
                        ? null
                        : () => _featureTask(context, () async {
                            music.personal.addToPlaylist(playlist, song);
                          }),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class MusicQueueScreen extends StatelessWidget {
  const MusicQueueScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final music = context.watch<MusicController>(), queue = music.queue;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Play queue'),
        actions: [
          TextButton(onPressed: music.clearQueue, child: const Text('Clear')),
        ],
      ),
      body: queue.isEmpty
          ? const Center(
              child: Text('Add songs using Play next or Add to queue.'),
            )
          : ReorderableListView.builder(
              itemCount: queue.length,
              onReorderItem: (oldIndex, newIndex) => music.reorderQueue(
                oldIndex,
                newIndex > oldIndex ? newIndex + 1 : newIndex,
              ),
              itemBuilder: (_, i) {
                final song = queue[i], current = music.current?.id == song.id;
                return ListTile(
                  key: ValueKey(song.id),
                  leading: Icon(current ? Icons.equalizer : Icons.music_note),
                  title: Text(song.title),
                  subtitle: Text(current ? 'Now playing' : song.artist),
                  onTap: () => music.play(song),
                  trailing: current
                      ? null
                      : IconButton(
                          tooltip: 'Remove from queue',
                          icon: const Icon(Icons.close),
                          onPressed: () => music.removeFromQueue(song.id),
                        ),
                );
              },
            ),
    );
  }
}

Future<void> _sleepTimerSheet(BuildContext context) async {
  final music = context.read<MusicController>();
  await _sheet(
    context,
    title: 'Sleep timer',
    (sheet) => [
      for (final minutes in [15, 30, 45, 60])
        ListTile(
          leading: const Icon(Icons.bedtime_outlined),
          title: Text('$minutes minutes'),
          onTap: () {
            music.setSleepTimer(Duration(minutes: minutes));
            Navigator.pop(sheet);
          },
        ),
      ListTile(
        title: const Text('End of this track'),
        onTap: () {
          music.setSleepTimer(null, afterTrack: true);
          Navigator.pop(sheet);
        },
      ),
      if (music.playback.hasSleepTimer)
        ListTile(
          title: const Text('Cancel timer'),
          onTap: () {
            music.playback.clearSleep();
            Navigator.pop(sheet);
          },
        ),
    ],
  );
}

class MusicLyricsScreen extends StatefulWidget {
  const MusicLyricsScreen({
    super.key,
    required this.song,
    this.karaoke = false,
  });
  final Song song;
  final bool karaoke;
  @override
  State<MusicLyricsScreen> createState() => _MusicLyricsScreenState();
}

class _MusicLyricsScreenState extends State<MusicLyricsScreen> {
  SongLyrics? lyrics;
  String? error, translated;
  bool busy = true, translating = false;
  final scroll = ScrollController();
  int lastLine = -1;
  Future<void> load() async {
    final music = context.read<MusicController>();
    try {
      final result = await music.lyricsService.get(
        widget.song,
        custom: music.personal.customLyrics[widget.song.id],
      );
      if (mounted) {
        setState(() {
          lyrics = result;
          error = null;
          busy = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          busy = false;
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => load());
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final music = context.watch<MusicController>();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.karaoke ? 'Sing along' : 'Lyrics'),
        actions: [
          IconButton(
            tooltip: 'Import LRC lyrics',
            icon: const Icon(Icons.file_open_outlined),
            onPressed: () => _featureTask(context, () async {
              final result = await FilePicker.pickFile(
                type: FileType.custom,
                allowedExtensions: ['lrc', 'txt'],
              );
              if (result == null) return;
              final file = result;
              if ((await file.length()) > 128000) {
                throw const FormatException('Choose lyrics under 128 KB.');
              }
              final text = utf8.decode(await file.readAsBytes());
              music.personal.customLyrics[widget.song.id] = text;
              music.personal.changed();
              if (mounted) await load();
            }),
          ),
          if (lyrics != null && MusicDevice.android)
            PopupMenuButton<String>(
              tooltip: 'Translate lyrics',
              icon: const Icon(Icons.translate),
              itemBuilder: (_) => [
                for (final entry in {
                  'hi': 'Hindi',
                  'en': 'English',
                  'es': 'Spanish',
                  'fr': 'French',
                  'ta': 'Tamil',
                  'te': 'Telugu',
                  'bn': 'Bengali',
                  'ur': 'Urdu',
                }.entries)
                  PopupMenuItem(value: entry.key, child: Text(entry.value)),
              ],
              onSelected: (language) async {
                setState(() => translating = true);
                try {
                  final text = await MusicDevice.translate(
                    lyrics!.plain.isEmpty
                        ? lyrics!.lines.map((l) => l.text).join('\n')
                        : lyrics!.plain,
                    language,
                  );
                  if (mounted) setState(() => translated = text);
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text('$e')));
                  }
                } finally {
                  if (mounted) setState(() => translating = false);
                }
              },
            ),
          if (!widget.karaoke)
            IconButton(
              tooltip: 'Sing along',
              icon: const Icon(Icons.mic),
              onPressed: () => _push(
                context,
                MusicLyricsScreen(song: widget.song, karaoke: true),
              ),
            ),
        ],
      ),
      body: busy
          ? const Center(child: CircularProgressIndicator())
          : error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(error!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    OutlinedButton(onPressed: load, child: const Text('Retry')),
                  ],
                ),
              ),
            )
          : Column(
              children: [
                if (translating) const LinearProgressIndicator(),
                if (translated != null)
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        translated!,
                        style: const TextStyle(fontSize: 20, height: 1.8),
                      ),
                    ),
                  ),
                Expanded(
                  child: lyrics!.instrumental
                      ? const Center(child: Text('Instrumental track'))
                      : !lyrics!.timed
                      ? SingleChildScrollView(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            lyrics!.plain,
                            style: const TextStyle(fontSize: 22, height: 1.8),
                          ),
                        )
                      : ValueListenableBuilder<Duration>(
                          valueListenable: music.positionListenable,
                          builder: (_, position, _) {
                            final active = music.current?.id == widget.song.id
                                ? lyrics!.activeLine(
                                    music.current?.id == widget.song.id
                                        ? position
                                        : Duration.zero,
                                  )
                                : -1;
                            if (active != lastLine) {
                              lastLine = active;
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (scroll.hasClients && active >= 0) {
                                  scroll.animateTo(
                                    (active * 88.0 - 120).clamp(
                                      0,
                                      scroll.position.maxScrollExtent,
                                    ),
                                    duration: const Duration(milliseconds: 350),
                                    curve: Curves.easeOut,
                                  );
                                }
                              });
                            }
                            return ListView.builder(
                              controller: scroll,
                              itemExtent: 88,
                              padding: const EdgeInsets.symmetric(vertical: 80),
                              itemCount: lyrics!.lines.length,
                              itemBuilder: (_, i) => InkWell(
                                onTap: () async {
                                  if (music.current?.id != widget.song.id) {
                                    await music.play(
                                      widget.song,
                                      initialPosition: lyrics!.lines[i].at,
                                    );
                                  } else {
                                    await music.seek(lyrics!.lines[i].at);
                                  }
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 24,
                                    vertical: 8,
                                  ),
                                  child: Text(
                                    lyrics!.lines[i].text,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: widget.karaoke ? 28 : 24,
                                      fontWeight: i == active
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                      color: i == active
                                          ? NexMusic.violet
                                          : _muted(context),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
                SafeArea(
                  top: false,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        tooltip: 'Previous',
                        onPressed: music.previous,
                        icon: const Icon(Icons.skip_previous),
                      ),
                      IconButton(
                        tooltip: music.playing ? 'Pause' : 'Play',
                        onPressed: () => music.current?.id == widget.song.id
                            ? music.togglePlay()
                            : music.play(widget.song),
                        icon: Icon(
                          music.playing ? Icons.pause : Icons.play_arrow,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Next',
                        onPressed: music.next,
                        icon: const Icon(Icons.skip_next),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class MusicDownloadsScreen extends StatelessWidget {
  const MusicDownloadsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final music = context.watch<MusicController>(), manager = music.downloads;
    return _SongSelectionScaffold(
      songs: music.downloadedSongs,
      appBar: AppBar(
        title: const Text('Downloads'),
        actions: [
          IconButton(
            tooltip: manager.paused ? 'Resume downloads' : 'Pause downloads',
            icon: Icon(manager.paused ? Icons.play_arrow : Icons.pause),
            onPressed: () {
              if (manager.paused) {
                manager.resume();
              } else {
                manager.pause();
              }
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 80),
        children: [
          if (manager.waitingMessage != null || manager.paused)
            ListTile(
              leading: const Icon(Icons.wifi_off_rounded),
              title: Text(
                manager.paused ? 'Downloads paused' : manager.waitingMessage!,
              ),
              subtitle: const Text(
                'Queued songs stay ready. Keep the app open to continue.',
              ),
              trailing: TextButton(
                onPressed: () => manager.resume(),
                child: const Text('Retry now'),
              ),
            ),
          SwitchListTile(
            title: const Text('Downloaded-only playback'),
            subtitle: const Text('Play saved music without streaming'),
            value: music.personal.settings.downloadedOnly,
            onChanged: (v) => music.setListeningSetting('downloadedOnly', v),
          ),
          SwitchListTile(
            title: const Text('Download on Wi-Fi only'),
            subtitle: const Text(
              'Turn off to allow downloads over mobile data',
            ),
            value: music.personal.settings.wifiOnly,
            onChanged: (v) => music.setListeningSetting('wifiOnly', v),
          ),
          SwitchListTile(
            title: const Text('Smart downloads'),
            subtitle: const Text('Keep up to 25 liked and recent tracks ready'),
            value: music.personal.settings.smartDownloads,
            onChanged: (v) => music.setListeningSetting('smartDownloads', v),
          ),
          ListTile(
            title: const Text('Storage budget'),
            trailing: DropdownButton<int>(
              value: music.personal.settings.storageBudgetMb,
              items: [
                for (final mb in {
                  256,
                  512,
                  1024,
                  2048,
                  4096,
                  music.personal.settings.storageBudgetMb,
                }.toList()..sort())
                  DropdownMenuItem(
                    value: mb,
                    child: Text(mb ~/ 1024 >= 1 ? '${mb / 1024} GB' : '$mb MB'),
                  ),
              ],
              onChanged: (v) {
                if (v != null) music.setListeningSetting('storageBudgetMb', v);
              },
            ),
          ),
          for (final job in manager.jobs.values.where(
            (j) => j.status != MusicDownloadStatus.complete,
          ))
            ListTile(
              title: Text(job.song.title),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(job.error ?? job.status.name),
                  if (job.status == MusicDownloadStatus.downloading)
                    LinearProgressIndicator(
                      value: job.total > 0 ? job.progress : null,
                    ),
                ],
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if ({
                    MusicDownloadStatus.failed,
                    MusicDownloadStatus.cancelled,
                  }.contains(job.status))
                    IconButton(
                      tooltip: 'Retry download',
                      onPressed: () => manager.retry(job.song.id),
                      icon: const Icon(Icons.refresh),
                    ),
                  if (!{
                    MusicDownloadStatus.cancelled,
                    MusicDownloadStatus.failed,
                  }.contains(job.status))
                    IconButton(
                      tooltip: 'Cancel download',
                      onPressed: () => manager.cancel(job.song.id),
                      icon: const Icon(Icons.close),
                    ),
                ],
              ),
            ),
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text(
              'Saved music',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
            ),
          ),
          if (music.downloadedSongs.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text('Download a track or playlist to listen offline.'),
            ),
          for (final song in music.downloadedSongs)
            SongTile(song: song, queue: music.downloadedSongs),
        ],
      ),
    );
  }
}

class ListeningSettingsScreen extends StatelessWidget {
  const ListeningSettingsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final music = context.watch<MusicController>(),
        settings = music.personal.settings;
    Widget quality(String title, String key) => ListTile(
      title: Text(title),
      subtitle: Text('${settings.quality(key).kbps} kbps target'),
      trailing: DropdownButton<MusicQuality>(
        value: settings.quality(key),
        items: [
          for (final q in MusicQuality.values)
            DropdownMenuItem(value: q, child: Text(q.label)),
        ],
        onChanged: (v) {
          if (v != null) music.setListeningSetting(key, v.name);
        },
      ),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Listening settings')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Autoplay similar music'),
            subtitle: const Text('Continue with radio when the queue ends'),
            value: settings.autoplay,
            onChanged: (v) => music.setListeningSetting('autoplay', v),
          ),
          if (MusicDevice.android)
            ListTile(
              leading: const Icon(Icons.tune_rounded),
              title: const Text('Notification player'),
              subtitle: const Text('Choose your playback shortcuts'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () =>
                  _push(context, const NotificationPlayerSettingsScreen()),
            ),
          SwitchListTile(
            title: const Text('Gapless playback'),
            value: settings.gapless,
            onChanged: (v) => music.setListeningSetting('gapless', v),
          ),
          ListTile(
            title: Text('Crossfade · ${settings.crossfade} seconds'),
            subtitle: Slider(
              value: settings.crossfade.toDouble(),
              min: 0,
              max: 12,
              divisions: 12,
              label: '${settings.crossfade}s',
              onChanged: (v) =>
                  music.setListeningSetting('crossfade', v.toInt()),
            ),
          ),
          quality('Wi-Fi streaming quality', 'wifiQuality'),
          quality('Mobile streaming quality', 'mobileQuality'),
          quality('Download quality', 'downloadQuality'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Text(
              'Audio estimate: ${(settings.quality('downloadQuality').kbps * 240 / 8 / 1024).toStringAsFixed(1)} MB for a 4-minute track. Actual size varies; video streams may be larger.',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Text(
              'Available quality depends on each source. YouTube music downloads include video data.',
              style: TextStyle(fontSize: 12),
            ),
          ),
          if (MusicDevice.android)
            ListTile(
              leading: const Icon(Icons.equalizer),
              title: const Text('Equalizer & bass'),
              onTap: () => _push(context, const EqualizerScreen()),
            ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('Downloads & storage'),
            onTap: () => _push(context, const MusicDownloadsScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.sync),
            title: const Text('Sync library'),
            subtitle: Text(
              music.personal.syncError ??
                  (music.personal.cloudAvailable
                      ? 'Likes, playlists and listening activity sync to your account'
                      : 'Sign in to sync across devices'),
            ),
            trailing: music.personal.syncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: () => music.personal.syncNow(),
          ),
          if (settings.values['hiddenSongs'] != null ||
              music.personal.hiddenSongs.isNotEmpty ||
              music.personal.hiddenArtists.isNotEmpty)
            ListTile(
              title: const Text('Reset hidden songs & artists'),
              onTap: () {
                music.personal.hiddenSongs.clear();
                music.personal.hiddenArtists.clear();
                music.personal.setSetting('hiddenSongs', <String>[]);
                music.personal.setSetting('hiddenArtists', <String>[]);
              },
            ),
        ],
      ),
    );
  }
}

class EqualizerScreen extends StatefulWidget {
  const EqualizerScreen({super.key});
  @override
  State<EqualizerScreen> createState() => _EqualizerScreenState();
}

class _EqualizerScreenState extends State<EqualizerScreen> {
  Map<String, dynamic>? parameters;
  String? error;
  bool enabled = true;
  int bass = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final id = context
          .read<MusicController>()
          .playback
          .player
          .androidAudioSessionId;
      if (id == null) {
        setState(() => error = 'Start a song before opening the equalizer.');
        return;
      }
      try {
        final value = await MusicDevice.equalizer(id);
        if (mounted) {
          setState(() {
            parameters = value;
            enabled = value['enabled'] == true;
            bass = (value['bass'] as num? ?? 0).toInt();
          });
        }
      } catch (_) {
        if (mounted) {
          setState(
            () => error = 'Audio effects are unavailable on this device.',
          );
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Equalizer')),
    body: error != null
        ? Center(child: Text(error!))
        : parameters == null
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            children: [
              SwitchListTile(
                title: const Text('Equalizer'),
                value: enabled,
                onChanged: (v) {
                  setState(() => enabled = v);
                  MusicDevice.setEq(-1, 0, v);
                },
              ),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                children: [
                  for (final preset in {
                    'Flat': [0, 0, 0, 0, 0],
                    'Bass': [5, 4, 0, 0, 0],
                    'Vocal': [-2, 0, 4, 3, -1],
                    'Rock': [4, 2, -1, 2, 4],
                  }.entries)
                    ActionChip(
                      label: Text(preset.key),
                      onPressed: () {
                        final bands = parameters!['bands'] as List;
                        for (var i = 0; i < bands.length; i++) {
                          final gain = preset
                              .value[(i * 5 ~/ bands.length).clamp(0, 4)]
                              .toDouble();
                          (bands[i] as Map)['gain'] = gain;
                          MusicDevice.setEq(i, gain, enabled);
                        }
                        setState(() {});
                      },
                    ),
                ],
              ),
              for (final raw in parameters!['bands'] as List)
                Builder(
                  builder: (_) {
                    final band = raw as Map;
                    final index = (band['index'] as num).toInt();
                    return ListTile(
                      title: Text(
                        '${((band['frequency'] as num) / 1000).round()} Hz',
                      ),
                      subtitle: Slider(
                        value: (band['gain'] as num).toDouble().clamp(
                          (parameters!['min'] as num).toDouble(),
                          (parameters!['max'] as num).toDouble(),
                        ),
                        min: (parameters!['min'] as num).toDouble(),
                        max: (parameters!['max'] as num).toDouble(),
                        onChanged: enabled
                            ? (v) {
                                setState(() => band['gain'] = v);
                                MusicDevice.setEq(index, v, enabled);
                              }
                            : null,
                      ),
                    );
                  },
                ),
              ListTile(
                title: const Text('Bass boost'),
                subtitle: Slider(
                  value: bass.toDouble(),
                  min: 0,
                  max: 1000,
                  divisions: 10,
                  onChanged: (v) {
                    setState(() => bass = v.toInt());
                    MusicDevice.setBass(bass);
                  },
                ),
              ),
            ],
          ),
  );
}

class ListeningStatsScreen extends StatelessWidget {
  const ListeningStatsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final music = context.watch<MusicController>(),
        stats = music.personal.stats();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Your listening week'),
        actions: [
          IconButton(
            tooltip: 'Share recap',
            icon: const Icon(Icons.share_outlined),
            onPressed: () => _shareMusic(
              context,
              'My week on nexMusic 🎧\n${stats['minutes']} minutes · ${stats['uniqueTracks']} tracks\n${(stats['top'] as List).take(3).map((r) => (r['song'] as Map)['title']).join('\n')}',
            ),
          ),
        ],
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Wrap(
              spacing: 24,
              runSpacing: 12,
              children: [
                for (final e in {
                  'Minutes': stats['minutes'],
                  'Different tracks': stats['uniqueTracks'],
                  'Completed': stats['completed'],
                }.entries)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${e.value}',
                        style: const TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.w700,
                          color: NexMusic.violet,
                        ),
                      ),
                      Text(e.key),
                    ],
                  ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'Most listened',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
          for (final row in stats['top'] as List)
            ListTile(
              title: Text('${(row['song'] as Map)['title']}'),
              subtitle: Text('${(row['song'] as Map)['artist']}'),
              trailing: Text('${(row['ms'] as num).toInt() ~/ 60000} min'),
            ),
          if ((stats['topArtists'] as List).isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'Top artists',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
            for (final row in stats['topArtists'] as List)
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text('${row['artist']}'),
                trailing: Text('${(row['ms'] as num).toInt() ~/ 60000} min'),
              ),
          ],
          if ((stats['top'] as List).isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Listen to music to build your weekly recap.'),
            ),
        ],
      ),
    );
  }
}

class DeviceMusicScreen extends StatelessWidget {
  const DeviceMusicScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final music = context.watch<MusicController>(),
        tracks = music.personal.localTracks.values.toList();
    return _SongSelectionScaffold(
      songs: tracks,
      appBar: AppBar(
        title: const Text('Device music'),
        actions: [
          if (MusicDevice.android)
            IconButton(
              tooltip: 'Scan device music',
              icon: const Icon(Icons.refresh),
              onPressed: music.scanDeviceMusic,
            ),
          IconButton(
            tooltip: 'Import audio files',
            icon: const Icon(Icons.add),
            onPressed: () => _importDeviceAudio(context),
          ),
        ],
      ),
      body: tracks.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.folder_open, size: 48),
                  const SizedBox(height: 12),
                  const Text('Play your music without uploading it'),
                  const SizedBox(height: 16),
                  if (MusicDevice.android)
                    FilledButton(
                      onPressed: music.scanDeviceMusic,
                      child: const Text('Scan music'),
                    ),
                  OutlinedButton(
                    onPressed: () => _importDeviceAudio(context),
                    child: const Text('Import files'),
                  ),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: 80),
              children: [
                for (final folder
                    in tracks
                        .map((s) => s.localFolder)
                        .where((f) => f.isNotEmpty)
                        .toSet())
                  ExpansionTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(folder),
                    subtitle: const Text('Folder'),
                    children: [
                      for (final song in tracks.where(
                        (s) => s.localFolder == folder,
                      ))
                        SongTile(
                          song: song,
                          queue: tracks
                              .where((s) => s.localFolder == folder)
                              .toList(),
                        ),
                    ],
                  ),
                for (final artist
                    in tracks
                        .map((s) => s.artist)
                        .where((a) => a.isNotEmpty)
                        .toSet()
                        .take(20))
                  ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: Text(artist),
                    subtitle: const Text('Artist'),
                    onTap: () => _push(
                      context,
                      ArtistAlbumScreen(
                        song: tracks.firstWhere((s) => s.artist == artist),
                      ),
                    ),
                  ),
                for (final album
                    in tracks
                        .map((s) => s.album)
                        .where((a) => a.isNotEmpty)
                        .toSet()
                        .take(20))
                  ListTile(
                    leading: const Icon(Icons.album),
                    title: Text(album),
                    subtitle: const Text('Album'),
                    onTap: () => _push(
                      context,
                      ArtistAlbumScreen(
                        song: tracks.firstWhere((s) => s.album == album),
                        album: true,
                      ),
                    ),
                  ),
                for (final song in tracks) SongTile(song: song, queue: tracks),
              ],
            ),
    );
  }
}

Future<void> _importDeviceAudio(
  BuildContext context, {
  bool audiobook = false,
}) => _featureTask(context, () async {
  final music = context.read<MusicController>(), account = music.personal;
  final picked = await FilePicker.pickFiles(type: FileType.audio);
  if (picked.isEmpty) return;
  final documents = await getApplicationDocumentsDirectory();
  final folder = Directory('${documents.path}/local_music/${account.uid}');
  await folder.create(recursive: true);
  for (final file in picked) {
    if (file.path == null) continue;
    final id = newMusicId(), extension = file.extension ?? 'mp3';
    final copied = await File(file.path!).copy('${folder.path}/$id.$extension');
    final song = Song(
      id: 'local:$id',
      title: file.name.replaceFirst(RegExp(r'\.[^.]+$'), ''),
      kind: 'audio',
      url: copied.uri.toString(),
      sizeBytes: await file.length(),
      contentType: audiobook ? 'audiobook' : 'music',
      localFolder: 'Imported files',
    );
    if (audiobook) {
      account.longformTracks[song.id] = song;
    } else {
      account.localTracks[song.id] = song;
    }
  }
  account.changed();
  if (context.mounted) music.announce('Files imported to this device');
});

class LongformScreen extends StatelessWidget {
  const LongformScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final music = context.watch<MusicController>(),
        tracks = music.personal.longformTracks.values.toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Podcasts & audiobooks'),
        actions: [
          PopupMenuButton<String>(
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rss', child: Text('Add podcast feed')),
              PopupMenuItem(value: 'book', child: Text('Import audiobook')),
            ],
            onSelected: (value) async {
              if (value == 'book') {
                await _importDeviceAudio(context, audiobook: true);
                return;
              }
              final url = await _nameDialog(
                context,
                title: 'Podcast RSS link',
                action: 'Add',
              );
              if (url == null || !context.mounted) return;
              await _featureTask(context, () async {
                final feed = await loadPodcastFeed(url);
                music.personal.feeds[url] = feed.episodes
                    .map((s) => s.id)
                    .toList();
                music.personal.longformTracks.addEntries(
                  feed.episodes.map((s) => MapEntry(s.id, s)),
                );
                music.personal.changed();
              });
            },
          ),
        ],
      ),
      body: tracks.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Add a podcast RSS feed or import an audiobook. Your playback position is saved automatically.',
                ),
              ),
            )
          : ListView(
              children: [
                ListTile(
                  title: const Text('Playback speed'),
                  trailing: DropdownButton<double>(
                    value: music.playback.speed,
                    items: [
                      for (final value in {
                        0.5,
                        0.75,
                        1.0,
                        1.25,
                        1.5,
                        2.0,
                        music.playback.speed,
                      }.toList()..sort())
                        DropdownMenuItem(
                          value: value,
                          child: Text('${value}x'),
                        ),
                    ],
                    onChanged: (v) {
                      if (v != null) music.playback.setSpeed(v);
                    },
                  ),
                ),
                for (final song in tracks)
                  ListTile(
                    leading: const Icon(Icons.podcasts),
                    title: Text(song.title),
                    subtitle: Text(
                      '${song.artist}${music.personal.resumePositions[song.id] == null ? '' : ' · Resume ${_time(Duration(milliseconds: music.personal.resumePositions[song.id]!))}'}',
                    ),
                    onTap: () => music.play(song, from: tracks),
                    trailing: IconButton(
                      tooltip: 'More',
                      icon: const Icon(Icons.more_vert),
                      onPressed: () => _songActions(context, song),
                    ),
                  ),
              ],
            ),
    );
  }
}

part of 'music_ui.dart';

void _selectSong(BuildContext context, Song song, List<Song> queue) {
  final selection = context.read<SongSelection?>();
  if (selection == null) {
    _songActions(context, song);
  } else {
    selection.toggle(song, queue);
  }
}

Widget _songCheckbox(BuildContext context, Song song, List<Song> queue) {
  final selection = context.watch<SongSelection?>()!;
  return Checkbox(
    semanticLabel: 'Select ${song.title}',
    value: selection.contains(song),
    onChanged: selection.busy ? null : (_) => selection.toggle(song, queue),
  );
}

/// Keeps selection local to this route and resets it when the account changes.
class _SongSelectionScaffold extends StatelessWidget {
  const _SongSelectionScaffold({
    super.key,
    this.songs,
    this.playlistId,
    this.appBar,
    required this.body,
    this.bottomNavigationBar,
    this.floatingActionButton,
  });

  final List<Song>? songs;
  final String? playlistId;
  final PreferredSizeWidget? appBar;
  final Widget body;
  final Widget? bottomNavigationBar, floatingActionButton;

  @override
  Widget build(BuildContext context) => _SongSelectionHost(
    key: ObjectKey(context.select<MusicController, Object>((m) => m.personal)),
    scaffold: this,
  );
}

class _SongSelectionHost extends StatefulWidget {
  const _SongSelectionHost({super.key, required this.scaffold});
  final _SongSelectionScaffold scaffold;

  @override
  State<_SongSelectionHost> createState() => _SongSelectionHostState();
}

class _SongSelectionHostState extends State<_SongSelectionHost> {
  late final selection = SongSelection(songs: widget.scaffold.songs);

  @override
  void didUpdateWidget(_SongSelectionHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    selection.updateSongs(widget.scaffold.songs);
  }

  @override
  void dispose() {
    selection.dispose();
    super.dispose();
  }

  /// Song lists get the shell's random-play button, limited to their songs.
  Widget? _shuffleButton(List<Song>? songs) =>
      songs == null || !songs.any((s) => !s.isVideo)
      ? null
      : FloatingActionButton(
          tooltip: 'Play random',
          onPressed: () =>
              unawaited(context.read<MusicController>().playRandomFrom(songs)),
          child: const Icon(Icons.shuffle_rounded),
        );

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider.value(
    value: selection,
    child: Consumer<SongSelection>(
      builder: (context, selection, _) {
        final config = widget.scaffold;
        return PopScope(
          canPop: !selection.active,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && selection.active && !selection.busy) {
              selection.close();
            }
          },
          child: Scaffold(
            // Pages scroll on behind the floating mini player.
            extendBody: config.bottomNavigationBar != null,
            appBar: selection.active
                ? AppBar(
                    leading: IconButton(
                      tooltip: 'Cancel selection',
                      onPressed: selection.busy ? null : selection.close,
                      icon: const Icon(Icons.close),
                    ),
                    title: Text(
                      '${selection.selected.length} ${selection.selected.length == 1 ? 'song' : 'songs'} selected',
                    ),
                    titleTextStyle: Theme.of(context).textTheme.titleMedium,
                    actions: [
                      TextButton(
                        onPressed: selection.busy ? null : selection.selectAll,
                        child: Text(
                          selection.allSelected ? 'Clear' : 'Select all',
                        ),
                      ),
                    ],
                  )
                : config.appBar,
            body: config.body,
            floatingActionButton: selection.active
                ? null
                : config.floatingActionButton ?? _shuffleButton(config.songs),
            bottomNavigationBar: selection.active
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _SongSelectionBar(playlistId: config.playlistId),
                      if (config.bottomNavigationBar != null)
                        config.bottomNavigationBar!,
                    ],
                  )
                : config.bottomNavigationBar,
          ),
        );
      },
    ),
  );
}

class _SongSelectionBar extends StatefulWidget {
  const _SongSelectionBar({this.playlistId});
  final String? playlistId;

  @override
  State<_SongSelectionBar> createState() => _SongSelectionBarState();
}

class _SongSelectionBarState extends State<_SongSelectionBar> {
  SongFilePreparation? _sharePreparation;
  String? _shareProgress;
  double? _shareFraction;

  @override
  void dispose() {
    _sharePreparation?.cancel();
    super.dispose();
  }

  Future<void> shareAudio(MusicController music, List<Song> tracks) async {
    final account = music.personal;
    final songs = tracks.where((song) => !song.isVideo).toList();
    final preparation = SongFilePreparation(
      resolve: (song) => music.resolvedPlayableUrl(song, downloading: true),
      headers: music.playbackHeadersFor,
      maxBytes: account.settings.storageBudgetMb * 1024 * 1024,
      copyContentUri: (uri, _) async {
        final phone = music.phone;
        if (phone == null) {
          throw StateError('This device song could not be read.');
        }
        return phone.copyAudioToCache(uri);
      },
      extractAudio: (source) async {
        if (defaultTargetPlatform != TargetPlatform.android) {
          throw UnsupportedError(
            'Sharing audio from this container is available on Android.',
          );
        }
        final output =
            await const MethodChannel(
              'com.thenex.nexmusic/media_tools',
            ).invokeMethod<String>('extractAndTrimAudio', {
              'source': source.path,
              'startMs': 0,
              'endMs': 2147483647,
            });
        if (output == null) {
          throw StateError('The audio could not be extracted.');
        }
        return File(output);
      },
      beforeDownload: () async {
        if (account.settings.wifiOnly) {
          final network = await music.downloads.canDownloadOnCurrentNetwork();
          if (!network) {
            throw StateError(
              'Connect to Wi-Fi or turn off Wi-Fi-only downloads to share online audio.',
            );
          }
        }
      },
      onProgress: (song, index, total, fraction) {
        if (!mounted) return;
        setState(() {
          _shareProgress = 'Preparing audio ${index + 1}/$total: ${song.title}';
          _shareFraction = fraction == null ? null : (index + fraction) / total;
        });
      },
    );
    _sharePreparation = preparation;
    PreparedSongFiles? prepared;
    try {
      prepared = await preparation.prepare(songs);
      if (!mounted || account != music.personal) return;
      final render = context.findRenderObject();
      final origin = render is RenderBox
          ? render.localToGlobal(Offset.zero) & render.size
          : const Rect.fromLTWH(0, 0, 1, 1);
      setState(() => _shareProgress = 'Opening share sheet...');
      await SharePlus.instance.share(
        ShareParams(files: prepared.files, sharePositionOrigin: origin),
      );
    } finally {
      await prepared?.dispose();
      _sharePreparation = null;
      if (mounted) {
        setState(() {
          _shareProgress = null;
          _shareFraction = null;
        });
      }
    }
  }

  Future<void> run(
    Future<void> Function(MusicController, List<Song>) action,
  ) async {
    final selection = context.read<SongSelection>();
    final music = context.read<MusicController>();
    final tracks = selection.selected;
    if (selection.busy || tracks.isEmpty) return;
    selection.setBusy(true);
    try {
      await action(music, tracks);
      if (!selection.disposed) selection.close();
    } on SongShareCancelled {
      if (mounted) music.announce('Audio sharing cancelled');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (!selection.disposed) selection.setBusy(false);
    }
  }

  Future<void> more() async {
    final selection = context.read<SongSelection>();
    final music = context.read<MusicController>();
    final tracks = selection.selected;
    final account = music.personal;
    final playlist = widget.playlistId == null
        ? null
        : account.playlist(widget.playlistId!);
    final actions = <(String, String, IconData)>[
      if (tracks.any((s) => !s.isVideo)) ...[
        ('shuffle', 'Shuffle selected', Icons.shuffle),
        ('next', 'Play next', Icons.playlist_play),
      ],
      if (tracks.any((s) => !music.isLiked(s)))
        ('like', 'Like selected', Icons.favorite_border),
      if (tracks.any(music.isLiked))
        ('unlike', 'Unlike selected', Icons.favorite),
      if (!kIsWeb &&
          tracks.any((s) => !s.isLocal && !music.isSongDownloaded(s)))
        ('download', 'Download selected', Icons.download),
      if (!kIsWeb && tracks.any(music.isSongDownloaded))
        ('removeDownloads', 'Remove downloads', Icons.download_done),
      if (tracks.any((s) => !s.isVideo))
        ('share', 'Share selected songs', Icons.share_outlined)
      else
        ('shareVideos', 'Share selected video links', Icons.share_outlined),
      if (playlist != null && playlist.canEdit(account.uid))
        ('removePlaylist', 'Remove from playlist', Icons.playlist_remove),
    ];
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (value, title, icon) in actions)
                ListTile(
                  leading: Icon(icon),
                  title: Text(title),
                  onTap: () => Navigator.pop(sheet, value),
                ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || choice == null || account != music.personal) return;
    await run((music, tracks) async {
      switch (choice) {
        case 'shuffle':
          await music.playSelectedSongs(tracks, shuffle: true);
        case 'next':
          await music.addSongsToQueue(tracks, next: true);
        case 'like':
        case 'unlike':
          music.setSongsLiked(tracks, choice == 'like');
          music.announce(
            '${tracks.length} songs ${choice == 'like' ? 'liked' : 'unliked'}',
          );
        case 'download':
          await music.downloads.enqueue(tracks);
          music.announce(
            music.downloads.waitingMessage ??
                'Downloads queued. View progress in Downloads.',
          );
        case 'removeDownloads':
          for (final song in tracks.where(music.isSongDownloaded)) {
            await music.removeSongDownload(song);
          }
          music.announce('Selected downloads removed');
        case 'share':
          await shareAudio(music, tracks);
        case 'shareVideos':
          await _shareMusic(
            context,
            tracks
                .map(
                  (song) =>
                      '${song.title}${song.artist.isEmpty ? '' : ' — ${song.artist}'}${song.isLocal || song.isPrivate ? '' : '\n${_songShareLink(song)}'}',
                )
                .join('\n\n'),
          );
        case 'removePlaylist':
          if (playlist == null || !playlist.canEdit(account.uid)) return;
          final ids = tracks.map((s) => s.id).toSet();
          account.updatePlaylist(
            playlist,
            (p) => p.tracks.removeWhere((s) => ids.contains(s.id)),
          );
          music.announce('Selected songs removed from ${playlist.name}');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final selection = context.watch<SongSelection>();
    final selected = selection.selected;
    final enabled = selected.isNotEmpty && !selection.busy;
    Widget action(String label, IconData icon, VoidCallback? onPressed) =>
        Expanded(
          child: TextButton(
            onPressed: onPressed,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [Icon(icon), const SizedBox(height: 4), Text(label)],
            ),
          ),
        );
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selection.busy)
              LinearProgressIndicator(minHeight: 2, value: _shareFraction),
            if (_shareProgress != null)
              Padding(
                padding: const EdgeInsets.only(left: 16, right: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _shareProgress!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_sharePreparation != null)
                      TextButton(
                        onPressed: _sharePreparation!.cancel,
                        child: const Text('Cancel'),
                      ),
                  ],
                ),
              ),
            Row(
              children: [
                action(
                  'Play',
                  Icons.play_arrow,
                  enabled && selected.any((s) => !s.isVideo)
                      ? () => run(
                          (music, tracks) => music.playSelectedSongs(tracks),
                        )
                      : null,
                ),
                action(
                  'Queue',
                  Icons.queue_music,
                  enabled && selected.any((s) => !s.isVideo)
                      ? () => run(
                          (music, tracks) => music.addSongsToQueue(tracks),
                        )
                      : null,
                ),
                action(
                  'Playlist',
                  Icons.playlist_add,
                  enabled
                      ? () => _choosePlaylistsForSelection(context, selected)
                      : null,
                ),
                action('More', Icons.more_horiz, enabled ? more : null),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _choosePlaylistsForSelection(
  BuildContext context,
  List<Song> tracks,
) async {
  final music = context.read<MusicController>();
  final account = music.personal;
  final selection = context.read<SongSelection>();
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('New playlist'),
              onTap: () => Navigator.pop(sheet, 'new'),
            ),
            for (final playlist in account.playlists.where(
              (p) => p.canEdit(account.uid),
            ))
              ListTile(
                leading: _playlistCover(playlist.cover),
                title: Text(playlist.name),
                subtitle: Text('${playlist.tracks.length} tracks'),
                onTap: () => Navigator.pop(sheet, playlist.id),
              ),
          ],
        ),
      ),
    ),
  );
  if (!context.mounted || choice == null || account != music.personal) return;
  String? name;
  if (choice == 'new') {
    name = await _nameDialog(context, title: 'New playlist', action: 'Create');
    if (!context.mounted || name == null || account != music.personal) return;
  }
  await _featureTask(context, () async {
    if (choice == 'new') {
      account.createPlaylist(name!, tracks: tracks);
      music.announce('Playlist created with ${tracks.length} songs');
    } else {
      final playlist = account.playlist(choice);
      if (playlist == null || playlist.deleted) {
        throw StateError('This playlist is unavailable.');
      }
      account.addSongsToPlaylist(playlist, tracks);
      music.announce('Selected songs added to ${playlist.name}');
    }
    selection.close();
  });
}

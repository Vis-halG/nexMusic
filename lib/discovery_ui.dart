part of 'music_ui.dart';

class DiscoveryTools extends StatelessWidget {
  const DiscoveryTools({super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ActionChip(
          avatar: const Icon(Icons.swipe_up, size: 18),
          label: const Text('Music previews'),
          onPressed: () => _push(context, const MusicPreviewsScreen()),
        ),
        ActionChip(
          avatar: const Icon(Icons.explore_outlined, size: 18),
          label: const Text('Moods & languages'),
          onPressed: () => _push(context, const MusicDiscoveryScreen()),
        ),
        ActionChip(
          avatar: const Icon(Icons.auto_awesome, size: 18),
          label: const Text('Create a mix'),
          onPressed: () =>
              _push(context, const MusicDiscoveryScreen(prompt: true)),
        ),
        ActionChip(
          avatar: const Icon(Icons.mic, size: 18),
          label: const Text('Identify a song'),
          onPressed: () => _push(context, const RecognitionScreen()),
        ),
      ],
    ),
  );
}

class MusicDiscoveryScreen extends StatefulWidget {
  const MusicDiscoveryScreen({super.key, this.prompt = false});
  final bool prompt;
  @override
  State<MusicDiscoveryScreen> createState() => _MusicDiscoveryScreenState();
}

class _MusicDiscoveryScreenState extends State<MusicDiscoveryScreen> {
  final input = TextEditingController();
  List<Song> tracks = [];
  bool busy = false;
  String? error;
  int generation = 0;
  String language = 'Any', mood = 'Any';
  String? mixName;
  Future<void> discover() async {
    final request = ++generation, music = context.read<MusicController>();
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final description = widget.prompt
          ? MusicPrompt.parse(input.text)
          : MusicPrompt(
              '$language $mood music',
              language: language,
              mood: mood,
            );
      final result = await music.discovery.browse(
        query: description.query.replaceAll('Any', '').trim(),
      );
      final ranked = rankDiscovery(
        result.songs,
        accepts: music.personal.accepts,
        recent: music.recentSongs.map((s) => s.id).toSet(),
        language: description.language,
        feedback: Map<String, int>.from(
          music.personal.stats()['feedback'] as Map,
        ),
      ).take(description.limit).toList();
      music.library.rememberSongs(ranked);
      if (!mounted || request != generation) return;
      setState(() {
        tracks = ranked;
        mixName = description.query;
        busy = false;
        error = tracks.isEmpty
            ? 'No tracks found. Try a different mood or description.'
            : null;
      });
    } catch (e) {
      if (mounted && request == generation) {
        setState(() {
          busy = false;
          error = '$e';
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    final music = context.read<MusicController>();
    language = music.personal.settings.language;
    mood = music.personal.settings.mood;
    if (!widget.prompt) {
      WidgetsBinding.instance.addPostFrameCallback((_) => discover());
    }
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final music = context.watch<MusicController>();
    final visible = music.visibleSongs(tracks);
    return _SongSelectionScaffold(
      songs: visible,
      appBar: AppBar(
        title: Text(widget.prompt ? 'Create a mix' : 'Discover music'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                if (widget.prompt)
                  TextField(
                    controller: input,
                    maxLength: 300,
                    decoration: const InputDecoration(
                      hintText: '20 Hindi songs for a rainy night',
                      labelText: 'Describe your playlist',
                    ),
                    onSubmitted: (_) => discover(),
                  )
                else
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      DropdownButton<String>(
                        value: language,
                        items: [
                          for (final value in [
                            'Any',
                            'Hindi',
                            'English',
                            'Punjabi',
                            'Tamil',
                            'Telugu',
                            'Bengali',
                            'Marathi',
                            'Kannada',
                            'Malayalam',
                            'Gujarati',
                            'Bhojpuri',
                          ])
                            DropdownMenuItem(value: value, child: Text(value)),
                        ],
                        onChanged: (v) {
                          if (v != null) {
                            setState(() => language = v);
                            music.setListeningSetting('language', v);
                            discover();
                          }
                        },
                      ),
                      DropdownButton<String>(
                        value: mood,
                        items: [
                          for (final value in [
                            'Any',
                            'Romantic',
                            'Workout',
                            'Party',
                            'Focus',
                            'Sleep',
                            'Sad',
                            'Travel',
                            'Rainy',
                            'Night',
                            'Devotional',
                          ])
                            DropdownMenuItem(value: value, child: Text(value)),
                        ],
                        onChanged: (v) {
                          if (v != null) {
                            setState(() => mood = v);
                            music.setListeningSetting('mood', v);
                            discover();
                          }
                        },
                      ),
                    ],
                  ),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: busy ? null : discover,
                      icon: const Icon(Icons.auto_awesome),
                      label: const Text('Find tracks'),
                    ),
                    if (visible.isNotEmpty)
                      OutlinedButton.icon(
                        onPressed: () =>
                            music.play(visible.first, from: visible),
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Play'),
                      ),
                    if (visible.isNotEmpty)
                      OutlinedButton.icon(
                        onPressed: () => _featureTask(context, () async {
                          final p = music.personal.createPlaylist(
                            (mixName ?? 'My mix').substring(
                              0,
                              (mixName ?? 'My mix').length.clamp(0, 80),
                            ),
                            tracks: visible,
                          );
                          _push(context, PlaylistScreen(id: p.id));
                        }),
                        icon: const Icon(Icons.playlist_add),
                        label: const Text('Save mix'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Padding(padding: const EdgeInsets.all(16), child: Text(error!)),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 80),
              itemCount: visible.length,
              itemBuilder: (_, i) =>
                  _discoveryTile(context, visible[i], visible, explain: true),
            ),
          ),
        ],
      ),
    );
  }
}

Widget _discoveryTile(
  BuildContext context,
  Song song,
  List<Song> tracks, {
  bool explain = false,
}) => Builder(
  builder: (context) {
    final selection = context.watch<SongSelection?>();
    return ListTile(
      selected: selection?.contains(song) ?? false,
      selectedTileColor: NexMusic.violet.withValues(alpha: 0.12),
      leading: _Thumb(icon: Icons.music_note, imageUrl: song.artworkUrl),
      title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(song.artist),
      onTap: () => _openSong(context, song, queue: tracks),
      onLongPress: () => _selectSong(context, song, tracks),
      trailing: selection?.active == true
          ? _songCheckbox(context, song, tracks)
          : PopupMenuButton<String>(
              tooltip: 'Song options',
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'preview',
                  child: Text('Preview 30 seconds'),
                ),
                const PopupMenuItem(value: 'more', child: Text('More options')),
                if (explain)
                  const PopupMenuItem(
                    value: 'reason',
                    child: Text('Why this track?'),
                  ),
              ],
              onSelected: (value) {
                if (value == 'preview') {
                  _previewSong(context, song);
                } else if (value == 'reason') {
                  final music = context.read<MusicController>();
                  final settings = music.personal.settings;
                  final score =
                      (music.personal.stats()['feedback'] as Map)[song.id]
                          as int? ??
                      0;
                  _sheet(
                    context,
                    (_) => [
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(
                          [
                            'Found in the music catalogue for this search.',
                            if (settings.language != 'Any' &&
                                song.language.toLowerCase() ==
                                    settings.language.toLowerCase())
                              'Matches your ${settings.language} language preference.',
                            if (score > 0)
                              'You have completed this track recently.',
                            if (score < 0)
                              'Recent skips reduce this track’s priority.',
                            if (music.recentSongs.any((s) => s.id == song.id))
                              'Recently played tracks receive a lower priority to reduce repeats.',
                            'Hidden songs and artists are excluded from discovery mixes.',
                          ].join('\n\n'),
                        ),
                      ),
                    ],
                    title: 'Why this track?',
                  );
                } else {
                  _songActions(context, song);
                }
              },
            ),
    );
  },
);

Future<void> _previewSong(BuildContext context, Song song) =>
    _featureTask(context, () async {
      final music = context.read<MusicController>();
      if (!music.allowsSong(song)) return;
      final wasPlaying = music.playing;
      final restoreSong = music.current;
      final restorePosition = music.position;
      await music.pauseAudio();
      final player = AudioPlayer();
      Timer? stop;
      try {
        final url = song.previewUrl.isNotEmpty
            ? song.previewUrl
            : await music.resolvedPlayableUrl(song);
        if (!context.mounted) return;
        await player.setUrl(url, headers: music.audioHeadersFor(song, url));
        unawaited(player.play());
        stop = Timer(const Duration(seconds: 30), () => player.pause());
        if (context.mounted) {
          await showDialog<void>(
            context: context,
            builder: (dialog) => AlertDialog(
              title: Text(song.title),
              content: const Text('30-second preview'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialog),
                  child: const Text('Close'),
                ),
              ],
            ),
          );
        }
      } finally {
        stop?.cancel();
        await player.dispose();
        if (wasPlaying && restoreSong?.id == music.current?.id) {
          await music.seek(restorePosition);
          await music.playback.resume();
        }
      }
    });

class ArtistAlbumScreen extends StatefulWidget {
  const ArtistAlbumScreen({super.key, required this.song, this.album = false});
  final Song song;
  final bool album;
  @override
  State<ArtistAlbumScreen> createState() => _ArtistAlbumScreenState();
}

class _ArtistAlbumScreenState extends State<ArtistAlbumScreen> {
  List<Song> tracks = [];
  final _seenProviderIds = <String>{};
  bool busy = false, hasMore = true;
  int page = 0, request = 0;
  String? error;

  Future<List<Song>> _artistPage(
    MusicController music,
    Song seed,
    int nextPage,
  ) async {
    final result = await music.discovery.browse(
      query: widget.album ? '${seed.album} ${seed.artist}' : seed.artist,
      page: nextPage,
      limit: 50,
    );
    if (result.songs.isEmpty && result.unavailable.isNotEmpty) {
      throw StateError('The music provider is temporarily unavailable.');
    }
    return result.songs;
  }

  Future<void> load({bool more = false}) async {
    if (busy || (more && !hasMore)) return;
    final generation = ++request;
    final music = context.read<MusicController>(), seed = widget.song;
    final account = music.personal;
    final nextPage = more ? page + 1 : 1;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final local = more
          ? <Song>[]
          : widget.album
          ? music.allMusic
                .where(
                  (s) =>
                      s.album == seed.album &&
                      (seed.isLocal || s.artist == seed.artist),
                )
                .toList()
          : music.artistCategories
                    .where((a) => a.key == seed.artist.trim().toLowerCase())
                    .firstOrNull
                    ?.tracks ??
                <Song>[];
      final online = seed.isLocal
          ? <Song>[]
          : widget.album &&
                seed.albumId.isNotEmpty &&
                seed.providerId == 'jiosaavn'
          ? await music.catalog.album(seed)
          : await _artistPage(music, seed, nextPage);
      if (!mounted || generation != request || account != music.personal) {
        return;
      }
      if (!more) _seenProviderIds.clear();
      final fresh = online
          .where((s) => !_seenProviderIds.contains(s.id))
          .toList();
      _seenProviderIds.addAll(online.map((s) => s.id));
      final artist = normalizeMusicText(seed.artist);
      final matching = fresh.where(
        (s) =>
            widget.album ||
            songArtistNames(s).any((a) => normalizeMusicText(a) == artist),
      );
      final results = mergeMusicResults([
        if (more) tracks,
        local,
        matching.toList(),
      ]);
      music.library.rememberSongs(results);
      setState(() {
        tracks = results;
        page = nextPage;
        busy = false;
        hasMore = !widget.album && !seed.isLocal && fresh.isNotEmpty;
      });
    } catch (_) {
      if (mounted && generation == request) {
        setState(() {
          error = 'Could not load more tracks. Tap to retry.';
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
    request++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = context.watch<MusicController>().visibleSongs(tracks);
    return _SongSelectionScaffold(
      songs: visible,
      appBar: AppBar(
        title: Text(widget.album ? widget.song.album : widget.song.artist),
      ),
      body: Column(
        children: [
          if (busy) const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${visible.length} songs${hasMore ? ' · more available' : ''}',
                style: TextStyle(color: _muted(context), fontSize: 12),
              ),
            ),
          ),
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification.depth == 0 &&
                    notification.metrics.axis == Axis.vertical &&
                    notification.metrics.pixels > 0 &&
                    notification.metrics.extentAfter < 450 &&
                    !busy &&
                    hasMore &&
                    error == null) {
                  load(more: true);
                }
                return false;
              },
              child: ListView.builder(
                padding: const EdgeInsets.only(bottom: 80),
                itemCount: visible.length + 1,
                itemBuilder: (_, i) {
                  if (i < visible.length) {
                    return _discoveryTile(context, visible[i], visible);
                  }
                  if (error != null) {
                    return TextButton(
                      onPressed: () => load(more: page > 0),
                      child: Text(error!),
                    );
                  }
                  if (!hasMore) return const SizedBox.shrink();
                  return TextButton(
                    onPressed: busy ? null : () => load(more: true),
                    child: Text(busy ? 'Loading songs…' : 'Load more songs'),
                  );
                },
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: const MiniPlayer(),
    );
  }
}

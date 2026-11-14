part of 'music_ui.dart';

class MusicPreviewsScreen extends StatefulWidget {
  const MusicPreviewsScreen({super.key});
  @override
  State<MusicPreviewsScreen> createState() => _MusicPreviewsScreenState();
}

class _MusicPreviewsScreenState extends State<MusicPreviewsScreen> {
  final player = AudioPlayer();
  List<Song> tracks = [];
  Timer? timer;
  bool busy = true, fullPlay = false, resume = false;
  String? error;
  int generation = 0, index = 0;
  MusicController? music;
  String? previousId;
  Duration previousPosition = Duration.zero;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => load());
  }

  Future<void> load() async {
    final controller = context.read<MusicController>();
    music = controller;
    resume = controller.playing;
    previousId = controller.current?.id;
    previousPosition = controller.position;
    await controller.pauseAudio();
    final settings = controller.personal.settings;
    try {
      final result = await controller.discovery.browse(
        query:
            '${settings.language == 'Any' ? '' : settings.language} ${settings.mood == 'Any' ? '' : settings.mood} songs'
                .trim(),
        limit: 30,
      );
      final songs = result.songs
          .where(controller.personal.accepts)
          .where((s) => !s.isVideo)
          .toList();
      if (!mounted) return;
      setState(() {
        tracks = songs;
        busy = false;
      });
      if (songs.isNotEmpty) await preview(0);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = 'Could not load previews. Try again.';
          busy = false;
        });
      }
    }
  }

  Future<void> preview(int next) async {
    final request = ++generation;
    timer?.cancel();
    index = next;
    try {
      await player.pause();
      final song = tracks[next];
      final url = song.previewUrl.isNotEmpty
          ? song.previewUrl
          : await music!.resolvedPlayableUrl(song);
      if (!mounted || request != generation) return;
      await player.setUrl(url, headers: music!.audioHeadersFor(song, url));
      if (!mounted || request != generation) return;
      unawaited(player.play());
      timer = Timer(const Duration(seconds: 30), () => player.pause());
      setState(() => error = null);
    } catch (e) {
      if (mounted && request == generation) {
        setState(() => error = 'Preview unavailable. Swipe to the next track.');
      }
    }
  }

  @override
  void dispose() {
    ++generation;
    timer?.cancel();
    unawaited(player.dispose());
    final controller = music;
    if (!fullPlay &&
        resume &&
        controller != null &&
        controller.current?.id == previousId) {
      unawaited(
        controller
            .seek(previousPosition)
            .then((_) => controller.playback.resume()),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<MusicController>();
    return Scaffold(
      appBar: AppBar(title: const Text('Music previews')),
      body: busy
          ? const Center(child: _LoadingDots())
          : tracks.isEmpty
          ? Center(child: Text(error ?? 'No previews found.'))
          : PageView.builder(
              scrollDirection: Axis.vertical,
              itemCount: tracks.length,
              onPageChanged: preview,
              itemBuilder: (context, i) {
                final song = tracks[i];
                return LayoutBuilder(
                  builder: (context, box) => SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: box.maxHeight),
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _Thumb(
                              icon: Icons.music_note,
                              size: math
                                  .min(box.maxWidth - 48, box.maxHeight * 0.45)
                                  .clamp(80, 320),
                              imageUrl: song.artworkUrl,
                            ),
                            const SizedBox(height: 24),
                            Text(
                              song.title,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(song.artist, textAlign: TextAlign.center),
                            const SizedBox(height: 16),
                            Text(
                              error ??
                                  '30 seconds · Swipe up for another track',
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),
                            Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 12,
                              children: [
                                IconButton(
                                  tooltip: 'Like',
                                  icon: Icon(
                                    controller.isLiked(song)
                                        ? Icons.favorite
                                        : Icons.favorite_border,
                                  ),
                                  onPressed: () => controller.toggleLike(song),
                                ),
                                IconButton(
                                  tooltip: 'Add to playlist',
                                  icon: const Icon(Icons.playlist_add),
                                  onPressed: () =>
                                      _choosePlaylist(context, song),
                                ),
                                IconButton(
                                  tooltip: 'Restart preview',
                                  icon: const Icon(Icons.replay),
                                  onPressed: () => preview(i),
                                ),
                                FilledButton.icon(
                                  icon: const Icon(Icons.play_arrow),
                                  label: const Text('Play full song'),
                                  onPressed: () async {
                                    fullPlay = true;
                                    timer?.cancel();
                                    await player.pause();
                                    await controller.play(song, from: tracks);
                                    if (context.mounted) Navigator.pop(context);
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

part of 'music_ui.dart';

class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key});
  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  final _surfaceKey = GlobalKey();
  Timer? _volumeDismiss;
  double _swipeStart = 0, _swipeDistance = 0;
  double _volumeStart = 1, _volumeOrigin = 0, _volumeOriginX = 0;
  bool? _volumeHorizontal;
  bool _showVolume = false, _adjustingVolume = false, _skipping = false;

  Duration get _duration => MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 180);

  @override
  void dispose() {
    _volumeDismiss?.cancel();
    super.dispose();
  }

  void _swipeBegin(DragStartDetails details) {
    _volumeDismiss?.cancel();
    _swipeStart = details.globalPosition.dy;
    _swipeDistance = 0;
    unawaited(context.read<MusicController>().playback.warmAdjacent());
    if (_showVolume) setState(() => _showVolume = false);
  }

  void _swipeUpdate(DragUpdateDetails details) {
    _swipeDistance = details.globalPosition.dy - _swipeStart;
  }

  void _swipeEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final skip =
        _swipeDistance.abs() >= 36 ||
        (_swipeDistance.abs() >= 12 && velocity.abs() >= 450);
    final next = _swipeDistance < 0;
    _swipeDistance = 0;
    if (skip) unawaited(_skip(next));
  }

  Future<void> _skip(bool next) async {
    if (_skipping || _adjustingVolume) return;
    _volumeDismiss?.cancel();
    final music = context.read<MusicController>();
    setState(() {
      _skipping = true;
      _showVolume = false;
    });
    unawaited(HapticFeedback.selectionClick());
    try {
      if (next) {
        await music.next();
      } else {
        await music.previous(restartCurrent: false);
      }
    } catch (_) {
      if (mounted) music.announce('Could not change tracks. Try again.');
    } finally {
      if (mounted) setState(() => _skipping = false);
    }
  }

  void _volumeBegin(LongPressStartDetails details) {
    _volumeDismiss?.cancel();
    _swipeDistance = 0;
    _volumeStart = context.read<MusicController>().playback.volume;
    _volumeOrigin = details.globalPosition.dy;
    _volumeOriginX = details.globalPosition.dx;
    _volumeHorizontal = null;
    setState(() {
      _adjustingVolume = true;
      _showVolume = true;
    });
    unawaited(HapticFeedback.selectionClick());
  }

  void _volumeMove(LongPressMoveUpdateDetails details) {
    if (!_adjustingVolume) return;
    final travel = (MediaQuery.sizeOf(context).height * 0.32).clamp(
      180.0,
      280.0,
    );
    final dx = details.globalPosition.dx - _volumeOriginX;
    final dy = _volumeOrigin - details.globalPosition.dy;
    if (dx == 0 && dy == 0) return;
    _volumeHorizontal ??= dx.abs() > dy.abs();
    _setVolume(_volumeStart + (_volumeHorizontal! ? dx : dy) / travel);
  }

  void _volumeDragBegin(DragStartDetails details) {
    _volumeDismiss?.cancel();
    _volumeStart = context.read<MusicController>().playback.volume;
    _volumeOriginX = details.globalPosition.dx;
    setState(() => _adjustingVolume = true);
  }

  void _volumeDragUpdate(DragUpdateDetails details) {
    _setVolume(
      _volumeStart + (details.globalPosition.dx - _volumeOriginX) / 240,
    );
  }

  void _setVolume(double value) {
    final music = context.read<MusicController>();
    unawaited(
      music.playback.setVolume(value).catchError((Object _) {
        if (mounted) music.announce('Could not change volume. Try again.');
      }),
    );
  }

  void _volumeEnd() {
    if (!_adjustingVolume) return;
    setState(() => _adjustingVolume = false);
    _volumeDismiss?.cancel();
    _volumeDismiss = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _showVolume = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context
        .select<
          MusicController,
          ({
            Song? song,
            bool playing,
            bool loading,
            bool liked,
            String category,
            double volume,
          })
        >(
          (music) => (
            song: music.current,
            playing: music.playing,
            loading: music.loading,
            liked: music.current != null && music.isLiked(music.current!),
            category: music.current == null || music.current!.isPrivate
                ? 'Private library'
                : music.categoryName(music.current!.categoryId),
            volume: music.playback.volume,
          ),
        );
    final song = state.song;
    if (song == null) return const SizedBox.shrink();
    final music = context.read<MusicController>();
    final scheme = Theme.of(context).colorScheme;
    final textScaler = MediaQuery.textScalerOf(context);
    final rowHeight = math.max(
      66.0,
      textScaler.scale(13) * 1.5 + textScaler.scale(11) * 1.5 + 18,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
      child: Semantics(
        hint:
            'Swipe up for next song, down for previous. Hold, then slide left or right, or up and down, to adjust volume.',
        customSemanticsActions: {
          const CustomSemanticsAction(label: 'Next song'): () =>
              unawaited(_skip(true)),
          const CustomSemanticsAction(label: 'Previous song'): () =>
              unawaited(_skip(false)),
          const CustomSemanticsAction(label: 'Increase volume'): () =>
              _setVolume(state.volume + 0.05),
          const CustomSemanticsAction(label: 'Decrease volume'): () =>
              _setVolume(state.volume - 0.05),
        },
        child: Listener(
          onPointerCancel: (_) {
            _swipeDistance = 0;
            _volumeEnd();
          },
          child: GestureDetector(
            key: const ValueKey('mini-player-gestures'),
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            onVerticalDragStart: _swipeBegin,
            onVerticalDragUpdate: _swipeUpdate,
            onVerticalDragEnd: _swipeEnd,
            onVerticalDragCancel: () => _swipeDistance = 0,
            onLongPressStart: _volumeBegin,
            onLongPressMoveUpdate: _volumeMove,
            onLongPressEnd: (_) => _volumeEnd(),
            onLongPressCancel: _volumeEnd,
            onHorizontalDragStart: _showVolume ? _volumeDragBegin : null,
            onHorizontalDragUpdate: _showVolume ? _volumeDragUpdate : null,
            onHorizontalDragEnd: _showVolume ? (_) => _volumeEnd() : null,
            onHorizontalDragCancel: _showVolume ? _volumeEnd : null,
            child: TooltipTheme(
              data: TooltipTheme.of(
                context,
              ).copyWith(triggerMode: TooltipTriggerMode.manual),
              child: Material(
                key: _surfaceKey,
                color: _showVolume
                    ? Color.alphaBlend(
                        NexMusic.violet.withValues(alpha: 0.06),
                        scheme.surfaceContainerHigh,
                      )
                    : scheme.surfaceContainerHigh,
                shape: const StadiumBorder(),
                elevation: 6,
                animationDuration: _duration,
                shadowColor: Colors.black.withValues(alpha: 0.35),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () {
                    if (_showVolume) {
                      _volumeDismiss?.cancel();
                      setState(() => _showVolume = false);
                    } else {
                      final box = _surfaceKey.currentContext
                          ?.findRenderObject();
                      final origin = box is RenderBox && box.hasSize
                          ? box.localToGlobal(Offset.zero) & box.size
                          : null;
                      _openPlayer(
                        context,
                        origin: origin,
                        preview: _MiniPlayerPreview(
                          song: song,
                          subtitle: song.artist.isNotEmpty
                              ? song.artist
                              : state.category,
                          playing: state.playing,
                          liked: state.liked,
                        ),
                      );
                    }
                  },
                  child: SizedBox(
                    height: rowHeight,
                    child: AnimatedSwitcher(
                      duration: _duration,
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, animation) =>
                          FadeTransition(opacity: animation, child: child),
                      child: _showVolume
                          ? _MiniPlayerVolume(
                              key: const ValueKey('volume'),
                              volume: state.volume,
                            )
                          : Padding(
                              key: const ValueKey('track'),
                              padding: const EdgeInsets.fromLTRB(8, 7, 6, 7),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: ClipRect(
                                      child: AnimatedSwitcher(
                                        duration: _duration,
                                        switchInCurve: Curves.easeOutCubic,
                                        switchOutCurve: Curves.easeInCubic,
                                        layoutBuilder: (current, previous) =>
                                            Stack(
                                              alignment: Alignment.centerLeft,
                                              children: [
                                                for (final child in previous)
                                                  IgnorePointer(
                                                    child: ExcludeSemantics(
                                                      child: child,
                                                    ),
                                                  ),
                                                ?current,
                                              ],
                                            ),
                                        transitionBuilder: (child, animation) =>
                                            FadeTransition(
                                              opacity: animation,
                                              child: child,
                                            ),
                                        child: Row(
                                          key: ValueKey(song.id),
                                          children: [
                                            ClipOval(
                                              child: _Thumb(
                                                icon: Icons.music_note_rounded,
                                                imageUrl: song.artworkUrl,
                                                size: 44,
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.stretch,
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  Text(
                                                    song.title,
                                                    maxLines: 1,
                                                    softWrap: false,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      fontSize: 13,
                                                      height: 1.4,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 2),
                                                  Text(
                                                    song.artist.isNotEmpty
                                                        ? song.artist
                                                        : state.category,
                                                    maxLines: 1,
                                                    softWrap: false,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      color: scheme
                                                          .onSurfaceVariant,
                                                      fontSize: 11,
                                                      height: 1.4,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 44,
                                    height: 48,
                                    child: song.isPrivate
                                        ? null
                                        : IconButton(
                                            tooltip: state.liked
                                                ? 'Unlike'
                                                : 'Like',
                                            iconSize: 20,
                                            onPressed: () =>
                                                music.toggleLike(song),
                                            icon: Icon(
                                              state.liked
                                                  ? Icons.favorite_rounded
                                                  : Icons
                                                        .favorite_border_rounded,
                                              color: state.liked
                                                  ? NexMusic.violet
                                                  : scheme.onSurfaceVariant,
                                            ),
                                          ),
                                  ),
                                  SizedBox.square(
                                    dimension: 48,
                                    child: IconButton(
                                      key: const ValueKey('mini-player-play'),
                                      padding: EdgeInsets.zero,
                                      tooltip: state.playing ? 'Pause' : 'Play',
                                      iconSize: 44,
                                      onPressed: music.togglePlay,
                                      icon: Stack(
                                        alignment: Alignment.center,
                                        children: [
                                          Icon(
                                            state.playing
                                                ? Icons
                                                      .pause_circle_filled_rounded
                                                : Icons
                                                      .play_circle_filled_rounded,
                                            color: NexMusic.violet,
                                            size: 44,
                                          ),
                                          if (state.loading)
                                            const SizedBox.square(
                                              dimension: 48,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniPlayerPreview extends StatelessWidget {
  const _MiniPlayerPreview({
    required this.song,
    required this.subtitle,
    required this.playing,
    required this.liked,
  });
  final Song song;
  final String subtitle;
  final bool playing, liked;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 7, 6, 7),
    child: Row(
      children: [
        ClipOval(
          child: _Thumb(
            icon: Icons.music_note_rounded,
            imageUrl: song.artworkUrl,
            size: 44,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          width: 44,
          child: song.isPrivate
              ? null
              : Icon(
                  liked
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  size: 20,
                  color: liked
                      ? NexMusic.violet
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
        ),
        SizedBox(
          width: 48,
          child: Icon(
            playing
                ? Icons.pause_circle_filled_rounded
                : Icons.play_circle_filled_rounded,
            size: 44,
            color: NexMusic.violet,
          ),
        ),
      ],
    ),
  );
}

class _MiniPlayerVolume extends StatelessWidget {
  const _MiniPlayerVolume({super.key, required this.volume});
  final double volume;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final percent = '${(volume * 100).round()}%';
    return Semantics(
      label: 'Playback volume',
      value: percent,
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            Icon(
              volume == 0
                  ? Icons.volume_off_rounded
                  : volume < 0.5
                  ? Icons.volume_down_rounded
                  : Icons.volume_up_rounded,
              color: NexMusic.violet,
              size: 24,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      const Text(
                        'Volume',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        percent,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: volume,
                      minHeight: 4,
                      backgroundColor: scheme.outlineVariant.withValues(
                        alpha: 0.4,
                      ),
                      valueColor: const AlwaysStoppedAnimation(NexMusic.violet),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

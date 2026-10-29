part of 'music_ui.dart';

class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key});

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer>
    with SingleTickerProviderStateMixin {
  late final _drag = AnimationController.unbounded(vsync: this);
  Timer? _volumeDismiss;
  double _swipeStart = 0, _swipeDistance = 0;
  double _volumeStart = 1, _volumeOrigin = 0;
  double _direction = -1;
  bool _showVolume = false, _adjustingVolume = false, _skipping = false;

  Duration get _duration => MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 260);

  @override
  void dispose() {
    _volumeDismiss?.cancel();
    _drag.dispose();
    super.dispose();
  }

  void _settle() =>
      _drag.animateTo(0, duration: _duration, curve: Curves.easeOutCubic);

  void _swipeBegin(DragStartDetails details) {
    _volumeDismiss?.cancel();
    _drag.stop();
    _swipeStart = details.globalPosition.dy;
    _swipeDistance = 0;
    if (_showVolume) setState(() => _showVolume = false);
  }

  void _swipeUpdate(DragUpdateDetails details) {
    _swipeDistance = details.globalPosition.dy - _swipeStart;
    _drag.value = MediaQuery.disableAnimationsOf(context)
        ? 0
        : (_swipeDistance * 0.18).clamp(-14.0, 14.0);
  }

  void _swipeEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final skip =
        _swipeDistance.abs() >= 36 ||
        (_swipeDistance.abs() >= 12 && velocity.abs() >= 450);
    final next = _swipeDistance < 0;
    _swipeDistance = 0;
    _settle();
    if (skip) unawaited(_skip(next));
  }

  Future<void> _skip(bool next) async {
    if (_skipping || _adjustingVolume) return;
    _volumeDismiss?.cancel();
    final music = context.read<MusicController>();
    setState(() {
      _direction = next ? -1 : 1;
      _skipping = true;
      _showVolume = false;
    });
    unawaited(HapticFeedback.selectionClick());
    try {
      if (next) {
        await music.next();
      } else {
        // A downward swipe always asks for the previous track, even mid-song.
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
    _settle();
    _volumeStart = context.read<MusicController>().playback.volume;
    _volumeOrigin = details.globalPosition.dy;
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
    _setVolume(
      _volumeStart + (_volumeOrigin - details.globalPosition.dy) / travel,
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
    _volumeDismiss = Timer(const Duration(milliseconds: 650), () {
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
            Duration duration,
            String category,
            double volume,
          })
        >(
          (music) => (
            song: music.current,
            playing: music.playing,
            loading: music.loading,
            liked: music.current != null && music.isLiked(music.current!),
            duration: music.duration,
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
      62.0,
      textScaler.scale(13) * 1.5 + textScaler.scale(11) * 1.5 + 18,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
      child: Semantics(
        hint:
            'Swipe up for next song, down for previous. Hold, then slide up or down to adjust volume.',
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
            _settle();
          },
          child: GestureDetector(
            key: const ValueKey('mini-player-gestures'),
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            onVerticalDragStart: _swipeBegin,
            onVerticalDragUpdate: _swipeUpdate,
            onVerticalDragEnd: _swipeEnd,
            onVerticalDragCancel: _settle,
            onLongPressStart: _volumeBegin,
            onLongPressMoveUpdate: _volumeMove,
            onLongPressEnd: (_) => _volumeEnd(),
            onLongPressCancel: _volumeEnd,
            child: AnimatedScale(
              scale: _adjustingVolume ? 1.015 : 1,
              duration: _duration,
              curve: Curves.easeOutCubic,
              child: TooltipTheme(
                data: TooltipTheme.of(
                  context,
                ).copyWith(triggerMode: TooltipTriggerMode.manual),
                child: Material(
                  color: _showVolume
                      ? Color.alphaBlend(
                          NexMusic.violet.withValues(alpha: 0.06),
                          scheme.surfaceContainerHigh,
                        )
                      : scheme.surfaceContainerHigh,
                  shape: const StadiumBorder(),
                  elevation: _adjustingVolume ? 8 : 6,
                  animationDuration: _duration,
                  shadowColor: Colors.black.withValues(alpha: 0.35),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () {
                      if (_showVolume) {
                        _volumeDismiss?.cancel();
                        setState(() => _showVolume = false);
                      } else {
                        _openPlayer(context);
                      }
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          height: rowHeight,
                          child: AnimatedSwitcher(
                            duration: _duration,
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            layoutBuilder: (current, previous) => Stack(
                              alignment: Alignment.center,
                              children: [
                                for (final child in previous)
                                  IgnorePointer(
                                    child: ExcludeSemantics(child: child),
                                  ),
                                ?current,
                              ],
                            ),
                            transitionBuilder: (child, animation) =>
                                FadeTransition(
                                  opacity: animation,
                                  child: ScaleTransition(
                                    scale: Tween(
                                      begin: 0.97,
                                      end: 1.0,
                                    ).animate(animation),
                                    child: child,
                                  ),
                                ),
                            child: _showVolume
                                ? _MiniPlayerVolume(
                                    key: const ValueKey('volume'),
                                    volume: state.volume,
                                  )
                                : Padding(
                                    key: const ValueKey('track'),
                                    padding: const EdgeInsets.fromLTRB(
                                      8,
                                      7,
                                      6,
                                      7,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: AnimatedBuilder(
                                            animation: _drag,
                                            builder: (_, child) =>
                                                Transform.translate(
                                                  offset: Offset(
                                                    0,
                                                    _drag.value,
                                                  ),
                                                  child: child,
                                                ),
                                            child: ClipRect(
                                              child: AnimatedSwitcher(
                                                duration: _duration,
                                                switchInCurve:
                                                    Curves.easeOutCubic,
                                                switchOutCurve:
                                                    Curves.easeInCubic,
                                                transitionBuilder: (child, animation) {
                                                  final incoming =
                                                      child.key ==
                                                      ValueKey(song.id);
                                                  return FadeTransition(
                                                    opacity: animation,
                                                    child: SlideTransition(
                                                      position: Tween(
                                                        begin: Offset(
                                                          0,
                                                          (incoming
                                                                  ? -_direction
                                                                  : _direction) *
                                                              0.3,
                                                        ),
                                                        end: Offset.zero,
                                                      ).animate(animation),
                                                      child: child,
                                                    ),
                                                  );
                                                },
                                                child: Row(
                                                  key: ValueKey(song.id),
                                                  children: [
                                                    ClipOval(
                                                      child: _Thumb(
                                                        icon: song.isVideo
                                                            ? Icons
                                                                  .play_arrow_rounded
                                                            : Icons
                                                                  .music_note_rounded,
                                                        imageUrl:
                                                            song.artworkUrl,
                                                        size: 44,
                                                      ),
                                                    ),
                                                    const SizedBox(width: 12),
                                                    Expanded(
                                                      child: Column(
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .start,
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          Text(
                                                            song.title,
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style:
                                                                const TextStyle(
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w600,
                                                                  fontSize: 13,
                                                                ),
                                                          ),
                                                          const SizedBox(
                                                            height: 2,
                                                          ),
                                                          Text(
                                                            song
                                                                    .artist
                                                                    .isNotEmpty
                                                                ? song.artist
                                                                : state
                                                                      .category,
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style: TextStyle(
                                                              color: scheme
                                                                  .onSurfaceVariant,
                                                              fontSize: 11,
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
                                        ),
                                        if (!song.isProvider)
                                          IconButton(
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
                                        if (song.providerId.startsWith('yt'))
                                          IconButton(
                                            tooltip: 'Watch Video',
                                            iconSize: 22,
                                            visualDensity:
                                                VisualDensity.compact,
                                            onPressed: () =>
                                                _openSongVideo(context, song),
                                            icon: const Icon(
                                              Icons.smart_display_rounded,
                                              color: NexMusic.violet,
                                            ),
                                          ),
                                        IconButton(
                                          tooltip: state.playing
                                              ? 'Pause'
                                              : 'Play',
                                          iconSize: 30,
                                          onPressed: music.togglePlay,
                                          icon: state.loading
                                              ? const SizedBox.square(
                                                  dimension: 20,
                                                  child:
                                                      CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                      ),
                                                )
                                              : Icon(
                                                  state.playing
                                                      ? Icons
                                                            .pause_circle_filled_rounded
                                                      : Icons
                                                            .play_circle_filled_rounded,
                                                  color: NexMusic.violet,
                                                ),
                                        ),
                                      ],
                                    ),
                                  ),
                          ),
                        ),
                        ValueListenableBuilder<Duration>(
                          valueListenable: music.positionListenable,
                          builder: (_, position, _) {
                            final total = state.duration.inMilliseconds;
                            final value = total <= 0
                                ? 0.0
                                : (position.inMilliseconds / total).clamp(
                                    0.0,
                                    1.0,
                                  );
                            return Padding(
                              padding: const EdgeInsets.fromLTRB(28, 0, 28, 4),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: LinearProgressIndicator(
                                  value: value,
                                  minHeight: 2.5,
                                  backgroundColor: scheme.outlineVariant
                                      .withValues(alpha: 0.3),
                                  valueColor: const AlwaysStoppedAnimation(
                                    NexMusic.violet,
                                  ),
                                ),
                              ),
                            );
                          },
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
    );
  }
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
            const SizedBox(width: 12),
            Icon(
              Icons.unfold_more_rounded,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

part of 'music_ui.dart';

typedef _MiniTrack = ({
  Song song,
  String subtitle,
  bool playing,
  bool liked,
  bool loading,
});

class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key});
  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer>
    with SingleTickerProviderStateMixin {
  final _surfaceKey = GlobalKey();
  late final _motion = AnimationController.unbounded(vsync: this);
  final _pendingSwipes = <bool>[];
  Timer? _volumeDismiss;
  double _swipeStart = 0, _swipeDistance = 0, _cardHeight = 66;
  double _volumeStart = 1, _volumeOrigin = 0, _volumeOriginX = 0;
  bool? _volumeHorizontal;
  bool _showVolume = false,
      _adjustingVolume = false,
      _draining = false,
      _queuedGesture = false;
  _MiniTrack? _departing;
  Song? _target;

  Duration get _duration => MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 180);

  _MiniTrack _track(MusicController music, Song song) => (
    song: song,
    subtitle: song.artist.isNotEmpty
        ? song.artist
        : song.isPrivate
        ? 'Private library'
        : music.categoryName(song.categoryId),
    playing: music.playing,
    liked: music.isLiked(song),
    loading: music.loading,
  );

  @override
  void dispose() {
    _volumeDismiss?.cancel();
    _pendingSwipes.clear();
    _motion.dispose();
    super.dispose();
  }

  Future<void> _animate(double value) async {
    if (!mounted) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _motion.value = value;
      return;
    }
    await _motion
        .animateTo(value, duration: _duration, curve: Curves.easeOutCubic)
        .orCancel;
  }

  Future<void> _settle() async {
    if (_draining || !mounted) return;
    try {
      await _animate(0);
    } on TickerCanceled {
      return;
    }
    if (mounted && !_draining) {
      setState(() {
        _departing = null;
        _target = null;
      });
    }
  }

  void _swipeBegin(DragStartDetails details) {
    _volumeDismiss?.cancel();
    _swipeStart = details.globalPosition.dy;
    _swipeDistance = 0;
    _queuedGesture = _draining;
    if (_draining) return;
    _motion.stop();
    final music = context.read<MusicController>();
    setState(() {
      _showVolume = false;
      _departing = music.current == null ? null : _track(music, music.current!);
      _target = null;
    });
    unawaited(music.playback.warmAdjacent());
  }

  void _swipeUpdate(DragUpdateDetails details) {
    _swipeDistance = details.globalPosition.dy - _swipeStart;
    if (_queuedGesture || _draining) return;
    final music = context.read<MusicController>();
    final target = music.playback.queue.swipeTarget(next: _swipeDistance < 0);
    if (_target?.id != target?.id) setState(() => _target = target);
    _motion.value = MediaQuery.disableAnimationsOf(context)
        ? 0
        : (_swipeDistance * 0.7).clamp(-_cardHeight, _cardHeight);
  }

  void _swipeEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final skip =
        _swipeDistance.abs() >= 30 ||
        (_swipeDistance.abs() >= 12 && velocity.abs() >= 450);
    final next = _swipeDistance < 0;
    _swipeDistance = 0;
    if (skip) {
      unawaited(_skip(next));
    } else if (!_queuedGesture) {
      unawaited(_settle());
    }
    _queuedGesture = false;
  }

  Future<void> _skip(bool next) async {
    if (_adjustingVolume) return;
    _pendingSwipes.add(next);
    if (_draining) return;
    _draining = true;
    _volumeDismiss?.cancel();
    final music = context.read<MusicController>();
    try {
      while (mounted && _pendingSwipes.isNotEmpty) {
        final direction = _pendingSwipes.removeAt(0);
        final target = music.playback.queue.swipeTarget(next: direction);
        if (target == null ||
            !music.allowsSong(target) ||
            music.current == null) {
          await _animate(0);
          if (mounted) {
            setState(() {
              _departing = null;
              _target = null;
            });
          }
          continue;
        }
        setState(() {
          _departing ??= _track(music, music.current!);
          _target = target;
          _showVolume = false;
        });
        final switching = music.playback.swipeTo(target, backwards: !direction);
        await _animate((direction ? -1 : 1) * _cardHeight * 1.15);
        final switched = await switching;
        if (!mounted) return;
        if (switched && music.current?.id == target.id) {
          unawaited(HapticFeedback.selectionClick());
          setState(() {
            _departing = null;
            _target = null;
            _motion.value = 0;
          });
        } else {
          await _animate(0);
          if (mounted) {
            setState(() {
              _departing = null;
              _target = null;
            });
          }
        }
      }
    } on TickerCanceled {
      // The player route was removed during its animation.
    } catch (_) {
      if (mounted) {
        music.announce('Could not change tracks. Try again.');
        _motion.value = 0;
        setState(() {
          _departing = null;
          _target = null;
        });
      }
    } finally {
      _draining = false;
    }
  }

  void _volumeBegin(LongPressStartDetails details) {
    if (_draining) return;
    _volumeDismiss?.cancel();
    _motion.stop();
    _motion.value = 0;
    _swipeDistance = 0;
    _volumeStart = context.read<MusicController>().playback.volume;
    _volumeOrigin = details.globalPosition.dy;
    _volumeOriginX = details.globalPosition.dx;
    _volumeHorizontal = null;
    setState(() {
      _departing = null;
      _target = null;
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

  void _volumeDragUpdate(DragUpdateDetails details) => _setVolume(
    _volumeStart + (details.globalPosition.dx - _volumeOriginX) / 240,
  );

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
    _volumeDismiss = Timer(const Duration(seconds: 1), () {
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
            Song? next,
            Song? previous,
            bool playing,
            bool loading,
            bool liked,
            String subtitle,
            double volume,
          })
        >(
          (music) => (
            song: music.current,
            next: music.playback.queue.swipeTarget(next: true),
            previous: music.playback.queue.swipeTarget(next: false),
            playing: music.playing,
            loading: music.loading,
            liked: music.current != null && music.isLiked(music.current!),
            subtitle: music.current == null
                ? ''
                : music.songSource(music.current!),
            volume: music.playback.volume,
          ),
        );
    final song = state.song;
    if (song == null) return const SizedBox.shrink();
    final music = context.read<MusicController>();
    final scheme = Theme.of(context).colorScheme;
    final textScaler = MediaQuery.textScalerOf(context);
    final rowHeight = _cardHeight = math.max(
      66.0,
      textScaler.scale(13) * 1.5 + textScaler.scale(11) * 1.5 + 18,
    );
    final foreground = _departing ?? _track(music, song);
    final behind = _target ?? state.next ?? state.previous;
    final front = SizedBox(
      key: const ValueKey('mini-player-current-card'),
      height: rowHeight,
      child: Material(
        key: _surfaceKey,
        color: scheme.surfaceContainerHigh,
        shape: const StadiumBorder(),
        elevation: 6,
        shadowColor: Colors.black.withValues(alpha: 0.25),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            if (_draining || _departing != null) return;
            if (_showVolume) {
              _volumeDismiss?.cancel();
              setState(() => _showVolume = false);
              return;
            }
            final box = _surfaceKey.currentContext?.findRenderObject();
            final origin = box is RenderBox && box.hasSize
                ? box.localToGlobal(Offset.zero) & box.size
                : null;
            _openPlayer(
              context,
              origin: origin,
              preview: _MiniPlayerPreview(
                song: song,
                subtitle: foreground.subtitle,
                playing: state.playing,
                liked: state.liked,
              ),
            );
          },
          child: AnimatedSwitcher(
            duration: _duration,
            child: _showVolume
                ? _MiniPlayerVolume(
                    key: const ValueKey('volume'),
                    volume: state.volume,
                  )
                : IgnorePointer(
                    ignoring: _draining || _departing != null,
                    child: _MiniPlayerFace(
                      song: foreground.song,
                      subtitle: foreground.subtitle,
                      playing: foreground.playing,
                      liked: foreground.liked,
                      loading: foreground.loading,
                      onLike: () => music.toggleLike(foreground.song),
                      onPlay: music.togglePlay,
                    ),
                  ),
          ),
        ),
      ),
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
            unawaited(_settle());
          },
          child: GestureDetector(
            key: const ValueKey('mini-player-gestures'),
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            onVerticalDragStart: _swipeBegin,
            onVerticalDragUpdate: _swipeUpdate,
            onVerticalDragEnd: _swipeEnd,
            onVerticalDragCancel: () => unawaited(_settle()),
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
              child: SizedBox(
                height: rowHeight + 10,
                child: AnimatedBuilder(
                  animation: _motion,
                  child: front,
                  builder: (context, child) {
                    final reduced = MediaQuery.disableAnimationsOf(context);
                    final motion = reduced ? 0.0 : _motion.value;
                    final progress = (motion.abs() / rowHeight).clamp(0.0, 1.0);
                    return Stack(
                      key: const ValueKey('mini-player-deck'),
                      clipBehavior: Clip.none,
                      children: [
                        if (behind != null && !_showVolume) ...[
                          Positioned(
                            top: 10,
                            left: 16,
                            right: 16,
                            height: rowHeight,
                            child: ExcludeSemantics(
                              child: IgnorePointer(
                                child: DecoratedBox(
                                  decoration: ShapeDecoration(
                                    shape: const StadiumBorder(),
                                    color: Color.alphaBlend(
                                      NexMusic.violet.withValues(alpha: 0.07),
                                      scheme.surfaceContainerHigh,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            top: 6 * (1 - progress),
                            left: 8 * (1 - progress),
                            right: 8 * (1 - progress),
                            height: rowHeight,
                            child: ExcludeSemantics(
                              child: IgnorePointer(
                                child: Opacity(
                                  opacity: 0.7 + 0.3 * progress,
                                  child: RepaintBoundary(
                                    child: Material(
                                      key: const ValueKey(
                                        'mini-player-upcoming-card',
                                      ),
                                      shape: const StadiumBorder(),
                                      clipBehavior: Clip.antiAlias,
                                      color: scheme.surfaceContainerHigh,
                                      child: _MiniPlayerFace(
                                        song: behind,
                                        subtitle: _track(
                                          music,
                                          behind,
                                        ).subtitle,
                                        playing: _draining,
                                        liked: music.isLiked(behind),
                                        loading: _draining && state.loading,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                        Transform.translate(
                          key: const ValueKey('mini-player-card-motion'),
                          offset: Offset(0, motion),
                          child: Opacity(
                            key: const ValueKey('mini-player-card-opacity'),
                            opacity: 1 - progress,
                            child: RepaintBoundary(child: child),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniPlayerFace extends StatelessWidget {
  const _MiniPlayerFace({
    required this.song,
    required this.subtitle,
    required this.playing,
    required this.liked,
    this.loading = false,
    this.onLike,
    this.onPlay,
  });
  final Song song;
  final String subtitle;
  final bool playing, liked, loading;
  final VoidCallback? onLike, onPlay;
  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
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
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  strutStyle: const StrutStyle(
                    fontSize: 13,
                    height: 1.4,
                    forceStrutHeight: true,
                  ),
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
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  strutStyle: const StrutStyle(
                    fontSize: 11,
                    height: 1.4,
                    forceStrutHeight: true,
                  ),
                  style: TextStyle(color: muted, fontSize: 11, height: 1.4),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 44,
            height: 48,
            child: song.isPrivate
                ? null
                : onLike == null
                ? Icon(
                    liked
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    size: 20,
                    color: liked ? NexMusic.violet : muted,
                  )
                : IconButton(
                    tooltip: liked ? 'Unlike' : 'Like',
                    iconSize: 20,
                    onPressed: onLike,
                    icon: Icon(
                      liked
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      color: liked ? NexMusic.violet : muted,
                    ),
                  ),
          ),
          SizedBox.square(
            dimension: 48,
            child: onPlay == null
                ? _playIcon()
                : IconButton(
                    key: const ValueKey('mini-player-play'),
                    padding: EdgeInsets.zero,
                    tooltip: playing ? 'Pause' : 'Play',
                    iconSize: 44,
                    onPressed: onPlay,
                    icon: _playIcon(),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _playIcon() => Stack(
    alignment: Alignment.center,
    children: [
      Icon(
        playing
            ? Icons.pause_circle_filled_rounded
            : Icons.play_circle_filled_rounded,
        size: 44,
        color: NexMusic.violet,
      ),
      if (loading)
        const SizedBox.square(
          dimension: 48,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
    ],
  );
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
  Widget build(BuildContext context) => _MiniPlayerFace(
    song: song,
    subtitle: subtitle,
    playing: playing,
    liked: liked,
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

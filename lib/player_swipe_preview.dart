part of 'music_ui.dart';

/// Browses a private queue while gestures animate; only the final choice reaches
/// the audio player after the listener has lifted their finger and settled.
class _PlayerSwipePreview {
  _PlayerSwipePreview(this.music, this.onChanged) {
    music.addListener(_validate);
  }

  final MusicController music;
  final VoidCallback onChanged;
  ListeningQueue? _preview;
  String? _origin, _committing;
  Object? _account;
  List<String> _ids = [], _history = [];
  bool _shuffle = false, _backwards = false;
  MusicRepeat _repeat = MusicRepeat.off;
  final _pointers = <int>{};
  Timer? _timer;
  bool _released = false, _idle = false;
  int _revision = 0;
  bool _animating = false, _disposed = false;

  Song? get song => _preview?.current;
  bool get active => _preview != null;

  void begin() {
    if (_preview != null || music.current == null) return;
    final queue = music.playback.queue;
    _preview = ListeningQueue()..restore(queue.toJson());
    // Persistence deliberately strips expiring URLs. Keep the actual objects
    // for previews and leave both the real queue and its history untouched.
    _preview!.tracks
      ..clear()
      ..addAll(queue.tracks);
    _origin = music.current!.id;
    _account = music.personal;
    _ids = queue.tracks.map((song) => song.id).toList();
    _history = List.of(queue.history);
    _shuffle = queue.shuffled;
    _repeat = queue.repeat;
  }

  Song? target(bool next) {
    begin();
    return _preview?.swipeTarget(next: next);
  }

  Song? step(bool next) {
    final candidate = target(next);
    if (candidate == null || !music.allowsSong(candidate)) return null;
    final queue = _preview!;
    if (!next && queue.peekPrevious()?.id == candidate.id) {
      queue.previous();
    } else {
      queue.select(candidate);
    }
    _backwards = !next && _history.contains(candidate.id);
    onChanged();
    _schedule();
    return candidate;
  }

  void pointerDown(int pointer) {
    _pointers.add(pointer);
    _revision++;
    _timer?.cancel();
    _released = false;
    _idle = false;
  }

  void pointerUp(int pointer) {
    if (!_pointers.remove(pointer)) return;
    if (_pointers.isNotEmpty) return;
    _startDelay();
  }

  void animating(bool value) {
    _animating = value;
    if (!value) _schedule();
  }

  // Accessibility actions have no pointer events.
  void release() {
    if (_pointers.isEmpty && !_released) _startDelay();
  }

  void _startDelay() {
    _released = true;
    _idle = false;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 500), () {
      _idle = true;
      _schedule();
    });
  }

  bool get _valid {
    final queue = music.playback.queue;
    return _account == music.personal &&
        (music.current?.id == _origin || music.current?.id == _committing) &&
        listEquals(_ids, queue.tracks.map((song) => song.id).toList()) &&
        _shuffle == queue.shuffled &&
        _repeat == queue.repeat;
  }

  void _validate() {
    if (active && !_valid) cancel();
  }

  void _schedule() {
    if (_disposed || !active || _pointers.isNotEmpty || !_idle || _animating) {
      return;
    }
    _idle = false;
    unawaited(_commit());
  }

  Future<void> _commit() async {
    if (_disposed || _pointers.isNotEmpty || _animating || !active) return;
    final targetId = song?.id;
    if (!_valid || targetId == music.current?.id) {
      cancel();
      return;
    }
    final target = music.playback.queue.tracks
        .where((song) => song.id == targetId)
        .firstOrNull;
    if (target == null || !music.allowsSong(target)) {
      cancel();
      return;
    }
    final revision = ++_revision;
    _committing = target.id;
    bool isCurrent() => !_disposed && revision == _revision && _valid;
    final switched = await music.playback.swipeTo(
      target,
      backwards: _backwards,
      isCurrent: isCurrent,
    );
    if (!isCurrent()) return;
    if (switched && music.current?.id == target.id) {
      unawaited(HapticFeedback.selectionClick());
    }
    cancel();
  }

  void cancel() {
    _revision++;
    _timer?.cancel();
    _preview = null;
    _committing = null;
    _released = false;
    _idle = false;
    if (!_disposed) onChanged();
  }

  void dispose() {
    _disposed = true;
    _revision++;
    _timer?.cancel();
    music.removeListener(_validate);
  }
}

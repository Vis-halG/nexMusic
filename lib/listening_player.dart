import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'listening_models.dart';
import 'music_data.dart';

typedef MusicSourceResolver = Future<AudioSource> Function(Song song);

/// Owns actual playback, preloading, transitions and traversal independently of UI.
class ListeningPlayer extends ChangeNotifier {
  ListeningPlayer({
    required this._player,
    required this.resolve,
    required this.settings,
    required this.onTrack,
    required this.onListening,
    required this.onError,
    this.onPlayerChanged,
    this.onQueueSaved,
    this.onQueueEnd,
    this.onAudioSession,
    this.canPlay,
  }) {
    _attach();
    _clock = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
  }
  AudioPlayer _player;
  AudioPlayer get player => _player;
  final MusicSourceResolver resolve;
  final ListeningSettings Function() settings;
  final void Function(Song song) onTrack;
  final void Function(Song song, int ms, {bool skipped, bool completed})
  onListening;
  final void Function(String message) onError;
  final void Function(AudioPlayer player)? onPlayerChanged;
  final void Function()? onQueueSaved;
  final Future<void> Function()? onQueueEnd;
  final void Function(int)? onAudioSession;
  final bool Function(Song)? canPlay;
  bool _allowed(Song song) => canPlay?.call(song) ?? true;
  final ListeningQueue queue = ListeningQueue();
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);
  Duration restoredPosition = Duration.zero;
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _clock;
  DateTime? sleepAt;
  bool sleepAfterTrack = false, sleepFade = true;
  double speed = 1;
  double _volume = 1, _fadeProgress = 0;
  double get volume => _volume;

  double get _sleepGain {
    final remaining = sleepAt?.difference(DateTime.now());
    if (!sleepFade || remaining == null) return 1;
    return (remaining.inMilliseconds / 5000).clamp(0.0, 1.0);
  }

  bool _disposed = false,
      _preparing = false,
      _fading = false,
      _advancing = false;
  int _generation = 0, _listened = 0;
  int? _manualGeneration;
  bool _reloadNeeded = false;
  Future<void> _nativeEdits = Future.value();
  Completer<void>? _advanceDone;
  DateTime _lastTick = DateTime.now();
  AudioPlayer? _standby;
  String? _preparedId;
  final _sources = <String, ({DateTime at, AudioSource source})>{};
  final _resolving = <String, Future<AudioSource>>{};
  int _sourceEpoch = 0;
  bool get playing => _player.playing;
  bool get loading =>
      _manualGeneration != null ||
      _player.processingState == ProcessingState.loading ||
      _player.processingState == ProcessingState.buffering;
  Duration get duration => _player.duration ?? Duration.zero;
  bool get hasSleepTimer => sleepAt != null || sleepAfterTrack;
  Duration? get sleepRemaining => sleepAt?.difference(DateTime.now());

  void _attach() {
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    _subs.add(
      _player.androidAudioSessionIdStream.listen((id) {
        if (!_disposed && id != null) onAudioSession?.call(id);
      }),
    );
    _subs.add(
      _player.playerStateStream.listen((state) {
        if (_disposed) return;
        notifyListeners();
        if (state.processingState == ProcessingState.completed &&
            _manualGeneration == null &&
            !_fading &&
            !_advancing) {
          if (sleepAfterTrack) {
            clearSleep();
            unawaited(pause());
          } else {
            unawaited(next(completed: true));
          }
        }
      }),
    );
    _subs.add(
      _player.positionStream.listen((value) {
        if (!_disposed) position.value = value;
      }),
    );
    _subs.add(
      _player.durationStream.listen((_) {
        if (!_disposed) notifyListeners();
      }),
    );
    _subs.add(
      _player.currentIndexStream.listen((_) {
        if (_disposed || _manualGeneration != null) return;
        final tag = _player.sequenceState.currentSource?.tag;
        if (tag is Song && tag.id != queue.currentId) {
          if (!_allowed(tag)) {
            unawaited(applyFilter(stopCurrent: true));
            return;
          }
          if (sleepAfterTrack) {
            clearSleep();
            unawaited(pause());
            return;
          }
          _flush(completed: true);
          queue.select(tag);
          _preparedId = null;
          onTrack(tag);
          onQueueSaved?.call();
          notifyListeners();
          unawaited(_prepareNext());
        }
      }),
    );
    _subs.add(
      _player.errorStream.listen((error) {
        if (!_disposed) {
          onError(
            'Playback interrupted. Retry this track or choose another source.',
          );
        }
      }),
    );
  }

  Future<AudioSource> _source(Song song) async {
    final cached = _sources[song.id];
    if (cached != null &&
        DateTime.now().difference(cached.at) < const Duration(minutes: 2)) {
      final source = cached.source;
      return source is UriAudioSource
          ? AudioSource.uri(source.uri, headers: source.headers, tag: song)
          : source;
    }
    final epoch = _sourceEpoch;
    final pending = _resolving.putIfAbsent(song.id, () => resolve(song));
    try {
      final source = await pending;
      if (!_disposed && epoch == _sourceEpoch) {
        _sources[song.id] = (at: DateTime.now(), source: source);
        if (_sources.length > 10) _sources.remove(_sources.keys.first);
      }
      return source is UriAudioSource
          ? AudioSource.uri(source.uri, headers: source.headers, tag: song)
          : source;
    } finally {
      if (identical(_resolving[song.id], pending)) _resolving.remove(song.id);
    }
  }

  /// Resolve both directions before a swipe; the native player also buffers
  /// the next source for gapless playback. Sharing pending work avoids a
  /// second provider request when the user swipes during preparation.
  Future<void> warmAdjacent() async {
    if (_disposed) return;
    await Future.wait([
      for (final song in [
        queue.swipeTarget(next: true),
        queue.swipeTarget(next: false),
      ].whereType<Song>())
        if (_allowed(song))
          _source(song).then<void>((_) {}, onError: (Object _) {}),
    ]);
  }

  void invalidateSources() {
    ++_sourceEpoch;
    _resolving.clear();
    _sources.clear();
    _preparedId = null;
  }

  Future<T> _editSources<T>(Future<T> Function() edit) {
    final operation = _nativeEdits.then((_) => edit());
    _nativeEdits = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<bool> play(
    Song song, {
    List<Song>? from,
    Duration initialPosition = Duration.zero,
    bool recordHistory = true,
  }) async {
    if (song.isVideo || _disposed || !_allowed(song)) return false;
    from = from?.where(_allowed).toList();
    final generation = ++_generation;
    _manualGeneration = generation;
    _fading = false;
    notifyListeners();
    Map<String, dynamic>? previousQueue;
    try {
      await _standby?.dispose();
      if (generation != _generation || _disposed) return false;
      _standby = null;
      _preparedId = null;
      final ready =
          !_reloadNeeded &&
              from == null &&
              _player.processingState == ProcessingState.ready
          ? _player.audioSources
                .whereType<UriAudioSource>()
                .where((s) => s.tag is Song && (s.tag as Song).id == song.id)
                .firstOrNull
          : null;
      final source = ready != null
          ? AudioSource.uri(ready.uri, headers: ready.headers, tag: song)
          : await _source(song);
      if (generation != _generation || _disposed || !_allowed(song)) {
        return false;
      }
      final switched = await _editSources(() async {
        if (generation != _generation || _disposed || !_allowed(song)) {
          return false;
        }
        previousQueue = queue.toJson();
        _flush(
          skipped:
              queue.currentId != null &&
              queue.currentId != song.id &&
              position.value.inSeconds < 30,
        );
        final preparedIndex =
            !_reloadNeeded &&
                from == null &&
                _player.processingState == ProcessingState.ready
            ? _player.audioSources.indexWhere(
                (s) =>
                    s is UriAudioSource &&
                    s.tag is Song &&
                    (s.tag as Song).id == song.id,
              )
            : -1;
        if (from != null || !queue.tracks.any((s) => s.id == song.id)) {
          queue.replace(from ?? [song], song);
        } else {
          queue.select(song, record: recordHistory);
        }
        await _player.setVolume(_volume * _sleepGain);
        await _player.setSpeed(song.isLongform ? speed : 1);
        if (preparedIndex >= 0) {
          await _player.seek(initialPosition, index: preparedIndex);
        } else {
          await _player.pause();
          await _player.setAudioSources([
            source,
          ], initialPosition: initialPosition);
        }
        if (generation != _generation || _disposed || !_allowed(song)) {
          return false;
        }
        await _player.setLoopMode(
          queue.repeat == MusicRepeat.one ? LoopMode.one : LoopMode.off,
        );
        if (generation != _generation || _disposed || !_allowed(song)) {
          return false;
        }
        onTrack(song);
        _reloadNeeded = false;
        onQueueSaved?.call();
        unawaited(_player.play());
        return true;
      });
      if (switched) {
        unawaited(_prepareNext());
        unawaited(warmAdjacent());
      }
      return switched;
    } on PlayerInterruptedException {
      if (generation == _generation && !_disposed) {
        await _restoreAfterFailedSwitch(generation, previousQueue);
        onError('Track change was interrupted. Please swipe again.');
      }
      return false;
    } catch (_) {
      if (generation == _generation && !_disposed) {
        await _restoreAfterFailedSwitch(generation, previousQueue);
        onError(
          'This track could not play. Check the connection or local file, then retry.',
        );
      }
      return false;
    } finally {
      final ownedLoading = _manualGeneration == generation;
      if (ownedLoading) _manualGeneration = null;
      if (!_disposed && (ownedLoading || generation == _generation)) {
        notifyListeners();
      }
    }
  }

  Future<void> _restoreAfterFailedSwitch(
    int generation,
    Map<String, dynamic>? snapshot,
  ) async {
    if (snapshot == null) return;
    queue.restore(snapshot);
    _reloadNeeded = true;
    await _editSources(() async {
      if (!_disposed && generation == _generation) await _player.pause();
    });
  }

  /// A confirmed manual step, separate from automatic queue-end behaviour.
  Future<bool> swipeTo(Song song, {required bool backwards}) async {
    await _advanceDone?.future;
    if (_disposed ||
        !_allowed(song) ||
        song.id == queue.currentId ||
        !queue.tracks.any((s) => s.id == song.id)) {
      return false;
    }
    final history = List<String>.of(queue.history);
    final switched = await play(song, recordHistory: !backwards);
    if (switched && backwards) {
      final previousIndex = history.lastIndexOf(song.id);
      queue.history
        ..clear()
        ..addAll(
          previousIndex >= 0 ? history.take(previousIndex + 1) : [song.id],
        );
      onQueueSaved?.call();
    }
    return switched;
  }

  Future<void> _prepareNext() async {
    final next = queue.peekNext(completed: true);
    if (_disposed ||
        _preparing ||
        sleepAfterTrack ||
        queue.repeat == MusicRepeat.one ||
        next == null ||
        !_allowed(next) ||
        next.id == _preparedId ||
        next.isLongform ||
        queue.current?.isLongform == true) {
      return;
    }
    _preparing = true;
    final generation = _generation;
    try {
      final source = await _source(next);
      if (generation != _generation ||
          _disposed ||
          !_allowed(next) ||
          queue.peekNext(completed: true)?.id != next.id) {
        return;
      }
      if (settings().crossfade > 0) {
        final standby = AudioPlayer(handleAudioSessionActivation: false);
        await standby.setVolume(0);
        await standby.setAudioSource(source);
        if (generation != _generation || _disposed) {
          await standby.dispose();
          return;
        }
        await _standby?.dispose();
        _standby = standby;
        _preparedId = next.id;
      } else if (settings().gapless) {
        // Native playlist transitions happen without waiting on Dart/network.
        await _editSources(() async {
          if (generation != _generation || _disposed || !_allowed(next)) return;
          final nextIndex = (_player.currentIndex ?? 0) + 1;
          final existing = _player.audioSources.elementAtOrNull(nextIndex);
          if (existing is! UriAudioSource ||
              existing.tag is! Song ||
              (existing.tag as Song).id != next.id) {
            while (_player.audioSources.length > nextIndex) {
              await _player.removeAudioSourceAt(
                _player.audioSources.length - 1,
              );
            }
            if (generation != _generation || _disposed || !_allowed(next)) {
              return;
            }
            await _player.addAudioSource(source);
          }
          if (generation == _generation && !_disposed) _preparedId = next.id;
        });
      }
    } catch (_) {
      /* Playback remains usable when preload fails. */
    } finally {
      _preparing = false;
      if (generation != _generation && !_disposed) unawaited(_prepareNext());
    }
  }

  Future<void> queueChanged() async {
    if (_disposed) return;
    ++_generation;
    _fading = false;
    await _player.setVolume(_volume * _sleepGain);
    _preparedId = null;
    await _standby?.dispose();
    _standby = null;
    await _editSources(() async {
      if (_disposed) return;
      final currentIndex = _player.currentIndex ?? 0;
      while (_player.audioSources.length > currentIndex + 1) {
        await _player.removeAudioSourceAt(_player.audioSources.length - 1);
      }
    });
    onQueueSaved?.call();
    notifyListeners();
    unawaited(_prepareNext());
  }

  /// Invalidates native preloads and crossfades when language choices change.
  /// An excluded current song stops immediately; the next start is explicit.
  Future<void> applyFilter({bool stopCurrent = false}) async {
    if (_disposed) return;
    final current = queue.current;
    final excluded = stopCurrent || (current != null && !_allowed(current));
    queue.retainWhere(_allowed);
    if (excluded) {
      // Do not display a replacement as if its audio were already loaded.
      queue.currentId = null;
      await stop();
      if (_disposed) return;
      position.value = Duration.zero;
      restoredPosition = Duration.zero;
    }
    await queueChanged();
  }

  Future<void> next({bool completed = false}) async {
    if (_advancing || _disposed) return;
    _advancing = true;
    final advancing = _advanceDone = Completer<void>();
    try {
      queue.retainWhere(_allowed);
      if (queue.peekNext(completed: completed) == null && settings().autoplay) {
        try {
          await onQueueEnd?.call();
        } catch (_) {
          onError('Could not load more tracks. Your queue is saved.');
        }
      }
      final song = queue.peekNext(completed: completed);
      if (song == null) {
        _flush(completed: completed);
        await pause();
        return;
      }
      _flush(completed: completed);
      await play(song);
    } finally {
      _advancing = false;
      if (identical(_advanceDone, advancing)) _advanceDone = null;
      advancing.complete();
    }
  }

  Future<void> previous({bool restartCurrent = true}) async {
    if (_disposed || _advancing) return;
    queue.retainWhere(_allowed);
    if (restartCurrent && position.value.inSeconds > 4) {
      await seek(Duration.zero);
      return;
    }
    _flush();
    final song = queue.previous();
    if (song != null) await play(song, recordHistory: false);
  }

  Future<void> toggle() async {
    if (_player.playing) {
      await pause();
    } else {
      await resume();
    }
  }

  Future<void> resume() async {
    if (_player.playing || _disposed) return;
    if (queue.current == null) return;
    if (!_allowed(queue.current!)) {
      await applyFilter();
      return;
    }
    if (_reloadNeeded ||
        _player.processingState == ProcessingState.idle ||
        _player.processingState == ProcessingState.completed) {
      await play(
        queue.current!,
        initialPosition: _player.processingState == ProcessingState.completed
            ? Duration.zero
            : restoredPosition,
      );
    } else {
      unawaited(_player.play());
    }
  }

  Future<void> pause() async {
    _flush();
    await _player.pause();
    await _standby?.pause();
  }

  Future<void> stop() async {
    ++_generation;
    _manualGeneration = null;
    _flush();
    clearSleep();
    await _standby?.dispose();
    _standby = null;
    await _player.stop();
    _preparedId = null;
  }

  Future<void> seek(Duration value) => _player.seek(value);

  /// User volume is independent of the temporary crossfade/sleep envelopes.
  Future<void> setVolume(double value) async {
    if (_disposed || !value.isFinite) return;
    _volume = value.clamp(0.0, 1.0);
    notifyListeners();
    final gain = _volume * _sleepGain;
    await _player.setVolume(gain * (_fading ? 1 - _fadeProgress : 1));
    if (_fading) await _standby?.setVolume(gain * _fadeProgress);
  }

  Future<void> setSpeed(double value) async {
    speed = value.clamp(0.5, 2.5);
    await _player.setSpeed(speed);
    notifyListeners();
  }

  Future<void> setRepeat(MusicRepeat value) async {
    queue.repeat = value;
    await _player.setLoopMode(
      value == MusicRepeat.one ? LoopMode.one : LoopMode.off,
    );
    await queueChanged();
  }

  void setSleep(
    Duration? duration, {
    bool afterTrack = false,
    bool fade = true,
  }) {
    sleepAfterTrack = afterTrack;
    sleepFade = fade;
    sleepAt = duration == null ? null : DateTime.now().add(duration);
    if (afterTrack) unawaited(queueChanged());
    notifyListeners();
  }

  void clearSleep() {
    sleepAt = null;
    sleepAfterTrack = false;
    if (!_disposed) unawaited(_player.setVolume(_volume));
    if (!_disposed) notifyListeners();
  }

  void _flush({bool skipped = false, bool completed = false}) {
    final song = queue.current;
    if (song != null && (_listened > 0 || skipped || completed)) {
      onListening(
        song,
        _listened.clamp(0, 30000),
        skipped: skipped,
        completed: completed,
      );
    }
    _listened = 0;
  }

  void _tick() {
    if (_disposed) return;
    final now = DateTime.now(),
        elapsed = DateTime.now().difference(_lastTick).inMilliseconds;
    _lastTick = now;
    if (_player.playing && _player.processingState == ProcessingState.ready) {
      _listened += elapsed.clamp(0, 1500);
      if (_listened >= 10000) _flush();
    }
    final remaining = sleepAt?.difference(now);
    if (remaining != null) {
      if (remaining.isNegative) {
        clearSleep();
        unawaited(pause().then((_) => _player.setVolume(_volume)));
      } else if (sleepFade &&
          remaining.inMilliseconds < 5000 &&
          _player.playing) {
        unawaited(_player.setVolume(_volume * _sleepGain));
      }
      notifyListeners();
    }
    if (!_fading &&
        _preparedId != null &&
        _standby != null &&
        _player.playing &&
        settings().crossfade > 0 &&
        !hasSleepTimer) {
      final left = duration - position.value;
      if (duration > Duration.zero &&
          left <= Duration(seconds: settings().crossfade) &&
          left > Duration.zero) {
        unawaited(_crossfade(left));
      }
    }
  }

  Future<void> _crossfade(Duration left) async {
    final incoming = _standby, next = queue.peekNext(completed: true);
    if (incoming == null ||
        next == null ||
        !_allowed(next) ||
        incoming.processingState != ProcessingState.ready) {
      return;
    }
    _fading = true;
    _fadeProgress = 0;
    final generation = _generation, outgoing = _player;
    unawaited(incoming.play());
    final steps = math.max(1, left.inMilliseconds ~/ 50);
    for (var i = 1; i <= steps; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (_disposed || generation != _generation || !_fading) return;
      if (!outgoing.playing) {
        await incoming.pause();
        await incoming.seek(Duration.zero);
        await incoming.setVolume(0);
        await outgoing.setVolume(_volume);
        _fading = false;
        return;
      }
      _fadeProgress = i / steps;
      await outgoing.setVolume(_volume * (1 - _fadeProgress));
      await incoming.setVolume(_volume * _fadeProgress);
    }
    if (_disposed || generation != _generation) return;
    _flush(completed: true);
    _player = incoming;
    _standby = null;
    _preparedId = null;
    queue.select(next);
    onPlayerChanged?.call(incoming);
    _attach();
    onTrack(next);
    onQueueSaved?.call();
    await outgoing.dispose();
    _fading = false;
    notifyListeners();
    unawaited(_prepareNext());
  }

  @override
  void dispose() {
    _flush();
    _disposed = true;
    ++_generation;
    _clock?.cancel();
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    unawaited(_standby?.dispose());
    unawaited(_player.dispose());
    position.dispose();
    super.dispose();
  }
}

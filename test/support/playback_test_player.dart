import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

/// Playback without a platform decoder, with observable controls and volume.
class PlaybackTestPlayer extends Fake implements AudioPlayer {
  final _states = StreamController<PlayerState>.broadcast(sync: true);
  final List<AudioSource> sources = [];
  final List<double> volumes = [];
  bool isPlaying = false;
  Duration lastSeek = Duration.zero;
  int sourceLoads = 0, _index = 0;
  @override
  bool get playing => isPlaying;
  @override
  ProcessingState get processingState => ProcessingState.ready;
  @override
  Duration get duration => const Duration(minutes: 3);
  @override
  Duration get position => lastSeek;
  @override
  Duration get bufferedPosition => duration;
  @override
  double get speed => 1;
  @override
  double get volume => volumes.lastOrNull ?? 1;
  @override
  List<AudioSource> get audioSources => sources;
  @override
  int? get currentIndex => _index;
  @override
  Stream<int?> get androidAudioSessionIdStream => const Stream.empty();
  @override
  Stream<PlayerState> get playerStateStream => _states.stream;
  @override
  Stream<bool> get playingStream =>
      _states.stream.map((state) => state.playing);
  @override
  Stream<PlaybackEvent> get playbackEventStream => const Stream.empty();
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<int?> get currentIndexStream => const Stream.empty();
  @override
  Stream<PlayerException> get errorStream => const Stream.empty();

  @override
  Future<Duration?> setAudioSources(
    List<AudioSource> audioSources, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
    ShuffleOrder? shuffleOrder,
  }) async {
    sourceLoads++;
    _index = initialIndex ?? 0;
    sources
      ..clear()
      ..addAll(audioSources);
    lastSeek = initialPosition ?? Duration.zero;
    return duration;
  }

  @override
  Future<void> setVolume(double value) async => volumes.add(value);
  @override
  Future<void> play() async {
    isPlaying = true;
    _states.add(PlayerState(true, processingState));
  }

  @override
  Future<void> pause() async {
    isPlaying = false;
    _states.add(PlayerState(false, processingState));
  }

  @override
  Future<void> stop() => pause();
  @override
  Future<void> seek(Duration? position, {int? index}) async {
    lastSeek = position ?? Duration.zero;
    if (index != null) _index = index;
  }

  @override
  Future<void> addAudioSource(AudioSource source) async => sources.add(source);
  @override
  Future<void> removeAudioSourceAt(int index) async => sources.removeAt(index);

  @override
  Future<void> setSpeed(double speed) async {}
  @override
  Future<void> setLoopMode(LoopMode mode) async {}
  @override
  Future<void> dispose() async => _states.close();
}

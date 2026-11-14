import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:nex_music/listening_models.dart';
import 'package:nex_music/listening_player.dart';
import 'package:nex_music/music_data.dart';
import 'support/playback_test_player.dart';

final _tracks = [
  for (var i = 0; i < 3; i++)
    Song(
      id: '$i',
      title: 'Song $i',
      kind: 'audio',
      url: 'https://example.test/$i.mp3',
    ),
];

class _DelayedPreload extends PlaybackTestPlayer {
  final adding = Completer<void>(), release = Completer<void>();
  bool applying = false;
  @override
  Future<void> addAudioSource(AudioSource source) async {
    sources.add(source);
    applying = true;
    if (!adding.isCompleted) adding.complete();
    await release.future;
    applying = false;
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    if (applying) throw StateError('Native playlist update has not completed');
    await super.seek(position, index: index);
  }
}

class _ObservedPlayer extends PlaybackTestPlayer {
  int playCalls = 0;
  bool failSeek = false;

  @override
  Future<void> play() async {
    playCalls++;
    await super.play();
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    if (failSeek) throw StateError('Native seek failed');
    await super.seek(position, index: index);
  }
}

class _NoisyIndices extends PlaybackTestPlayer {
  final indices = StreamController<int?>.broadcast(sync: true);
  @override
  Stream<int?> get currentIndexStream => indices.stream;
  @override
  SequenceState get sequenceState => SequenceState(
    sequence: sources.whereType<IndexedAudioSource>().toList(),
    currentIndex: currentIndex,
    shuffleIndices: List.generate(sources.length, (i) => i),
    shuffleModeEnabled: false,
    loopMode: LoopMode.off,
  );
  @override
  Future<void> seek(Duration? position, {int? index}) async {
    indices.add(currentIndex); // A native callback from the outgoing source.
    await super.seek(position, index: index);
    indices.add(currentIndex);
  }

  Future<void> automaticNext(int index) async {
    await super.seek(Duration.zero, index: index);
    indices.add(index);
  }

  @override
  Future<void> dispose() async {
    await indices.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final gapless in [true, false]) {
    for (final paused in [true, false]) {
      test(
        'swipe preserves ${paused ? 'paused' : 'playing'} state with ${gapless ? 'prepared sources' : 'a source reload'}',
        () async {
          final native = _ObservedPlayer();
          final engine = ListeningPlayer(
            player: native,
            resolve: (s) async => AudioSource.uri(Uri.parse(s.url), tag: s),
            settings: () => ListeningSettings({'gapless': gapless}),
            onTrack: (_) {},
            onListening: (_, _, {skipped = false, completed = false}) {},
            onError: fail,
          );
          await engine.play(_tracks.first, from: _tracks);
          await Future<void>.delayed(Duration.zero);
          if (paused) await engine.pause();
          final loads = native.sourceLoads, starts = native.playCalls;
          expect(await engine.swipeTo(_tracks[1], backwards: false), isTrue);
          expect(engine.queue.current?.id, '1');
          expect(native.playing, !paused);
          expect(native.sourceLoads, loads + (gapless ? 0 : 1));
          expect(native.playCalls, starts + (!paused && !gapless ? 1 : 0));
          engine.dispose();
        },
      );
    }
  }

  test(
    'a failed paused swipe restores its queue without starting audio',
    () async {
      final native = _ObservedPlayer(), errors = <String>[];
      final engine = ListeningPlayer(
        player: native,
        resolve: (s) async => AudioSource.uri(Uri.parse(s.url), tag: s),
        settings: () => ListeningSettings(),
        onTrack: (_) {},
        onListening: (_, _, {skipped = false, completed = false}) {},
        onError: errors.add,
      );
      await engine.play(_tracks.first, from: _tracks);
      await Future<void>.delayed(Duration.zero);
      await engine.pause();
      final starts = native.playCalls;
      native.failSeek = true;
      expect(await engine.swipeTo(_tracks[1], backwards: false), isFalse);
      expect(engine.queue.current?.id, '0');
      expect(native.playing, isFalse);
      expect(native.playCalls, starts);
      expect(errors, hasLength(1));
      native.failSeek = false;
      await engine.resume();
      expect(engine.queue.current?.id, '0');
      expect(native.playing, isTrue);
      engine.dispose();
    },
  );

  for (final pauseDuringResolve in [false, true]) {
    test(
      '${pauseDuringResolve ? 'pausing' : 'a newer preview'} cancels a pending swipe without starting its audio',
      () async {
        final pending = Completer<AudioSource>();
        final native = _ObservedPlayer(), selected = <String>[];
        final engine = ListeningPlayer(
          player: native,
          resolve: (s) => s.id == '1'
              ? pending.future
              : Future.value(AudioSource.uri(Uri.parse(s.url), tag: s)),
          settings: () => ListeningSettings({'gapless': false}),
          onTrack: (s) => selected.add(s.id),
          onListening: (_, _, {skipped = false, completed = false}) {},
          onError: fail,
        );
        await engine.play(_tracks.first, from: _tracks);
        var current = true;
        final starts = native.playCalls, loads = native.sourceLoads;
        final switching = engine.swipeTo(
          _tracks[1],
          backwards: false,
          isCurrent: () => current,
        );
        await Future<void>.delayed(Duration.zero);
        expect(engine.loading, isTrue);
        if (pauseDuringResolve) {
          await engine.pause();
        } else {
          current = false;
        }
        pending.complete(
          AudioSource.uri(Uri.parse(_tracks[1].url), tag: _tracks[1]),
        );
        expect(await switching, isFalse);
        expect(engine.queue.current?.id, '0');
        expect(selected, ['0']);
        expect(engine.loading, isFalse);
        expect(native.playing, !pauseDuringResolve);
        expect(native.playCalls, starts);
        expect(native.sourceLoads, loads);
        if (!pauseDuringResolve) {
          expect(await engine.swipeTo(_tracks[2], backwards: false), isTrue);
          expect(selected, ['0', '2']);
          expect(native.playing, isTrue);
        }
        engine.dispose();
      },
    );
  }

  test('swiping while buffering reuses the prepared native source', () async {
    final native = PlaybackTestPlayer();
    final engine = ListeningPlayer(
      player: native,
      resolve: (s) async => AudioSource.uri(Uri.parse(s.url), tag: s),
      settings: () => ListeningSettings(),
      onTrack: (_) {},
      onListening: (_, _, {skipped = false, completed = false}) {},
      onError: fail,
    );
    await engine.play(_tracks.first, from: _tracks);
    await Future<void>.delayed(Duration.zero);
    expect(native.sources.length, 2);
    final loads = native.sourceLoads;
    native.emitState(ProcessingState.buffering);
    expect(await engine.swipeTo(_tracks[1], backwards: false), isTrue);
    expect(native.sourceLoads, loads);
    expect(native.currentIndex, 1);
    expect(engine.queue.current?.id, '1');
    engine.dispose();
  });
  test(
    'a newer preview cancels a swipe waiting for a native playlist edit',
    () async {
      final native = _DelayedPreload();
      final engine = ListeningPlayer(
        player: native,
        resolve: (s) async => AudioSource.uri(Uri.parse(s.url), tag: s),
        settings: () => ListeningSettings(),
        onTrack: (_) {},
        onListening: (_, _, {skipped = false, completed = false}) {},
        onError: fail,
      );
      await engine.play(_tracks.first, from: _tracks);
      await native.adding.future;
      var current = true;
      final switching = engine.swipeTo(
        _tracks[1],
        backwards: false,
        isCurrent: () => current,
      );
      await Future<void>.delayed(Duration.zero);
      current = false;
      native.release.complete();
      expect(await switching, isFalse);
      expect(native.currentIndex, 0);
      expect(native.playing, isTrue);
      expect(engine.queue.current?.id, '0');
      engine.dispose();
    },
  );
  test(
    'swiping during native preload waits for its playlist edit instead of losing the switch',
    () async {
      final native = _DelayedPreload(), errors = <String>[];
      final engine = ListeningPlayer(
        player: native,
        resolve: (s) async => AudioSource.uri(Uri.parse(s.url), tag: s),
        settings: () => ListeningSettings(),
        onTrack: (_) {},
        onListening: (_, _, {skipped = false, completed = false}) {},
        onError: errors.add,
      );
      await engine.play(_tracks.first, from: _tracks);
      await native.adding.future;
      final switching = engine.swipeTo(_tracks[1], backwards: false);
      await Future<void>.delayed(Duration.zero);
      expect(native.currentIndex, 0);
      native.release.complete();
      expect(await switching, isTrue);
      expect(native.currentIndex, 1);
      expect(engine.queue.current?.id, '1');
      expect(errors, isEmpty);
      engine.dispose();
    },
  );

  test(
    'outgoing native callbacks cannot select the old song during a swipe; automatic advance still works',
    () async {
      final native = _NoisyIndices(), selected = <String>[];
      final engine = ListeningPlayer(
        player: native,
        resolve: (s) async => AudioSource.uri(Uri.parse(s.url), tag: s),
        settings: () => ListeningSettings(),
        onTrack: (s) => selected.add(s.id),
        onListening: (_, _, {skipped = false, completed = false}) {},
        onError: fail,
      );
      await engine.play(_tracks.first, from: _tracks);
      await Future<void>.delayed(Duration.zero);
      expect(await engine.swipeTo(_tracks[1], backwards: false), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(selected, ['0', '1']);
      expect(engine.queue.current?.id, '1');
      await native.automaticNext(2);
      expect(engine.queue.current?.id, '2');
      expect(selected, ['0', '1', '2']);
      engine.dispose();
    },
  );

  test(
    'manual queue boundaries wrap without enabling repeat or leaving the queue',
    () {
      final queue = ListeningQueue()..replace(_tracks, _tracks.last);
      expect(queue.swipeTarget(next: true)?.id, '0');
      expect(queue.repeat, MusicRepeat.off);
      queue.replace(_tracks, _tracks.first);
      expect(queue.swipeTarget(next: false)?.id, '2');
      queue.replace([_tracks.first], _tracks.first);
      expect(queue.swipeTarget(next: true), isNull);
      expect(queue.swipeTarget(next: false), isNull);
    },
  );

  test(
    'a queue edit during resolution clears cancelled swipe loading and notifies the UI',
    () async {
      final pending = Completer<AudioSource>();
      final native = PlaybackTestPlayer();
      final engine = ListeningPlayer(
        player: native,
        resolve: (s) => s.id == '1'
            ? pending.future
            : Future.value(AudioSource.uri(Uri.parse(s.url), tag: s)),
        settings: () => ListeningSettings({'gapless': false}),
        onTrack: (_) {},
        onListening: (_, _, {skipped = false, completed = false}) {},
        onError: fail,
      );
      await engine.play(_tracks.first, from: _tracks);
      final switching = engine.swipeTo(_tracks[1], backwards: false);
      await Future<void>.delayed(Duration.zero);
      expect(engine.loading, isTrue);
      await engine.queueChanged();
      var notifications = 0;
      engine.addListener(() => notifications++);
      pending.complete(
        AudioSource.uri(Uri.parse(_tracks[1].url), tag: _tracks[1]),
      );
      expect(await switching, isFalse);
      expect(engine.loading, isFalse);
      expect(notifications, greaterThan(0));
      engine.dispose();
    },
  );
}

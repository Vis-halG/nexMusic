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
      title: 'Track $i',
      kind: 'audio',
      url: 'https://example.test/$i.wav',
    ),
];

ListeningPlayer _engine(
  PlaybackTestPlayer native, {
  MusicSourceResolver? resolve,
  Map<String, dynamic>? settings,
  AudioPlayer Function()? standby,
  Future<void> Function()? onQueueEnd,
  void Function(String)? onError,
}) => ListeningPlayer(
  player: native,
  resolve:
      resolve ??
      (song) async => AudioSource.uri(Uri.parse(song.url), tag: song),
  settings: () => ListeningSettings({'gapless': false, ...?settings}),
  standbyPlayerFactory: standby,
  onTrack: (_) {},
  onListening: (_, _, {skipped = false, completed = false}) {},
  onError: onError ?? (_) {},
  onQueueEnd: onQueueEnd,
);

class _InstantCompletion extends PlaybackTestPlayer {
  @override
  Future<void> play() async {
    await super.play();
    if ((sources.first as UriAudioSource).tag == _tracks.first) {
      emitState(ProcessingState.completed);
    }
  }
}

class _RejectsPlayOnce extends PlaybackTestPlayer {
  bool rejected = false;
  @override
  Future<void> play() async {
    if (!rejected) {
      rejected = true;
      throw PlayerException(0, 'Play request failed', 0);
    }
    await super.play();
  }
}

class _FailedPreload extends PlaybackTestPlayer {
  bool disposed = false;
  @override
  Future<Duration?> setAudioSource(
    AudioSource source, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async => throw PlayerException(0, 'Preload failed', 0);
  @override
  Future<void> dispose() async {
    disposed = true;
    await super.dispose();
  }
}

void main() {
  testWidgets(
    'an incoming crossfade error preserves outgoing audio and normal queue advance',
    (tester) async {
      final native = PlaybackTestPlayer()
        ..trackDuration = const Duration(seconds: 2);
      final incoming = PlaybackTestPlayer();
      final engine = _engine(
        native,
        settings: {'crossfade': 1},
        standby: () => incoming,
      );
      await engine.play(_tracks.first, from: _tracks.take(2).toList());
      await tester.pump();
      engine.position.value = const Duration(seconds: 1);
      await tester.pump(const Duration(milliseconds: 500));
      await engine.pause();
      await engine.resume();
      incoming.emitError(PlayerException(0, 'Incoming stream failed', 0));
      await tester.pump();
      expect(engine.player, same(native));
      expect(native.playing, isTrue);
      expect(native.volume, 1);
      native.emitState(ProcessingState.completed);
      await tester.pump();
      expect(engine.queue.currentId, '1');
      expect(engine.playing, isTrue);
      engine.dispose();
      await tester.pump(const Duration(milliseconds: 50));
    },
  );

  test('queue snapshots preserve traversal when a switch is rolled back', () {
    final queue = ListeningQueue()..replace(_tracks, _tracks.first);
    queue.select(_tracks[1]);
    final snapshot = queue.toJson();
    queue.select(_tracks[2]);
    queue.restore(snapshot);
    expect(queue.currentId, '1');
    expect(queue.history, ['0', '1']);
    expect(queue.peekPrevious()?.id, '0');
  });

  testWidgets(
    'a rejected play future is handled and retried without an uncaught error',
    (tester) async {
      final native = _RejectsPlayOnce();
      final engine = _engine(native);
      await engine.play(_tracks.first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(native.sourceLoads, 2);
      expect(native.playing, isTrue);
      expect(tester.takeException(), isNull);
      engine.dispose();
      await tester.pump();
    },
  );

  testWidgets('failed standby preparation releases its native player', (
    tester,
  ) async {
    final native = PlaybackTestPlayer();
    final standby = _FailedPreload();
    final engine = _engine(
      native,
      settings: {'crossfade': 1},
      standby: () => standby,
    );
    await engine.play(_tracks.first, from: _tracks);
    await tester.pump();
    expect(standby.disposed, isTrue);
    expect(native.playing, isTrue);
    engine.dispose();
    await tester.pump();
  });

  testWidgets('recovery is bounded even with repeat one enabled', (
    tester,
  ) async {
    final native = PlaybackTestPlayer();
    final engine = _engine(native);
    await engine.play(_tracks.first);
    await engine.setRepeat(MusicRepeat.one);
    native.emitError(PlayerException(0, 'Unavailable stream', 0));
    await tester.pump();
    expect(native.sourceLoads, 2);
    native.emitError(PlayerException(0, 'Still unavailable', 0));
    await tester.pump();
    expect(native.playing, isFalse);
    expect(native.sourceLoads, 2);
    expect(engine.queue.currentId, '0');
    engine.dispose();
    await tester.pump();
  });

  testWidgets(
    'pause cancels a pending recovery and does not restart playback',
    (tester) async {
      final pending = Completer<AudioSource>();
      var calls = 0;
      final native = PlaybackTestPlayer();
      final engine = _engine(
        native,
        resolve: (song) async {
          if (++calls > 1) return pending.future;
          return AudioSource.uri(Uri.parse(song.url), tag: song);
        },
      );
      await engine.play(_tracks.first);
      native.emitError(PlayerException(0, 'Connection lost', 0));
      await tester.pump();
      await engine.pause();
      pending.complete(
        AudioSource.uri(Uri.parse(_tracks.first.url), tag: _tracks.first),
      );
      await tester.pump();
      expect(native.playing, isFalse);
      expect(native.sourceLoads, 1);
      engine.dispose();
      await tester.pump();
    },
  );

  testWidgets('duplicate completion events advance exactly once', (
    tester,
  ) async {
    final native = PlaybackTestPlayer();
    final engine = _engine(native);
    await engine.play(_tracks.first, from: _tracks);
    native.emitState(ProcessingState.completed);
    native.emitState(ProcessingState.completed);
    await tester.pump();
    expect(engine.queue.currentId, '1');
    expect(native.playing, isTrue);
    engine.dispose();
    await tester.pump();
  });

  testWidgets('completion during the final loading callback is not lost', (
    tester,
  ) async {
    final native = _InstantCompletion();
    final engine = _engine(native);
    await engine.play(_tracks.first, from: _tracks);
    await tester.pump();
    expect(engine.queue.currentId, '1');
    expect(native.playing, isTrue);
    engine.dispose();
    await tester.pump();
  });

  testWidgets('automatic next skips an unavailable track and keeps the queue', (
    tester,
  ) async {
    final native = PlaybackTestPlayer();
    final engine = _engine(
      native,
      resolve: (song) async {
        if (song.id == '1') throw StateError('Unavailable source');
        return AudioSource.uri(Uri.parse(song.url), tag: song);
      },
    );
    await engine.play(_tracks.first, from: _tracks);
    native.emitState(ProcessingState.completed);
    await tester.pump();
    expect(engine.queue.currentId, '2');
    expect(native.playing, isTrue);
    expect(engine.queue.tracks.length, 3);
    engine.dispose();
    await tester.pump();
  });

  testWidgets('pause cancels a pending source switch', (tester) async {
    final pending = Completer<AudioSource>();
    final native = PlaybackTestPlayer();
    final engine = _engine(
      native,
      resolve: (song) => song.id == '1'
          ? pending.future
          : Future.value(AudioSource.uri(Uri.parse(song.url), tag: song)),
    );
    await engine.play(_tracks.first, from: _tracks);
    final switching = engine.play(_tracks[1]);
    await tester.pump();
    await engine.pause();
    pending.complete(
      AudioSource.uri(Uri.parse(_tracks[1].url), tag: _tracks[1]),
    );
    expect(await switching, isFalse);
    expect(native.playing, isFalse);
    expect(engine.queue.currentId, '0');
    expect(engine.loading, isFalse);
    engine.dispose();
    await tester.pump();
  });

  testWidgets('pause while radio loads prevents an unwanted restart', (
    tester,
  ) async {
    final waiting = Completer<void>();
    final native = PlaybackTestPlayer();
    late ListeningPlayer engine;
    engine = _engine(
      native,
      onQueueEnd: () async {
        await waiting.future;
        engine.queue.add(_tracks[1]);
      },
    );
    await engine.play(_tracks.first);
    native.emitState(ProcessingState.completed);
    await tester.pump();
    await engine.pause();
    waiting.complete();
    await tester.pump();
    expect(native.playing, isFalse);
    expect(engine.queue.currentId, '0');
    engine.dispose();
    await tester.pump();
  });

  testWidgets('an early crossfade handoff restores the chosen volume', (
    tester,
  ) async {
    final native = PlaybackTestPlayer()
      ..trackDuration = const Duration(seconds: 2);
    final incoming = PlaybackTestPlayer();
    final engine = _engine(
      native,
      settings: {'crossfade': 1},
      standby: () => incoming,
    );
    await engine.setVolume(0.7);
    await engine.play(_tracks.first, from: _tracks.take(2).toList());
    await tester.pump();
    engine.position.value = const Duration(seconds: 1);
    await tester.pump(const Duration(milliseconds: 500));
    expect(incoming.playing, isTrue);
    native.emitState(ProcessingState.completed, playing: false);
    await tester.pump(const Duration(milliseconds: 50));
    expect(engine.queue.currentId, '1');
    expect(engine.player.playing, isTrue);
    expect(incoming.volume, closeTo(0.7, 0.001));
    engine.dispose();
    await tester.pump();
  });

  testWidgets(
    'quick pause and resume during a crossfade cannot promote paused audio',
    (tester) async {
      final native = PlaybackTestPlayer()
        ..trackDuration = const Duration(seconds: 2);
      final incoming = PlaybackTestPlayer();
      final engine = _engine(
        native,
        settings: {'crossfade': 1},
        standby: () => incoming,
      );
      await engine.play(_tracks.first, from: _tracks.take(2).toList());
      await tester.pump();
      engine.position.value = const Duration(seconds: 1);
      await tester.pump(const Duration(milliseconds: 500));
      expect(incoming.playing, isTrue);
      await engine.pause();
      await engine.resume();
      for (var i = 0; i < 35; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(engine.player.playing, isTrue);
      expect(engine.player.volume, closeTo(1, 0.001));
      engine.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'a stream error reloads a fresh source at the interrupted position',
    (tester) async {
      var resolves = 0;
      final native = PlaybackTestPlayer();
      final engine = _engine(
        native,
        resolve: (song) async {
          resolves++;
          return AudioSource.uri(
            Uri.parse('${song.url}?attempt=$resolves'),
            tag: song,
          );
        },
      );
      await engine.play(_tracks.first);
      native.lastSeek = const Duration(seconds: 17);
      native.emitError(PlayerException(0, 'Transient connection failure', 0));
      await tester.pump();
      expect(resolves, 2);
      expect(native.sourceLoads, 2);
      expect(native.lastSeek, const Duration(seconds: 17));
      expect(native.playing, isTrue);
      engine.dispose();
      await tester.pump();
    },
  );

  testWidgets('sleep after this track deliberately pauses without advancing', (
    tester,
  ) async {
    final native = PlaybackTestPlayer();
    final engine = _engine(native);
    await engine.play(_tracks.first, from: _tracks);
    engine.setSleep(null, afterTrack: true);
    await tester.pump();
    native.emitState(ProcessingState.completed);
    await tester.pump();
    expect(engine.queue.currentId, '0');
    expect(native.playing, isFalse);
    engine.dispose();
    await tester.pump();
  });
}

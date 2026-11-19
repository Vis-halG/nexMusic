import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:nex_music/listening_models.dart';
import 'package:nex_music/listening_player.dart';
import 'package:nex_music/main.dart';
import 'package:nex_music/music_controller.dart';
import 'package:nex_music/music_data.dart';
import 'package:nex_music/music_provider.dart';
import 'package:nex_music/music_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

AudioSource _source(Song song) =>
    AudioSource.uri(Uri.parse(song.url), tag: song);

ListeningPlayer _engine(
  PlaybackTestPlayer native,
  MusicSourceResolver resolve,
) => ListeningPlayer(
  player: native,
  resolve: resolve,
  settings: () => ListeningSettings({'gapless': false}),
  onTrack: (_) {},
  onListening: (_, _, {skipped = false, completed = false}) {},
  onError: fail,
);

/// Holds one source load open, as a slow network does.
class _SlowLoad extends PlaybackTestPlayer {
  Completer<void>? gate;
  final waiting = Completer<void>();

  @override
  Future<Duration?> setAudioSources(
    List<AudioSource> audioSources, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
    ShuffleOrder? shuffleOrder,
  }) async {
    final open = gate;
    if (open != null) {
      gate = null;
      if (!waiting.isCompleted) waiting.complete();
      await open.future;
    }
    return super.setAudioSources(
      audioSources,
      preload: preload,
      initialIndex: initialIndex,
      initialPosition: initialPosition,
      shuffleOrder: shuffleOrder,
    );
  }
}

/// An online catalogue whose stream links resolve only when [link] completes.
class _SlowProvider implements MusicProvider {
  final link = Completer<String>();
  @override
  String get id => 'slow';
  @override
  String get displayName => 'Slow';
  @override
  Map<String, String> playbackHeaders(Song song) => const {};
  @override
  Future<List<Song>> loadFeatured({int limit = 20, int page = 1}) async => [];
  @override
  Future<List<Song>> searchSongs(
    String query, {
    int limit = 20,
    int page = 1,
  }) async => [];
  @override
  Future<List<Song>> loadRadio(String sourceId, {int limit = 25}) async => [];
  @override
  Future<String> resolveStreamUrl(Song song) => link.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a chosen song shows at once and silences the outgoing one while it loads',
    () async {
      final pending = Completer<AudioSource>();
      final native = PlaybackTestPlayer();
      final engine = _engine(
        native,
        (s) => s.id == '1' ? pending.future : Future.value(_source(s)),
      );
      await engine.play(_tracks.first, from: _tracks);
      expect(native.playing, isTrue);
      final choosing = engine.play(_tracks[1], from: _tracks);
      await Future<void>.delayed(Duration.zero);
      expect(engine.requested?.id, '1');
      expect(engine.queue.currentId, '0');
      expect(native.playing, isFalse);
      expect(engine.willPlay, isTrue);
      pending.complete(_source(_tracks[1]));
      expect(await choosing, isTrue);
      expect(engine.requested, isNull);
      expect(engine.queue.currentId, '1');
      expect(native.playing, isTrue);
      engine.dispose();
    },
  );

  test(
    'pause while a chosen song loads cancels it instead of resuming the old one',
    () async {
      final pending = Completer<AudioSource>();
      final native = PlaybackTestPlayer();
      final engine = _engine(
        native,
        (s) => s.id == '1' ? pending.future : Future.value(_source(s)),
      );
      await engine.play(_tracks.first, from: _tracks);
      final choosing = engine.play(_tracks[1], from: _tracks);
      await Future<void>.delayed(Duration.zero);
      await engine.toggle();
      pending.complete(_source(_tracks[1]));
      expect(await choosing, isFalse);
      expect(engine.requested, isNull);
      expect(engine.willPlay, isFalse);
      expect(native.playing, isFalse);
      expect(engine.queue.currentId, '0');
      engine.dispose();
    },
  );

  test('a swipe that overtakes a loading switch keeps playing', () async {
    final native = _SlowLoad();
    final engine = _engine(native, (s) async => _source(s));
    await engine.play(_tracks.first, from: _tracks);
    final gate = native.gate = Completer<void>();
    final first = engine.swipeTo(_tracks[1], backwards: false);
    await native.waiting.future;
    // The first switch paused its outgoing source before loading.
    expect(native.playing, isFalse);
    final second = engine.swipeTo(_tracks[2], backwards: false);
    gate.complete();
    expect(await first, isFalse);
    expect(await second, isTrue);
    expect(engine.queue.currentId, '2');
    expect(native.playing, isTrue);
    expect(engine.willPlay, isTrue);
    engine.dispose();
  });

  test('swiping a paused player keeps it paused', () async {
    final native = PlaybackTestPlayer();
    final engine = _engine(native, (s) async => _source(s));
    await engine.play(_tracks.first, from: _tracks);
    await engine.pause();
    expect(await engine.swipeTo(_tracks[1], backwards: false), isTrue);
    expect(engine.queue.currentId, '1');
    expect(native.playing, isFalse);
    expect(engine.willPlay, isFalse);
    engine.dispose();
  });

  testWidgets('the mini player shows a chosen song before its audio loads', (
    tester,
  ) async {
    // Online links pick their quality from the connection type.
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const connectivity = MethodChannel('dev.fluttercommunity.plus/connectivity');
    messenger.setMockMethodCallHandler(connectivity, (_) async => ['wifi']);
    addTearDown(() => messenger.setMockMethodCallHandler(connectivity, null));
    SharedPreferences.setMockInitialValues({});
    final provider = _SlowProvider();
    final native = PlaybackTestPlayer();
    final music = MusicController(
      await SharedPreferences.getInstance(),
      player: native,
      musicProviders: [provider],
    );
    music.personal.settings.values['gapless'] = false;
    const first = Song(
      id: 'first',
      title: 'First song',
      kind: 'audio',
      url: 'https://example.test/first.mp3',
    );
    const chosen = Song(
      id: 'provider:slow:2',
      title: 'Chosen song',
      kind: 'audio',
      url: '',
      providerId: 'slow',
      sourceId: '2',
    );
    await music.play(first, from: const [first]);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: music,
        child: MaterialApp(
          theme: NexMusic.theme(Brightness.light),
          home: const Scaffold(bottomNavigationBar: MiniPlayer()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final card = find.byKey(const ValueKey('mini-player-current-card'));
    expect(
      find.descendant(of: card, matching: find.text('First song')),
      findsOneWidget,
    );

    final choosing = music.play(chosen, from: const [first, chosen]);
    await tester.pump();
    expect(
      find.descendant(of: card, matching: find.text('Chosen song')),
      findsOneWidget,
    );
    expect(native.isPlaying, isFalse);
    expect(
      find.descendant(of: card, matching: find.byTooltip('Pause')),
      findsOneWidget,
      reason: 'the play button keeps showing the intended state',
    );

    provider.link.complete('https://example.test/chosen.mp3');
    await choosing;
    await tester.pumpAndSettle();
    expect(music.current?.id, chosen.id);
    expect(native.isPlaying, isTrue);
    expect(
      find.descendant(of: card, matching: find.text('Chosen song')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    music.dispose();
    await tester.pump();
  });

  testWidgets('the first frame is the app itself, with no logo overlay', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final music = MusicController(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      ChangeNotifierProvider.value(value: music, child: const NexMusic()),
    );
    expect(find.byType(WelcomeScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('launch-logo')), findsNothing);
    final fades = tester.widgetList<FadeTransition>(
      find.ancestor(
        of: find.byType(WelcomeScreen),
        matching: find.byType(FadeTransition),
      ),
    );
    expect(fades.every((fade) => fade.opacity.value == 1), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    music.dispose();
    await tester.pump();
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_music/main.dart';
import 'package:nex_music/music_controller.dart';
import 'package:nex_music/music_data.dart';
import 'package:nex_music/music_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/playback_test_player.dart';

final _songs = [
  for (var i = 0; i < 3; i++)
    Song(
      id: 's$i',
      title: 'Track $i',
      artist: 'Singer $i',
      kind: 'audio',
      url: 'https://example.test/$i.mp3',
    ),
];

typedef _Harness = ({
  MusicController music,
  PlaybackTestPlayer player,
  Future<void> Function() close,
});

Future<_Harness> _mount(
  WidgetTester tester, {
  bool reducedMotion = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final player = PlaybackTestPlayer();
  final music = MusicController(
    await SharedPreferences.getInstance(),
    player: player,
  );
  music.personal.settings.values['gapless'] = false;
  await music.play(_songs[1], from: _songs);
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: music,
      child: MaterialApp(
        theme: NexMusic.theme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reducedMotion),
          child: child!,
        ),
        home: const Scaffold(bottomNavigationBar: MiniPlayer()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  var closed = false;
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await tester.pumpWidget(const SizedBox.shrink());
    music.dispose();
    await tester.pump();
  }

  addTearDown(close);
  return (music: music, player: player, close: close);
}

void main() {
  testWidgets(
    'a tiny horizontal movement after hold adjusts volume and release waits two seconds',
    (tester) async {
      final state = await _mount(tester);
      await state.music.playback.setVolume(0.5);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Track 1')),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byIcon(Icons.unfold_more_rounded), findsNothing);
      await gesture.moveBy(const Offset(3, 0));
      await tester.pump();
      expect(state.music.playback.volume, greaterThan(0.5));
      await gesture.moveBy(const Offset(-6, 0));
      await tester.pump();
      expect(state.music.playback.volume, lessThan(0.5));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 1900));
      expect(find.text('Volume'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 101));
      await tester.pumpAndSettle();
      expect(find.text('Volume'), findsNothing);
      expect(state.music.current?.id, 's1');
      await state.close();
    },
  );

  testWidgets('tap expands the mini surface into the full player and back', (
    tester,
  ) async {
    final state = await _mount(tester);
    final source = tester.getRect(
      find.byKey(const ValueKey('mini-player-gestures')),
    );
    await tester.tap(find.text('Track 1'));
    await tester.pump();
    await tester.pump();
    final container = find.byKey(const ValueKey('expanding-page-container'));
    final start = tester.getRect(container);
    expect(start.width, closeTo(source.width, 1));
    expect(start.height, closeTo(source.height, 1));
    await tester.pump(const Duration(milliseconds: 160));
    final middle = tester.getRect(container);
    expect(middle.height, greaterThan(start.height));
    expect(middle.height, lessThan(tester.view.physicalSize.height));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    final full = tester.getRect(container);
    expect(full.topLeft, Offset.zero);
    expect(full.size, tester.view.physicalSize / tester.view.devicePixelRatio);
    await tester.tap(find.byTooltip('Close'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    expect(tester.getRect(container).height, lessThan(full.height));
    await tester.pumpAndSettle();
    expect(container, findsNothing);
    expect(find.byType(NowPlayingScreen), findsNothing);
    expect(state.music.current?.id, 's1');
    await state.close();
  });

  testWidgets(
    'mini controls keep their positions through swipes and have no video or timeline',
    (tester) async {
      final state = await _mount(tester);
      final play = find.byKey(const ValueKey('mini-player-play'));
      final before = tester.getRect(play);
      expect(tester.widget<IconButton>(play).iconSize, 44);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      state.music.personal.settings.values['gapless'] = true;
      await state.music.playback.queueChanged();
      await tester.pumpAndSettle();
      final loads = state.player.sourceLoads;
      await tester.drag(
        find.byKey(const ValueKey('mini-player-gestures')),
        const Offset(0, -100),
      );
      await tester.pump(const Duration(milliseconds: 90));
      expect(tester.getRect(play), before);
      await tester.pumpAndSettle();
      expect(state.music.current?.id, 's2');
      expect(state.player.sourceLoads, loads);
      await tester.drag(
        find.byKey(const ValueKey('mini-player-gestures')),
        const Offset(0, 100),
      );
      await tester.pumpAndSettle();
      expect(state.music.current?.id, 's1');
      expect(state.player.sourceLoads, loads);
      expect(tester.getRect(play), before);
      final videoSource = _songs[1].copyWith(providerId: 'ytmusic');
      state.music.playback.queue.replace([videoSource], videoSource);
      state.music.current = videoSource;
      state.music.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byTooltip('Watch Video'), findsNothing);
      expect(tester.getRect(play), before);
      await state.close();
    },
  );

  testWidgets(
    'up and down swipes change exactly one track, including mid-song previous',
    (tester) async {
      final state = await _mount(tester);
      final target = find.byKey(const ValueKey('mini-player-gestures'));
      await tester.drag(target, const Offset(0, -100));
      await tester.pumpAndSettle();
      expect(state.music.current?.id, 's2');
      expect(find.byType(NowPlayingScreen), findsNothing);
      state.music.playback.position.value = const Duration(seconds: 35);
      await tester.drag(target, const Offset(0, 100));
      await tester.pumpAndSettle();
      expect(state.music.current?.id, 's1');
      expect(find.byType(NowPlayingScreen), findsNothing);
      await state.close();
    },
  );

  testWidgets(
    'hold and vertical movement adjust volume without skipping or opening player',
    (tester) async {
      final state = await _mount(tester);
      await state.music.playback.setVolume(0.5);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Track 1')),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Volume'), findsOneWidget);
      expect(find.text('50%'), findsOneWidget);
      await gesture.moveBy(const Offset(0, -80));
      await tester.pump();
      expect(state.music.playback.volume, greaterThan(0.5));
      await gesture.moveBy(const Offset(0, 160));
      await tester.pump();
      expect(state.music.playback.volume, lessThan(0.5));
      expect(state.music.current?.id, 's1');
      expect(find.byType(NowPlayingScreen), findsNothing);
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 2100));
      await tester.pumpAndSettle();
      expect(find.text('Volume'), findsNothing);
      expect(find.text('Track 1'), findsOneWidget);
      expect(state.player.volume, state.music.playback.volume);
      await state.close();
    },
  );

  testWidgets('hold over play button consumes its tap and clamps volume', (
    tester,
  ) async {
    final state = await _mount(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byTooltip('Pause')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(0, 500));
    await tester.pump();
    expect(state.music.playback.volume, 0);
    await gesture.moveBy(const Offset(0, -1000));
    await tester.pump();
    expect(state.music.playback.volume, 1);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(state.player.isPlaying, true);
    expect(state.music.current?.id, 's1');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    await state.close();
  });

  testWidgets('cancelled swipe does not change track', (tester) async {
    final state = await _mount(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Track 1')),
    );
    await gesture.moveBy(const Offset(0, -90));
    await tester.pump();
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(state.music.current?.id, 's1');
    expect(find.byType(NowPlayingScreen), findsNothing);
    await state.close();
  });

  testWidgets('tap, like and playback buttons retain their normal actions', (
    tester,
  ) async {
    final state = await _mount(tester);
    await tester.tap(find.byTooltip('Like'));
    await tester.pumpAndSettle();
    expect(state.music.isLiked(_songs[1]), true);
    await tester.tap(find.byTooltip('Pause'));
    await tester.pumpAndSettle();
    expect(state.player.isPlaying, false);
    await tester.tap(find.text('Track 1'));
    await tester.pumpAndSettle();
    expect(find.byType(NowPlayingScreen), findsOneWidget);
    expect(state.music.current?.id, 's1');
    await state.close();
  });

  testWidgets('gestures work with reduced motion enabled', (tester) async {
    final state = await _mount(tester, reducedMotion: true);
    await tester.drag(find.text('Track 1'), const Offset(0, -90));
    await tester.pumpAndSettle();
    expect(state.music.current?.id, 's2');
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Track 2')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(0, 100));
    await tester.pump();
    expect(state.music.playback.volume, lessThan(1));
    await gesture.cancel();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await state.close();
  });

  testWidgets(
    'volume survives track changes, queue changes and sleep cancellation',
    (tester) async {
      final state = await _mount(tester);
      await state.music.playback.setVolume(0.35);
      await state.music.next();
      expect(state.player.volume, 0.35);
      await state.music.playback.queueChanged();
      expect(state.player.volume, 0.35);
      state.music.playback.setSleep(const Duration(seconds: 2));
      await state.music.playback.setVolume(0.35);
      expect(state.player.volume, inExclusiveRange(0, 0.35));
      state.music.playback.clearSleep();
      expect(state.player.volume, 0.35);
      await state.music.playback.setVolume(double.nan);
      expect(state.music.playback.volume, 0.35);
      await state.close();
    },
  );
}

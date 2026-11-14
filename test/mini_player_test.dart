import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_music/main.dart';
import 'package:nex_music/music_controller.dart';
import 'package:nex_music/music_data.dart';
import 'package:nex_music/music_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/playback_test_player.dart';

class _ObservedPlayer extends PlaybackTestPlayer {
  int seeks = 0, plays = 0;

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    seeks++;
    await super.seek(position, index: index);
  }

  @override
  Future<void> play() async {
    plays++;
    await super.play();
  }
}

class _FailingSeek extends _ObservedPlayer {
  bool fail = false;
  @override
  Future<void> seek(Duration? position, {int? index}) async {
    if (fail) throw StateError('Native seek failed');
    await super.seek(position, index: index);
  }
}

List<String> _haptics() {
  final calls = <String>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') {
      calls.add(call.arguments as String);
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return calls;
}

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
  bool fullScreen = false,
  PlaybackTestPlayer? native,
}) async {
  SharedPreferences.setMockInitialValues({});
  final player = native ?? PlaybackTestPlayer();
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
        home: fullScreen
            ? const NowPlayingScreen()
            : const Scaffold(bottomNavigationBar: MiniPlayer()),
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

Future<void> _commitSwipe(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 501));
  await tester.pumpAndSettle();
}

Finder _swipeSurface(bool fullScreen) => find.byKey(
  ValueKey(
    fullScreen ? 'now-playing-artwork-gestures' : 'mini-player-gestures',
  ),
);

void main() {
  for (final fullScreen in [false, true]) {
    final label = fullScreen ? 'full player' : 'mini player';

    testWidgets('$label waits for 500ms after release before changing audio', (
      tester,
    ) async {
      final native = _ObservedPlayer();
      final state = await _mount(
        tester,
        fullScreen: fullScreen,
        native: native,
      );
      final vibrations = _haptics();
      final before = (native.sourceLoads, native.seeks, native.plays);
      final gesture = await tester.startGesture(
        tester.getCenter(_swipeSurface(fullScreen)),
      );
      await gesture.moveBy(const Offset(0, -90));
      await tester.pump(const Duration(milliseconds: 700));
      expect(state.music.current?.id, 's1');
      expect((native.sourceLoads, native.seeks, native.plays), before);
      expect(native.isPlaying, isTrue);
      expect(vibrations, isEmpty);

      await gesture.up();
      await tester.pump(const Duration(milliseconds: 499));
      expect(state.music.current?.id, 's1');
      expect((native.sourceLoads, native.seeks, native.plays), before);
      expect(native.isPlaying, isTrue);
      expect(vibrations, isEmpty);
      await tester.pump(const Duration(milliseconds: 2));
      await tester.pumpAndSettle();
      expect(state.music.current?.id, 's2');
      expect(vibrations, hasLength(1));
      expect(native.sourceLoads + native.seeks, before.$1 + before.$2 + 1);
      expect(native.isPlaying, isTrue);
      await state.close();
    });

    testWidgets('$label rapid previews commit only the final song', (
      tester,
    ) async {
      final native = _ObservedPlayer();
      final state = await _mount(
        tester,
        fullScreen: fullScreen,
        native: native,
      );
      final vibrations = _haptics();
      final before = (native.sourceLoads, native.seeks, native.plays);
      final surface = _swipeSurface(fullScreen);
      await tester.drag(surface, const Offset(0, -90));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.drag(surface, const Offset(0, -90));
      await tester.pump(const Duration(milliseconds: 499));
      expect(state.music.current?.id, 's1');
      expect((native.sourceLoads, native.seeks, native.plays), before);
      expect(vibrations, isEmpty);
      await tester.pump(const Duration(milliseconds: 2));
      await tester.pumpAndSettle();
      expect(state.music.current?.id, 's0');
      expect(native.sourceLoads + native.seeks, before.$1 + before.$2 + 1);
      expect(native.plays, lessThanOrEqualTo(before.$3 + 1));
      expect(vibrations, hasLength(1));
      await state.close();
    });

    testWidgets(
      '$label reversing the preview keeps the current audio position',
      (tester) async {
        final native = _ObservedPlayer();
        final state = await _mount(
          tester,
          fullScreen: fullScreen,
          native: native,
        );
        final vibrations = _haptics();
        final before = (native.sourceLoads, native.seeks, native.plays);
        native.lastSeek = const Duration(seconds: 35);
        state.music.playback.position.value = native.lastSeek;
        final surface = _swipeSurface(fullScreen);
        await tester.drag(surface, const Offset(0, -90));
        await tester.pump(const Duration(milliseconds: 200));
        await tester.drag(surface, const Offset(0, 90));
        await _commitSwipe(tester);
        expect(state.music.current?.id, 's1');
        expect((native.sourceLoads, native.seeks, native.plays), before);
        expect(native.lastSeek, const Duration(seconds: 35));
        expect(vibrations, isEmpty);
        await state.close();
      },
    );

    testWidgets(
      '$label finger contact resets the delay even during a long hold',
      (tester) async {
        final native = _ObservedPlayer();
        final state = await _mount(
          tester,
          fullScreen: fullScreen,
          native: native,
        );
        final before = (native.sourceLoads, native.seeks, native.plays);
        final surface = _swipeSurface(fullScreen);
        await tester.drag(surface, const Offset(0, -90));
        await tester.pump(const Duration(milliseconds: 200));
        final held = await tester.startGesture(tester.getCenter(surface));
        await tester.pump(const Duration(milliseconds: 700));
        expect(state.music.current?.id, 's1');
        expect((native.sourceLoads, native.seeks, native.plays), before);
        await held.up();
        await tester.pump(const Duration(milliseconds: 499));
        expect(state.music.current?.id, 's1');
        expect((native.sourceLoads, native.seeks, native.plays), before);
        await tester.pump(const Duration(milliseconds: 2));
        await tester.pumpAndSettle();
        expect(state.music.current?.id, 's2');
        await state.close();
      },
    );

    testWidgets(
      '$label a cancelled follow-up preserves only the valid preview',
      (tester) async {
        final native = _ObservedPlayer();
        final state = await _mount(
          tester,
          fullScreen: fullScreen,
          native: native,
        );
        final before = (native.sourceLoads, native.seeks, native.plays);
        final surface = _swipeSurface(fullScreen);
        await tester.drag(surface, const Offset(0, -90));
        await tester.pump(const Duration(milliseconds: 200));
        final cancelled = await tester.startGesture(tester.getCenter(surface));
        await cancelled.moveBy(const Offset(0, -24));
        await tester.pump(const Duration(milliseconds: 700));
        expect(state.music.current?.id, 's1');
        expect((native.sourceLoads, native.seeks, native.plays), before);
        await cancelled.cancel();
        await tester.pump(const Duration(milliseconds: 499));
        expect(state.music.current?.id, 's1');
        expect((native.sourceLoads, native.seeks, native.plays), before);
        await tester.pump(const Duration(milliseconds: 2));
        await tester.pumpAndSettle();
        expect(state.music.current?.id, 's2');
        await state.close();
      },
    );

    testWidgets('$label committing a preview preserves paused playback', (
      tester,
    ) async {
      final native = _ObservedPlayer();
      final state = await _mount(
        tester,
        fullScreen: fullScreen,
        native: native,
      );
      await state.music.togglePlay();
      await tester.pumpAndSettle();
      expect(native.isPlaying, isFalse);
      final plays = native.plays;
      await tester.drag(_swipeSurface(fullScreen), const Offset(0, -90));
      await _commitSwipe(tester);
      expect(state.music.current?.id, 's2');
      expect(native.isPlaying, isFalse);
      expect(native.plays, plays);
      await state.close();
    });

    testWidgets(
      '$label disposal cancels a pending preview without changing audio',
      (tester) async {
        final native = _ObservedPlayer();
        final state = await _mount(
          tester,
          fullScreen: fullScreen,
          native: native,
        );
        final before = (native.sourceLoads, native.seeks, native.plays);
        await tester.drag(_swipeSurface(fullScreen), const Offset(0, -90));
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pumpWidget(const SizedBox.shrink());
        await _commitSwipe(tester);
        expect(state.music.current?.id, 's1');
        expect((native.sourceLoads, native.seeks, native.plays), before);
        expect(tester.takeException(), isNull);
        await state.close();
      },
    );
  }

  testWidgets(
    'grabbing a settling mini card continues from its visible position',
    (tester) async {
      final state = await _mount(tester);
      final card = find.byKey(const ValueKey('mini-player-current-card'));
      final restingTop = tester.getTopLeft(card).dy;
      final first = await tester.startGesture(tester.getCenter(card));
      await first.moveBy(const Offset(0, -42));
      await tester.pump();
      await first.cancel();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final settlingTop = tester.getTopLeft(card).dy;
      expect(settlingTop, lessThan(restingTop));
      final second = await tester.startGesture(tester.getCenter(card));
      await second.moveBy(const Offset(0, -22));
      await tester.pump();
      expect(tester.getTopLeft(card).dy, closeTo(settlingTop - 22 * 0.7, 0.1));
      await second.cancel();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await state.close();
    },
  );

  testWidgets(
    'single-song mini player resists dragging instead of disappearing',
    (tester) async {
      final state = await _mount(tester);
      await state.music.play(_songs[1], from: [_songs[1]]);
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Track 1')),
      );
      await gesture.moveBy(const Offset(0, -180));
      await tester.pump();
      expect(
        tester
            .widget<Opacity>(
              find.byKey(const ValueKey('mini-player-card-opacity')),
            )
            .opacity,
        greaterThan(0.8),
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(state.music.current?.id, 's1');
      await state.close();
    },
  );

  testWidgets(
    'full player swipes next and previous without moving transport controls or reloading prepared audio',
    (tester) async {
      final state = await _mount(tester, fullScreen: true);
      state.music.personal.settings.values['gapless'] = true;
      await state.music.playback.queueChanged();
      await tester.pumpAndSettle();
      final loads = state.player.sourceLoads;
      final controls = find.byKey(const ValueKey('now-playing-controls'));
      final bounds = tester.getRect(controls);
      final art = find.byKey(const ValueKey('now-playing-artwork-gestures'));
      await tester.drag(art, const Offset(0, -100));
      await _commitSwipe(tester);
      expect(state.music.current?.id, 's2');
      expect(tester.getRect(controls), bounds);
      state.music.playback.position.value = const Duration(seconds: 35);
      await tester.drag(art, const Offset(0, 100));
      await _commitSwipe(tester);
      expect(state.music.current?.id, 's1');
      expect(state.player.sourceLoads, loads);
      expect(tester.getRect(controls), bounds);
      expect(find.byType(NowPlayingScreen), findsOneWidget);
      await state.close();
    },
  );

  testWidgets(
    'full player coalesces rapid swipes and confirms final change once',
    (tester) async {
      final state = await _mount(tester, fullScreen: true);
      final vibrations = _haptics();
      final art = find.byKey(const ValueKey('now-playing-artwork-gestures'));
      await tester.drag(art, const Offset(0, -90));
      await tester.drag(art, const Offset(0, -90));
      expect(state.music.current?.id, 's1');
      expect(vibrations, isEmpty);
      await _commitSwipe(tester);
      expect(state.music.current?.id, 's0');
      expect(vibrations.length, 1);
      expect(tester.takeException(), isNull);
      await state.close();
    },
  );

  testWidgets('full player cancelled and short drags keep the current track', (
    tester,
  ) async {
    final state = await _mount(tester, fullScreen: true);
    final art = find.byKey(const ValueKey('now-playing-artwork-gestures'));
    final gesture = await tester.startGesture(tester.getCenter(art));
    await gesture.moveBy(const Offset(0, -90));
    await tester.pump();
    await gesture.cancel();
    await _commitSwipe(tester);
    expect(
      state.music.current?.id,
      's1',
      reason: 'pointer cancellation must not select a track',
    );
    await tester.timedDrag(
      art,
      const Offset(0, -24),
      const Duration(milliseconds: 350),
    );
    await _commitSwipe(tester);
    expect(state.music.current?.id, 's1');
    final seek = find.byKey(const ValueKey('now-playing-seek'));
    await tester.ensureVisible(seek);
    await tester.drag(seek, const Offset(80, 0));
    await tester.pumpAndSettle();
    expect(state.music.current?.id, 's1');
    expect(state.player.lastSeek, greaterThan(Duration.zero));
    await state.close();
  });

  testWidgets('full player swipes work with reduced motion', (tester) async {
    final state = await _mount(tester, fullScreen: true, reducedMotion: true);
    await tester.drag(
      find.byKey(const ValueKey('now-playing-artwork-gestures')),
      const Offset(0, -90),
    );
    expect(state.music.current?.id, 's1');
    await tester.pump(const Duration(milliseconds: 499));
    expect(state.music.current?.id, 's1');
    await tester.pump(const Duration(milliseconds: 2));
    await tester.pumpAndSettle();
    expect(state.music.current?.id, 's2');
    final transform = tester.widget<Transform>(
      find.byKey(const ValueKey('now-playing-artwork-motion')),
    );
    expect(transform.transform.storage[13], 0);
    expect(tester.takeException(), isNull);
    await state.close();
  });

  testWidgets(
    'drag reveals the prepared card immediately and fades the outgoing card; cancel restores it',
    (tester) async {
      final state = await _mount(tester);
      final vibrations = _haptics();
      final current = find.byKey(const ValueKey('mini-player-current-card'));
      final before = tester.getRect(current);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Track 1')),
      );
      await gesture.moveBy(const Offset(0, -42));
      await tester.pump();
      expect(tester.getRect(current).top, lessThan(before.top));
      expect(
        tester
            .widget<Opacity>(
              find.byKey(const ValueKey('mini-player-card-opacity')),
            )
            .opacity,
        lessThan(1),
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('mini-player-upcoming-card')),
          matching: find.text('Track 2'),
        ),
        findsOneWidget,
      );
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(state.music.current?.id, 's1');
      expect(tester.getRect(current), before);
      expect(vibrations, isEmpty);
      await state.close();
    },
  );

  testWidgets('two rapid mini swipes commit the final track and vibrate once', (
    tester,
  ) async {
    final state = await _mount(tester);
    final vibrations = _haptics();
    final surface = find.byKey(const ValueKey('mini-player-gestures'));
    await tester.drag(surface, const Offset(0, -90));
    await tester.drag(surface, const Offset(0, -90));
    expect(state.music.current?.id, 's1');
    expect(vibrations, isEmpty);
    await _commitSwipe(tester);
    expect(state.music.current?.id, 's0');
    expect(vibrations.length, 1);
    await state.close();
  });

  testWidgets(
    'a failed native switch restores the old song without a success vibration',
    (tester) async {
      final native = _FailingSeek();
      final state = await _mount(tester, native: native);
      state.music.personal.settings.values['gapless'] = true;
      await state.music.playback.queueChanged();
      await tester.pumpAndSettle();
      final vibrations = _haptics();
      native.fail = true;
      await tester.drag(
        find.byKey(const ValueKey('mini-player-gestures')),
        const Offset(0, -90),
      );
      await _commitSwipe(tester);
      expect(state.music.current?.id, 's1');
      expect(vibrations, isEmpty);
      expect(state.music.notice, contains('could not play'));
      expect(
        tester
            .widget<Opacity>(
              find.byKey(const ValueKey('mini-player-card-opacity')),
            )
            .opacity,
        1,
      );
      native.fail = false;
      await state.music.togglePlay();
      await tester.pumpAndSettle();
      expect(state.music.current?.id, 's1');
      expect(native.isPlaying, isTrue);
      await state.close();
    },
  );

  testWidgets('a one-song queue never gives a false switch vibration', (
    tester,
  ) async {
    final state = await _mount(tester);
    await state.music.play(_songs[1], from: [_songs[1]]);
    await tester.pumpAndSettle();
    final vibrations = _haptics();
    await tester.drag(
      find.byKey(const ValueKey('mini-player-gestures')),
      const Offset(0, -90),
    );
    await _commitSwipe(tester);
    expect(state.music.current?.id, 's1');
    expect(vibrations, isEmpty);
    expect(
      find.byKey(const ValueKey('mini-player-upcoming-card')),
      findsNothing,
    );
    await state.close();
  });

  testWidgets(
    'a tiny horizontal movement after hold adjusts volume and release waits one second',
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
      await tester.pump(const Duration(milliseconds: 900));
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
      find.byKey(const ValueKey('mini-player-current-card')),
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
    'swipe cards move and fade but controls return to their resting positions',
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
      expect(tester.getRect(play).top, lessThan(before.top));
      await _commitSwipe(tester);
      expect(state.music.current?.id, 's2');
      expect(state.player.sourceLoads, loads);
      await tester.drag(
        find.byKey(const ValueKey('mini-player-gestures')),
        const Offset(0, 100),
      );
      await _commitSwipe(tester);
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
      await _commitSwipe(tester);
      expect(state.music.current?.id, 's2');
      expect(find.byType(NowPlayingScreen), findsNothing);
      state.music.playback.position.value = const Duration(seconds: 35);
      await tester.drag(target, const Offset(0, 100));
      await _commitSwipe(tester);
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
    await _commitSwipe(tester);
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
    expect(state.music.current?.id, 's1');
    await tester.pump(const Duration(milliseconds: 499));
    expect(state.music.current?.id, 's1');
    await tester.pump(const Duration(milliseconds: 2));
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

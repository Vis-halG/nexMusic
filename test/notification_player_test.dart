import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_music/listening_models.dart';
import 'package:nex_music/main.dart';
import 'package:nex_music/music_controller.dart';
import 'package:nex_music/music_data.dart';
import 'package:nex_music/music_ui.dart';
import 'package:nex_music/phone_services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/playback_test_player.dart';

const _track = Song(
  id: 'notification-track',
  title: 'Test song',
  artist: 'Test artist',
  kind: 'audio',
  url: 'https://example.test/song.mp3',
);

Future<({MusicController music, NexAudioHandler handler})> _controller() async {
  SharedPreferences.setMockInitialValues({});
  final player = PlaybackTestPlayer();
  final handler = NexAudioHandler(player);
  final music = MusicController(
    await SharedPreferences.getInstance(),
    player: player,
    audioHandler: handler,
  );
  music.personal.settings.values['gapless'] = false;
  await music.play(_track, from: [_track]);
  return (music: music, handler: handler);
}

void main() {
  test(
    'all shortcut combinations keep transport controls and fit five action slots',
    () {
      for (final first in NotificationPlayerAction.values) {
        for (final second in NotificationPlayerAction.values) {
          final controls = notificationPlayerControls(
            playing: true,
            first: first,
            second: second,
          );
          expect(controls.length, inInclusiveRange(3, 5));
          expect(controls.take(3).map((c) => c.action), [
            MediaAction.skipToPrevious,
            MediaAction.pause,
            MediaAction.skipToNext,
          ]);
          expect(controls.map((c) => c.label).toSet().length, controls.length);
        }
      }
    },
  );

  test(
    'notification actions operate on the active player and reflect live state',
    () async {
      final state = await _controller();
      final music = state.music, handler = state.handler;
      addTearDown(music.dispose);
      expect(handler.playbackState.value.controls.map((c) => c.label), [
        'Previous',
        'Pause',
        'Next',
        'Like',
        'Close player',
      ]);
      await handler.customAction('toggleLike');
      expect(music.isLiked(_track), true);
      expect(handler.playbackState.value.controls[3].label, 'Unlike');
      await music.setListeningSetting('notificationShortcut1', 'shuffle');
      await handler.customAction('toggleShuffle');
      expect(music.playback.queue.shuffled, true);
      expect(
        handler.playbackState.value.shuffleMode,
        AudioServiceShuffleMode.all,
      );
      expect(handler.playbackState.value.controls[3].label, 'Turn shuffle off');
      await music.setListeningSetting('notificationShortcut1', 'repeat');
      await handler.customAction('toggleRepeat');
      expect(music.playback.queue.repeat, MusicRepeat.all);
      expect(
        handler.playbackState.value.repeatMode,
        AudioServiceRepeatMode.all,
      );
      await handler.customAction('toggleRepeat');
      expect(music.playback.queue.repeat, MusicRepeat.one);
      expect(handler.playbackState.value.controls[3].label, 'Turn repeat off');
      await handler.pause();
      expect(music.playing, false);
      expect(handler.playbackState.value.controls[1].label, 'Play');
      await handler.play();
      expect(music.playing, true);
    },
  );

  testWidgets('shortcut settings update the player immediately and persist', (
    tester,
  ) async {
    final state = await _controller();
    final music = state.music;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: music,
        child: MaterialApp(
          theme: NexMusic.theme(Brightness.light),
          home: const NotificationPlayerSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notification-shortcut-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Shuffle').last);
    await tester.pumpAndSettle();
    expect(
      state.handler.playbackState.value.controls[3].label,
      'Turn shuffle on',
    );
    expect(music.playing, true);
    await music.personal.saved;
    final restored = MusicController(
      await SharedPreferences.getInstance(),
      player: PlaybackTestPlayer(),
    );
    expect(restored.personal.settings.text('notificationShortcut1'), 'shuffle');
    restored.dispose();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    music.dispose();
    await tester.pump();
  });
}

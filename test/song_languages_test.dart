import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_music/main.dart';
import 'package:nex_music/listening_models.dart';
import 'package:nex_music/music_controller.dart';
import 'package:nex_music/music_data.dart';
import 'package:nex_music/music_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/playback_test_player.dart';

Song track(String id, String language) => Song(
  id: id,
  title: '$id song',
  language: language,
  kind: 'audio',
  url: 'https://example.test/$id.mp3',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Hindi and English default; only certain language metadata excludes songs',
    () {
      final settings = ListeningSettings();
      expect(settings.selectedLanguages, {'Hindi', 'English'});
      for (final language in [
        '',
        'unknown',
        'und',
        'instrumental',
        'Hindi / Punjabi',
        'hi-IN',
        'ENG',
      ]) {
        expect(
          settings.allowsLanguage(track('s', language)),
          isTrue,
          reason: language,
        );
      }
      expect(settings.allowsLanguage(track('s', 'Punjabi')), isFalse);
      expect(settings.allowsLanguage(track('s', 'ta')), isFalse);
    },
  );

  test(
    'language changes filter catalogue, queue, history and direct playback, and persist',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final player = PlaybackTestPlayer();
      final music = MusicController(prefs, player: player);
      music.personal.settings.values['gapless'] = false;
      final songs = [
        track('hindi', 'Hindi'),
        track('english', 'English'),
        track('punjabi', 'Punjabi'),
        track('unknown', ''),
      ];
      music.songs = songs;
      expect(music.songsIn(null).map((s) => s.id), [
        'hindi',
        'english',
        'unknown',
      ]);
      await music.play(songs.first, from: songs);
      expect(music.queue.map((s) => s.id), ['hindi', 'english', 'unknown']);
      await music.next();
      expect(music.current?.id, 'english');
      await music.setListeningSetting('songLanguages', ['Hindi', 'Punjabi']);
      expect(player.playing, isFalse);
      expect(music.current, isNull);
      expect(music.queue.map((s) => s.id), ['hindi', 'unknown']);
      expect(music.playback.queue.history, isNot(contains('english')));
      await music.play(songs[1]);
      expect(player.playing, isFalse);
      await music.play(songs[2], from: songs);
      expect(music.current?.id, 'punjabi');
      expect(music.queue.map((s) => s.id), ['hindi', 'punjabi', 'unknown']);
      await music.next();
      expect(music.current?.id, 'unknown');
      await music.personal.saved;
      music.dispose();
      final restored = MusicController(prefs, player: PlaybackTestPlayer());
      expect(restored.personal.settings.selectedLanguages, {
        'Hindi',
        'Punjabi',
      });
      expect(restored.queue.every(restored.allowsSong), isTrue);
      restored.dispose();
    },
  );

  testWidgets(
    'Profile language choices save immediately and keep unknown songs',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final music = MusicController(
        await SharedPreferences.getInstance(),
        player: PlaybackTestPlayer(),
      );
      music.songs = [
        track('hindi', 'Hindi'),
        track('punjabi', 'Punjabi'),
        track('unknown', ''),
      ];
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: music,
          child: MaterialApp(
            theme: NexMusic.theme(Brightness.light),
            home: const SongLanguagesScreen(),
          ),
        ),
      );
      expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, 'Hindi'))
            .selected,
        isTrue,
      );
      expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, 'English'))
            .selected,
        isTrue,
      );
      final punjabi = find.widgetWithText(FilterChip, 'Punjabi');
      await tester.ensureVisible(punjabi);
      await tester.tap(punjabi);
      await tester.pumpAndSettle();
      expect(music.songsIn(null).length, 3);
      await tester.tap(find.widgetWithText(FilterChip, 'Hindi'));
      await tester.pumpAndSettle();
      expect(music.songsIn(null).map((s) => s.id), ['punjabi', 'unknown']);
      await tester.pumpWidget(const SizedBox.shrink());
      music.dispose();
    },
  );
}

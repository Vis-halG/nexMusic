import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_music/main.dart';
import 'package:nex_music/music_controller.dart';
import 'package:nex_music/music_data.dart';
import 'package:nex_music/music_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/playback_test_player.dart';

void main() {
  for (final scale in [1.0, 1.5]) {
    testWidgets(
      'track changes keep title, seek and controls stationary at text scale $scale',
      (tester) async {
        tester.view.physicalSize = const Size(412, 915);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        final music = MusicController(
          await SharedPreferences.getInstance(),
          player: PlaybackTestPlayer(),
        );
        const song = Song(
          id: 'short',
          title: 'Chinni Chinni',
          kind: 'audio',
          artist: 'Mohit Chauhan',
          url: 'https://example.test/s.mp3',
        );
        void change(Song next) {
          music.playback.queue.replace([next], next);
          music.current = next;
          music.notifyListeners();
        }

        change(song);
        await tester.pumpWidget(
          ChangeNotifierProvider.value(
            value: music,
            child: MaterialApp(
              theme: NexMusic.theme(Brightness.light),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: const NowPlayingScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        const keys = [
          'now-playing-details',
          'now-playing-title',
          'now-playing-seek',
          'now-playing-controls',
        ];
        final positions = {
          for (final key in keys)
            key: tester.getRect(find.byKey(ValueKey(key))),
        };
        for (final next in [
          song.copyWith(
            id: 'long',
            title:
                'A very long song title that must never wrap onto another line even when it has many words',
            artist:
                'An equally long list of credited singers, composers and performers',
          ),
          song.copyWith(
            id: 'yt',
            providerId: 'ytmusic',
            title: 'छोटी सी कहानी और बहुत लंबा गाने का नाम',
          ),
          song.copyWith(id: 'private-1', title: 'Private song'),
        ]) {
          change(next);
          await tester.pumpAndSettle();
          for (final key in keys) {
            expect(
              tester.getRect(find.byKey(ValueKey(key))),
              positions[key],
              reason: '${next.id}: $key moved',
            );
          }
          final title = tester.widget<Text>(
            find.byKey(const ValueKey('now-playing-title')),
          );
          expect(title.maxLines, 1);
          expect(title.overflow, TextOverflow.ellipsis);
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        music.dispose();
      },
    );
  }
}

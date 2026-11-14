import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_music/main.dart';
import 'package:nex_music/music_controller.dart';
import 'package:nex_music/music_data.dart';
import 'package:nex_music/music_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'music_discovery_test.dart' show FakeMusicProvider;
import 'support/playback_test_player.dart';

class _CategoryProvider extends FakeMusicProvider {
  _CategoryProvider() : super('jiosaavn', []);
  final queries = <String>[];

  @override
  Future<List<Song>> searchSongs(
    String query, {
    int limit = 20,
    int page = 1,
  }) async {
    queries.add(query);
    return [
      Song(
        id: 'result:$query',
        title: 'Result for $query',
        kind: 'audio',
        url: 'https://example.test/song.mp3',
      ),
    ];
  }
}

void main() {
  testWidgets(
    'search opens focused and browsing dismisses the keyboard on scroll',
    (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final music = MusicController(
        await SharedPreferences.getInstance(),
        player: PlaybackTestPlayer(),
      );
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: music,
          child: MaterialApp(
            theme: NexMusic.theme(Brightness.light),
            home: const SearchScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final editable = tester.widget<EditableText>(find.byType(EditableText));
      expect(editable.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.hasAnyClients, isTrue);

      await tester.drag(find.byType(Scrollable).last, const Offset(0, -250));
      await tester.pump();
      expect(editable.focusNode.hasFocus, isFalse);
      expect(tester.testTextInput.hasAnyClients, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      music.dispose();
    },
  );

  for (final category in ['Pop & Hits', 'Nature Sounds']) {
    testWidgets(
      'browsing $category starts a provider search and shows its songs',
      (tester) async {
        tester.view.physicalSize = const Size(360, 780);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        final provider = _CategoryProvider();
        final music = MusicController(
          await SharedPreferences.getInstance(),
          player: PlaybackTestPlayer(),
          musicProvider: provider,
        );
        await tester.pumpWidget(
          ChangeNotifierProvider.value(
            value: music,
            child: MaterialApp(
              theme: NexMusic.theme(Brightness.light),
              home: const SearchScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
        expect(grid.delegate.estimatedChildCount, 72);
        await tester.scrollUntilVisible(
          find.text(category),
          500,
          scrollable: find.byType(Scrollable).last,
          maxScrolls: 30,
        );
        await tester.tap(find.text(category));
        await tester.pumpAndSettle();
        final query = category == 'Pop & Hits' ? 'Pop hits' : 'Nature sounds';
        expect(provider.queries, [query]);
        expect(find.text('Result for $query'), findsWidgets);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        music.dispose();
      },
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_music/main.dart';
import 'package:nex_music/music_controller.dart';
import 'package:nex_music/music_data.dart';
import 'package:nex_music/music_provider.dart';
import 'package:nex_music/music_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/playback_test_player.dart';

class _ArtistProvider extends Fake implements MusicProvider {
  final pages = <int>[];
  bool failNext = false;
  @override
  String get id => 'jiosaavn';
  @override
  String get displayName => 'Test catalogue';
  Song song(String id, {String artist = 'Singer'}) => Song(
    id: id,
    title: 'Artist song $id',
    artist: artist,
    kind: 'audio',
    providerId: 'jiosaavn',
    sourceId: id,
    url: '',
  );
  @override
  Future<List<Song>> searchSongs(
    String query, {
    int limit = 20,
    int page = 1,
  }) async {
    pages.add(page);
    if (failNext) {
      failNext = false;
      throw StateError('Offline');
    }
    return switch (page) {
      1 => [song('a'), song('b'), song('unrelated', artist: 'Other singer')],
      2 => [song('b'), song('c')],
      _ => [],
    };
  }
}

void main() {
  testWidgets(
    'artist songs paginate beyond first results and keep existing songs on failure',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final provider = _ArtistProvider();
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
            home: ArtistAlbumScreen(song: provider.song('seed')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Artist song a'), findsOneWidget);
      expect(find.text('Artist song unrelated'), findsNothing);
      provider.failNext = true;
      await tester.tap(find.text('Load more songs'));
      await tester.pumpAndSettle();
      expect(find.text('Artist song a'), findsOneWidget);
      expect(find.textContaining('Tap to retry'), findsOneWidget);
      await tester.tap(find.textContaining('Tap to retry'));
      await tester.pumpAndSettle();
      expect(find.text('Artist song c'), findsOneWidget);
      expect(find.text('Artist song b'), findsOneWidget);
      await tester.tap(find.text('Load more songs'));
      await tester.pumpAndSettle();
      expect(find.text('Load more songs'), findsNothing);
      expect(provider.pages, [1, 2, 2, 3]);
      await tester.pumpWidget(const SizedBox.shrink());
      music.dispose();
    },
  );
}

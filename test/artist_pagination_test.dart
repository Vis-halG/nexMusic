import 'dart:async';
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
  _ArtistProvider([this.id = 'jiosaavn']);
  final pages = <int>[];
  int? failPage;
  Completer<void>? secondPage;
  Completer<void>? firstPage;
  bool repeatPage = false;
  @override
  final String id;
  @override
  String get displayName => 'Test catalogue';
  Song song(String id, {String artist = 'Singer'}) => Song(
    id: id,
    title: 'Artist song $id',
    artist: artist,
    kind: 'audio',
    providerId: this.id,
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
    if (page == 1) await firstPage?.future;
    if (failPage == page) {
      failPage = null;
      throw StateError('Offline');
    }
    if (page == 2) await secondPage?.future;
    if (repeatPage) return [song('a'), song('b')];
    return switch (page) {
      1 => [song('a'), song('b'), song('unrelated', artist: 'Other singer')],
      2 => [song('b'), song('c')],
      _ => [],
    };
  }
}

void main() {
  testWidgets(
    'a fast source displays artist songs while another source is still loading',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final pending = Completer<void>();
      final first = _ArtistProvider();
      final second = _ArtistProvider('ytmusic')..firstPage = pending;
      final music = MusicController(
        await SharedPreferences.getInstance(),
        player: PlaybackTestPlayer(),
        musicProviders: [first, second],
      );
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: music,
          child: MaterialApp(home: ArtistAlbumScreen(song: first.song('seed'))),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Artist song a'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      pending.complete();
      await tester.pumpAndSettle();
      expect(first.pages, [1, 2, 3]);
      expect(second.pages, [1, 2, 3]);
      await tester.pumpWidget(const SizedBox.shrink());
      music.dispose();
    },
  );
  testWidgets(
    'artist songs paginate beyond first results and keep existing songs on failure',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final provider = _ArtistProvider()..failPage = 2;
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
      expect(find.text('Artist song a'), findsOneWidget);
      expect(find.textContaining('Tap to retry'), findsOneWidget);
      await tester.tap(find.textContaining('Tap to retry'));
      await tester.pumpAndSettle();
      expect(find.text('Artist song c'), findsOneWidget);
      expect(find.text('Artist song b'), findsOneWidget);
      expect(find.text('Load more songs'), findsNothing);
      expect(provider.pages, [1, 2, 2, 3]);
      await tester.pumpWidget(const SizedBox.shrink());
      music.dispose();
    },
  );

  testWidgets(
    'opening an artist automatically loads every page without scrolling or displaying counts',
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
            home: ArtistAlbumScreen(song: provider.song('seed')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(provider.pages, [1, 2, 3]);
      expect(find.text('Artist song a'), findsOneWidget);
      expect(find.text('Artist song b'), findsOneWidget);
      expect(find.text('Artist song c'), findsOneWidget);
      expect(find.text('Artist song unrelated'), findsNothing);
      expect(find.text('Load more songs'), findsNothing);
      expect(find.textContaining(RegExp(r'^\d+ songs')), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      music.dispose();
    },
  );

  testWidgets('repeated provider pages stop automatic loading', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final provider = _ArtistProvider()..repeatPage = true;
    final music = MusicController(
      await SharedPreferences.getInstance(),
      player: PlaybackTestPlayer(),
      musicProvider: provider,
    );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: music,
        child: MaterialApp(
          home: ArtistAlbumScreen(song: provider.song('seed')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(provider.pages, [1, 2]);
    expect(find.text('Artist song a'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    music.dispose();
  });

  testWidgets(
    'leaving the artist page stops pagination after an in-flight request',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final pending = Completer<void>();
      final provider = _ArtistProvider()..secondPage = pending;
      final music = MusicController(
        await SharedPreferences.getInstance(),
        player: PlaybackTestPlayer(),
        musicProvider: provider,
      );
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: music,
          child: MaterialApp(
            home: ArtistAlbumScreen(song: provider.song('seed')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('Artist song a'), findsOneWidget);
      expect(provider.pages, [1, 2]);
      await tester.pumpWidget(const SizedBox.shrink());
      pending.complete();
      await tester.pump();
      await tester.pump();
      expect(provider.pages, [1, 2]);
      expect(tester.takeException(), isNull);
      music.dispose();
    },
  );

  testWidgets(
    'partial provider failures preserve visible tracks and retry the same page',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final first = _ArtistProvider();
      final second = _ArtistProvider('ytmusic')..failPage = 2;
      final music = MusicController(
        await SharedPreferences.getInstance(),
        player: PlaybackTestPlayer(),
        musicProviders: [first, second],
      );
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: music,
          child: MaterialApp(home: ArtistAlbumScreen(song: first.song('seed'))),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Artist song c'), findsOneWidget);
      expect(find.textContaining('Tap to retry'), findsOneWidget);
      await tester.tap(find.textContaining('Tap to retry'));
      await tester.pumpAndSettle();
      expect(first.pages, [1, 2, 3]);
      expect(second.pages, [1, 2, 2, 3]);
      expect(find.text('Artist song c'), findsOneWidget);
      expect(find.textContaining('Tap to retry'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      music.dispose();
    },
  );
}

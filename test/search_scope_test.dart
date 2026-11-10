import 'dart:async';
import 'dart:io';

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

Song _song(String id, {bool online = false, String? title}) => Song(
  id: id,
  title: title ?? 'Match $id',
  artist: 'Singer $id',
  kind: 'audio',
  url: 'https://example.test/$id.mp3',
  providerId: online ? 'jiosaavn' : '',
  sourceId: online ? id : '',
);

class _SearchProvider extends FakeMusicProvider {
  _SearchProvider(List<Song> songs) : super('jiosaavn', songs);

  final queries = <String>[];
  final pending = <String, Completer<List<Song>>>{};

  @override
  Future<List<Song>> searchSongs(
    String query, {
    int limit = 20,
    int page = 1,
  }) async {
    queries.add(query);
    if (pending[query] case final response?) return response.future;
    return songs
        .where((song) => song.title.toLowerCase().contains(query.toLowerCase()))
        .toList();
  }
}

Future<MusicController> _music(_SearchProvider provider) async {
  SharedPreferences.setMockInitialValues({});
  return MusicController(
    await SharedPreferences.getInstance(),
    player: PlaybackTestPlayer(),
    musicProvider: provider,
  )..signedIn = true;
}

Future<void> _show(
  WidgetTester tester,
  MusicController music, {
  Widget? home,
}) async {
  tester.view.physicalSize = const Size(440, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: music,
      child: home == null
          ? const NexMusic()
          : MaterialApp(theme: NexMusic.theme(Brightness.light), home: home),
    ),
  );
  await tester.pumpAndSettle();
}

List<String> _shownSongs(WidgetTester tester) => tester
    .widgetList<SongTile>(find.byType(SongTile))
    .map((tile) => tile.song.id)
    .toList();

Future<void> _finish(WidgetTester tester, MusicController music) async {
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
  music.dispose();
}

void main() {
  testWidgets('Home shows online first, then only saved library sources', (
    tester,
  ) async {
    final online = _song('online', online: true);
    final provider = _SearchProvider([online]);
    final music = await _music(provider)
      ..songs = [_song('upload')];
    music.personal.localTracks['local:phone'] = _song('local:phone');
    music.personal.createPlaylist(
      'Saved music',
      tracks: [_song('playlist', online: true)],
    );
    music.toggleLike(_song('liked', online: true));
    music.library.rememberSongs([_song('remembered', online: true)]);
    await _show(tester, music, home: const SearchScreen());
    await tester.enterText(find.byType(TextField), 'Match');
    await tester.pumpAndSettle();
    final shown = _shownSongs(tester);
    expect(shown.first, online.id);
    expect(shown.toSet(), {
      'online',
      'upload',
      'liked',
      'local:phone',
      'playlist',
    });
    expect(shown.where((id) => id == online.id), hasLength(1));
    expect(
      tester.getTopLeft(find.text('Online songs')).dy,
      lessThan(tester.getTopLeft(find.text('Library')).dy),
    );
    await _finish(tester, music);
  });

  testWidgets(
    'Home hides old results during debounce and ignores late replies',
    (tester) async {
      final provider = _SearchProvider([]);
      final first = provider.pending['first'] = Completer<List<Song>>();
      final second = provider.pending['second'] = Completer<List<Song>>();
      final music = await _music(provider);
      await _show(tester, music, home: const SearchScreen());
      await tester.enterText(find.byType(TextField), 'first');
      await tester.pump(const Duration(milliseconds: 510));
      expect(provider.queries, ['first']);
      expect(find.text('No results for "first"'), findsNothing);
      await tester.enterText(find.byType(TextField), 'second');
      first.complete([_song('old-result', online: true)]);
      await tester.pump(const Duration(milliseconds: 100));
      expect(_shownSongs(tester), isEmpty);
      await tester.pump(const Duration(milliseconds: 410));
      expect(provider.queries, ['first', 'second']);
      second.complete([_song('new-result', online: true)]);
      await tester.pumpAndSettle();
      expect(_shownSongs(tester), ['new-result']);
      await tester.enterText(find.byType(TextField), 'third');
      await tester.pump();
      expect(_shownSongs(tester), isEmpty);
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      expect(find.text('Browse Categories'), findsOneWidget);
      expect(provider.queries, ['first', 'second']);
      await _finish(tester, music);
    },
  );

  testWidgets('Stream searches online only and removes previous query rows', (
    tester,
  ) async {
    final provider = _SearchProvider([_song('online', online: true)]);
    final music = await _music(provider)
      ..songs = [_song('upload')];
    await _show(tester, music);
    await tester.tap(find.byType(NavigationDestination).at(1));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Match');
    await tester.pumpAndSettle();
    expect(_shownSongs(tester), ['online']);
    await tester.enterText(find.byType(TextField), 'Other');
    await tester.pump();
    expect(_shownSongs(tester), isEmpty);
    await tester.pumpAndSettle();
    expect(_shownSongs(tester), isEmpty);
    await _finish(tester, music);
  });

  testWidgets('Library searches its saved songs without searching providers', (
    tester,
  ) async {
    final provider = _SearchProvider([_song('online', online: true)]);
    final music = await _music(provider)
      ..songs = [_song('upload')];
    music.personal.createPlaylist(
      'Saved music',
      tracks: [_song('playlist', online: true)],
    );
    music.toggleLike(_song('liked', online: true));
    music.library.rememberSongs([_song('remembered', online: true)]);
    await _show(tester, music);
    await tester.tap(find.byType(NavigationDestination).at(2));
    await tester.pumpAndSettle();
    final queriesBefore = List.of(provider.queries);
    await tester.enterText(find.byType(TextField), 'Match');
    await tester.pumpAndSettle();
    expect(_shownSongs(tester).toSet(), {'upload', 'liked', 'playlist'});
    expect(provider.queries, queriesBefore);
    await tester.enterText(find.byType(TextField), 'playlist');
    await tester.pumpAndSettle();
    expect(_shownSongs(tester), ['playlist']);
    expect(provider.queries, queriesBefore);
    await _finish(tester, music);
  });

  testWidgets('Downloads searches complete downloaded files only', (
    tester,
  ) async {
    final folder = Directory.systemTemp.createTempSync('nexmusic-search-');
    addTearDown(() => folder.deleteSync(recursive: true));
    final file = File('${folder.path}/download.mp3')
      ..writeAsBytesSync([1, 2, 3]);
    final provider = _SearchProvider([_song('online', online: true)]);
    final music = await _music(provider)
      ..songs = [_song('upload')];
    final downloaded = _song('downloaded', online: true);
    final missing = _song('missing', online: true);
    music.personal.offlineTracks.addAll({
      downloaded.id: downloaded,
      missing.id: missing,
    });
    music.offlineSongs.addAll({
      downloaded.id: file.path,
      missing.id: '${folder.path}/missing.mp3',
    });
    await _show(tester, music);
    await tester.tap(find.byType(NavigationDestination).at(3));
    await tester.pumpAndSettle();
    final queriesBefore = List.of(provider.queries);
    await tester.enterText(find.byType(TextField), 'Match');
    await tester.pumpAndSettle();
    expect(_shownSongs(tester), ['downloaded']);
    expect(provider.queries, queriesBefore);
    await tester.enterText(find.byType(TextField), 'upload');
    await tester.pumpAndSettle();
    expect(_shownSongs(tester), isEmpty);
    expect(provider.queries, queriesBefore);
    await _finish(tester, music);
  });
}

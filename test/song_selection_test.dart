import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:nex_music/main.dart';
import 'package:nex_music/listening_models.dart';
import 'package:nex_music/music_controller.dart';
import 'package:nex_music/music_data.dart';
import 'package:nex_music/music_downloads.dart';
import 'package:nex_music/music_ui.dart';
import 'package:nex_music/song_selection.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Song _song(String id, {bool video = false}) => Song(
  id: id,
  title: 'Track $id',
  artist: 'Artist',
  kind: video ? 'video' : 'audio',
  url: 'https://example.test/$id.mp3',
);

Future<MusicController> _music() async {
  SharedPreferences.setMockInitialValues({});
  final music = MusicController(
    await SharedPreferences.getInstance(),
    player: _SelectionPlayer(),
  );
  music.personal.settings.values.addAll({
    'gapless': false,
    'crossfade': 0,
    'autoplay': false,
  });
  return music;
}

Widget _app(MusicController music, Widget home) => ChangeNotifierProvider.value(
  value: music,
  child: MaterialApp(theme: NexMusic.theme(Brightness.light), home: home),
);

Widget _list() => SongListScreen(
  title: 'All songs',
  emptyText: 'No songs',
  select: (music) => music.songs,
);

void _phone(WidgetTester tester, {Size size = const Size(360, 780)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _finish(WidgetTester tester, MusicController music) async {
  await tester.pumpWidget(const SizedBox.shrink());
  music.dispose();
}

Future<void> _selectAll(WidgetTester tester) async {
  await tester.longPress(
    find
        .descendant(of: find.byType(SongTile), matching: find.text('Track a'))
        .first,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Select all'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
          (_) async => null,
        );
  });

  test('selection removes stale tracks and keeps list order after updates', () {
    final a = _song('a'), b = _song('b'), c = _song('c');
    final selection = SongSelection(songs: [a, b, a, c]);
    selection.toggle(c, [a, b, c]);
    selection.toggle(a, [a, b, c]);
    expect(selection.selected.map((s) => s.id), ['a', 'c']);
    selection.updateSongs([c.copyWith(title: 'Renamed'), b]);
    expect(selection.selected.single.title, 'Renamed');
    selection.selectAll();
    expect(selection.selected.map((s) => s.id), ['c', 'b']);
    selection.updateSongs([]);
    expect(selection.active, false);
    expect(selection.selected, isEmpty);
    selection.dispose();
  });

  test(
    'batch play-next preserves order, deduplicates and skips videos',
    () async {
      final music = await _music();
      final a = _song('a'), b = _song('b'), c = _song('c'), d = _song('d');
      music.playback.queue.replace([a, b, d], a);
      music.playback.queue.setShuffle(true);
      await music.addSongsToQueue([
        a,
        b,
        c,
        b,
        _song('v', video: true),
      ], next: true);
      expect(music.playback.queue.tracks.map((s) => s.id), [
        'a',
        'b',
        'c',
        'd',
      ]);
      expect(music.playback.queue.peekNext()!.id, 'b');
      music.dispose();
    },
  );

  test('batch append preserves the current track and existing queue', () async {
    final music = await _music();
    final a = _song('a'), b = _song('b'), c = _song('c');
    music.playback.queue.replace([a, b], a);
    await music.addSongsToQueue([b, c, a, c, _song('v', video: true)]);
    expect(music.playback.queue.currentId, 'a');
    expect(music.playback.queue.tracks.map((s) => s.id), ['a', 'b', 'c']);
    music.dispose();
  });

  test(
    'selected playback replaces the queue with selected audio only',
    () async {
      final music = await _music();
      final a = _song('a'), b = _song('b'), c = _song('c');
      music.playback.queue.replace([a, b, c], a);
      music.playback.queue.setShuffle(true);
      await music.playSelectedSongs([c, _song('v', video: true), b, c]);
      expect(music.current?.id, 'c');
      expect(music.playback.queue.tracks.map((s) => s.id), ['c', 'b']);
      expect(music.playback.queue.shuffled, false);
      await music.playSelectedSongs([b, c], shuffle: true);
      expect(music.playback.queue.tracks.map((s) => s.id).toSet(), {'b', 'c'});
      expect(music.playback.queue.shuffled, true);
      music.dispose();
    },
  );

  test(
    'bulk likes set a shared value for mixed selections and persist',
    () async {
      final music = await _music();
      final a = _song('a'), b = _song('b');
      music.toggleLike(a);
      music.setSongsLiked([a, b, b], true);
      expect(music.isLiked(a), true);
      expect(music.isLiked(b), true);
      music.setSongsLiked([a, b], true);
      expect(music.liked, {'a', 'b'});
      await music.personal.saved;
      final restored = MusicController(
        await SharedPreferences.getInstance(),
        player: _SelectionPlayer(),
      );
      expect(restored.isLiked(a), true);
      expect(restored.isLiked(b), true);
      restored.dispose();
      music.setSongsLiked([a, b], false);
      expect(music.liked, isEmpty);
      music.dispose();
    },
  );

  test(
    'playlist batch limits and permissions leave rejected edits intact',
    () async {
      final music = await _music();
      final personal = music.personal;
      final tracks = List.generate(299, (i) => _song('$i'));
      final playlist = personal.createPlaylist('Almost full', tracks: tracks);
      final updatedAt = playlist.updatedAt;
      expect(
        () => personal.addSongsToPlaylist(playlist, [_song('a'), _song('b')]),
        throwsFormatException,
      );
      expect(playlist.tracks.length, 299);
      expect(playlist.updatedAt, updatedAt);
      personal.addSongsToPlaylist(playlist, [
        tracks.first,
        _song('a'),
        _song('a'),
      ]);
      expect(playlist.tracks.length, 300);
      final foreign = MusicPlaylist.fromJson({
        ...playlist.toJson(),
        'ownerUid': 'another-user',
        'editors': <String>[],
      });
      expect(
        () => personal.addSongsToPlaylist(foreign, [_song('z')]),
        throwsStateError,
      );
      expect(foreign.tracks.length, 300);
      expect(foreign.tracks.any((s) => s.id == 'z'), false);
      music.dispose();
    },
  );

  testWidgets(
    'long press selects; taps toggle; empty selection disables actions',
    (tester) async {
      _phone(tester);
      final music = await _music()
        ..songs = [_song('a'), _song('b')];
      await tester.pumpWidget(_app(music, _list()));
      await tester.longPress(find.text('Track b'));
      await tester.pumpAndSettle();
      expect(find.text('1 song selected'), findsOneWidget);
      expect(music.current, isNull);
      await tester.tap(find.text('Track a'));
      await tester.pumpAndSettle();
      expect(find.text('2 songs selected'), findsOneWidget);
      expect(music.current, isNull);
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(find.text('0 songs selected'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Queue'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Like'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byTooltip('Cancel selection'));
      await tester.pumpAndSettle();
      expect(find.text('All songs'), findsOneWidget);
      expect(find.byType(Checkbox), findsNothing);
      expect(tester.takeException(), isNull);
      await _finish(tester, music);
    },
  );

  testWidgets(
    'selected playback uses list order and excludes unselected songs',
    (tester) async {
      _phone(tester);
      final music = await _music()
        ..songs = [_song('a'), _song('b'), _song('c')];
      await tester.pumpWidget(_app(music, _list()));
      await tester.longPress(find.text('Track c'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Track a'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Play selected'));
      await tester.pumpAndSettle();
      expect(music.playback.queue.tracks.map((s) => s.id), ['a', 'c']);
      expect(music.current?.id, 'a');
      expect(find.byType(Checkbox), findsNothing);
      expect(tester.takeException(), isNull);
      await _finish(tester, music);
    },
  );

  testWidgets('bulk playlist addition handles existing and new playlists', (
    tester,
  ) async {
    _phone(tester);
    final music = await _music()
      ..songs = [_song('a'), _song('b')];
    final playlist = music.personal.createPlaylist(
      'My mix',
      tracks: [_song('a')],
    );
    await tester.pumpWidget(_app(music, _list()));
    await _selectAll(tester);
    await tester.tap(find.widgetWithText(TextButton, 'More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to playlist'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('My mix'));
    await tester.pumpAndSettle();
    expect(playlist.tracks.map((s) => s.id), ['a', 'b']);
    await _selectAll(tester);
    await tester.tap(find.widgetWithText(TextButton, 'More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to playlist'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New playlist'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'New selection');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(
      music.personal.playlists
          .firstWhere((p) => p.name == 'New selection')
          .tracks
          .map((s) => s.id),
      ['a', 'b'],
    );
    expect(tester.takeException(), isNull);
    await _finish(tester, music);
  });

  testWidgets(
    'playlist long press selects and bulk removal keeps other tracks',
    (tester) async {
      _phone(tester);
      final music = await _music();
      final playlist = music.personal.createPlaylist(
        'My mix',
        tracks: [_song('a'), _song('b'), _song('c')],
      );
      await tester.pumpWidget(_app(music, PlaylistScreen(id: playlist.id)));
      await tester.longPress(find.text('Track a'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Track b'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from playlist'));
      await tester.pumpAndSettle();
      expect(playlist.tracks.single.id, 'c');
      expect(find.byType(Checkbox), findsNothing);
      // Removing the last track must also leave selection available afterward.
      await tester.longPress(find.text('Track c'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from playlist'));
      await tester.pumpAndSettle();
      expect(playlist.tracks, isEmpty);
      music.personal.addSongsToPlaylist(playlist, [_song('a')]);
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Track a'));
      await tester.pumpAndSettle();
      expect(find.text('1 song selected'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _finish(tester, music);
    },
  );

  testWidgets(
    'mixed likes can be liked together; paused downloads enqueue a batch',
    (tester) async {
      _phone(tester);
      final music = await _music()
        ..songs = [_song('a'), _song('b')];
      music.toggleLike(music.songs.first);
      music.downloads.pause();
      await tester.pumpWidget(_app(music, _list()));
      await _selectAll(tester);
      await tester.tap(find.widgetWithText(TextButton, 'More'));
      await tester.pumpAndSettle();
      expect(find.text('Like selected'), findsOneWidget);
      expect(find.text('Unlike selected'), findsOneWidget);
      await tester.tap(find.text('Like selected'));
      await tester.pumpAndSettle();
      expect(music.liked, {'a', 'b'});
      await _selectAll(tester);
      await tester.tap(find.widgetWithText(TextButton, 'More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download selected'));
      await tester.pumpAndSettle();
      expect(music.downloads.jobs.keys, ['a', 'b']);
      expect(
        music.downloads.jobs.values.every(
          (j) => j.status == MusicDownloadStatus.queued,
        ),
        true,
      );
      expect(tester.takeException(), isNull);
      await _finish(tester, music);
    },
  );

  testWidgets(
    'bulk removal clears offline files without changing song catalogue',
    (tester) async {
      _phone(tester);
      final directory = Directory.systemTemp.createTempSync('nex-selection-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final music = await _music()
        ..songs = [_song('a'), _song('b')];
      for (final song in music.songs) {
        final file = File('${directory.path}/${song.id}.mp3')
          ..writeAsBytesSync([1]);
        music.offlineSongs[song.id] = file.path;
        music.personal.offlineTracks[song.id] = song;
      }
      await tester.pumpWidget(_app(music, const MusicDownloadsScreen()));
      await _selectAll(tester);
      await tester.tap(find.widgetWithText(TextButton, 'More'));
      await tester.pumpAndSettle();
      final selection = tester
          .element(find.byType(SongTile).first)
          .read<SongSelection>();
      await tester.tap(find.text('Remove downloads'));
      await tester.pump();
      await tester.runAsync(() async {
        for (var attempt = 0; attempt < 100 && selection.busy; attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
        }
      });
      await tester.pumpAndSettle();
      expect(music.downloadedSongs, isEmpty);
      expect(directory.listSync(), isEmpty);
      expect(music.songs.length, 2);
      expect(tester.takeException(), isNull);
      await _finish(tester, music);
    },
  );

  testWidgets('selection fits compact portrait and landscape with large text', (
    tester,
  ) async {
    _phone(tester, size: const Size(320, 640));
    tester.platformDispatcher.textScaleFactorTestValue = 1.4;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final music = await _music()
      ..songs = [_song('a'), _song('b')];
    await tester.pumpWidget(_app(music, _list()));
    await _selectAll(tester);
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(640, 320);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextButton, 'More'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _finish(tester, music);
  });

  test(
    'large like batches retain metadata for every liked song after restart',
    () async {
      final music = await _music();
      final songs = List.generate(600, (i) => _song('$i'));
      music.setSongsLiked(songs, true);
      await music.personal.saved;
      await music.library.saved;
      final restored = MusicController(
        await SharedPreferences.getInstance(),
        player: _SelectionPlayer(),
      );
      expect(restored.likedSongs.length, 600);
      expect(
        restored.likedSongs.map((s) => s.id).toSet(),
        songs.map((s) => s.id).toSet(),
      );
      restored.dispose();
      music.dispose();
    },
  );

  testWidgets(
    'search Select all includes community and online results and resets on query change',
    (tester) async {
      _phone(tester);
      final music = await _music()
        ..songs = [_song('a')]
        ..providerSongs = [_song('b')];
      await tester.pumpWidget(_app(music, const SearchScreen()));
      await tester.enterText(find.byType(TextField), 'Track a');
      await tester.pumpAndSettle();
      await _selectAll(tester);
      expect(find.text('2 songs selected'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Track b');
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNothing);
      expect(find.text('Search'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _finish(tester, music);
    },
  );

  testWidgets('screen selection drops removed tracks without build errors', (
    tester,
  ) async {
    _phone(tester);
    final music = await _music()
      ..songs = [_song('a'), _song('b')];
    await tester.pumpWidget(_app(music, _list()));
    await _selectAll(tester);
    music.songs = [music.songs.last];
    music.announce('Catalogue updated');
    await tester.pumpAndSettle();
    expect(find.text('1 song selected'), findsOneWidget);
    expect(find.text('Track a'), findsNothing);
    expect(tester.takeException(), isNull);
    await _finish(tester, music);
  });

  testWidgets(
    'sharing sends all selected audio attachments with real bytes and preserves offline files',
    (tester) async {
      _phone(tester);
      final directory = Directory.systemTemp.createTempSync('nex-file-share-');
      addTearDown(() => directory.deleteSync(recursive: true));
      Map? shared;
      final attachments = <List<int>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => directory.path,
          );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              null,
            );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('dev.fluttercommunity.plus/share'),
              null,
            );
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('dev.fluttercommunity.plus/share'),
            (call) async {
              shared = call.arguments as Map;
              for (final file in (shared!['paths'] as List).cast<String>()) {
                attachments.add(await File(file).readAsBytes());
              }
              return 'success';
            },
          );
      final music = await _music()
        ..songs = [_song('a'), _song('b')];
      for (var index = 0; index < music.songs.length; index++) {
        final file = File('${directory.path}/original-$index.mp3')
          ..writeAsBytesSync([index, 7, 8]);
        music.offlineSongs[music.songs[index].id] = file.path;
      }
      await tester.pumpWidget(_app(music, _list()));
      await _selectAll(tester);
      await tester.tap(find.widgetWithText(TextButton, 'More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Share selected songs'));
      await tester.pump();
      final selection = tester
          .element(find.byType(SongTile).first)
          .read<SongSelection>();
      await tester.runAsync(() async {
        for (var attempt = 0; attempt < 150 && selection.busy; attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
        }
      });
      await tester.pumpAndSettle();
      expect(shared, isNotNull);
      expect(shared!['paths'], hasLength(2));
      expect(shared!['mimeTypes'], ['audio/mpeg', 'audio/mpeg']);
      expect(shared!['text'], isNull);
      expect(attachments, [
        [0, 7, 8],
        [1, 7, 8],
      ]);
      expect(File('${directory.path}/original-0.mp3').readAsBytesSync(), [
        0,
        7,
        8,
      ]);
      expect(File('${directory.path}/original-1.mp3').readAsBytesSync(), [
        1,
        7,
        8,
      ]);
      expect(
        (shared!['paths'] as List).every(
          (file) => !File(file as String).existsSync(),
        ),
        true,
      );
      expect(selection.active, false);
      expect(tester.takeException(), isNull);
      await _finish(tester, music);
    },
  );

  testWidgets(
    'failed audio preparation retains selection and never opens the share sheet',
    (tester) async {
      _phone(tester);
      final directory = Directory.systemTemp.createTempSync(
        'nex-file-share-fail-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      var shareCalls = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => directory.path,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/share'),
        (_) async {
          shareCalls++;
          return 'success';
        },
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
        messenger.setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/share'),
          null,
        );
      });
      final music = await _music()
        ..songs = [_song('a').copyWith(url: 'device:missing')];
      await tester.pumpWidget(_app(music, _list()));
      await tester.longPress(find.text('Track a'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Share selected songs'));
      await tester.pump();
      final selection = tester
          .element(find.byType(SongTile).first)
          .read<SongSelection>();
      await tester.runAsync(() async {
        for (var attempt = 0; attempt < 100 && selection.busy; attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
        }
      });
      await tester.pumpAndSettle();
      expect(shareCalls, 0);
      expect(selection.active, true);
      expect(selection.busy, false);
      expect(selection.selected.length, 1);
      expect(
        find.textContaining('not available on this device'),
        findsOneWidget,
      );
      await _finish(tester, music);
    },
  );

  testWidgets(
    'video selection keeps playlist actions but disables audio queue controls',
    (tester) async {
      _phone(tester);
      final music = await _music()
        ..songs = [_song('a', video: true)];
      await tester.pumpWidget(_app(music, _list()));
      await tester.longPress(find.text('Track a'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.shuffle_rounded),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Queue'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'More'))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
      await _finish(tester, music);
    },
  );

  testWidgets('Back exits selection before leaving the song list', (
    tester,
  ) async {
    _phone(tester);
    final music = await _music()
      ..songs = [_song('a'), _song('b')];
    await tester.pumpWidget(
      _app(
        music,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(
                context,
              ).push(MaterialPageRoute<void>(builder: (_) => _list())),
              child: const Text('Open list'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open list'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Track a'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('All songs'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Open list'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _finish(tester, music);
  });

  testWidgets(
    'selection pill has Queue Like Download More with a separate circular shuffle',
    (tester) async {
      _phone(tester);
      final music = await _music()
        ..songs = [_song('a'), _song('b'), _song('c')];
      await tester.pumpWidget(_app(music, _list()));
      await tester.longPress(find.text('Track a'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Track c'));
      await tester.pumpAndSettle();
      final pill = find.byKey(const ValueKey('selection-actions-pill'));
      expect(tester.widget<Material>(pill).shape, isA<StadiumBorder>());
      expect(
        tester.getRect(pill).right,
        lessThan(tester.getRect(find.byTooltip('Shuffle selected')).left),
      );
      expect(
        tester.getCenter(find.text('Queue')).dx,
        lessThan(tester.getCenter(find.text('Like')).dx),
      );
      expect(
        tester.getCenter(find.text('Like')).dx,
        lessThan(tester.getCenter(find.text('Download')).dx),
      );
      expect(
        tester.getCenter(find.text('Download')).dx,
        lessThan(tester.getCenter(find.text('More')).dx),
      );
      await tester.tap(find.byTooltip('Shuffle selected'));
      await tester.pumpAndSettle();
      expect(music.playback.queue.tracks.map((s) => s.id).toSet(), {'a', 'c'});
      expect(music.playback.queue.shuffled, true);
      expect(find.byType(Checkbox), findsNothing);
      expect(tester.takeException(), isNull);
      await _finish(tester, music);
    },
  );

  testWidgets(
    'pill Download queues selected songs and skips local or saved files',
    (tester) async {
      _phone(tester);
      final directory = Directory.systemTemp.createTempSync(
        'nexmusic-pill-download-',
      );
      final saved = File('${directory.path}/saved.mp3')
        ..writeAsBytesSync([1, 2, 3]);
      final music = await _music()
        ..songs = [
          _song('a'),
          _song('b'),
          _song('local:device'),
          _song('saved'),
          _song('unselected'),
        ];
      music.offlineSongs['saved'] = saved.path;
      music.downloads.pause();
      await tester.pumpWidget(_app(music, _list()));
      await tester.longPress(find.text('Track a'));
      await tester.pumpAndSettle();
      for (final name in ['Track b', 'Track local:device', 'Track saved']) {
        await tester.tap(find.text(name));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.widgetWithText(TextButton, 'Download'));
      await tester.pumpAndSettle();
      expect(music.downloads.jobs.keys.toSet(), {'a', 'b'});
      expect(find.byType(Checkbox), findsNothing);
      expect(saved.existsSync(), true);
      expect(tester.takeException(), isNull);
      await _finish(tester, music);
      directory.deleteSync(recursive: true);
    },
  );
}

class _SelectionPlayer extends Fake implements AudioPlayer {
  final List<AudioSource> _sources = [];
  @override
  List<AudioSource> get audioSources => _sources;
  @override
  int? get currentIndex => 0;
  @override
  ProcessingState get processingState => ProcessingState.ready;
  @override
  bool get playing => false;
  @override
  Duration get duration => const Duration(minutes: 3);
  @override
  Stream<int?> get androidAudioSessionIdStream => const Stream.empty();
  @override
  Stream<PlayerState> get playerStateStream => const Stream.empty();
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<int?> get currentIndexStream => const Stream.empty();
  @override
  Stream<PlayerException> get errorStream => const Stream.empty();
  @override
  Future<Duration?> setAudioSources(
    List<AudioSource> sources, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
    ShuffleOrder? shuffleOrder,
  }) async {
    _sources
      ..clear()
      ..addAll(sources);
    return duration;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if ([
      #pause,
      #setVolume,
      #setSpeed,
      #setLoopMode,
      #play,
      #dispose,
    ].contains(invocation.memberName)) {
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

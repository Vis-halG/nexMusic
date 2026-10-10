import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nex_music/main.dart';
import 'package:nex_music/music_controller.dart';
import 'package:nex_music/music_data.dart';
import 'package:nex_music/music_sharing.dart';
import 'package:nex_music/music_ui.dart';

const track = Song(
  id: 'provider:ytmusic:one',
  providerId: 'ytmusic',
  sourceId: 'one',
  title: 'Tum Hi Ho',
  artist: 'Arijit Singh',
  durationMs: 210000,
  kind: 'audio',
  url: '',
);

class UploadMusic extends MusicController {
  UploadMusic(super.preferences, this.root, this.source);
  final Directory root;
  final File source;
  Completer<void>? pending;
  bool failPreparation = false, authenticated = true;
  int preparations = 0;
  List<UploadItem>? submitted;
  String? submittedCategory;
  @override
  String? get uid => authenticated ? 'listener' : null;
  @override
  SongFilePreparation createAudioFilePreparation({
    int? maxBytes,
    void Function(Song, int, int, double?)? onProgress,
  }) {
    preparations++;
    return SongFilePreparation(
      resolve: (_) async {
        await pending?.future;
        if (failPreparation) throw StateError('Provider unavailable');
        return source.uri.toString();
      },
      headers: (_) => {},
      maxBytes: maxBytes!,
      temporaryDirectory: () async => root,
      onProgress: onProgress,
    );
  }

  @override
  Future<void> startUploads(
    List<UploadItem> items, {
    required String categoryId,
  }) async {
    submitted = items;
    submittedCategory = categoryId;
    uploads = items;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late UploadMusic music;
  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
          (_) async => null,
        );
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('nex-stream-upload-');
    final cache = await Directory('${root.path}/cache').create();
    final file = await File(
      '${root.path}/original.mp3',
    ).writeAsBytes(List.filled(128, 1));
    music = UploadMusic(await SharedPreferences.getInstance(), cache, file);
    music.categories = [
      const MusicCategory(id: 'bolly', name: 'Bollywood', ownerUid: 'listener'),
    ];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => cache.path,
        );
  });
  tearDown(() async {
    music.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (await root.exists()) await root.delete(recursive: true);
  });
  Widget app(Widget home) => ChangeNotifierProvider<MusicController>.value(
    value: music,
    child: MaterialApp(theme: NexMusic.theme(Brightness.light), home: home),
  );

  Future<void> settlePreparation(WidgetTester tester) async {
    for (var i = 0; i < 50; i++) {
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      if (find.text('Preparing audio for your Library...').evaluate().isEmpty) {
        await tester.pumpAndSettle();
        return;
      }
    }
    fail('Audio preparation did not finish');
  }

  testWidgets(
    'Stream menu prepares audio and uploads title, artist and duration to chosen category',
    (tester) async {
      await tester.pumpWidget(
        app(
          Scaffold(
            body: SongTile(song: track, queue: [track]),
          ),
        ),
      );
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      expect(find.text('Upload to Library'), findsOneWidget);
      await tester.tap(find.text('Upload to Library'));
      await tester.pump();
      await settlePreparation(tester);
      expect(find.byType(UploadScreen), findsOneWidget);
      expect(find.text('Tum Hi Ho'), findsOneWidget);
      expect(find.text('Arijit Singh'), findsOneWidget);
      final upload = find.widgetWithText(FilledButton, 'Upload');
      expect(tester.widget<FilledButton>(upload).onPressed, isNull);
      await tester.ensureVisible(find.text('Bollywood'));
      await tester.tap(find.text('Bollywood'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(upload);
      await tester.tap(upload);
      await tester.pumpAndSettle();
      expect(music.submittedCategory, 'bolly');
      final item = music.submitted!.single;
      expect(item.title, track.title);
      expect(item.artist, track.artist);
      expect(item.durationMs, track.durationMs);
      await tester.runAsync(() async {
        expect(await File(item.path).length(), 128);
        expect(await music.source.exists(), true);
      });
      expect(item.path, isNot(music.source.path));
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        expect(
          await File(item.path).exists(),
          true,
          reason: 'Upload owns its prepared audio',
        );
      });
    },
  );

  testWidgets('preparation can be cancelled and provider errors retried', (
    tester,
  ) async {
    music.pending = Completer<void>();
    await tester.pumpWidget(app(const UploadScreen(streamSong: track)));
    await tester.pump();
    expect(find.text('Preparing audio for your Library...'), findsOneWidget);
    await tester.tap(find.text('Cancel preparation'));
    await tester.pumpAndSettle();
    final pending = music.pending!;
    music.pending = null;
    pending.complete();
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    music.failPreparation = true;
    await tester.tap(find.text('Retry audio'));
    await tester.pump();
    await settlePreparation(tester);
    expect(find.textContaining('Provider unavailable'), findsOneWidget);
    music.failPreparation = false;
    await tester.tap(find.text('Retry audio'));
    await tester.pump();
    await settlePreparation(tester);
    expect(find.textContaining('1 file'), findsOneWidget);
    expect(music.preparations, 3);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.runAsync(() async {
      expect(
        await Directory('${root.path}/cache/nexmusic_uploads').list().toList(),
        isEmpty,
      );
      expect(await music.source.exists(), true);
    });
  });

  testWidgets('guest upload does not download audio', (tester) async {
    music.authenticated = false;
    await tester.pumpWidget(
      app(
        Scaffold(
          body: SongTile(song: track, queue: [track]),
        ),
      ),
    );
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Upload to Library'));
    await tester.pumpAndSettle();
    expect(music.preparations, 0);
    expect(find.byType(UploadScreen), findsNothing);
    expect(music.notice, contains('Sign in'));
    await tester.pumpWidget(const SizedBox());
  });
}

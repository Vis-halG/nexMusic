import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_music/main.dart';
import 'package:nex_music/music_controller.dart';
import 'package:nex_music/music_data.dart';
import 'package:nex_music/music_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _categories = [
  MusicCategory(id: 'bolly', name: 'Bollywood', ownerUid: 'u1'),
  MusicCategory(id: 'lofi', name: 'Lo-fi', ownerUid: 'u2'),
];

const _songs = [
  Song(
    id: 's1',
    title: 'Tum Hi Ho',
    kind: 'audio',
    url: 'https://example.com/1.mp3',
    categoryId: 'bolly',
    ownerUid: 'u1',
    ownerName: 'Vishal',
  ),
  Song(
    id: 's2',
    title: 'Kesariya',
    kind: 'video',
    url: 'https://example.com/2.mp4',
    categoryId: 'bolly',
    ownerUid: 'u2',
    ownerName: 'Aman',
  ),
  Song(
    id: 's3',
    title: 'Lofi Rain',
    kind: 'audio',
    url: 'https://example.com/3.mp3',
    categoryId: 'lofi',
    ownerUid: 'u2',
    ownerName: 'Riya',
  ),
];

Future<MusicController> _controller() async {
  SharedPreferences.setMockInitialValues({});
  return MusicController(await SharedPreferences.getInstance());
}

Widget _app(MusicController controller, {Widget? home}) =>
    ChangeNotifierProvider.value(
      value: controller,
      child: home == null
          ? const NexMusic()
          : MaterialApp(theme: NexMusic.theme(Brightness.light), home: home),
    );

/// A page with the upload screen for a shared link one tap away, so the upload
/// screen has somewhere to close back to.
class _SharedLinkOpener extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                const UploadScreen(sharedLink: 'https://youtu.be/abc'),
          ),
        ),
        child: const Text('Open shared link'),
      ),
    ),
  );
}

void _usePhone(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('video switch is offered only for matching YouTube sources', (
    tester,
  ) async {
    final music = await _controller();
    const audio = Song(
      id: 'provider:jiosaavn:123',
      title: 'Audio recording',
      kind: 'audio',
      url: '',
      providerId: 'jiosaavn',
      sourceId: '123',
      artist: 'Singer',
    );
    music.playback.queue.replace([audio], audio);
    music.current = audio;
    await tester.pumpWidget(_app(music, home: const NowPlayingScreen()));
    expect(find.text('Video'), findsNothing);
    expect(find.text('Watch Music Video'), findsNothing);
    final video = audio.copyWith(
      id: 'provider:ytmusic:abcdefghijk',
      providerId: 'ytmusic',
      sourceId: 'abcdefghijk',
    );
    music.playback.queue.replace([video], video);
    music.current = video;
    music.notifyListeners();
    await tester.pump();
    expect(find.text('Video'), findsOneWidget);
    expect(find.text('Watch Music Video'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    music.dispose();
    await tester.pump();
  });

  testWidgets('shows the sign-in screen when signed out', (tester) async {
    final controller = await _controller();

    await tester.pumpWidget(_app(controller));
    await tester.pump();

    expect(find.text('nexMusic'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('home lists every upload and filters by category', (
    tester,
  ) async {
    _usePhone(tester, const Size(1080, 2340));
    final controller = await _controller()
      ..signedIn = true
      ..categories = _categories
      ..songs = _songs;

    await tester.pumpWidget(_app(controller));
    await tester.pumpAndSettle();

    expect(find.text('Tum Hi Ho'), findsWidgets);
    expect(find.text('Kesariya'), findsWidgets);
    expect(find.text('Lofi Rain'), findsWidgets);

    // The category pill comes before the song subtitles that repeat its name.
    await tester.tap(find.text('Lo-fi').first);
    await tester.pumpAndSettle();
    expect(find.text('Lofi Rain'), findsOneWidget);
    expect(find.text('Tum Hi Ho'), findsNothing);

    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    expect(find.text('Tum Hi Ho'), findsWidgets);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('anyone can edit or delete an upload from its menu', (
    tester,
  ) async {
    _usePhone(tester, const Size(1080, 2340));
    final controller = await _controller()
      ..signedIn = true
      ..categories = _categories
      ..songs = _songs;

    await tester.pumpWidget(_app(controller));
    await tester.pumpAndSettle();

    expect(find.textContaining('Aman'), findsNothing);
    // "Kesariya" was uploaded by someone else.
    await tester.tap(find.byTooltip('More').at(1));
    await tester.pumpAndSettle();
    expect(find.text('Edit or move'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('home shows upload progress while a batch runs', (tester) async {
    _usePhone(tester, const Size(1080, 2340));
    final controller = await _controller()
      ..signedIn = true
      ..categories = _categories
      ..songs = _songs
      ..uploads = [
        UploadItem(path: 'a.mp3', name: 'a.mp3', sizeBytes: 1000, title: 'A')
          ..status = UploadStatus.done,
        UploadItem(path: 'b.mp3', name: 'b.mp3', sizeBytes: 1000, title: 'B')
          ..status = UploadStatus.uploading
          ..progress = 0.4,
      ];

    await tester.pumpWidget(_app(controller));
    await tester.pump();

    expect(find.text('Uploading'), findsOneWidget);
    expect(find.text('1 of 2 processed'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('now playing fits compact portrait and landscape screens', (
    tester,
  ) async {
    _usePhone(tester, const Size(1080, 1920));
    final controller = await _controller()
      ..signedIn = true
      ..categories = _categories
      ..songs = _songs
      ..current = _songs.first
      ..queue = [_songs.first, _songs.last]
      ..duration = const Duration(minutes: 3, seconds: 20);
    controller.playback.queue.replace([
      _songs.first,
      _songs.last,
    ], _songs.first);

    await tester.pumpWidget(_app(controller, home: const NowPlayingScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Tum Hi Ho'), findsOneWidget);
    // Only the category is shown, never the uploader's name.
    expect(find.text('Bollywood'), findsOneWidget);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(1920, 1080);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('upload stays disabled until files and category are chosen', (
    tester,
  ) async {
    _usePhone(tester, const Size(1080, 2340));
    final controller = await _controller()
      ..signedIn = true
      ..categories = _categories;

    await tester.pumpWidget(_app(controller, home: const UploadScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Choose audio songs'), findsOneWidget);
    final upload = find.widgetWithText(FilledButton, 'Upload');
    expect(upload, findsOneWidget);
    expect(tester.widget<FilledButton>(upload).onPressed, isNull);

    // A category alone is not enough without any files.
    await tester.tap(find.text('Lo-fi'));
    await tester.pump();
    expect(tester.widget<FilledButton>(upload).onPressed, isNull);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('finished uploads list each file and offer a retry', (
    tester,
  ) async {
    _usePhone(tester, const Size(1080, 2340));
    final controller = await _controller()
      ..signedIn = true
      ..categories = _categories
      ..uploads = [
        UploadItem(
            path: 'a.mp3',
            name: 'a.mp3',
            sizeBytes: 3000000,
            title: 'Song A',
          )
          ..status = UploadStatus.done
          ..progress = 1,
        UploadItem(
          path: 'b.mp3',
          name: 'b.mp3',
          sizeBytes: 3000000,
          title: 'Song B',
        )..status = UploadStatus.skipped,
        UploadItem(
            path: 'c.mp3',
            name: 'c.mp3',
            sizeBytes: 3000000,
            title: 'Song C',
          )
          ..status = UploadStatus.failed
          ..error = 'Network error',
      ];

    await tester.pumpWidget(_app(controller, home: const UploadScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Upload finished'), findsOneWidget);
    expect(find.text('3 of 3 processed'), findsOneWidget);
    expect(find.text('Song A'), findsOneWidget);
    expect(find.text('Retry failed (1)'), findsOneWidget);
    expect(find.text('Done'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('category manager lists categories with song counts', (
    tester,
  ) async {
    _usePhone(tester, const Size(1080, 2340));
    final controller = await _controller()
      ..signedIn = true
      ..categories = _categories
      ..songs = _songs;

    await tester.pumpWidget(
      _app(controller, home: const CategoryManagerScreen()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Categories'), findsOneWidget);
    expect(find.text('Bollywood'), findsOneWidget);
    // Every category can be renamed or deleted, whoever created it.
    expect(find.text('2 songs'), findsOneWidget);
    expect(find.text('1 song'), findsOneWidget);
    expect(find.byTooltip('Rename'), findsNWidgets(_categories.length));
    expect(find.byTooltip('Delete'), findsNWidgets(_categories.length));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('upload screen links to category editing', (tester) async {
    _usePhone(tester, const Size(1080, 2340));
    final controller = await _controller()
      ..signedIn = true
      ..categories = _categories;

    await tester.pumpWidget(_app(controller, home: const UploadScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Categories'), findsOneWidget);
    expect(find.text('Lo-fi'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('a single audio upload offers trimming', (tester) async {
    _usePhone(tester, const Size(1080, 2340));
    final file = File('${Directory.systemTemp.path}/nexmusic_trim_test.mp3')
      ..writeAsBytesSync(List.filled(2048, 1));
    addTearDown(() {
      if (file.existsSync()) file.deleteSync();
    });
    final controller = await _controller()
      ..signedIn = true
      ..categories = _categories;

    await tester.pumpWidget(
      _app(controller, home: UploadScreen(initialPaths: [file.path])),
    );
    await tester.pumpAndSettle();

    expect(find.text('1 file · 2 KB'), findsOneWidget);
    expect(find.text('Trim audio'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('a shared link can be sent to upload before its audio is ready', (
    tester,
  ) async {
    _usePhone(tester, const Size(1080, 2340));
    final controller = await _controller()
      ..signedIn = true
      ..categories = _categories;

    await tester.pumpWidget(_app(controller, home: _SharedLinkOpener()));
    await tester.tap(find.text('Open shared link'));
    // The fetch spinner never settles, so pump frames by hand.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final job = SharedAudioJob.running.value.single;
    expect(find.text('Getting the audio'), findsOneWidget);
    expect(find.text('Finding a converter…'), findsOneWidget);
    final upload = find.widgetWithText(FilledButton, 'Upload');
    expect(tester.widget<FilledButton>(upload).onPressed, isNull);

    // Title and category can be chosen while the audio is on its way.
    await tester.enterText(find.byType(TextField), 'My song');
    await tester.tap(find.text('Lo-fi'));
    await tester.pump();
    expect(tester.widget<FilledButton>(upload).onPressed, isNotNull);

    // Upload does not wait for the download: the screen closes at once.
    await tester.tap(upload);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(job.uploadRequested, isTrue);
    expect(find.text('Getting the audio'), findsNothing);
    expect(
      find.text('The song uploads as soon as its audio is ready.'),
      findsOneWidget,
    );

    // A converter that gives up after the screen has closed still says so.
    job.fail('The converter did not start converting.');
    await tester.pump();
    expect(
      controller.notice,
      'A shared song could not be uploaded. '
      'The converter did not start converting.',
    );
    expect(SharedAudioJob.running.value, isEmpty);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('a waiting upload starts once the shared audio arrives', (
    tester,
  ) async {
    _usePhone(tester, const Size(1080, 2340));
    final file = File('${Directory.systemTemp.path}/Nexmusic Waiting Song.mp3')
      ..writeAsBytesSync(List.filled(2048, 1));
    addTearDown(() {
      if (file.existsSync()) file.deleteSync();
    });
    final controller = await _controller()
      ..signedIn = true
      ..categories = _categories;

    await tester.pumpWidget(_app(controller, home: _SharedLinkOpener()));
    await tester.tap(find.text('Open shared link'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final job = SharedAudioJob.running.value.single;
    await tester.tap(find.text('Lo-fi'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Upload'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    job.complete(file.path);
    await tester.pump();

    // The upload was handed to the controller with its category. Test
    // controllers have no Google account, so the controller turns it away
    // with its sign-in notice rather than a missing-category one.
    expect(controller.notice, 'Sign in with Google to upload.');
    expect(SharedAudioJob.running.value, isEmpty);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('shared audio that arrives before Upload joins the selection', (
    tester,
  ) async {
    _usePhone(tester, const Size(1080, 2340));
    final file = File('${Directory.systemTemp.path}/Nexmusic Shared Song.mp3')
      ..writeAsBytesSync(List.filled(2048, 1));
    addTearDown(() {
      if (file.existsSync()) file.deleteSync();
    });
    final controller = await _controller()
      ..signedIn = true
      ..categories = _categories;

    await tester.pumpWidget(
      _app(
        controller,
        home: const UploadScreen(sharedLink: 'https://youtu.be/abc'),
      ),
    );
    await tester.pump();

    SharedAudioJob.running.value.single.complete(file.path);
    await tester.pumpAndSettle();

    expect(find.text('1 file · 2 KB'), findsOneWidget);
    expect(find.text('Nexmusic Shared Song'), findsOneWidget);
    expect(SharedAudioJob.running.value, isEmpty);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('uploads in progress can be paused and cancelled', (
    tester,
  ) async {
    _usePhone(tester, const Size(1080, 2340));
    final controller = await _controller()
      ..signedIn = true
      ..categories = _categories
      ..uploads = [
        UploadItem(path: 'a.mp3', name: 'a.mp3', sizeBytes: 1000, title: 'A')
          ..status = UploadStatus.uploading
          ..progress = 0.4,
        UploadItem(path: 'b.mp3', name: 'b.mp3', sizeBytes: 1000, title: 'B'),
      ];

    await tester.pumpWidget(_app(controller, home: const UploadScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Uploading'), findsOneWidget);

    await tester.tap(find.text('Pause'));
    await tester.pumpAndSettle();
    expect(controller.uploadsPaused, isTrue);
    expect(find.text('Uploads paused'), findsOneWidget);
    expect(find.text('Resume'), findsOneWidget);

    // Cancelling asks first, then stops the songs not yet sent.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Stop uploading?'), findsOneWidget);
    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    expect(controller.uploads.last.status, UploadStatus.cancelled);
    expect(controller.uploadsPaused, isFalse);
    expect(find.textContaining('Cancelled'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}

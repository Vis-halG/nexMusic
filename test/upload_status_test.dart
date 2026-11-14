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
  testWidgets('top status slides in and out without a content jump', (
    tester,
  ) async {
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
          builder: (_, child) => UploadStatusHost(child: child!),
          home: const Scaffold(body: Text('Stable content')),
        ),
      ),
    );
    final initialTop = tester.getTopLeft(find.text('Stable content')).dy;
    final job = SharedAudioJob.start('https://youtu.be/smooth', music)
      ..report('Converting…');
    addTearDown(job.cancel);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 130));
    final entering = tester.widget<SizeTransition>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('upload-transfer-status')),
            matching: find.byType(SizeTransition),
          )
          .first,
    );
    expect(entering.sizeFactor.value, inExclusiveRange(0, 1));
    await tester.pump(const Duration(milliseconds: 150));
    final shownTop = tester.getTopLeft(find.text('Stable content')).dy;
    expect(shownTop, greaterThan(initialTop));
    expect(tester.getTopLeft(find.text('Converting…')).dy, lessThan(shownTop));

    job.cancel();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 130));
    final leaving = tester.widget<SizeTransition>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('upload-transfer-status')),
            matching: find.byType(SizeTransition),
          )
          .first,
    );
    expect(leaving.sizeFactor.value, inExclusiveRange(0, 1));
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.getTopLeft(find.text('Stable content')).dy, initialTop);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    music.dispose();
  });

  testWidgets(
    'top status shows conversion and download before actual upload, without Done',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final music = MusicController(
        await SharedPreferences.getInstance(),
        player: PlaybackTestPlayer(),
      );
      final job = SharedAudioJob.start('https://youtu.be/test', music);
      job.report('Converting…');
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: music,
          child: MaterialApp(
            theme: NexMusic.theme(Brightness.light),
            builder: (_, child) => UploadStatusHost(child: child!),
            home: const Scaffold(body: Text('Home content')),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Converting…'), findsOneWidget);
      expect(find.text('Uploading'), findsNothing);
      job.report('Downloading audio…', fraction: 0.4);
      await tester.pump();
      expect(find.text('Downloading audio…'), findsOneWidget);
      expect(find.text('40%'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        closeTo(0.4, 0.01),
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      job.cancel();
      final item =
          UploadItem(
              path: 'sample.mp3',
              name: 'sample.mp3',
              title: 'Audio',
              sizeBytes: 100,
            )
            ..status = UploadStatus.uploading
            ..progress = 0.6;
      music.uploads = [item];
      music.notifyListeners();
      await tester.pump();
      expect(find.text('Uploading'), findsOneWidget);
      expect(find.text('Converting…'), findsNothing);
      item
        ..status = UploadStatus.done
        ..progress = 1;
      music.notifyListeners();
      await tester.pump();
      expect(find.text('Upload complete'), findsOneWidget);
      expect(find.text('Done'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      music.dispose();
    },
  );
}

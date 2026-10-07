import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_music/cloudinary_status.dart';
import 'package:nex_music/main.dart';
import 'package:nex_music/music_controller.dart';
import 'package:nex_music/music_data.dart';
import 'package:nex_music/music_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

CloudinaryStatus _report() => CloudinaryStatus.fromJson({
  'cloudName': cloudinaryCloudName,
  'plan': 'Free',
  'mediaCount': 152,
  'songCount': 150,
  'otherMediaCount': 2,
  'lastUpdated': '2026-10-01',
  'fetchedAt': '2026-10-02T08:00:00Z',
  'storage': {'usage': 1073741824, 'limit': 5368709120},
  'bandwidth': {'usage': 2147483648, 'limit': 10737418240},
  'credits': {'usage': 3.5, 'limit': 25},
});

Future<MusicController> _music() async {
  SharedPreferences.setMockInitialValues({});
  final music = MusicController(await SharedPreferences.getInstance());
  music.songs = [
    const Song(
      id: 'cloud',
      title: 'Cloud song',
      kind: 'audio',
      url:
          'https://res.cloudinary.com/$cloudinaryCloudName/video/upload/nexmusic/a.mp3',
      sizeBytes: 1048576,
    ),
    const Song(
      id: 'link',
      title: 'Web link',
      kind: 'audio',
      url: 'https://example.com/a.mp3',
    ),
    const Song(
      id: 'other-account',
      title: 'Other cloud',
      kind: 'audio',
      url: 'https://res.cloudinary.com/other/video/upload/a.mp3',
    ),
  ];
  return music;
}

Widget _app(MusicController music, Widget home) => ChangeNotifierProvider.value(
  value: music,
  child: MaterialApp(theme: NexMusic.theme(Brightness.light), home: home),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'missing limits stay unknown and over-quota usage clamps only remaining',
    () {
      final unknown = CloudinaryMetric.fromJson({'usage': 100});
      expect(unknown.remaining, isNull);
      expect(unknown.fraction, isNull);
      final exhausted = CloudinaryMetric.fromJson({'usage': 30, 'limit': 25});
      expect(exhausted.remaining, 0);
      expect(exhausted.fraction, 1.2);
      expect(
        CloudinaryMetric.fromJson({
          'usage': -1,
          'limit': double.infinity,
        }).usage,
        isNull,
      );
      expect(CloudinaryMetric.fromJson({'limit': 0}).fraction, isNull);
      expect(CloudinaryStatus.fromJson({}).mediaCount, isNull);
      expect(_report().storage.remaining, 4294967296);
    },
  );

  testWidgets('Advance opens the dashboard without requiring WebView support', (
    tester,
  ) async {
    final music = await _music();
    await tester.pumpWidget(_app(music, const ProfileScreen()));
    await tester.scrollUntilVisible(find.text('Advance'), 200);
    expect(find.text('Advanced Web Browser'), findsNothing);
    await tester.tap(find.text('Advance'));
    await tester.pumpAndSettle();
    expect(find.text('Cloudinary'), findsOneWidget);
    expect(find.text('Account usage unavailable'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    music.dispose();
  });

  testWidgets(
    'report separates remote file counts from catalogue and fits narrow screens',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final music = await _music();
      await tester.pumpWidget(
        _app(music, AdvanceScreen(loadStatus: () async => _report())),
      );
      await tester.pumpAndSettle();
      expect(find.text('152 media files'), findsOneWidget);
      expect(find.text('1 listed file'), findsOneWidget);
      expect(find.textContaining('150 songs (audio formats)'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Storage used'), 150);
      expect(find.text('1.00 GB'), findsOneWidget);
      expect(find.textContaining('4.00 GB space remaining'), findsOneWidget);
      await tester.scrollUntilVisible(find.text("Today's playback usage"), 200);
      expect(find.text('Daily Cloudinary total unavailable'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      music.dispose();
    },
  );

  testWidgets('failed refresh retains the previous report and retry recovers', (
    tester,
  ) async {
    final music = await _music();
    var attempts = 0;
    await tester.pumpWidget(
      _app(
        music,
        AdvanceScreen(
          loadStatus: () async {
            if (++attempts == 2) {
              throw const CloudinaryStatusException('Temporary outage');
            }
            return _report();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Refresh Cloudinary status'));
    await tester.pumpAndSettle();
    expect(find.text('Showing previous report'), findsOneWidget);
    expect(find.text('152 media files'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Showing previous report'), findsNothing);
    expect(attempts, 3);
    await tester.pumpWidget(const SizedBox.shrink());
    music.dispose();
  });

  testWidgets('leaving while a report loads is safe', (tester) async {
    final music = await _music();
    final pending = Completer<CloudinaryStatus>();
    await tester.pumpWidget(
      _app(music, AdvanceScreen(loadStatus: () => pending.future)),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(_report());
    await tester.pump();
    expect(tester.takeException(), isNull);
    music.dispose();
  });

  testWidgets(
    'shared-credit storage is an estimate and today excludes other sources and dates',
    (tester) async {
      final music = await _music();
      final now = DateTime.now();
      final day =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      music.personal.days['today'] = {
        'date': day,
        'tracks': {
          'cloud': {
            'song': music.songs.first.toJson(),
            'ms': 120000,
            'completed': 1,
          },
          'web': {
            'song': music.songs[1].toJson(),
            'ms': 900000,
            'completed': 5,
          },
        },
      };
      music.personal.days['yesterday'] = {
        'date': '2020-01-01',
        'tracks': {
          'cloud': {
            'song': music.songs.first.toJson(),
            'ms': 900000,
            'completed': 5,
          },
        },
      };
      await tester.pumpWidget(
        _app(
          music,
          AdvanceScreen(
            loadStatus: () async => CloudinaryStatus.fromJson({
              'cloudName': cloudinaryCloudName,
              'plan': 'A long plan name that needs to fit in the header',
              'storage': {'usage': 100},
              'credits': {'usage': 3.5, 'limit': 25},
            }),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Storage used'), 150);
      expect(
        find.textContaining('Approx. 21.50 GB additional storage budget'),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(find.text("Today's playback usage"), 200);
      expect(
        find.textContaining('1 songs · 2 min · 1 completed plays'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      music.dispose();
    },
  );
}

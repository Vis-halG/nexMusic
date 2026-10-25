import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nex_music/main.dart';
import 'package:nex_music/music_controller.dart';
import 'package:nex_music/music_data.dart';
import 'package:nex_music/music_ui.dart';
import 'music_discovery_test.dart' show FakeMusicProvider;

Song track(String provider, String id, {String kind = 'audio'}) => Song(
  id: 'provider:$provider:$id',
  providerId: provider,
  sourceId: id,
  title: id,
  artist: 'Artist',
  kind: kind,
  url: '',
);

void main() {
  testWidgets('four tabs remain and Stream combines both catalogues', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final controller = MusicController(
      await SharedPreferences.getInstance(),
      musicProviders: [
        FakeMusicProvider('jiosaavn', [track('jiosaavn', 'Saavn pick')]),
        FakeMusicProvider('ytmusic', [track('ytmusic', 'YouTube pick')]),
        FakeMusicProvider('ytvideo', [
          track('ytvideo', 'YouTube video', kind: 'video'),
        ]),
      ],
    )..signedIn = true;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(value: controller, child: const NexMusic()),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<NavigationDestination>(find.byType(NavigationDestination))
          .map((d) => d.label),
      ['Home', 'Stream', 'Library', 'Profile'],
    );
    await tester.tap(find.text('Never Played').first);
    await tester.pumpAndSettle();
    expect(find.text('Saavn pick'), findsWidgets);
    expect(find.text('YouTube pick'), findsWidgets);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stream'));
    await tester.pumpAndSettle();
    expect(find.text('Saavn pick'), findsWidgets);
    expect(find.text('YouTube pick'), findsWidgets);
    expect(find.byTooltip('Play random'), findsOneWidget);
    expect(find.byType(SegmentedButton<bool>), findsNothing);
    expect(find.text('Videos'), findsNothing);
    for (final label in [
      'Music previews',
      'Moods & languages',
      'Create a mix',
      'Identify a song',
    ]) {
      expect(find.text(label), findsNothing);
    }
    expect(find.text('YouTube video'), findsNothing);
    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Play random'), findsOneWidget);
    expect(find.text('Search your library'), findsOneWidget);
    // Artists and the other library tools moved to Profile.
    expect(find.text('Artists'), findsNothing);
    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();
    expect(find.text('Artists', skipOffstage: false), findsOneWidget);
    controller.current = track('ytmusic', 'YouTube pick');
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(home: NowPlayingScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Watch Music Video'), findsOneWidget);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(value: controller, child: const NexMusic()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();
    expect(find.text('Profile'), findsWidgets);
    expect(find.byTooltip('Play random'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}

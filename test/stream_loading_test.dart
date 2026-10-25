import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nex_music/main.dart';
import 'package:nex_music/music_controller.dart';
import 'package:nex_music/music_data.dart';
import 'package:nex_music/music_discovery.dart';
import 'package:nex_music/music_recommendations.dart';
import 'music_discovery_test.dart' show FakeMusicProvider;

Song track(String provider, String title) => Song(
  id: 'provider:$provider:$title',
  title: title,
  artist: 'Artist',
  kind: 'audio',
  url: '',
  providerId: provider,
  sourceId: title,
);

class SlowProvider extends FakeMusicProvider {
  SlowProvider(super.id, super.songs);
  Completer<List<Song>>? waiting;
  @override
  Future<List<Song>> loadFeatured({int limit = 20, int page = 1}) {
    calls++;
    return waiting?.future ?? Future.value(songs.take(limit).toList());
  }
}

void main() {
  test(
    'a fast provider publishes songs before the slow provider completes',
    () async {
      final fast = FakeMusicProvider('jiosaavn', [track('jiosaavn', 'Fast')]);
      final slow = SlowProvider('ytmusic', [track('ytmusic', 'Slow')])
        ..waiting = Completer();
      final discovery = MusicDiscovery([fast, slow]);
      final ready = Completer<List<Song>>();
      final result = discovery.recommendations(
        MusicTaste([]),
        accepts: (_) => true,
        onUpdate: (songs) {
          if (songs.isNotEmpty && !ready.isCompleted) ready.complete(songs);
        },
      );
      expect((await ready.future).single.title, 'Fast');
      expect(slow.waiting!.isCompleted, false);
      slow.waiting!.complete(slow.songs);
      expect((await result).map((s) => s.title), ['Fast', 'Slow']);
    },
  );
  test(
    'large histories rank in an isolate and preserve hidden cross-provider recordings',
    () async {
      final history = List.generate(
        2500,
        (i) => MusicPreference(
          track('jiosaavn', 'History $i'),
          liked: i % 20 == 0,
        ),
      );
      final fast = FakeMusicProvider('jiosaavn', [
        track('jiosaavn', 'Visible'),
        track('jiosaavn', 'Hidden'),
      ]);
      final discovery = MusicDiscovery([fast]);
      history.add(MusicPreference(track('ytmusic', 'Hidden'), liked: true));
      final result = await discovery.recommendations(
        MusicTaste(history),
        accepts: (song) => song.id != 'provider:ytmusic:Hidden',
      );
      expect(result.map((s) => s.title), ['Visible']);
    },
  );
  testWidgets(
    'Stream retains search and loaded feed across tabs and pending refresh',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final fast = SlowProvider('jiosaavn', [track('jiosaavn', 'Loaded song')]);
      final controller = MusicController(
        await SharedPreferences.getInstance(),
        musicProviders: [fast],
      )..signedIn = true;
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const NexMusic(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stream'));
      await tester.pumpAndSettle();
      final stream = find.byKey(const PageStorageKey('stream'));
      final before = tester.widget(stream);
      controller.notifyListeners();
      await tester.pump();
      expect(
        identical(before, tester.widget(stream)),
        true,
        reason: 'Playback progress must not rebuild the entire Stream feed',
      );
      final search = find.widgetWithText(
        TextField,
        'Search songs and artists',
      );
      await tester.enterText(search, 'My query');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.text('Loaded song'), findsWidgets);
      final calls = fast.calls;
      await tester.tap(find.text('Library'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stream'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(search).controller!.text, 'My query');
      expect(fast.calls, calls);
      fast.waiting = Completer();
      // Pulling the feed down refreshes it; there is no refresh button.
      await tester.drag(stream, const Offset(0, 300));
      // Let the list settle on the dots' gap while the refresh is pending.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Loaded song'), findsWidgets);
      fast.waiting!.complete([track('jiosaavn', 'New song')]);
      await tester.pumpAndSettle();
      expect(find.text('New song'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}

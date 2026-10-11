import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nex_music/music_controller.dart';
import 'package:nex_music/music_data.dart';
import 'package:nex_music/phone_services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _WidgetPhone implements PhoneServices {
  final updates = <Map<String, dynamic>>[];

  @override
  Future<void> updateWidgets(String json) async {
    updates.add(jsonDecode(json) as Map<String, dynamic>);
  }

  @override
  Future<({int buildNumber, String version, String versionName})?>
  getAppVersion() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

void main() {
  testWidgets(
    'widgets follow saved app theme and update without track changes',
    (tester) async {
      SharedPreferences.setMockInitialValues({'darkMode': true});
      final preferences = await SharedPreferences.getInstance();
      final phone = _WidgetPhone();
      final music = MusicController(preferences, phone: phone);
      const song = Song(
        id: 'one',
        title: 'One',
        artist: 'Singer',
        kind: 'audio',
        url: 'https://example.com/one.mp3',
      );
      music.playback.queue.replace([song], song);
      music.current = song;
      music.notifyListeners();
      await tester.pump(const Duration(seconds: 1));
      expect(phone.updates.last['darkMode'], true);
      expect(phone.updates.last['now']['subtitle'], 'Singer');

      music.setDarkMode(false);
      await tester.pump(const Duration(seconds: 1));
      expect(phone.updates.last['darkMode'], false);
      expect(preferences.getBool('darkMode'), false);
      expect(phone.updates.last['now']['id'], song.id);
      final count = phone.updates.length;
      music.notifyListeners();
      await tester.pump(const Duration(seconds: 1));
      expect(phone.updates, hasLength(count));

      music.dispose();
      await tester.pump();
    },
  );
}

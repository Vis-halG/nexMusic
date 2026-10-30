import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_music/music_controller.dart';
import 'package:nex_music/music_data.dart';
import 'package:nex_music/music_downloads.dart';
import 'package:nex_music/phone_services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/playback_test_player.dart';

class _Auth extends Fake implements FirebaseAuth {}

class _Firestore extends Fake implements FirebaseFirestore {}

class _Messaging extends Fake implements FirebaseMessaging {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'upload and download service owners are independent and release on pause, completion and dispose',
    () async {
      final calls = <MethodCall>[];
      const channel = MethodChannel('com.thenex.nexmusic/phone');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final phone = PhoneServices(
        auth: _Auth(),
        firestore: _Firestore(),
        messaging: _Messaging(),
      );
      SharedPreferences.setMockInitialValues({});
      final music = MusicController(
        await SharedPreferences.getInstance(),
        player: PlaybackTestPlayer(),
        phone: phone,
      );
      final upload = UploadItem(
        path: 'example.mp3',
        name: 'example.mp3',
        title: 'Upload',
        sizeBytes: 100,
      );
      music.uploads = [upload];
      final download = MusicDownload(
        const Song(
          id: 'd',
          title: 'Download',
          kind: 'audio',
          url: 'https://example.test/d.mp3',
        ),
      );
      music.downloads.jobs['d'] = download;
      music.notifyListeners();
      await Future<void>.delayed(Duration.zero);
      final owners = <String>{};
      void applyCalls() {
        for (final call in calls.where(
          (c) => c.method == 'setTransferActive',
        )) {
          final args = Map<String, dynamic>.from(call.arguments as Map);
          args['active'] == true
              ? owners.add(args['owner'] as String)
              : owners.remove(args['owner']);
        }
        calls.clear();
      }

      applyCalls();
      expect(owners, {'uploads', 'downloads'});
      upload.status = UploadStatus.done;
      music.notifyListeners();
      await Future<void>.delayed(Duration.zero);
      applyCalls();
      expect(owners, {'downloads'});
      // A temporary network wait keeps background retry alive.
      download.status = MusicDownloadStatus.paused;
      music.notifyListeners();
      await Future<void>.delayed(Duration.zero);
      applyCalls();
      expect(owners, {'downloads'});
      music.downloads.pause();
      await Future<void>.delayed(Duration.zero);
      applyCalls();
      expect(owners, isEmpty);
      music.uploads = [
        UploadItem(path: 'a', name: 'a.mp3', title: 'Other', sizeBytes: 1),
      ];
      music.notifyListeners();
      await Future<void>.delayed(Duration.zero);
      applyCalls();
      expect(owners, {'uploads'});
      music.dispose();
      await Future<void>.delayed(Duration.zero);
      applyCalls();
      expect(owners, isEmpty);
    },
  );
}

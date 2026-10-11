import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nex_music/community_activity.dart';
import 'package:nex_music/media_library.dart';
import 'package:nex_music/music_data.dart';

Song track(String id, {String kind = 'audio'}) => Song(
  id: 'provider:ytmusic:$id',
  providerId: 'ytmusic',
  sourceId: id,
  title: id,
  kind: kind,
  url: '',
);

void main() {
  test(
    'global collections sort community counts and exclude globally played songs',
    () async {
      SharedPreferences.setMockInitialValues({});
      final activity = CommunityActivity(
        prefs: await SharedPreferences.getInstance(),
        uid: 'guest',
      );
      final a = track('A'),
          b = track('B'),
          c = track('C'),
          video = track('Video', kind: 'video');
      activity.replaceSnapshot([
        (song: a, likes: 12, plays: 3, lastPlayed: 10),
        (song: b, likes: 1, plays: 40, lastPlayed: 20),
        (song: video, likes: 9, plays: 2, lastPlayed: 30),
      ]);
      expect(activity.collection(MediaCollection.likedSongs), [a, b]);
      expect(activity.collection(MediaCollection.recent), [video, b, a]);
      expect(activity.collection(MediaCollection.mostPlayed), [b, a, video]);
      expect(activity.collection(MediaCollection.watched), [video]);
      expect(
        activity.collection(MediaCollection.neverPlayed, catalogue: [a, b, c]),
        [c],
      );
      activity.dispose();
    },
  );

  test(
    'offline events survive restart, keep receipt IDs, and never cross accounts',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final batches = <List<Map<String, dynamic>>>[];
      final first = CommunityActivity(
        prefs: prefs,
        uid: 'alice',
        send: (batch) async {
          batches.add(List.of(batch));
          return false;
        },
      );
      first.like(track('A'), true);
      first.play(track('A'));
      await first.flush();
      expect(batches.single.length, 2);
      final ids = batches.single.map((e) => e['eventId']).toList();
      first.dispose();
      final bob = CommunityActivity(
        prefs: prefs,
        uid: 'bob',
        send: (_) async => throw StateError('Wrong account'),
      );
      await bob.flush();
      bob.dispose();
      final resumed = CommunityActivity(
        prefs: prefs,
        uid: 'alice',
        send: (batch) async {
          expect(batch.map((e) => e['eventId']), ids);
          return true;
        },
      );
      await resumed.flush();
      await Future<void>.delayed(Duration.zero);
      expect(
        jsonDecode(prefs.getString('user:alice:community_pending_v1')!),
        isEmpty,
      );
      resumed.dispose();
    },
  );

  test(
    'only public tracks are shared; history imports and heart toggles coalesce',
    () async {
      SharedPreferences.setMockInitialValues({});
      final batches = <List<Map<String, dynamic>>>[];
      final activity = CommunityActivity(
        prefs: await SharedPreferences.getInstance(),
        uid: 'alice',
        send: (batch) async {
          batches.add(batch);
          return true;
        },
      );
      final local = Song(
        id: 'local:file',
        title: 'Private file',
        kind: 'audio',
        url: '/secret/file.mp3',
      );
      final private = Song(
        id: 'private-id',
        title: 'Private upload',
        kind: 'audio',
        url: 'https://storage.googleapis.com/private',
      );
      activity.play(local);
      activity.like(private, true);
      final history = LibraryMedia.song(track('A'))
        ..liked = true
        ..plays = 7
        ..lastPlayed = 1234;
      activity.seed([history]);
      activity.seed([history]);
      activity.like(track('A'), true);
      activity.like(track('A'), false);
      await activity.flush();
      expect(batches.single.map((e) => e['type']), ['seed', 'like']);
      expect(batches.single.first['plays'], 7);
      expect(batches.single.last['liked'], false);
      expect(batches.single.first['song'], isNot(contains('ownerUid')));
      activity.dispose();
    },
  );
}

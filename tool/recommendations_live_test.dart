// Run explicitly: flutter test tool/recommendations_live_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_music/music_discovery.dart';
import 'package:nex_music/music_provider.dart';
import 'package:nex_music/music_recommendations.dart';

void main() {
  test(
    'live matching and personalized recommendations use both catalogues',
    () async {
      final discovery = MusicDiscovery([
        JioSaavnProvider(),
        YouTubeMusicProvider(),
      ]);
      final found = await discovery.browse(
        query: 'Tum Hi Ho Arijit Singh',
        limit: 5,
      );
      final seed = found.songs.firstWhere((s) => s.providerId == 'jiosaavn');
      final radio = await discovery.radio(seed, limit: 20);
      expect(radio.map((s) => s.providerId).toSet(), {'jiosaavn', 'ytmusic'});
      expect(radio.any((s) => sameMusicRecording(s, seed)), false);
      final taste = MusicTaste([
        MusicPreference(
          seed,
          liked: true,
          plays: 3,
          completed: 2,
          listenedMs: 420000,
          lastPlayed: DateTime.now().millisecondsSinceEpoch,
        ),
      ]);
      final picks = await discovery.recommendations(
        taste,
        accepts: (_) => true,
        limit: 12,
      );
      expect(picks, hasLength(12));
      expect(picks.map((s) => s.id).toSet(), hasLength(12));
      expect(picks.any((s) => s.isVideo || s.isLongform), false);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

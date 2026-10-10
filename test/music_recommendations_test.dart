import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nex_music/music_controller.dart';
import 'package:nex_music/music_data.dart';
import 'package:nex_music/music_discovery.dart';
import 'package:nex_music/music_recommendations.dart';

import 'music_discovery_test.dart' show FakeMusicProvider;

Song song(
  String id, {
  String artist = 'Arijit Singh',
  String language = 'Hindi',
  String? title,
}) => Song(
  id: 'provider:jiosaavn:$id',
  sourceId: id,
  providerId: 'jiosaavn',
  title: title ?? id,
  artist: artist,
  language: language,
  durationMs: 210000,
  kind: 'audio',
  url: '',
);

bool accepts(Song _) => true;
final now = DateTime(2026, 10, 11);

class RecommendationProvider extends FakeMusicProvider {
  RecommendationProvider(
    super.id,
    super.songs, {
    this.searchResults = const [],
    this.radios = const {},
  });
  final List<Song> searchResults;
  final Map<String, List<Song>> radios;
  final List<String> queries = [], seeds = [];
  int featuredCalls = 0;
  Completer<void>? pending;
  @override
  Future<List<Song>> loadFeatured({int limit = 20, int page = 1}) async {
    featuredCalls++;
    return songs.take(limit).toList();
  }

  @override
  Future<List<Song>> searchSongs(
    String query, {
    int limit = 20,
    int page = 1,
  }) async {
    queries.add(query);
    return searchResults.take(limit).toList();
  }

  @override
  Future<List<Song>> loadRadio(String sourceId, {int limit = 25}) async {
    seeds.add(sourceId);
    if (pending != null) await pending!.future;
    return (radios[sourceId] ?? []).take(limit).toList();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'likes and completed listening beat a recent accidental tap; seeds have variety',
    () {
      final favourite = song('favourite');
      final completed = song('completed', artist: 'Shreya Ghoshal');
      final taste = MusicTaste([
        MusicPreference(
          song('tap', artist: 'Unrelated'),
          plays: 1,
          skips: 2,
          lastPlayed: now.millisecondsSinceEpoch,
        ),
        MusicPreference(favourite, liked: true),
        MusicPreference(song('same-artist'), liked: true),
        MusicPreference(
          completed,
          plays: 3,
          completed: 3,
          listenedMs: 600000,
          lastPlayed: now.millisecondsSinceEpoch,
        ),
      ], now: now);
      final seeds = taste.seeds(accepts: accepts, limit: 3);
      expect(seeds.map((s) => s.sourceId), isNot(contains('tap')));
      expect(seeds.take(2).map((s) => s.artist).toSet(), hasLength(2));
      final ranked = taste.rank([
        song('random', artist: 'Unrelated', language: 'English'),
        song('discovery', artist: 'Shreya Ghoshal'),
      ], accepts: accepts);
      expect(ranked.first.sourceId, 'discovery');
    },
  );

  test(
    'ranking diversifies artists while preserving provider order for ties',
    () {
      final taste = MusicTaste([
        MusicPreference(song('liked'), liked: true),
      ], now: now);
      final candidates = [
        song('a1'),
        song('a2'),
        song('a3'),
        song('b1', artist: 'Shreya Ghoshal'),
        song('c1', artist: 'Sonu Nigam'),
      ];
      final ranked = taste.rank(candidates, accepts: accepts);
      expect(ranked.first.sourceId, 'a1');
      expect(ranked[1].artist, isNot('Arijit Singh'));
      expect(ranked.map((s) => s.id).toSet(), hasLength(5));
      final cold = MusicTaste([], now: now).rank([
        song('first', artist: 'First'),
        song('second', artist: 'Second'),
      ], accepts: accepts);
      expect(cold.map((s) => s.sourceId), ['first', 'second']);
    },
  );

  test(
    'skips and hidden recordings apply across providers; remixes stay distinct',
    () {
      final skipped = song('skipped');
      final hidden = song('hidden');
      final taste = MusicTaste([
        MusicPreference(
          skipped,
          plays: 3,
          skips: 3,
          lastPlayed: now.millisecondsSinceEpoch,
        ),
        MusicPreference(hidden, liked: true),
      ], now: now);
      final crossProvider = skipped.copyWith(
        id: 'provider:ytmusic:skip',
        providerId: 'ytmusic',
        sourceId: 'skip',
        title: 'skipped (Official Audio)',
        artist: 'Arijit Singh - Topic',
      );
      final hiddenCopy = hidden.copyWith(
        id: 'provider:ytmusic:hidden',
        providerId: 'ytmusic',
        sourceId: 'hidden-copy',
      );
      final remix = skipped.copyWith(
        id: 'remix',
        sourceId: 'remix',
        title: 'skipped (Remix)',
      );
      final ranked = taste.rank([
        crossProvider,
        hiddenCopy,
        remix,
        song('ok'),
        song('video').copyWith(kind: 'video'),
        song('podcast').copyWith(contentType: 'podcast'),
      ], accepts: (s) => s.id != hidden.id);
      expect(ranked.map((s) => s.sourceId).toSet(), {'remix', 'ok'});
    },
  );

  test('explicit language and radio seed relevance influence ranking', () {
    final seed = song('seed');
    final taste = MusicTaste([], language: 'Hindi', now: now);
    final ranked = taste.rank(
      [
        seed.copyWith(
          id: 'provider:ytmusic:seed',
          providerId: 'ytmusic',
          title: 'seed (Official Music Video)',
        ),
        song('english', artist: 'Other', language: 'English'),
        song('hindi', artist: 'Shreya Ghoshal'),
      ],
      seed: seed,
      accepts: accepts,
    );
    expect(ranked.map((s) => s.sourceId), ['hindi', 'english']);
  });

  test(
    'cross-provider radio chooses the actual recording, not the first hit',
    () async {
      final seed = song('seed', title: 'Tum Hi Ho');
      final youtubeMatch = seed.copyWith(
        id: 'provider:ytmusic:correct',
        sourceId: 'correct',
        providerId: 'ytmusic',
        title: 'Tum Hi Ho (Official Audio)',
        artist: 'Arijit Singh - Topic',
      );
      final jio = RecommendationProvider(
        'jiosaavn',
        [],
        radios: {
          'seed': [song('jio-next')],
        },
      );
      final yt = RecommendationProvider(
        'ytmusic',
        [],
        searchResults: [
          youtubeMatch.copyWith(
            id: 'wrong-title',
            sourceId: 'wrong-title',
            title: 'Tum Hi Ho Remix',
          ),
          youtubeMatch.copyWith(
            id: 'cover',
            sourceId: 'cover',
            artist: 'Cover Singer',
          ),
          youtubeMatch,
        ],
        radios: {
          'correct': [
            youtubeMatch,
            song(
              'yt-next',
            ).copyWith(providerId: 'ytmusic', id: 'provider:ytmusic:yt-next'),
          ],
        },
      );
      final ranked = await MusicDiscovery([jio, yt]).radio(seed);
      expect(yt.seeds, ['correct']);
      expect(ranked.map((s) => s.sourceId).toSet(), {'jio-next', 'yt-next'});
      final unrelated = RecommendationProvider(
        'ytmusic',
        [],
        searchResults: [song('unrelated')],
      );
      await MusicDiscovery([jio, unrelated]).radio(seed);
      expect(unrelated.seeds, isEmpty);
    },
  );

  test(
    'personalized pages share a stable pool and failed radios use taste searches',
    () async {
      final seed = song('seed');
      final radio = List.generate(
        24,
        (i) => song('radio-$i', artist: 'Artist $i'),
      );
      final search = List.generate(
        20,
        (i) => song('search-$i', artist: 'New artist $i'),
      );
      final provider = RecommendationProvider(
        'jiosaavn',
        [song('global')],
        radios: {'seed': radio},
        searchResults: search,
      );
      final discovery = MusicDiscovery([provider]);
      final taste = MusicTaste([MusicPreference(seed, liked: true)], now: now);
      final first = await discovery.recommendations(taste, accepts: accepts);
      final second = await discovery.recommendations(
        taste,
        accepts: accepts,
        page: 2,
      );
      expect(first, hasLength(20));
      expect(second, hasLength(20));
      expect(
        first
            .map((s) => s.id)
            .toSet()
            .intersection(second.map((s) => s.id).toSet()),
        isEmpty,
      );
      expect(provider.featuredCalls, 0);
      expect(provider.seeds, ['seed']);
      expect(provider.queries, contains('arijit singh'));
      final offlineRadio = RecommendationProvider('jiosaavn', [
        song('global'),
      ], searchResults: search);
      final fallback = await MusicDiscovery([
        offlineRadio,
      ]).recommendations(taste, accepts: accepts);
      expect(fallback.first.sourceId, startsWith('search-'));
      expect(offlineRadio.featuredCalls, 0);
    },
  );

  test(
    'cold start uses selected language and preserves one working provider',
    () async {
      final failing = FakeMusicProvider('ytmusic', [], fail: true);
      final provider = RecommendationProvider(
        'jiosaavn',
        [song('chart')],
        searchResults: [song('hindi')],
      );
      final discovery = MusicDiscovery([provider, failing]);
      final cold = await discovery.recommendations(
        MusicTaste([]),
        accepts: accepts,
      );
      expect(cold.single.sourceId, 'chart');
      final language = await discovery.recommendations(
        MusicTaste([], language: 'Hindi'),
        accepts: accepts,
      );
      expect(language.single.sourceId, 'hindi');
      expect(provider.queries, contains('Hindi songs'));
    },
  );

  test(
    'controller learns from saved likes and listening, retains history after restart',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final seed = song('liked-only');
      final provider = RecommendationProvider(
        'jiosaavn',
        [song('global')],
        radios: {
          'liked-only': [song('relevant')],
        },
      );
      final music = MusicController(prefs, musicProviders: [provider]);
      music.toggleLike(seed);
      final skipped = song('skipped');
      music.personal.recordPlay(skipped);
      music.personal.recordListening(skipped, 5000, skipped: true);
      music.personal.recordListening(skipped, 5000, skipped: true);
      final picks = await music.fetchQuickPicks(limit: 4);
      expect(provider.seeds, contains('liked-only'));
      expect(provider.seeds, isNot(contains('skipped')));
      expect(picks.map((s) => s.sourceId), contains('relevant'));
      expect(picks.map((s) => s.sourceId), contains('liked-only'));
      await music.personal.saved;
      await music.library.saved;
      final restored = MusicController(prefs, musicProviders: [provider]);
      expect(
        restored
            .recommendationTaste()
            .seeds(accepts: accepts)
            .map((s) => s.sourceId),
        contains('liked-only'),
      );
      restored.dispose();
      music.dispose();
    },
  );

  test('legacy recent stream history still seeds recommendations', () async {
    final seed = song('legacy');
    SharedPreferences.setMockInitialValues({
      'recent_stream_history': [jsonEncode(seed.toJson())],
    });
    final music = MusicController(
      await SharedPreferences.getInstance(),
      musicProviders: [RecommendationProvider('jiosaavn', [])],
    );
    expect(
      music
          .recommendationTaste()
          .seeds(accepts: accepts)
          .map((s) => s.sourceId),
      contains('legacy'),
    );
    music.dispose();
  });
}

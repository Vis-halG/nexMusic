import 'package:flutter/foundation.dart';

import 'music_data.dart';
import 'music_provider.dart';
import 'music_recommendations.dart';

typedef _RankInput = ({
  MusicTaste taste,
  List<Song> songs,
  Set<String> accepted,
  Set<String> excluded,
  int? limit,
});
List<Song> _rankSnapshot(_RankInput input) => input.taste.rank(
  input.songs,
  accepts: (s) => input.accepted.contains(s.id),
  excludeIds: input.excluded,
  limit: input.limit,
);
typedef _SeedInput = ({MusicTaste taste, Set<String> accepted, int limit});
List<Song> _seedSnapshot(_SeedInput input) => input.taste.seeds(
  accepts: (s) => input.accepted.contains(s.id),
  limit: input.limit,
);
List<String> _tasteQueries(MusicTaste taste) => taste.fallbackQueries;

/// Round-robin ranking keeps both catalogues visible, with stable de-duplication.
List<Song> mergeMusicResults(Iterable<List<Song>> sources, {int? limit}) {
  final lists = sources.toList();
  final ids = <String>{};
  final recordings = MusicRecordingIndex<Song>((s) => s);
  final result = <Song>[];
  for (var row = 0; lists.any((list) => row < list.length); row++) {
    for (final list in lists) {
      if (row >= list.length) continue;
      final song = list[row];
      if (!ids.add(song.id)) continue;
      if (recordings.contains(song)) continue;
      recordings.add(song);
      result.add(song);
      if (limit != null && result.length >= limit) return result;
    }
  }
  return result;
}

class MusicFeedResult {
  const MusicFeedResult(this.songs, {this.unavailable = const []});
  final List<Song> songs;
  final List<String> unavailable;
}

/// Discovery failure on one source never hides results from the other source.
class MusicDiscovery {
  MusicDiscovery(this.providers);
  final List<MusicProvider> providers;
  final _pending = <String, Future<List<Song>>>{};
  final _cache = <String, ({DateTime at, List<Song> songs})>{};
  var _recommendationPools = Expando<Future<List<Song>>>();

  Future<List<Song>> _cached(String key, Future<List<Song>> Function() fetch) {
    final cached = _cache[key];
    if (cached != null && DateTime.now().difference(cached.at).inMinutes < 3) {
      return Future.value(cached.songs);
    }
    return _pending.putIfAbsent(key, () async {
      try {
        final songs = await fetch().timeout(const Duration(seconds: 30));
        if (_cache.length >= 80) _cache.remove(_cache.keys.first);
        _cache[key] = (at: DateTime.now(), songs: songs);
        return songs;
      } finally {
        _pending.remove(key);
      }
    });
  }

  void clearCache() {
    _cache.clear();
    _recommendationPools = Expando<Future<List<Song>>>();
  }

  Future<List<Song>> recommendationSeeds(
    MusicTaste taste, {
    required bool Function(Song) accepts,
    int limit = 5,
  }) {
    final input = (
      taste: taste,
      accepted: {
        for (final p in taste.preferences)
          if (accepts(p.song)) p.song.id,
      },
      limit: limit,
    );
    return taste.preferences.length < 200
        ? Future.value(_seedSnapshot(input))
        : compute(_seedSnapshot, input);
  }

  Future<List<Song>> _rank(
    MusicTaste taste,
    List<Song> songs, {
    required bool Function(Song) accepts,
    required Set<String> excluded,
    int? limit,
  }) {
    final input = (
      taste: taste,
      songs: songs,
      accepted: {
        for (final s in [...songs, ...taste.preferences.map((p) => p.song)])
          if (accepts(s)) s.id,
      },
      excluded: excluded,
      limit: limit,
    );
    return taste.preferences.length < 200 && songs.length < 200
        ? Future.value(_rankSnapshot(input))
        : compute(_rankSnapshot, input);
  }

  Future<MusicFeedResult> browse({
    String query = '',
    bool videos = false,
    int page = 1,
    int limit = 20,
    void Function(MusicFeedResult result)? onUpdate,
  }) async {
    final selected = providers
        .where(
          (p) => videos
              ? p.id == 'ytvideo'
              : p.id == 'jiosaavn' || p.id == 'ytmusic',
        )
        .toList();
    final failures = <String>[];
    final ready = <List<Song>>[];
    final lists = await Future.wait(
      selected.map((provider) async {
        try {
          final songs = await _cached(
            '${provider.id}:$query:$page:$limit',
            () => query.trim().isEmpty
                ? provider.loadFeatured(limit: limit, page: page)
                : provider.searchSongs(query.trim(), limit: limit, page: page),
          );
          ready.add(songs);
          onUpdate?.call(
            MusicFeedResult(
              mergeMusicResults(ready),
              unavailable: List.of(failures),
            ),
          );
          return songs;
        } catch (_) {
          failures.add(provider.displayName);
          return <Song>[];
        }
      }),
    );
    return MusicFeedResult(mergeMusicResults(lists), unavailable: failures);
  }

  Future<List<Song>> radio(
    Song seed, {
    int limit = 25,
    void Function(List<Song>)? onUpdate,
  }) async {
    if (limit <= 0) return [];
    final selected =
        providers.where((p) => p.id == 'jiosaavn' || p.id == 'ytmusic').toList()
          ..sort(
            (a, b) => (b.id == seed.providerId ? 1 : 0).compareTo(
              a.id == seed.providerId ? 1 : 0,
            ),
          );
    final ready = <List<Song>>[];
    final lists = await Future.wait(
      selected.map((provider) async {
        try {
          final songs = await _cached(
            'radio:${provider.id}:${seed.id}:$limit',
            () async {
              var sourceId = seed.sourceId;
              if (seed.providerId != provider.id &&
                  !(seed.providerId == 'ytvideo' && provider.id == 'ytmusic')) {
                final matches = await provider.searchSongs(
                  '${seed.title} ${seed.artist}'.trim(),
                  limit: 5,
                );
                final match = matchMusicSeed(seed, matches);
                if (match == null) return <Song>[];
                sourceId = match.sourceId;
              }
              if (sourceId.isEmpty) return <Song>[];
              final songs = await provider.loadRadio(
                sourceId,
                limit: limit + 1,
              );
              return songs
                  .where(
                    (s) =>
                        s.sourceId != sourceId && !sameMusicRecording(s, seed),
                  )
                  .toList();
            },
          );
          ready.add(songs);
          onUpdate?.call(mergeMusicResults(ready, limit: limit));
          return songs;
        } catch (_) {
          return <Song>[];
        }
      }),
    );
    return mergeMusicResults(lists)
        .where(
          (s) => !sameMusicRecording(s, seed) && !s.isVideo && !s.isLongform,
        )
        .take(limit)
        .toList();
  }

  Future<List<Song>> recommendations(
    MusicTaste taste, {
    required bool Function(Song) accepts,
    int limit = 20,
    int page = 1,
    Set<String> excludeIds = const {},
    void Function(List<Song>)? onUpdate,
  }) async {
    if (limit <= 0 || page < 1) return [];
    List<Song>? pending;
    Future<void>? publishing;
    Future<void> drain() async {
      while (pending != null) {
        final songs = pending!;
        pending = null;
        final ranked = await _rank(
          taste,
          songs,
          accepts: accepts,
          excluded: excludeIds,
          limit: limit,
        );
        // Coalesce provider updates while ranking runs outside the UI isolate.
        if (pending == null) onUpdate?.call(ranked);
      }
      publishing = null;
    }

    void publish(List<Song> candidates) {
      if (onUpdate == null || page != 1) return;
      pending = candidates;
      publishing ??= drain();
    }

    final candidates = await (_recommendationPools[taste] ??= () async {
      final seeds = await recommendationSeeds(taste, accepts: accepts);
      final ready = <String, List<Song>>{};
      void update(String id, List<Song> songs) {
        ready[id] = songs;
        publish(mergeMusicResults(ready.values));
      }

      final lists = await Future.wait(
        seeds.map(
          (s) => radio(s, limit: 24, onUpdate: (songs) => update(s.id, songs)),
        ),
      );
      final candidates = mergeMusicResults(lists);
      // Keep one stable candidate pool for pagination, regardless of page size.
      if (candidates.where(accepts).length >= 40) return candidates;
      final queries = taste.preferences.length < 200
          ? taste.fallbackQueries
          : await compute(_tasteQueries, taste);
      final extra = await Future.wait(
        queries.map(
          (query) => browse(
            query: query,
            limit: 20,
            onUpdate: (r) => update('query:$query', r.songs),
          ),
        ),
      );
      candidates.addAll(mergeMusicResults(extra.map((r) => r.songs)));
      // Global charts are a cold-start fallback, never the primary taste signal.
      if (queries.isEmpty || candidates.isEmpty) {
        candidates.addAll(
          (await browse(
            limit: 30,
            onUpdate: (r) => update('featured', r.songs),
          )).songs,
        );
      }
      return candidates;
    }());
    await publishing;
    final ranked = await _rank(
      taste,
      candidates,
      accepts: accepts,
      excluded: excludeIds,
    );
    return ranked.skip((page - 1) * limit).take(limit).toList();
  }
}

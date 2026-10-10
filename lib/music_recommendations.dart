import 'dart:math' as math;

import 'music_data.dart';

String normalizeMusicText(String value) => value
    .toLowerCase()
    .replaceAll('&', ' and ')
    .replaceAll(RegExp(r'[^a-z0-9\u00c0-\uffff]+'), ' ')
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ');

/// Ignore presentation labels, but preserve remix/live/acoustic versions.
String recordingTitle(String value) => normalizeMusicText(
  value
      .replaceAll(
        RegExp(
          r'\b(?:official\s+(?:music\s+)?(?:video|audio)|music\s+video|lyric(?:s|al)?(?:\s+video)?|audio\s+only)\b',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(RegExp(r'\(from\s+[^)]*\)', caseSensitive: false), ''),
);

Set<String> musicArtists(String value) => value
    .replaceAll(RegExp(r'\s*-\s*topic\s*$', caseSensitive: false), '')
    .split(
      RegExp(
        r'\s*(?:,|&|;|\bfeat\.?|\bft\.?|\bfeaturing\b)\s*',
        caseSensitive: false,
      ),
    )
    .map(normalizeMusicText)
    .where((a) => a.isNotEmpty && a != 'unknown' && a != 'unknown artist')
    .toSet();

bool sameMusicRecording(Song a, Song b) {
  if (a.id == b.id) return true;
  if (a.kind != b.kind) return false;
  if (a.sourceId.isNotEmpty &&
      a.sourceId == b.sourceId &&
      a.providerId == b.providerId) {
    return true;
  }
  final title = recordingTitle(a.title);
  return title.isNotEmpty &&
      title == recordingTitle(b.title) &&
      musicArtists(a.artist).intersection(musicArtists(b.artist)).isNotEmpty;
}

/// A bad cross-catalogue match makes every recommendation in that radio wrong.
Song? matchMusicSeed(Song seed, List<Song> candidates) {
  final title = recordingTitle(seed.title);
  if (title.isEmpty) return null;
  final artists = musicArtists(seed.artist);
  Song? best;
  var bestScore = double.negativeInfinity;
  for (final candidate in candidates) {
    if (candidate.isVideo ||
        candidate.isLongform ||
        candidate.sourceId.isEmpty) {
      continue;
    }
    final candidateTitle = recordingTitle(candidate.title);
    if (candidateTitle != title) continue;
    final otherArtists = musicArtists(candidate.artist);
    if (artists.isNotEmpty && artists.intersection(otherArtists).isEmpty) {
      continue;
    }
    final difference = (seed.durationMs - candidate.durationMs).abs();
    if (seed.durationMs > 0 &&
        candidate.durationMs > 0 &&
        difference > math.max(15000, seed.durationMs * 0.15)) {
      continue;
    }
    final score =
        artists.intersection(otherArtists).length * 10 -
        (seed.durationMs > 0 && candidate.durationMs > 0
            ? difference / 1000
            : 0);
    if (score > bestScore) {
      best = candidate;
      bestScore = score.toDouble();
    }
  }
  return best;
}

class MusicPreference {
  const MusicPreference(
    this.song, {
    this.liked = false,
    this.plays = 0,
    this.lastPlayed = 0,
    this.listenedMs = 0,
    this.completed = 0,
    this.skips = 0,
  });
  final Song song;
  final bool liked;
  final int plays, lastPlayed, listenedMs, completed, skips;

  double weight(DateTime now) {
    final age = lastPlayed > 0
        ? math.max(0, now.millisecondsSinceEpoch - lastPlayed) / 86400000
        : 90.0;
    final recency = 1 / (1 + age / 14);
    final listening = math.min(4.0, listenedMs / 180000);
    final engagement =
        math.min(8, plays) * 0.3 +
        listening +
        math.min(6, completed) * 1.2 -
        math.min(6, skips) * 2;
    return (liked ? 7 : 0) + engagement * recency;
  }
}

/// A snapshot of this listener, built from persisted likes and actual listening.
class MusicTaste {
  MusicTaste(
    Iterable<MusicPreference> history, {
    this.language = 'Any',
    DateTime? now,
  }) : preferences = history
           .where((p) => !p.song.isVideo && !p.song.isLongform)
           .toList(),
       now = now ?? DateTime.now() {
    for (final preference in preferences) {
      final weight = preference.weight(this.now);
      if (weight <= 0) continue;
      for (final artist in musicArtists(preference.song.artist)) {
        artists.update(artist, (v) => v + weight, ifAbsent: () => weight);
      }
      _add(languages, preference.song.language, weight);
      _add(genres, preference.song.genre, weight);
    }
  }

  final List<MusicPreference> preferences;
  final String language;
  final DateTime now;
  final Map<String, double> artists = {}, languages = {}, genres = {};

  static void _add(Map<String, double> values, String key, double weight) {
    final normalized = normalizeMusicText(key);
    if (normalized.isNotEmpty) {
      values.update(normalized, (v) => v + weight, ifAbsent: () => weight);
    }
  }

  double _affinity(Map<String, double> values, Iterable<String> keys) {
    if (values.isEmpty) return 0;
    final maximum = values.values.reduce(math.max);
    return keys.fold(
      0.0,
      (score, key) => math.max(score, (values[key] ?? 0) / maximum),
    );
  }

  List<Song> seeds({required bool Function(Song) accepts, int limit = 5}) {
    final remaining = preferences
        .where(
          (p) =>
              accepts(p.song) &&
              p.weight(now) > 0 &&
              (p.song.isProvider || musicArtists(p.song.artist).isNotEmpty),
        )
        .toList();
    final result = <Song>[];
    final usedArtists = <String, int>{};
    while (remaining.isNotEmpty && result.length < limit) {
      double score(MusicPreference p) =>
          p.weight(now) /
          (1 +
              musicArtists(
                    p.song.artist,
                  ).fold(0, (n, a) => math.max(n, usedArtists[a] ?? 0)) *
                  2);
      remaining.sort((a, b) {
        final order = score(b).compareTo(score(a));
        return order != 0 ? order : b.lastPlayed.compareTo(a.lastPlayed);
      });
      final song = remaining.removeAt(0).song;
      if (result.any((s) => sameMusicRecording(s, song))) continue;
      result.add(song);
      for (final artist in musicArtists(song.artist)) {
        usedArtists.update(artist, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    return result;
  }

  List<String> get fallbackQueries {
    final ranked = artists.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final queries = ranked.take(2).map((a) => a.key).toList();
    final preferred = normalizeMusicText(language) != 'any'
        ? language
        : (languages.entries.toList()
                ..sort((a, b) => b.value.compareTo(a.value)))
              .firstOrNull
              ?.key;
    if (preferred != null && preferred.isNotEmpty) {
      queries.add('$preferred songs');
    }
    return queries;
  }

  /// Keep provider relevance as a prior, then balance affinity and variety.
  List<Song> rank(
    Iterable<Song> candidates, {
    required bool Function(Song) accepts,
    Song? seed,
    Set<String> excludeIds = const {},
    int? limit,
  }) {
    if (limit != null && limit <= 0) return [];
    final pool = <({Song song, double score, int order})>[];
    final seen = <String>{};
    var order = 0;
    for (final song in candidates) {
      final index = order++;
      if (song.isVideo ||
          song.isLongform ||
          !accepts(song) ||
          excludeIds.contains(song.id) ||
          !seen.add(song.id) ||
          (seed != null && sameMusicRecording(seed, song)) ||
          preferences.any(
            (p) => !accepts(p.song) && sameMusicRecording(p.song, song),
          ) ||
          pool.any((p) => sameMusicRecording(p.song, song))) {
        continue;
      }
      final known = preferences
          .where((p) => sameMusicRecording(p.song, song))
          .toList();
      // Repeated early skips exclude the recording across both catalogues.
      if (known.any((p) => !p.liked && p.skips >= 2 && p.weight(now) < 0)) {
        continue;
      }
      var score = 16 / (1 + index * 0.04);
      score += 12 * _affinity(artists, musicArtists(song.artist));
      score += 7 * _affinity(languages, [normalizeMusicText(song.language)]);
      score += 4 * _affinity(genres, [normalizeMusicText(song.genre)]);
      if (language != 'Any' && song.language.isNotEmpty) {
        score +=
            normalizeMusicText(song.language) == normalizeMusicText(language)
            ? 18
            : -12;
      }
      if (seed != null) {
        if (musicArtists(
          seed.artist,
        ).intersection(musicArtists(song.artist)).isNotEmpty) {
          score += 6;
        }
        if (seed.language.isNotEmpty &&
            seed.language.toLowerCase() == song.language.toLowerCase()) {
          score += 8;
        }
      }
      for (final p in known) {
        score += p.liked ? 3 : math.min(0, p.weight(now)) * 3;
        if (p.lastPlayed > 0 &&
            now.millisecondsSinceEpoch - p.lastPlayed < 86400000) {
          score -= 8;
        }
      }
      if ((song.durationMs > 0 && song.durationMs < 60000) ||
          song.durationMs > 900000) {
        score -= 14;
      }
      pool.add((song: song, score: score, order: index));
    }
    final result = <Song>[];
    final artistCounts = <String, int>{}, albumCounts = <String, int>{};
    while (pool.isNotEmpty && (limit == null || result.length < limit)) {
      double adjusted(({Song song, double score, int order}) p) {
        final keys = musicArtists(p.song.artist);
        final repeated = keys.fold(
          0,
          (n, a) => math.max(n, artistCounts[a] ?? 0),
        );
        final consecutive =
            result.isNotEmpty &&
            keys.intersection(musicArtists(result.last.artist)).isNotEmpty;
        final album = normalizeMusicText(p.song.album);
        return p.score -
            repeated * 7 -
            (consecutive ? 10 : 0) -
            (album.isEmpty ? 0 : (albumCounts[album] ?? 0) * 3);
      }

      pool.sort((a, b) {
        final comparison = adjusted(b).compareTo(adjusted(a));
        return comparison != 0 ? comparison : a.order.compareTo(b.order);
      });
      final song = pool.removeAt(0).song;
      result.add(song);
      for (final artist in musicArtists(song.artist)) {
        artistCounts.update(artist, (n) => n + 1, ifAbsent: () => 1);
      }
      final album = normalizeMusicText(song.album);
      if (album.isNotEmpty) {
        albumCounts.update(album, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    return result;
  }
}

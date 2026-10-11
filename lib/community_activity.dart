import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'media_library.dart';
import 'music_data.dart';

typedef ActivitySender =
    Future<bool> Function(List<Map<String, dynamic>> events);

/// Global public-song collections, with an account-scoped durable upload queue.
/// Personal likes remain separate so the heart still reflects this listener.
class CommunityActivity extends ChangeNotifier {
  CommunityActivity({
    required this.prefs,
    required this.uid,
    FirebaseFirestore? firestore,
    this.token,
    ActivitySender? send,
    this.endpoint =
        'https://nexmusic-push.vishalgupta25989.workers.dev/community/activity',
  }) : _sendOverride = send {
    try {
      _pending.addAll(
        (jsonDecode(prefs.getString(_queueKey) ?? '[]') as List).map(
          (e) => Map<String, dynamic>.from(e as Map),
        ),
      );
    } catch (_) {
      /* Ignore an incomplete old queue. */
    }
    _seeded.addAll(prefs.getStringList(_seedKey) ?? []);
    if (firestore != null && uid != 'guest') {
      _subscription = firestore.collection('globalMusic').snapshots().listen((
        snapshot,
      ) {
        if (_disposed) return;
        for (final change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.removed) {
            _entries.remove(change.doc.id);
          } else {
            final data = change.doc.data();
            if (data == null) continue;
            final song = Song.fromJson(
              Map<String, dynamic>.from(data['song'] as Map? ?? {}),
            );
            if (song != null && isPublicCommunitySong(song)) {
              _entries[change.doc.id] = (
                song: song,
                likes: (data['likes'] as num? ?? 0).toInt(),
                plays: (data['plays'] as num? ?? 0).toInt(),
                lastPlayed: (data['lastPlayed'] as num? ?? 0).toInt(),
              );
            }
          }
        }
        _sorted.clear();
        notifyListeners();
      }, onError: (Object _) {});
    }
    if (_pending.isNotEmpty) _schedule();
  }
  final SharedPreferences prefs;
  final String uid, endpoint;
  final Future<String?> Function()? token;
  final ActivitySender? _sendOverride;
  final _entries =
      <String, ({Song song, int likes, int plays, int lastPlayed})>{};
  final _sorted = <MediaCollection, List<Song>>{};
  final _pending = <Map<String, dynamic>>[];
  final _seeded = <String>{};
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _subscription;
  Timer? _timer;
  Future<void> _saved = Future.value();
  bool _disposed = false, _sending = false;
  bool _saveScheduled = false;
  int _retry = 0;
  String get _queueKey => 'user:$uid:community_pending_v1';
  String get _seedKey => 'user:$uid:community_seeded_v1';

  List<Song> collection(
    MediaCollection collection, {
    Iterable<Song> catalogue = const [],
  }) {
    if (collection == MediaCollection.neverPlayed) {
      final played = _entries.values
          .where((e) => e.plays > 0)
          .map((e) => e.song.id)
          .toSet();
      return {
        for (final s in catalogue)
          if (isPublicCommunitySong(s) && !played.contains(s.id)) s.id: s,
      }.values.toList();
    }
    return _sorted.putIfAbsent(collection, () {
      final rows =
          _entries.values
              .where(
                (e) => switch (collection) {
                  MediaCollection.liked => e.likes > 0,
                  MediaCollection.likedSongs => e.likes > 0 && !e.song.isVideo,
                  MediaCollection.watched => e.plays > 0 && e.song.isVideo,
                  _ => e.plays > 0,
                },
              )
              .toList()
            ..sort((a, b) {
              final result = switch (collection) {
                MediaCollection.liked ||
                MediaCollection.likedSongs => b.likes.compareTo(a.likes),
                MediaCollection.mostPlayed => b.plays.compareTo(a.plays),
                _ => b.lastPlayed.compareTo(a.lastPlayed),
              };
              return result != 0 ? result : a.song.id.compareTo(b.song.id);
            });
      return List.unmodifiable(rows.map((r) => r.song));
    });
  }

  void like(Song song, bool value, {int? at}) =>
      _enqueue(song, 'like', liked: value, at: at);
  void play(Song song) => _enqueue(song, 'play');

  /// Import the account's existing public likes/history once. Server receipts
  /// prevent duplicate imports if another phone seeds the same account.
  void seed(Iterable<LibraryMedia> history) {
    if (_disposed || uid == 'guest') return;
    var added = false;
    for (final row in history) {
      if (!row.liked && !row.wasPlayed) continue;
      if (!isPublicCommunitySong(row.song) || _seeded.contains(row.song.id)) {
        continue;
      }
      _seeded.add(row.song.id);
      added = true;
      _enqueue(
        row.song,
        'seed',
        liked: row.liked,
        plays: row.plays > 0
            ? row.plays
            : row.wasPlayed
            ? 1
            : 0,
        lastPlayed: row.lastPlayed,
      );
    }
    if (added) unawaited(prefs.setStringList(_seedKey, _seeded.toList()));
  }

  void _enqueue(
    Song song,
    String type, {
    bool? liked,
    int? at,
    int plays = 0,
    int lastPlayed = 0,
  }) {
    if (_disposed || uid == 'guest' || !isPublicCommunitySong(song)) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final random = Random.secure();
    final event = <String, dynamic>{
      'eventId':
          '$now-${List.generate(12, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}',
      'type': type,
      'at': at != null && at > 0 ? at : now,
      'song': communitySongJson(song),
      'liked': ?liked,
      if (type == 'seed') ...{
        'plays': plays,
        'lastPlayed': lastPlayed,
        'likedAt': 0,
      },
    };
    // Keep the latest pending heart state while retaining every play receipt.
    if (type == 'like' && !_sending) {
      _pending.removeWhere(
        (e) => e['type'] == 'like' && (e['song'] as Map)['id'] == song.id,
      );
    }
    _pending.add(event);
    _save();
    _schedule();
  }

  void _save() {
    if (_saveScheduled) return;
    _saveScheduled = true;
    _saved = _saved.then((_) async {
      _saveScheduled = false;
      await prefs.setString(_queueKey, jsonEncode(_pending));
    });
  }

  void _schedule([Duration delay = const Duration(milliseconds: 400)]) {
    if (_disposed || _timer?.isActive == true || _sending) return;
    _timer = Timer(delay, () {
      unawaited(flush());
    });
  }

  Future<void> flush() async {
    if (_disposed || _sending || _pending.isEmpty) return;
    _sending = true;
    _timer?.cancel();
    final batch = _pending.take(10).toList();
    var success = false;
    try {
      await _saved;
      success = await (_sendOverride?.call(batch) ?? _send(batch));
    } catch (_) {
      /* Persisted events are retried when the connection recovers. */
    }
    if (_disposed) return;
    if (success) {
      final ids = batch.map((e) => e['eventId']).toSet();
      _pending.removeWhere((e) => ids.contains(e['eventId']));
      _save();
      _retry = 0;
    } else {
      _retry = min(_retry + 1, 5);
    }
    _sending = false;
    if (_pending.isNotEmpty) {
      _schedule(
        success
            ? const Duration(milliseconds: 400)
            : Duration(seconds: 5 * (1 << _retry)),
      );
    }
  }

  Future<bool> _send(List<Map<String, dynamic>> batch) async {
    final token = await this.token?.call();
    if (_disposed || token == null) return false;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client
          .postUrl(Uri.parse(endpoint))
          .timeout(const Duration(seconds: 15));
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.write(jsonEncode({'events': batch}));
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      await response.drain<void>().timeout(const Duration(seconds: 10));
      return response.statusCode == 200;
    } finally {
      client.close(force: true);
    }
  }

  @visibleForTesting
  void replaceSnapshot(
    Iterable<({Song song, int likes, int plays, int lastPlayed})> rows,
  ) {
    _entries
      ..clear()
      ..addEntries(rows.map((r) => MapEntry(r.song.id, r)));
    _sorted.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}

bool isPublicCommunitySong(Song song) {
  if (song.isPrivate ||
      song.isLocal ||
      song.storagePath != null ||
      song.isLongform) {
    return false;
  }
  if (song.isProvider) {
    return const {'jiosaavn', 'ytmusic', 'ytvideo'}.contains(song.providerId) &&
        song.sourceId.isNotEmpty &&
        song.sourceId.length <= 150 &&
        song.id == 'provider:${song.providerId}:${song.sourceId}';
  }
  final url = Uri.tryParse(song.url);
  return url?.scheme == 'https' && url?.host == 'res.cloudinary.com';
}

Map<String, dynamic> communitySongJson(Song song) => {
  'id': song.id,
  'title': song.title.length > 160 ? song.title.substring(0, 160) : song.title,
  'kind': song.kind,
  'url': song.isProvider ? '' : song.url,
  'providerId': song.providerId,
  'sourceId': song.sourceId,
  'artist': song.artist.length > 200
      ? song.artist.substring(0, 200)
      : song.artist,
  'album': song.album.length > 200 ? song.album.substring(0, 200) : song.album,
  'albumId': song.albumId,
  'artistId': song.artistId,
  'language': song.language,
  'genre': song.genre,
  'artworkUrl': song.artworkUrl.length > 2000 ? '' : song.artworkUrl,
  'durationMs': song.durationMs.clamp(0, 86400000),
};

import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'listening_models.dart';
import 'music_data.dart';
import 'music_recommendations.dart';

/// Persistent state is bound to one account for its entire lifetime.
class PersonalMusic extends ChangeNotifier {
  PersonalMusic(
    this.prefs, {
    required this.uid,
    this.firestore,
    this.legacy = false,
  }) {
    _restore();
    if (firestore != null && uid != 'guest') _startSync();
  }
  final SharedPreferences prefs;
  final String uid;
  final FirebaseFirestore? firestore;
  final bool legacy;
  final Map<String, MusicPlaylist> _playlists = {};
  final Map<String, Map<String, dynamic>> activity = {};
  final Map<String, Map<String, dynamic>> days = {};
  final Map<String, Song> offlineTracks = {},
      localTracks = {},
      longformTracks = {};
  final Map<String, String> customLyrics = {};

  /// Account-scoped tags supplement public files without requiring new rules.
  final Map<String, String> songArtists = {};
  final Map<String, int> resumePositions = {};
  final Set<String> hiddenSongs = {}, hiddenArtists = {};
  final Map<String, List<String>> feeds = {};
  ListeningSettings settings = ListeningSettings();
  final Set<String> _dirtyPlaylists = {}, _dirtyActivity = {}, _dirtyDays = {};
  bool _dirtySettings = false,
      syncing = false,
      _disposed = false,
      _writing = false;
  String? syncError;
  Timer? _syncTimer;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Future<void> _saving = Future.value();
  Future<void> get saved => _saving;
  void Function(Song song, bool liked)? onCloudLike;
  void Function()? onCloudActivity;
  String key(String name) => legacy ? name : 'user:$uid:$name';
  List<MusicPlaylist> get playlists =>
      _playlists.values.where((p) => !p.deleted).toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  MusicPlaylist? playlist(String id) => _playlists[id];
  void rememberSharedPlaylist(MusicPlaylist playlist) {
    _playlists[playlist.id] = playlist;
    changed(sync: false);
  }

  bool get cloudAvailable => firestore != null && uid != 'guest';

  void _restore() {
    try {
      final json = jsonDecode(
        prefs.getString(key('personal_music_v1')) ?? '{}',
      );
      if (json is! Map) return;
      for (final row in (json['playlists'] as List? ?? []).whereType<Map>()) {
        try {
          final p = MusicPlaylist.fromJson(Map<String, dynamic>.from(row));
          _playlists[p.id] = p;
        } catch (_) {}
      }
      for (final entry in (json['activity'] as Map? ?? {}).entries) {
        if (entry.value is Map) {
          activity['${entry.key}'] = Map<String, dynamic>.from(
            entry.value as Map,
          );
        }
      }
      for (final entry in (json['days'] as Map? ?? {}).entries) {
        if (entry.value is Map) {
          days['${entry.key}'] = Map<String, dynamic>.from(entry.value as Map);
        }
      }
      for (final song in readSongs(json['offlineTracks'])) {
        offlineTracks[song.id] = song;
      }
      for (final song in readSongs(json['localTracks'])) {
        localTracks[song.id] = song;
      }
      for (final song in readSongs(json['longformTracks'])) {
        longformTracks[song.id] = song;
      }
      customLyrics.addAll(
        Map<String, String>.from(json['lyrics'] as Map? ?? {}),
      );
      songArtists.addAll(
        Map<String, String>.from(json['songArtists'] as Map? ?? {}),
      );
      resumePositions.addAll(
        (json['resume'] as Map? ?? {}).map(
          (k, v) => MapEntry('$k', (v as num).toInt()),
        ),
      );
      hiddenSongs.addAll(List<String>.from(json['hiddenSongs'] as List? ?? []));
      hiddenArtists.addAll(
        List<String>.from(json['hiddenArtists'] as List? ?? []),
      );
      for (final e in (json['feeds'] as Map? ?? {}).entries) {
        feeds['${e.key}'] = List<String>.from(e.value as List);
      }
      settings = ListeningSettings(
        Map<String, dynamic>.from(json['settings'] as Map? ?? {}),
      );
      _dirtyPlaylists.addAll(
        List<String>.from(json['dirtyPlaylists'] as List? ?? []),
      );
      _dirtyActivity.addAll(
        List<String>.from(json['dirtyActivity'] as List? ?? []),
      );
      _dirtyDays.addAll(List<String>.from(json['dirtyDays'] as List? ?? []));
      _dirtySettings = json['dirtySettings'] == true;
    } catch (e) {
      debugPrint('Personal music cache: $e');
    }
  }

  void changed({bool sync = true}) {
    if (_disposed) return;
    final encoded = jsonEncode({
      'playlists': _playlists.values.map((p) => p.toJson()).toList(),
      'activity': activity,
      'days': days,
      'offlineTracks': offlineTracks.values.map((s) => s.toJson()).toList(),
      'localTracks': localTracks.values.map((s) => s.toJson()).toList(),
      'longformTracks': longformTracks.values.map((s) => s.toJson()).toList(),
      'lyrics': customLyrics,
      'songArtists': songArtists,
      'resume': resumePositions,
      'hiddenSongs': hiddenSongs.toList(),
      'hiddenArtists': hiddenArtists.toList(),
      'settings': settings.values,
      'feeds': feeds,
      'dirtyPlaylists': _dirtyPlaylists.toList(),
      'dirtyActivity': _dirtyActivity.toList(),
      'dirtyDays': _dirtyDays.toList(),
      'dirtySettings': _dirtySettings,
    });
    _saving = _saving.catchError((Object _) {}).then((_) async {
      await prefs.setString(key('personal_music_v1'), encoded);
    });
    unawaited(
      _saving.catchError((Object e) {
        debugPrint('Saving music library: $e');
      }),
    );
    notifyListeners();
    if (sync && cloudAvailable) {
      _syncTimer?.cancel();
      _syncTimer = Timer(
        const Duration(seconds: 2),
        () => unawaited(syncNow()),
      );
    }
  }

  MusicPlaylist createPlaylist(
    String name, {
    List<Song> tracks = const [],
    String cover = '🎧',
  }) {
    final value = name.trim();
    if (value.isEmpty || value.length > 80 || tracks.length > 300) {
      throw const FormatException(
        'Use a name up to 80 characters and at most 300 tracks.',
      );
    }
    final p = MusicPlaylist(
      id: newMusicId(),
      name: value,
      ownerUid: uid,
      tracks: List.of(tracks),
      cover: cover,
    );
    _playlists[p.id] = p;
    _dirtyPlaylists.add(p.id);
    changed();
    return p;
  }

  void updatePlaylist(MusicPlaylist p, void Function(MusicPlaylist) update) {
    if (!p.canEdit(uid)) {
      throw StateError('Only playlist editors can make changes.');
    }
    final candidate = MusicPlaylist.fromJson(p.toJson());
    update(candidate);
    if (candidate.name.trim().isEmpty ||
        candidate.name.length > 80 ||
        candidate.tracks.length > 300) {
      throw const FormatException('Playlist limit reached.');
    }
    p.name = candidate.name.trim();
    p.cover = candidate.cover;
    p.description = candidate.description;
    p.public = candidate.public;
    p.deleted = candidate.deleted;
    p.tracks = candidate.tracks;
    p.updatedAt = DateTime.now().millisecondsSinceEpoch;
    _dirtyPlaylists.add(p.id);
    changed();
  }

  void addToPlaylist(MusicPlaylist p, Song song) {
    if (p.tracks.any((s) => s.id == song.id)) return;
    if (p.tracks.length >= 300) {
      throw const FormatException('A playlist can contain up to 300 tracks.');
    }
    updatePlaylist(p, (p) => p.tracks.add(song));
  }

  /// Validate the whole batch before changing or syncing the playlist.
  void addSongsToPlaylist(MusicPlaylist p, Iterable<Song> songs) {
    updatePlaylist(p, (candidate) {
      final ids = candidate.tracks.map((s) => s.id).toSet();
      candidate.tracks.addAll(songs.where((s) => ids.add(s.id)));
    });
  }

  void deletePlaylist(MusicPlaylist p) {
    if (p.ownerUid != uid) {
      throw StateError('Only the owner can delete a playlist.');
    }
    updatePlaylist(p, (p) => p.deleted = true);
  }

  MusicPlaylist duplicate(MusicPlaylist p) => createPlaylist(
    '${p.name.substring(0, p.name.length.clamp(0, 72))} copy',
    tracks: p.tracks,
    cover: p.cover,
  );
  MusicPlaylist import(String input) {
    final p = importPlaylist(input, uid);
    _playlists[p.id] = p;
    _dirtyPlaylists.add(p.id);
    changed();
    return p;
  }

  void setSetting(String name, Object value) {
    settings.values[name] = value;
    settings.values['updatedAt'] = DateTime.now().millisecondsSinceEpoch;
    _dirtySettings = true;
    changed();
  }

  bool accepts(Song song) =>
      !hiddenSongs.contains(song.id) &&
      !hiddenArtists.any(
        (artist) => musicArtists(
          artist,
        ).intersection(musicArtists(song.artist)).isNotEmpty,
      );
  void hide(Song song, {bool artist = false}) {
    if (artist && song.artist.isNotEmpty) {
      hiddenArtists.add(song.artist.toLowerCase());
    } else {
      hiddenSongs.add(song.id);
    }
    settings.values['hiddenSongs'] = hiddenSongs.toList();
    settings.values['hiddenArtists'] = hiddenArtists.toList();
    setSetting('feedbackUpdatedAt', DateTime.now().millisecondsSinceEpoch);
  }

  void recordLike(Song song, bool liked) {
    recordLikes([song], liked);
  }

  void recordLikes(Iterable<Song> songs, bool liked) {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final song in songs) {
      final row = activity.putIfAbsent(
        song.id,
        () => {'song': trackJson(song, cloud: true)},
      );
      row['liked'] = liked;
      row['likedAt'] = now;
      _dirtyActivity.add(song.id);
    }
    changed();
  }

  void recordPlay(Song song) {
    final row = activity.putIfAbsent(
      song.id,
      () => {'song': trackJson(song, cloud: true)},
    );
    row['lastPlayed'] = DateTime.now().millisecondsSinceEpoch;
    _dirtyActivity.add(song.id);
    changed();
  }

  void recordListening(
    Song song,
    int milliseconds, {
    bool skipped = false,
    bool completed = false,
  }) {
    if (milliseconds < 0 || milliseconds > 30000) return;
    final now = DateTime.now();
    final day =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    var device = prefs.getString('musicDeviceId');
    if (device == null) {
      device = newMusicId();
      unawaited(prefs.setString('musicDeviceId', device));
    }
    final id = '$day-$device';
    final row = days.putIfAbsent(
      id,
      () => {'date': day, 'device': device, 'tracks': <String, dynamic>{}},
    );
    final tracks = Map<String, dynamic>.from(row['tracks'] as Map);
    final track = Map<String, dynamic>.from(
      tracks[song.id] as Map? ??
          {
            'song': trackJson(song, cloud: true),
            'ms': 0,
            'skips': 0,
            'completed': 0,
          },
    );
    track['ms'] = (track['ms'] as num).toInt() + milliseconds;
    if (skipped) track['skips'] = (track['skips'] as num).toInt() + 1;
    if (completed) track['completed'] = (track['completed'] as num).toInt() + 1;
    tracks[song.id] = track;
    row['tracks'] = tracks;
    row['updatedAt'] = now.millisecondsSinceEpoch;
    _dirtyDays.add(id);
    if (days.length > 400) {
      final oldest = days.keys.toList()..sort();
      for (final key in oldest.take(days.length - 400)) {
        if (!_dirtyDays.contains(key)) days.remove(key);
      }
    }
    changed();
  }

  Map<String, dynamic> stats({int withinDays = 7}) {
    final cutoff = DateTime.now().subtract(Duration(days: withinDays));
    final totals = <String, Map<String, dynamic>>{};
    int listened = 0, completed = 0;
    for (final day in days.values) {
      if ((DateTime.tryParse('${day['date']}') ?? DateTime(1970)).isBefore(
        DateTime(cutoff.year, cutoff.month, cutoff.day),
      )) {
        continue;
      }
      for (final e in (day['tracks'] as Map? ?? {}).entries) {
        final row = e.value as Map;
        final ms = (row['ms'] as num? ?? 0).toInt();
        listened += ms;
        completed += (row['completed'] as num? ?? 0).toInt();
        final item = totals.putIfAbsent(
          '${e.key}',
          () => {'song': row['song'], 'ms': 0, 'skips': 0, 'completed': 0},
        );
        item['ms'] = (item['ms'] as int) + ms;
        item['skips'] =
            (item['skips'] as int) + (row['skips'] as num? ?? 0).toInt();
        item['completed'] =
            (item['completed'] as int) +
            (row['completed'] as num? ?? 0).toInt();
      }
    }
    final top = totals.values.toList()
      ..sort((a, b) => (b['ms'] as int).compareTo(a['ms'] as int));
    final artists = <String, int>{};
    for (final row in top) {
      final artist = '${(row['song'] as Map?)?['artist'] ?? ''}'.trim();
      if (artist.isNotEmpty) {
        artists.update(
          artist,
          (ms) => ms + (row['ms'] as int),
          ifAbsent: () => row['ms'] as int,
        );
      }
    }
    final topArtists = artists.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return {
      'minutes': listened ~/ 60000,
      'completed': completed,
      'uniqueTracks': totals.length,
      'top': top.take(10).toList(),
      'topArtists': topArtists
          .take(10)
          .map((a) => {'artist': a.key, 'ms': a.value})
          .toList(),
      'feedback': {
        for (final e in totals.entries)
          e.key:
              ((e.value['completed'] as int) * 2 -
                      (e.value['skips'] as int) * 3)
                  .clamp(-9, 9),
      },
      'tracks': totals,
    };
  }

  CollectionReference<Map<String, dynamic>> _userCollection(String name) =>
      firestore!.collection('users').doc(uid).collection(name);
  String _docId(String id) =>
      base64Url.encode(utf8.encode(id)).replaceAll('=', '');
  void _startSync() {
    _subscriptions.add(
      firestore!
          .collection('playlists')
          .where('members', arrayContains: uid)
          .snapshots()
          .listen((snapshot) {
            for (final doc in snapshot.docs) {
              try {
                final remote = MusicPlaylist.fromJson({
                  ...doc.data(),
                  'id': doc.id,
                });
                final local = _playlists[doc.id];
                if (!_dirtyPlaylists.contains(doc.id) &&
                    (local == null || remote.updatedAt >= local.updatedAt)) {
                  _playlists[doc.id] = remote;
                }
              } catch (_) {}
            }
            changed(sync: false);
          }, onError: _syncFailed),
    );
    _subscriptions.add(
      _userCollection('activity').snapshots().listen((snapshot) {
        for (final doc in snapshot.docs) {
          final remote = doc.data();
          final song = remote['song'] is Map
              ? Song.fromJson(Map<String, dynamic>.from(remote['song'] as Map))
              : null;
          if (song == null) continue;
          final local = activity[song.id] ?? {};
          final merged = {...remote, ...local};
          if ((remote['likedAt'] as num? ?? 0) >
              (local['likedAt'] as num? ?? -1)) {
            merged['liked'] = remote['liked'];
            merged['likedAt'] = remote['likedAt'];
            onCloudLike?.call(song, remote['liked'] == true);
          }
          merged['lastPlayed'] = ((remote['lastPlayed'] as num? ?? 0).toInt())
              .clamp(
                (local['lastPlayed'] as num? ?? 0).toInt(),
                8640000000000000,
              );
          activity[song.id] = merged;
        }
        onCloudActivity?.call();
        changed(sync: false);
      }, onError: _syncFailed),
    );
    _subscriptions.add(
      _userCollection('listeningDays').snapshots().listen((snapshot) {
        for (final doc in snapshot.docs) {
          if (!_dirtyDays.contains(doc.id)) days[doc.id] = doc.data();
        }
        changed(sync: false);
      }, onError: _syncFailed),
    );
    _subscriptions.add(
      _userCollection('preferences').doc('listening').snapshots().listen((doc) {
        final row = doc.data();
        if (row != null && !_dirtySettings) {
          // Device-only download/offline settings are deliberately not synced.
          settings.values.addAll(row);
          hiddenSongs
            ..clear()
            ..addAll(List<String>.from(row['hiddenSongs'] as List? ?? []));
          hiddenArtists
            ..clear()
            ..addAll(List<String>.from(row['hiddenArtists'] as List? ?? []));
          changed(sync: false);
        }
      }, onError: _syncFailed),
    );
    unawaited(syncNow());
  }

  void _syncFailed(Object error) {
    if (_disposed) return;
    syncError = 'Cloud sync unavailable. Changes are saved on this device.';
    debugPrint('Music sync: $error');
    notifyListeners();
  }

  Future<void> syncNow() async {
    if (!cloudAvailable || _writing || _disposed) return;
    _writing = true;
    syncing = true;
    notifyListeners();
    try {
      for (final id in _dirtyPlaylists.toList()) {
        final p = _playlists[id];
        if (p == null) continue;
        final revision = p.updatedAt;
        final row = p.toJson(cloud: true),
            reference = firestore!.collection('playlists').doc(id);
        Map<String, dynamic>? newer;
        await firestore!.runTransaction((transaction) async {
          final remote = (await transaction.get(reference)).data();
          if (remote != null && (remote['updatedAt'] as num? ?? 0) > revision) {
            newer = remote;
            return;
          }
          if (remote == null) {
            transaction.set(reference, row);
          } else {
            transaction.update(reference, {
              'name': row['name'],
              'cover': row['cover'],
              'description': row['description'],
              'tracks': row['tracks'],
              'updatedAt': revision,
              if (p.ownerUid == uid) 'public': row['public'],
              if (p.ownerUid == uid) 'deleted': row['deleted'],
            });
          }
        });
        if (newer != null && p.updatedAt == revision) {
          if (!p.deleted) {
            createPlaylist(
              'Recovered: ${p.name.substring(0, p.name.length.clamp(0, 68))}',
              tracks: p.tracks,
              cover: p.cover,
            );
          }
          _playlists[id] = MusicPlaylist.fromJson({...newer!, 'id': id});
        }
        if (p.updatedAt == revision) _dirtyPlaylists.remove(id);
      }
      for (final id in _dirtyActivity.toList()) {
        final row = Map<String, dynamic>.from(activity[id]!);
        final reference = _userCollection('activity').doc(_docId(id));
        await firestore!.runTransaction((transaction) async {
          final remote =
              (await transaction.get(reference)).data() ?? <String, dynamic>{};
          final merged = {...remote, 'song': row['song']};
          if ((row['likedAt'] as num? ?? 0) >=
                  (remote['likedAt'] as num? ?? 0) &&
              row.containsKey('likedAt')) {
            merged['liked'] = row['liked'];
            merged['likedAt'] = row['likedAt'];
          }
          merged['lastPlayed'] = ((row['lastPlayed'] as num? ?? 0).toInt())
              .clamp(
                (remote['lastPlayed'] as num? ?? 0).toInt(),
                9999999999999,
              );
          transaction.set(reference, merged);
        });
        if (jsonEncode(row) == jsonEncode(activity[id])) {
          _dirtyActivity.remove(id);
        }
      }
      for (final id in _dirtyDays.toList()) {
        final row = jsonDecode(jsonEncode(days[id])) as Map<String, dynamic>;
        await _userCollection('listeningDays').doc(id).set(row);
        if (row['updatedAt'] == days[id]?['updatedAt']) _dirtyDays.remove(id);
      }
      if (_dirtySettings) {
        final revision = settings.values['updatedAt'];
        final row = Map<String, dynamic>.from(settings.values)
          ..removeWhere(
            (k, _) => {
              'wifiOnly',
              'smartDownloads',
              'downloadedOnly',
              'storageBudgetMb',
              'downloadQuality',
            }.contains(k),
          );
        await _userCollection('preferences').doc('listening').set(row);
        if (revision == settings.values['updatedAt']) _dirtySettings = false;
      }
      syncError = null;
    } catch (e) {
      _syncFailed(e);
    } finally {
      _writing = false;
      syncing = false;
      if (!_disposed) changed(sync: false);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _syncTimer?.cancel();
    for (final sub in _subscriptions) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }
}

/// Old device-global activity is claimed by the first signed-in account once.
Future<void> migrateMusicAccount(SharedPreferences prefs, String uid) async {
  if (uid == 'guest' || prefs.getString('musicLegacyOwner') != null) return;
  for (final name in [
    'likedSongIds',
    'recentSongIds',
    'recent_stream_history',
  ]) {
    final list = prefs.getStringList(name);
    if (list != null) await prefs.setStringList('user:$uid:$name', list);
  }
  for (final name in ['media_library_v1', 'offlineSongs', 'offlineMedia']) {
    final value = prefs.getString(name);
    if (value != null) await prefs.setString('user:$uid:$name', value);
  }
  await prefs.setString('musicLegacyOwner', uid);
}

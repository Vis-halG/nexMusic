import 'dart:convert';
import 'dart:math';
import 'music_data.dart';
import 'song_languages.dart';
import 'music_recommendations.dart';
import 'package:pointycastle/digests/sha256.dart';

enum MusicRandomScope { home, stream, library }

String musicStorageId(String value) => SHA256Digest()
    .process(utf8.encode(value))
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();

String newMusicId() {
  final random = Random.secure();
  return '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${List.generate(16, (_) => random.nextInt(36).toRadixString(36)).join()}';
}

enum MusicQuality {
  low('Data saver', 96),
  standard('Standard', 160),
  high('High', 320);

  const MusicQuality(this.label, this.kbps);
  final String label;
  final int kbps;
}

enum MusicRepeat { off, all, one }

class MusicPlaylist {
  MusicPlaylist({
    required this.id,
    required this.name,
    required this.ownerUid,
    List<Song>? tracks,
    this.cover = '🎧',
    this.description = '',
    this.public = false,
    this.deleted = false,
    int? updatedAt,
    List<String>? members,
    List<String>? editors,
  }) : tracks = uniqueMusicTracks(tracks ?? []),
       members = members ?? [ownerUid],
       editors = editors ?? [ownerUid],
       updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;
  final String id, ownerUid;
  String name, cover, description;
  bool public, deleted;
  int updatedAt;
  List<Song> tracks;
  List<String> members, editors;
  bool canEdit(String uid) => ownerUid == uid || editors.contains(uid);
  Map<String, dynamic> toJson({bool cloud = false}) => {
    'id': id,
    'name': name,
    'ownerUid': ownerUid,
    'cover': cover,
    'description': description,
    'public': public,
    'deleted': deleted,
    'updatedAt': updatedAt,
    'members': members,
    'editors': editors,
    'tracks': tracks.map((s) => trackJson(s, cloud: cloud)).toList(),
  };
  static MusicPlaylist fromJson(Map<String, dynamic> row) => MusicPlaylist(
    id: row['id'] as String,
    name: row['name'] as String,
    ownerUid: row['ownerUid'] as String,
    cover: row['cover'] as String? ?? '🎧',
    description: row['description'] as String? ?? '',
    public: row['public'] == true,
    deleted: row['deleted'] == true,
    updatedAt: (row['updatedAt'] as num?)?.toInt() ?? 0,
    members: List<String>.from(row['members'] as List? ?? []),
    editors: List<String>.from(row['editors'] as List? ?? []),
    tracks: readSongs(row['tracks']),
  );
}

Map<String, dynamic> trackJson(Song song, {bool cloud = false}) {
  final row = Map<String, dynamic>.from(song.toJson());
  if (cloud &&
      (song.isLocal ||
          song.isPrivate ||
          song.url.startsWith('file:') ||
          song.url.startsWith('content:'))) {
    row['url'] = 'device:${song.id}';
    row['localFolder'] = '';
  }
  // Provider streams expire. Persist identity, resolve at playback time.
  if (song.isProvider) row['url'] = '';
  return row;
}

List<Song> readSongs(dynamic value) {
  final songs = <Song>[];
  if (value is! List) return songs;
  for (final row in value.whereType<Map>()) {
    try {
      final song = Song.fromJson(Map<String, dynamic>.from(row));
      if (song != null) songs.add(song);
    } catch (_) {
      /* Preserve usable rows. */
    }
  }
  return songs;
}

class ListeningSettings {
  ListeningSettings([Map<String, dynamic>? values]) : values = values ?? {};
  final Map<String, dynamic> values;
  bool flag(String key, [bool fallback = false]) =>
      values[key] is bool ? values[key] as bool : fallback;
  int number(String key, int fallback) =>
      (values[key] as num?)?.toInt() ?? fallback;
  String text(String key, [String fallback = '']) =>
      values[key] as String? ?? fallback;
  bool get autoplay => flag('autoplay', true);
  bool get wifiOnly => flag('wifiOnly', true);
  bool get smartDownloads => flag('smartDownloads');
  bool get downloadedOnly => flag('downloadedOnly');
  bool get gapless => flag('gapless', true);
  int get crossfade => number('crossfade', 0).clamp(0, 12);
  int get storageBudgetMb => number('storageBudgetMb', 1024).clamp(64, 16384);
  String get language => text('language', 'Any');
  Set<String> get selectedLanguages {
    final stored = values['songLanguages'];
    if (stored is! List) return {'Hindi', 'English'};
    return stored
        .whereType<String>()
        .map(normalizeSongLanguage)
        .where((s) => s.isNotEmpty)
        .toSet();
  }

  bool allowsLanguage(Song song) {
    final language = normalizeSongLanguage(song.language);
    // Untagged songs stay available; guessing could hide the wrong songs.
    return language.isEmpty || selectedLanguages.contains(language);
  }

  String get mood => text('mood', 'Any');
  MusicQuality quality(String key) => MusicQuality.values.firstWhere(
    (q) => q.name == text(key, 'high'),
    orElse: () => MusicQuality.high,
  );
}

/// A traversal has its own history. Random play visits each queued entry once.
class ListeningQueue {
  ListeningQueue({Random? random}) : _random = random ?? Random();
  final Random _random;
  final List<Song> tracks = [];
  final List<String> history = [], _remaining = [];
  String? currentId;
  bool shuffled = false;
  MusicRepeat repeat = MusicRepeat.off;
  Song? get current => tracks.where((s) => s.id == currentId).firstOrNull;
  void replace(List<Song> songs, Song song) {
    tracks
      ..clear()
      ..addAll(
        {for (final s in songs.where((s) => !s.isVideo)) s.id: s}.values,
      );
    if (!tracks.any((s) => s.id == song.id)) tracks.insert(0, song);
    currentId = song.id;
    history
      ..clear()
      ..add(song.id);
    _reshuffle();
  }

  void select(Song song, {bool record = true}) {
    currentId = song.id;
    _remaining.remove(song.id);
    if (record && (history.isEmpty || history.last != song.id)) {
      history.add(song.id);
    }
    if (history.length > 500) history.removeRange(0, history.length - 500);
  }

  void setShuffle(bool value) {
    shuffled = value;
    _reshuffle();
  }

  void _reshuffle() {
    _remaining
      ..clear()
      ..addAll(tracks.where((s) => s.id != currentId).map((s) => s.id))
      ..shuffle(_random);
  }

  Song? peekNext({bool completed = false}) {
    if (completed && repeat == MusicRepeat.one) return current;
    if (tracks.isEmpty) return null;
    if (shuffled) {
      if (_remaining.isEmpty && repeat == MusicRepeat.all) _reshuffle();
      return _remaining.isEmpty
          ? null
          : tracks.where((s) => s.id == _remaining.first).firstOrNull;
    }
    final index = tracks.indexWhere((s) => s.id == currentId);
    if (index + 1 < tracks.length) return tracks[index + 1];
    return repeat == MusicRepeat.all ? tracks.first : null;
  }

  Song? previous() {
    if (history.length > 1) {
      history.removeLast();
      currentId = history.last;
      return current;
    }
    final index = tracks.indexWhere((s) => s.id == currentId);
    if (index > 0) {
      currentId = tracks[index - 1].id;
      return current;
    }
    return null;
  }

  Song? peekPrevious() {
    if (history.length > 1) {
      return tracks
          .where((s) => s.id == history[history.length - 2])
          .firstOrNull;
    }
    final index = tracks.indexWhere((s) => s.id == currentId);
    return index > 0 ? tracks[index - 1] : null;
  }

  void add(Song song, {bool next = false}) {
    if (song.isVideo || song.id == currentId) return;
    if (tracks.any((s) => s.id == song.id)) {
      if (!next) return;
      remove(song.id);
    }
    final index = tracks.indexWhere((s) => s.id == currentId);
    tracks.insert(
      next ? (index + 1).clamp(0, tracks.length) : tracks.length,
      song,
    );
    if (next) {
      _remaining.insert(0, song.id);
    } else {
      _remaining.add(song.id);
    }
  }

  void remove(String id) {
    if (id == currentId) return;
    tracks.removeWhere((s) => s.id == id);
    _remaining.remove(id);
    history.removeWhere((e) => e == id);
  }

  /// Also prunes traversal history, so Previous and shuffled repeat cannot
  /// bring back a track excluded by the listener's current preferences.
  void retainWhere(bool Function(Song) accepts) {
    tracks.removeWhere((s) => !accepts(s));
    final ids = tracks.map((s) => s.id).toSet();
    history.removeWhere((id) => !ids.contains(id));
    _remaining.removeWhere((id) => !ids.contains(id));
    if (!ids.contains(currentId)) {
      currentId = null;
    }
  }

  void reorder(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    tracks.insert(newIndex, tracks.removeAt(oldIndex));
    _reshuffle();
  }

  Map<String, dynamic> toJson() => {
    'tracks': tracks.map((s) => trackJson(s)).toList(),
    'currentId': currentId,
    'history': history,
    'remaining': _remaining,
    'shuffled': shuffled,
    'repeat': repeat.name,
  };
  void restore(dynamic json) {
    if (json is! Map) return;
    tracks
      ..clear()
      ..addAll(readSongs(json['tracks']));
    currentId = json['currentId'] as String?;
    history
      ..clear()
      ..addAll(List<String>.from(json['history'] as List? ?? []));
    _remaining
      ..clear()
      ..addAll(List<String>.from(json['remaining'] as List? ?? []));
    shuffled = json['shuffled'] == true;
    repeat = MusicRepeat.values.firstWhere(
      (r) => r.name == json['repeat'],
      orElse: () => MusicRepeat.off,
    );
  }
}

String exportPlaylist(MusicPlaylist playlist) =>
    const JsonEncoder.withIndent('  ').convert({
      'format': 'nexMusic-playlist',
      'version': 1,
      'playlist': playlist.toJson(cloud: true),
    });

MusicPlaylist importPlaylist(String input, String uid) {
  final row = jsonDecode(input);
  if (row is! Map ||
      !{'nexMusic-playlist', 'nexApp-playlist'}.contains(row['format']) ||
      row['version'] != 1 ||
      row['playlist'] is! Map) {
    throw const FormatException('Choose a nexMusic playlist JSON file.');
  }
  final source = MusicPlaylist.fromJson(
    Map<String, dynamic>.from(row['playlist'] as Map),
  );
  if (source.name.trim().isEmpty ||
      source.name.length > 80 ||
      source.tracks.length > 300) {
    throw const FormatException(
      'Playlist must have a name and at most 300 tracks.',
    );
  }
  return MusicPlaylist(
    id: newMusicId(),
    name: source.name,
    ownerUid: uid,
    tracks: source.tracks,
    cover: source.cover,
    description: source.description,
  );
}

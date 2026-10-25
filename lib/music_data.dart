/// Prefix for ids of private library items wrapped in a [Song] for playback.
const privateSongPrefix = 'private-';

/// A shared category. Any signed-in user can create, rename or delete one.
class MusicCategory {
  const MusicCategory({
    required this.id,
    required this.name,
    required this.ownerUid,
  });
  final String id, name, ownerUid;
}

/// A playable audio or video item.
///
/// Public uploads are stored on Cloudinary and listed in the shared `songs`
/// collection. Private library files are wrapped in a [Song] only while they
/// play.
class Song {
  const Song({
    required this.id,
    required this.title,
    required this.kind,
    required this.url,
    this.categoryId = '',
    this.extraCategoryIds = const [],
    this.ownerUid = '',
    this.ownerName = '',
    this.artist = '',
    this.artworkUrl = '',
    this.providerId = '',
    this.sourceId = '',
    this.album = '',
    this.albumId = '',
    this.artistId = '',
    this.language = '',
    this.genre = '',
    this.contentType = 'music',
    this.previewUrl = '',
    this.localFolder = '',
    this.publicId,
    this.storagePath,
    this.sizeBytes = 0,
    this.durationMs = 0,
    this.createdAt,
  });
  final String id, title, kind, url, categoryId, ownerUid, ownerName;

  /// Categories the song is also listed in, besides its main [categoryId].
  /// Older app versions only know the main one.
  final List<String> extraCategoryIds;
  final String artist, artworkUrl, providerId, sourceId;

  /// Every category the song is listed in, the main one first.
  List<String> get categoryIds => [
    if (categoryId.isNotEmpty) categoryId,
    for (final id in extraCategoryIds)
      if (id != categoryId) id,
  ];

  bool inCategory(String id) =>
      categoryId == id || extraCategoryIds.contains(id);
  final String album,
      albumId,
      artistId,
      language,
      genre,
      contentType,
      previewUrl,
      localFolder;
  bool get isLocal => id.startsWith('local:');
  bool get isLongform => contentType == 'podcast' || contentType == 'audiobook';

  /// Cloudinary id of a public upload.
  final String? publicId;

  /// Firebase Storage path of a private library file.
  final String? storagePath;
  final int sizeBytes;
  final int durationMs;
  final DateTime? createdAt;

  bool get isVideo => kind == 'video';
  bool get isPrivate => id.startsWith(privateSongPrefix);
  bool get isProvider => providerId.isNotEmpty;

  Song copyWith({
    String? id,
    String? title,
    String? kind,
    String? url,
    String? categoryId,
    List<String>? extraCategoryIds,
    String? ownerUid,
    String? ownerName,
    String? artist,
    String? artworkUrl,
    String? providerId,
    String? sourceId,
    String? album,
    String? albumId,
    String? artistId,
    String? language,
    String? genre,
    String? contentType,
    String? previewUrl,
    String? localFolder,
    String? publicId,
    String? storagePath,
    int? sizeBytes,
    int? durationMs,
    DateTime? createdAt,
  }) => Song(
    id: id ?? this.id,
    title: title ?? this.title,
    kind: kind ?? this.kind,
    url: url ?? this.url,
    categoryId: categoryId ?? this.categoryId,
    extraCategoryIds: extraCategoryIds ?? this.extraCategoryIds,
    ownerUid: ownerUid ?? this.ownerUid,
    ownerName: ownerName ?? this.ownerName,
    artist: artist ?? this.artist,
    artworkUrl: artworkUrl ?? this.artworkUrl,
    providerId: providerId ?? this.providerId,
    sourceId: sourceId ?? this.sourceId,
    album: album ?? this.album,
    albumId: albumId ?? this.albumId,
    artistId: artistId ?? this.artistId,
    language: language ?? this.language,
    genre: genre ?? this.genre,
    contentType: contentType ?? this.contentType,
    previewUrl: previewUrl ?? this.previewUrl,
    localFolder: localFolder ?? this.localFolder,
    publicId: publicId ?? this.publicId,
    storagePath: storagePath ?? this.storagePath,
    sizeBytes: sizeBytes ?? this.sizeBytes,
    durationMs: durationMs ?? this.durationMs,
    createdAt: createdAt ?? this.createdAt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'kind': kind,
    'url': url,
    'categoryId': categoryId,
    'categoryIds': categoryIds,
    'ownerUid': ownerUid,
    'ownerName': ownerName,
    'artist': artist,
    'artworkUrl': artworkUrl,
    'providerId': providerId,
    'sourceId': sourceId,
    'album': album,
    'albumId': albumId,
    'artistId': artistId,
    'language': language,
    'genre': genre,
    'contentType': contentType,
    'previewUrl': previewUrl,
    'localFolder': localFolder,
    'storagePath': storagePath,
    'publicId': publicId,
    'sizeBytes': sizeBytes,
    'durationMs': durationMs,
    'createdAt': createdAt?.millisecondsSinceEpoch,
  };

  /// The ids in a stored `categoryIds` list other than [main].
  static List<String> extraCategories(Object? stored, String main) => [
    if (stored is List)
      for (final id in stored.whereType<String>().toSet())
        if (id.isNotEmpty && id != main) id,
  ];

  /// Reads a song saved by [toJson], or returns null for an unusable entry.
  static Song? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final url = json['url'];
    final providerId = json['providerId'] as String? ?? '';
    final sourceId = json['sourceId'] as String? ?? '';
    if (id is! String ||
        id.isEmpty ||
        url is! String ||
        (url.isEmpty && (providerId.isEmpty || sourceId.isEmpty))) {
      return null;
    }
    final createdAt = json['createdAt'];
    final categoryId = json['categoryId'] as String? ?? '';
    return Song(
      id: id,
      title: json['title'] as String? ?? 'Untitled',
      kind: json['kind'] == 'video' ? 'video' : 'audio',
      url: url,
      categoryId: categoryId,
      extraCategoryIds: extraCategories(json['categoryIds'], categoryId),
      ownerUid: json['ownerUid'] as String? ?? '',
      ownerName: json['ownerName'] as String? ?? '',
      artist: json['artist'] as String? ?? '',
      artworkUrl: json['artworkUrl'] as String? ?? '',
      providerId: providerId,
      sourceId: sourceId,
      album: json['album'] as String? ?? '',
      albumId: json['albumId'] as String? ?? '',
      artistId: json['artistId'] as String? ?? '',
      language: json['language'] as String? ?? '',
      genre: json['genre'] as String? ?? '',
      contentType: json['contentType'] as String? ?? 'music',
      previewUrl: json['previewUrl'] as String? ?? '',
      localFolder: json['localFolder'] as String? ?? '',
      storagePath: json['storagePath'] as String?,
      publicId: json['publicId'] as String?,
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
      createdAt: createdAt is int
          ? DateTime.fromMillisecondsSinceEpoch(createdAt)
          : null,
    );
  }
}

enum UploadStatus { queued, uploading, done, skipped, failed, cancelled }

/// One file in the public upload queue. The controller updates it in place
/// and notifies its listeners.
class UploadItem {
  UploadItem({
    required this.path,
    required this.name,
    required this.sizeBytes,
    required this.title,
  });

  /// The file that will be uploaded; a trimmed copy once [applyTrim] ran.
  String path, name;
  int sizeBytes;
  String title;
  String artist = '';
  bool artistRead = false;

  /// The picked file before trimming, kept so a trim can be redone or undone.
  ({String path, String name, int sizeBytes})? original;
  Duration? trimStart, trimEnd;

  bool get trimmed => original != null;

  /// Swaps in a trimmed copy of the original file.
  void applyTrim({
    required String trimmedPath,
    required int trimmedSize,
    required Duration start,
    required Duration end,
  }) {
    final source = original ??= (path: path, name: name, sizeBytes: sizeBytes);
    final extension =
        RegExp(r'\.[^./\\]+$').firstMatch(trimmedPath)?.group(0) ?? '';
    name = '${source.name.replaceAll(RegExp(r'\.[^.]+$'), '')}$extension';
    path = trimmedPath;
    sizeBytes = trimmedSize;
    trimStart = start;
    trimEnd = end;
  }

  /// Goes back to the picked file and returns the trimmed copy it replaced.
  String? undoTrim() {
    final source = original;
    if (source == null) return null;
    final trimmedPath = path;
    path = source.path;
    name = source.name;
    sizeBytes = source.sizeBytes;
    original = null;
    trimStart = null;
    trimEnd = null;
    return trimmedPath;
  }

  String categoryId = '';

  /// More categories to list the upload in, besides [categoryId].
  List<String> extraCategoryIds = const [];
  UploadStatus status = UploadStatus.queued;

  /// Fraction (0–1) of this file sent to Cloudinary.
  double progress = 0;
  String? error;

  /// Set once the file reached Cloudinary, so a retry only repeats the
  /// Firestore write instead of uploading the file again.
  String? uploadedUrl, uploadedPublicId;

  /// Reused after a timed-out catalogue write to avoid duplicate entries.
  String? catalogId;
  int durationMs = 0;

  bool get finished =>
      status != UploadStatus.queued && status != UploadStatus.uploading;
}

class MediaFolder {
  const MediaFolder({required this.id, required this.name});
  final String id, name;

  MediaFolder copyWith({String? name}) =>
      MediaFolder(id: id, name: name ?? this.name);
}

class SavedMedia {
  const SavedMedia({
    required this.id,
    required this.title,
    required this.kind,
    required this.folderId,
    this.sourceUrl,
    this.storagePath,
  });
  final String id, title, kind, folderId;
  final String? sourceUrl, storagePath;

  SavedMedia copyWith({
    String? title,
    String? folderId,
    String? sourceUrl,
    String? storagePath,
  }) => SavedMedia(
    id: id,
    title: title ?? this.title,
    kind: kind,
    folderId: folderId ?? this.folderId,
    sourceUrl: sourceUrl ?? this.sourceUrl,
    storagePath: storagePath ?? this.storagePath,
  );
}

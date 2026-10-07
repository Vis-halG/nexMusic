import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_update.dart';
import 'cloudinary_status.dart';
import 'media_library.dart';
import 'music_data.dart';
import 'music_discovery.dart';
import 'music_provider.dart';
import 'phone_services.dart';
import 'listening_models.dart';
import 'personal_music.dart';
import 'music_catalog.dart';
import 'music_social.dart';
import 'listening_player.dart';
import 'music_downloads.dart';
import 'music_transfer.dart';
import 'music_lyrics.dart';
import 'music_device.dart';
import 'music_artists.dart';

part 'listening_controller.dart';

/// File types accepted for public uploads: the audio and video formats
/// Cloudinary stores. Phones play most of them directly; the rest are
/// converted by Cloudinary when they are streamed (see [playbackUrlFor]).
const audioExtensions = [
  'mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg', 'oga', 'opus', 'amr', '3ga', //
  'mka', 'aiff', 'aif',
];
const videoExtensions = [
  'mp4', 'm4v', 'mov', 'webm', 'mkv', '3gp', '3g2', 'avi', 'flv', 'wmv', //
  'mpg', 'mpeg', 'ts', 'mts', 'm2ts', 'ogv', 'mxf',
];

/// Formats phones cannot play reliably, and what Cloudinary streams instead.
const _streamAsMp3 = {'aiff', 'aif'};
const _streamAsMp4 = {
  '3g2',
  'avi',
  'flv',
  'wmv',
  'mpg',
  'mpeg',
  'ts',
  'mts',
  'm2ts',
  'ogv',
  'mxf', //
};

/// The link saved for an uploaded file. Cloudinary converts a file when its
/// link ends in another extension, so formats phones cannot play are streamed
/// as MP3 or MP4; the original stays on Cloudinary.
String playbackUrlFor(String cloudinaryUrl) {
  final match = RegExp(r'\.([A-Za-z0-9]+)$').firstMatch(cloudinaryUrl);
  if (match == null) return cloudinaryUrl;
  final extension = match.group(1)!.toLowerCase();
  final target = _streamAsMp3.contains(extension)
      ? 'mp3'
      : _streamAsMp4.contains(extension)
      ? 'mp4'
      : null;
  return target == null
      ? cloudinaryUrl
      : '${cloudinaryUrl.substring(0, match.start)}.$target';
}

/// Largest audio or video file the Cloudinary free plan accepts.
const maxUploadBytes = 100 * 1024 * 1024;

/// Cloudinary account that stores public uploads. Neither value is a secret:
/// unsigned uploads only need the cloud name and an unsigned upload preset.
const cloudinaryCloudName = String.fromEnvironment(
  'CLOUDINARY_CLOUD_NAME',
  defaultValue: 'j0fu6gju',
);
const cloudinaryUploadPreset = String.fromEnvironment(
  'CLOUDINARY_UPLOAD_PRESET',
  defaultValue: 'nexmusic_unsigned',
);

/// Returns 'audio' or 'video' for a supported upload, or null otherwise.
String? uploadKindFor(String fileName) {
  final extension = path
      .extension(fileName)
      .toLowerCase()
      .replaceFirst('.', '');
  if (videoExtensions.contains(extension)) return 'video';
  if (audioExtensions.contains(extension)) return 'audio';
  return null;
}

/// Returns the first YouTube link in shared text, or null if there is none.
String? youtubeLinkIn(String text) {
  final match = RegExp(r'https?://\S+').firstMatch(text);
  if (match == null) return null;
  final link = match.group(0)!.replaceAll(RegExp(r'[),.]+$'), '');
  final host = Uri.tryParse(link)?.host.toLowerCase() ?? '';
  final youtube =
      host == 'youtu.be' ||
      host == 'youtube.com' ||
      host.endsWith('.youtube.com');
  return youtube ? link : null;
}

/// Whether [url] is a DASH, HLS, SmoothStreaming or RTSP stream. The APK leaves
/// ExoPlayer's streaming modules out (see android/app/build.gradle.kts), so
/// these links must not reach a player.
bool isStreamingLink(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return false;
  if (uri.scheme.toLowerCase().startsWith('rtsp')) return true;
  final manifest = RegExp(
    r'(\.m3u8|\.mpd|\.isml?(/manifest(\(.+\))?)?)$',
    caseSensitive: false,
  );
  return manifest.hasMatch(uri.path) || manifest.hasMatch(uri.fragment);
}

/// Deletes a copy the app made inside its cache (a file-picker copy or an
/// in-app browser download). The user's own files are never touched.
void discardTemporaryCopy(String filePath) {
  if (kIsWeb) return;
  final normalized = filePath.replaceAll(r'\', '/');
  if (!normalized.contains('/cache/file_picker/') &&
      !normalized.contains('/cache/browser_downloads/') &&
      !normalized.contains('/cache/nexmusic_exports/') &&
      !normalized.contains('/cache/nexmusic_uploads/')) {
    return;
  }
  unawaited(File(filePath).delete().then<void>((_) {}, onError: (Object _) {}));
}

/// Names a browser download from its Content-Disposition header, falling back
/// to the URL, and adds an extension from the MIME type when one is missing.
String downloadFileName(Uri url, String? contentDisposition, String mimeType) {
  var name = '';
  if (contentDisposition != null) {
    final encoded = RegExp(
      r"filename\*\s*=\s*[\w-]+''([^;]+)",
      caseSensitive: false,
    ).firstMatch(contentDisposition);
    final plain = RegExp(
      r'filename\s*=\s*"?([^";]+)"?',
      caseSensitive: false,
    ).firstMatch(contentDisposition);
    final raw = (encoded?.group(1) ?? plain?.group(1))?.trim();
    if (raw != null) {
      try {
        name = Uri.decodeComponent(raw);
      } catch (_) {
        name = raw;
      }
    }
  }
  if (name.isEmpty && url.pathSegments.isNotEmpty) {
    name = url.pathSegments.last;
  }
  name = name
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (uploadKindFor(name) == null) {
    final extension = switch (mimeType.toLowerCase()) {
      'audio/mpeg' || 'audio/mp3' => '.mp3',
      'audio/mp4' || 'audio/m4a' || 'audio/x-m4a' => '.m4a',
      'audio/aac' || 'audio/aacp' || 'audio/x-aac' => '.aac',
      'audio/wav' || 'audio/x-wav' || 'audio/wave' => '.wav',
      'audio/flac' || 'audio/x-flac' => '.flac',
      'audio/ogg' => '.ogg',
      'audio/opus' => '.opus',
      'audio/amr' || 'audio/amr-wb' => '.amr',
      'audio/3gpp' => '.3ga',
      'audio/x-matroska' => '.mka',
      'audio/aiff' || 'audio/x-aiff' => '.aiff',
      'video/mp4' => '.mp4',
      'video/x-m4v' => '.m4v',
      'video/webm' => '.webm',
      'video/quicktime' => '.mov',
      'video/x-matroska' => '.mkv',
      'video/3gpp' => '.3gp',
      'video/3gpp2' => '.3g2',
      'video/x-msvideo' || 'video/avi' => '.avi',
      'video/x-flv' => '.flv',
      'video/x-ms-wmv' => '.wmv',
      'video/mpeg' => '.mpg',
      'video/mp2t' => '.ts',
      'video/ogg' => '.ogv',
      'application/mxf' => '.mxf',
      _ => '',
    };
    if (extension.isNotEmpty) {
      name = '${name.isEmpty ? 'download' : name}$extension';
    }
  }
  if (name.length > 120) {
    final extension = path.extension(name);
    name = '${name.substring(0, 120 - extension.length)}$extension';
  }
  return name.isEmpty ? 'download' : name;
}

/// Saves [url] into the app cache when it is an audio or video file, so the
/// in-app browser can hand it to the upload screen. `isWebPage` is true when
/// the link is an ordinary page that the browser should open instead.
Future<({String? path, bool isWebPage, String? error})> downloadBrowserMedia(
  Uri url, {
  String? referer,
  String? userAgent,
  void Function(double fraction)? onProgress,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  File? file;
  try {
    final request = await client.getUrl(url);
    if (userAgent != null) {
      request.headers.set(HttpHeaders.userAgentHeader, userAgent);
    }
    if (referer != null) {
      request.headers.set(HttpHeaders.refererHeader, referer);
    }
    final response = await request.close().timeout(const Duration(minutes: 1));
    final mimeType = response.headers.contentType?.mimeType.toLowerCase() ?? '';
    if (mimeType == 'text/html') {
      return (path: null, isWebPage: true, error: null);
    }
    if (response.statusCode != HttpStatus.ok) {
      return (
        path: null,
        isWebPage: false,
        error: 'Download failed (HTTP ${response.statusCode}).',
      );
    }
    final name = downloadFileName(
      url,
      response.headers.value('content-disposition'),
      mimeType,
    );
    if (uploadKindFor(name) == null) {
      return (
        path: null,
        isWebPage: false,
        error: 'This link is not an audio or video file.',
      );
    }
    final expected = response.contentLength;
    if (expected >= maxUploadBytes) {
      return (
        path: null,
        isWebPage: false,
        error: 'Files over 100 MB cannot be uploaded.',
      );
    }
    final cache = await getTemporaryDirectory();
    // A folder per download keeps the original file name for the title.
    final folder = Directory(
      path.join(
        cache.path,
        'browser_downloads',
        '${DateTime.now().millisecondsSinceEpoch}',
      ),
    );
    await folder.create(recursive: true);
    file = File(path.join(folder.path, name));
    final sink = file.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.timeout(const Duration(minutes: 1))) {
        received += chunk.length;
        if (received >= maxUploadBytes) {
          throw const _UploadFailure('Files over 100 MB cannot be uploaded.');
        }
        sink.add(chunk);
        if (expected > 0) onProgress?.call(received / expected);
      }
    } finally {
      await sink.close();
    }
    if (received == 0) throw const _UploadFailure('The download was empty.');
    return (path: file.path, isWebPage: false, error: null);
  } on _UploadFailure catch (error) {
    await _deleteQuietly(file);
    return (path: null, isWebPage: false, error: error.message);
  } catch (error) {
    await _deleteQuietly(file);
    return (path: null, isWebPage: false, error: 'Download failed: $error');
  } finally {
    client.close(force: true);
  }
}

Future<void> _deleteQuietly(File? file) async {
  if (file == null) return;
  try {
    await file.delete();
  } catch (_) {}
}

/// Playback, preferences and Firebase access stay in one controller so the
/// project remains deliberately compact.
class MusicController extends ChangeNotifier {
  MusicController(
    SharedPreferences preferences, {
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
    FirebaseStorage? storage,
    AudioPlayer? player,
    NexAudioHandler? audioHandler,
    PhoneServices? phone,
    MusicProvider? musicProvider,
    List<MusicProvider>? musicProviders,
  }) : this._withFirebase(
         preferences,
         auth,
         firestore,
         storage,
         player ?? AudioPlayer(),
         audioHandler,
         phone,
         musicProviders ??
             [
               musicProvider ?? JioSaavnProvider(),
               if (musicProvider == null) YouTubeMusicProvider(),
               if (musicProvider == null) YouTubeVideoProvider(),
             ],
       );

  MusicController._withFirebase(
    this._prefs,
    this._auth,
    this._firestore,
    this._storage,
    this._audio,
    this._audioHandler,
    this.phone,
    this._musicProviders,
  ) {
    if (_musicProviders.isEmpty) {
      throw ArgumentError.value(_musicProviders, 'musicProviders');
    }
    activeProviderId = _musicProviders.first.id;
    if (!kIsWeb) {
      _uploadNetwork = Connectivity().onConnectivityChanged.listen((_) {
        if (uploadsWaiting && !uploadsPaused && !_uploadsDisposed) {
          unawaited(resumeUploads());
        }
      }, onError: (Object _) {});
    }
    _initPersonal(_auth?.currentUser?.uid ?? 'guest');
    signedIn = _auth?.currentUser != null;
    pushEnabled = _prefs.getBool('pushEnabled') ?? true;
    // Lock screen and notification buttons follow the app's own queue.
    _audioHandler
      ?..onNext = next
      ..onPrevious = previous;
    // Without Firestore (tests) there is no catalogue to wait for.
    catalogLoaded = _firestore == null;
    darkMode = _prefs.getBool('darkMode') ?? false;
    browserPillOne = _prefs.getString('browserPillOne');
    browserPillTwo = _prefs.getString('browserPillTwo');
    liked.addAll(_prefs.getStringList(_accountKey('likedSongIds')) ?? const []);
    recentSongIds.addAll(
      _prefs.getStringList(_accountKey('recentSongIds')) ?? const [],
    );
    try {
      final saved = jsonDecode(
        _prefs.getString(_accountKey('offlineMedia')) ?? '{}',
      );
      if (saved is Map) {
        offlinePaths.addAll(
          saved.map((key, value) => MapEntry('$key', '$value')),
        );
      }
    } catch (_) {
      _prefs.remove(_accountKey('offlineMedia'));
    }
    try {
      final saved = jsonDecode(
        _prefs.getString(_accountKey('offlineSongs')) ?? '{}',
      );
      if (saved is Map) {
        offlineSongs.addAll(
          saved.map((key, value) => MapEntry('$key', '$value')),
        );
      }
    } catch (_) {
      _prefs.remove(_accountKey('offlineSongs'));
    }
    try {
      final streamList =
          _prefs.getStringList(_accountKey('recent_stream_history')) ??
          const [];
      for (final str in streamList) {
        final decoded = jsonDecode(str);
        if (decoded is Map<String, dynamic>) {
          final song = Song.fromJson(decoded);
          if (song != null) _recentStreamSongs.add(song);
        }
      }
    } catch (_) {
      _prefs.remove(_accountKey('recent_stream_history'));
    }
    _initPlayback();
    if (_auth != null) {
      _subs.add(
        _auth.authStateChanges().listen((user) {
          signedIn = user != null;
          if (user != null) {
            guestMode = false;
            unawaited(
              _switchAccount(user.uid).then((_) async {
                if (_auth.currentUser?.uid != user.uid) return;
                await _startCatalog();
                await loadCloudLibrary();
              }),
            );
            if (pushEnabled) unawaited(phone?.enablePush());
          } else {
            _stopCatalog();
            unawaited(_switchAccount('guest'));
          }
          notifyListeners();
        }),
      );
    }
    _initInstalledVersion();
  }

  final SharedPreferences _prefs;
  SharedPreferences get preferences => _prefs;

  /// Device-local history and likes shared by music and video sources.
  late MediaLibrary library;
  late PersonalMusic personal;
  final MusicCatalog catalog = MusicCatalog();
  MusicSocial? social;
  late MusicDownloads downloads;
  late ListeningPlayer playback;
  late final MusicLyricsService lyricsService = MusicLyricsService(_prefs);
  Future<void> _accountSwitch = Future.value();
  String _accountUid = 'guest';
  int _accountGeneration = 0;
  bool guestMode = false;

  String _installedVersion = currentAppVersion;
  String get installedVersion => _installedVersion;

  void _initInstalledVersion() {
    phone?.getAppVersion().then((info) {
      if (info != null && info.version.isNotEmpty) {
        _installedVersion = info.version;
        notifyListeners();
      }
    });
  }

  final FirebaseAuth? _auth;
  final FirebaseFirestore? _firestore;
  final FirebaseStorage? _storage;
  AudioPlayer _audio;
  final NexAudioHandler? _audioHandler;
  final List<MusicProvider> _musicProviders;
  late final MusicDiscovery discovery = MusicDiscovery(_musicProviders);

  /// Widgets, notifications and push on Android; null in tests.
  final PhoneServices? phone;
  final List<StreamSubscription<dynamic>> _subs = [];
  final List<StreamSubscription<dynamic>> _catalogSubs = [];
  final ValueNotifier<Duration> positionListenable = ValueNotifier(
    Duration.zero,
  );
  final Set<String> liked = {};
  final List<String> recentSongIds = [];
  final List<Song> _recentStreamSongs = [];
  List<Song> get recentStreamSongs => List.unmodifiable(_recentStreamSongs);

  void _recordStreamSong(Song song) {
    if (!song.isProvider) return;
    _recentStreamSongs.removeWhere((s) => s.id == song.id);
    _recentStreamSongs.insert(0, song);
    if (_recentStreamSongs.length > 25) {
      _recentStreamSongs.removeRange(25, _recentStreamSongs.length);
    }
    final raw = _recentStreamSongs.map((s) => jsonEncode(s.toJson())).toList();
    unawaited(_prefs.setStringList(_accountKey('recent_stream_history'), raw));
  }

  Map<String, String> offlinePaths = {};

  /// Public songs saved on this device for offline listening, by song id.
  Map<String, String> offlineSongs = {};

  /// Progress (0–1) of song downloads that are still running, by song id.
  final Map<String, double> songDownloads = {};

  /// Shared catalogue. Songs are cached on the device and only documents
  /// changed since the last sync are read from Firestore.
  List<MusicCategory> categories = const [];
  List<Song> songs = const [];

  /// Results from the optional online provider. They stay separate from the
  /// shared Firebase catalogue and are never uploaded to Firestore.
  List<Song> providerSongs = const [];
  bool providerLoading = false;
  String? providerError;
  String providerQuery = '';
  String activeProviderId = '';
  int _providerRequest = 0;
  int _catalogSyncedAt = 0;
  bool _catalogStarting = false;
  Timer? _catalogSaveTimer;

  /// Current or most recent batch of public uploads.
  List<UploadItem> uploads = const [];
  bool _drainingUploads = false;
  bool _uploadDrainAgain = false, _uploadsDisposed = false;
  StreamSubscription<List<ConnectivityResult>>? _uploadNetwork;
  late final TransferRecovery _uploadRecovery = TransferRecovery(
    onRetry: () {
      if (!_uploadsDisposed && !uploadsPaused) unawaited(resumeUploads());
    },
  );
  bool get uploadsWaiting => _uploadRecovery.waiting;
  String? get uploadWaitMessage => _uploadRecovery.message;

  /// True while the listener has paused the batch. Nothing new starts, and a
  /// file that was halfway starts again from the beginning on resume, because
  /// Cloudinary takes each file in a single request.
  bool uploadsPaused = false;

  /// The request sending each file, so a pause or cancel can pull it back.
  final Map<UploadItem, HttpClient> _uploadClients = {};

  /// What a file in flight becomes once its request has been pulled back.
  final Map<UploadItem, UploadStatus> _stopTo = {};

  List<Song> queue = const [];
  List<Song> streamRandomTracks = const [];
  MusicRandomScope? _randomScope;
  List<MediaFolder> mediaFolders = const [
    MediaFolder(id: 'local-imports', name: 'My Imports'),
  ];
  List<SavedMedia> savedMedia = const [];
  Song? current;
  Duration position = Duration.zero, duration = Duration.zero;
  bool signedIn = false,
      catalogLoaded = false,
      darkMode = false,
      playing = false,
      loading = false,
      shuffle = false,
      repeat = false;
  String? notice;
  String? browserPillOne, browserPillTwo;

  /// Whether this phone is notified about other people's activity.
  bool pushEnabled = true;
  Timer? _widgetTimer;
  String? _widgetData;
  DateTime _uploadNotifiedAt = DateTime.fromMillisecondsSinceEpoch(0);
  final Set<UploadItem> _reportedUploads = {};

  bool get backendConfigured =>
      _auth != null && _firestore != null && _storage != null;
  bool get uploadsConfigured =>
      cloudinaryCloudName.isNotEmpty && cloudinaryUploadPreset.isNotEmpty;
  String? get uid => _auth?.currentUser?.uid;

  Future<CloudinaryStatus> loadCloudinaryStatus() async {
    final token = await _auth?.currentUser?.getIdToken();
    if (token == null || token.isEmpty) {
      throw const CloudinaryStatusException(
        'Sign in to view Cloudinary account usage.',
      );
    }
    final status = await CloudinaryStatusService().load(
      workerUrl: pushWorkerUrl,
      token: token,
    );
    if (status.cloudName != cloudinaryCloudName) {
      throw const CloudinaryStatusException(
        'Cloudinary account reporting is connected to a different account.',
      );
    }
    return status;
  }

  bool get uploading => uploads.any((item) => !item.finished);
  int get uploadsFinished => uploads.where((item) => item.finished).length;
  int get uploadsFailed =>
      uploads.where((item) => item.status == UploadStatus.failed).length;
  int get uploadsCancelled =>
      uploads.where((item) => item.status == UploadStatus.cancelled).length;

  /// Share of the batch's bytes that are finished or in flight.
  double get uploadFraction {
    final total = uploads.fold<int>(0, (bytes, item) => bytes + item.sizeBytes);
    if (total == 0) return 0;
    final sent = uploads.fold<double>(
      0,
      (bytes, item) =>
          bytes +
          switch (item.status) {
            UploadStatus.queued => 0,
            UploadStatus.uploading => item.sizeBytes * item.progress,
            _ => item.sizeBytes.toDouble(),
          },
    );
    return (sent / total).clamp(0.0, 1.0);
  }

  String get profileName {
    final name = _auth?.currentUser?.displayName?.trim();
    return name == null || name.isEmpty ? 'Listener' : name;
  }

  String get profileEmail => _auth?.currentUser?.email?.trim() ?? '';

  String get profileInitials {
    final words = profileName
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty);
    return words.take(2).map((word) => word[0].toUpperCase()).join();
  }

  List<Song> get likedSongs => librarySongs(MediaCollection.likedSongs);
  List<Song> get recentSongs => librarySongs(MediaCollection.recent);
  List<Song> get myUploads {
    final userId = uid;
    if (userId == null) return const [];
    return songs.where((song) => song.ownerUid == userId).toList();
  }

  Song? songById(String id) {
    for (final song in songs) {
      if (song.id == id) return song;
    }
    return personal.offlineTracks[id] ??
        personal.localTracks[id] ??
        personal.longformTracks[id] ??
        library.entries
            .where((e) => e.song.id == id)
            .map((e) => e.song)
            .firstOrNull ??
        personal.playlists
            .expand((p) => p.tracks)
            .where((s) => s.id == id)
            .firstOrNull;
  }

  MusicCategory? categoryById(String id) {
    for (final category in categories) {
      if (category.id == id) return category;
    }
    return null;
  }

  String categoryName(String id) => categoryById(id)?.name ?? 'Uncategorized';

  List<({String id, String name})> get musicProviders => [
    for (final provider in _musicProviders)
      (id: provider.id, name: provider.displayName),
  ];

  MusicProvider? _providerById(String id) {
    for (final provider in _musicProviders) {
      if (provider.id == id) return provider;
    }
    return null;
  }

  bool hasProvider(String id) => _providerById(id) != null;

  Future<void> loadDiscoveryHome() async {
    final request = ++_providerRequest;
    providerLoading = true;
    providerError = null;
    notifyListeners();
    final result = await discovery.browse();
    if (request != _providerRequest) return;
    providerSongs = result.songs;
    library.rememberSongs(result.songs);
    providerError = result.songs.isEmpty && result.unavailable.isNotEmpty
        ? 'Online music could not load. Pull down to retry.'
        : null;
    providerLoading = false;
    notifyListeners();
  }

  String providerNameFor(String id) =>
      _providerById(id)?.displayName ?? 'Online music';

  String get providerName => providerNameFor(activeProviderId);

  String songSource(Song song) {
    if (song.isPrivate) return 'Private library';
    if (song.isLocal) return 'On this device';
    if (song.isLongform) {
      return song.contentType == 'podcast' ? 'Podcast' : 'Audiobook';
    }
    if (!song.isProvider) return categoryName(song.categoryId);
    return [
      song.artist,
      providerNameFor(song.providerId),
    ].where((part) => part.isNotEmpty).join(' · ');
  }

  void selectProvider(String providerId) {
    if (activeProviderId == providerId || !hasProvider(providerId)) return;
    _providerRequest++;
    activeProviderId = providerId;
    providerQuery = '';
    providerSongs = const [];
    providerError = null;
    providerLoading = false;
    notifyListeners();
  }

  Future<void> loadProviderHome(String providerId) async {
    final provider = _providerById(providerId);
    if (provider == null) return;
    final request = ++_providerRequest;
    activeProviderId = providerId;
    providerQuery = '';
    providerSongs = const [];
    providerError = null;
    providerLoading = true;
    notifyListeners();
    try {
      final results = await provider.loadFeatured();
      if (request != _providerRequest) return;
      providerSongs = results;
      library.rememberSongs(results);
    } catch (_) {
      if (request != _providerRequest) return;
      providerSongs = const [];
      providerError =
          'Could not load ${provider.displayName}. Check your connection.';
    } finally {
      if (request == _providerRequest) {
        providerLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> searchProvider(String query, {String? providerId}) async {
    final targetId = providerId ?? activeProviderId;
    final provider = _providerById(targetId);
    if (provider == null) return;
    if (activeProviderId != targetId) {
      activeProviderId = targetId;
      providerSongs = const [];
    }
    final value = query.trim();
    final request = ++_providerRequest;
    providerQuery = value;
    providerError = null;
    if (value.isEmpty) {
      providerSongs = const [];
      providerLoading = false;
      notifyListeners();
      return;
    }
    providerLoading = true;
    notifyListeners();
    try {
      final results = await provider.searchSongs(value);
      if (request != _providerRequest) return;
      providerSongs = results;
      library.rememberSongs(results);
    } catch (_) {
      if (request != _providerRequest) return;
      providerSongs = const [];
      providerError =
          'Could not search ${provider.displayName}. Check your connection.';
    } finally {
      if (request == _providerRequest) {
        providerLoading = false;
        notifyListeners();
      }
    }
  }

  void clearProviderSearch() {
    _providerRequest++;
    providerQuery = '';
    providerSongs = const [];
    providerError = null;
    providerLoading = false;
    notifyListeners();
  }

  Future<List<Song>> fetchProviderFeatured(
    String providerId, {
    int limit = 20,
    int page = 1,
  }) async {
    final provider = _providerById(providerId);
    if (provider == null) return const [];
    try {
      return await provider.loadFeatured(limit: limit, page: page);
    } catch (_) {
      return const [];
    }
  }

  Future<List<Song>> fetchProviderQuery(
    String providerId,
    String query, {
    int limit = 20,
    int page = 1,
  }) async {
    final provider = _providerById(providerId);
    if (provider == null) return const [];
    try {
      return await provider.searchSongs(query, limit: limit, page: page);
    } catch (_) {
      return const [];
    }
  }

  List<Song> songsIn(String? categoryId) => categoryId == null
      ? songs
      : songs.where((song) => song.categoryId == categoryId).toList();

  bool ownsSong(Song song) => uid != null && song.ownerUid == uid;
  bool ownsCategory(MusicCategory category) =>
      uid != null && category.ownerUid == uid;
  bool isLiked(Song song) => liked.contains(song.id);
  bool isDownloaded(SavedMedia item) => offlinePaths.containsKey(item.id);
  bool isSongDownloaded(Song song) =>
      offlineSongs[song.id] != null &&
      File(offlineSongs[song.id]!).existsSync();
  List<Song> get downloadedSongs {
    final found = <String, Song>{
      for (final s in [
        ...songs,
        ...personal.offlineTracks.values,
        ...library.entries.map((e) => e.song),
      ])
        s.id: s,
    };
    return found.values
        .where(
          (s) =>
              offlineSongs.containsKey(s.id) &&
              File(offlineSongs[s.id]!).existsSync(),
        )
        .toList();
  }

  /// The downloaded file for a song when it is still on this device,
  /// otherwise its streaming URL.
  String playableUrl(Song song) {
    final offline = offlineSongs[song.id];
    if (offline != null && !kIsWeb && File(offline).existsSync()) {
      return Uri.file(offline).toString();
    }
    return song.url;
  }

  Future<String> resolvedPlayableUrl(
    Song song, {
    bool downloading = false,
  }) async {
    if (song.isPrivate) {
      final item = savedMedia
          .where((m) => '$privateSongPrefix${m.id}' == song.id)
          .firstOrNull;
      if (item == null ||
          (song.ownerUid.isNotEmpty && song.ownerUid != _accountUid)) {
        throw StateError('This private file belongs to another account.');
      }
      final resolved = await privateSong(item);
      if (resolved == null) {
        throw StateError('The private file is unavailable.');
      }
      return resolved.url;
    }
    final local = playableUrl(song);
    if (!song.isProvider ||
        local.startsWith('file:') ||
        (!downloading && local.isNotEmpty)) {
      return local;
    }
    var qualityKey = downloading ? 'downloadQuality' : 'wifiQuality';
    if (!downloading) {
      try {
        final network = await Connectivity().checkConnectivity();
        if (!network.contains(ConnectivityResult.wifi) &&
            !network.contains(ConnectivityResult.ethernet)) {
          qualityKey = 'mobileQuality';
        }
      } catch (_) {}
    }
    final provider = _providerById(song.providerId);
    if (provider == null) {
      throw FormatException('Unknown music provider: ${song.providerId}');
    }
    if (provider is JioSaavnProvider) {
      provider.quality = personal.settings.quality(qualityKey).kbps;
    }
    if (provider is YouTubeMusicProvider) {
      provider.preferLowBitrate =
          personal.settings.quality(
            downloading ? 'downloadQuality' : 'wifiQuality',
          ) ==
          MusicQuality.low;
    }
    return provider.resolveStreamUrl(
      downloading ? song.copyWith(url: '') : song,
    );
  }

  Map<String, String> playbackHeadersFor(Song song) =>
      _providerById(song.providerId)?.playbackHeaders(song) ?? const {};

  Map<String, String>? audioHeadersFor(Song song, String url) {
    final scheme = Uri.tryParse(url)?.scheme;
    if (scheme != 'https' && scheme != 'http') return null;
    final headers = playbackHeadersFor(song);
    return headers.isEmpty ? null : headers;
  }

  @override
  void notifyListeners() {
    super.notifyListeners();
    _showUploadProgress();
    _scheduleWidgetUpdate();
  }

  // ── Widgets and notifications ────────────────────────────────────────────

  static const _uploadNotificationId = 1001;

  MediaItem _mediaItem(Song song, {Duration? duration}) {
    final category = song.isPrivate ? 'Private library' : songSource(song);
    return MediaItem(
      id: song.id,
      title: song.title,
      artist: song.artist.isEmpty ? category : song.artist,
      album: category,
      duration:
          duration ??
          (song.durationMs > 0
              ? Duration(milliseconds: song.durationMs)
              : null),
      artUri: song.artworkUrl.isEmpty ? null : Uri.tryParse(song.artworkUrl),
    );
  }

  /// Hands the latest songs and playback state to the home screen widgets,
  /// at most once a second and only when something they show changed.
  void _scheduleWidgetUpdate() {
    if (phone == null || (_widgetTimer?.isActive ?? false)) return;
    _widgetTimer = Timer(const Duration(seconds: 1), () {
      Map<String, Object> row(Song song) => {
        'id': song.id,
        'title': song.title,
        'subtitle': song.isPrivate
            ? 'Private library'
            : categoryName(song.categoryId),
      };
      final song = current;
      final index = song == null
          ? -1
          : queue.indexWhere((item) => item.id == song.id);
      // The Big player shows what plays next; shuffle makes it unknown.
      final upNext = index < 0 || queue.length < 2 || shuffle
          ? null
          : queue[(index + 1) % queue.length].title;
      final data = jsonEncode({
        'latest': [for (final item in songs.take(3)) row(item)],
        'recent': [for (final item in recentSongs.take(3)) row(item)],
        'liked': [for (final item in likedSongs.take(3)) row(item)],
        'now': song == null
            ? null
            : {...row(song), 'playing': playing, 'next': ?upNext},
      });
      if (data == _widgetData) return;
      _widgetData = data;
      unawaited(phone?.updateWidgets(data));
    });
  }

  void _showUploadProgress() {
    if (phone == null || !_drainingUploads || uploads.isEmpty) return;
    final now = DateTime.now();
    if (now.difference(_uploadNotifiedAt) < const Duration(seconds: 1)) return;
    _uploadNotifiedAt = now;
    unawaited(
      phone?.showProgress(
        _uploadNotificationId,
        title:
            'Uploading ${math.min(uploadsFinished + 1, uploads.length)} of ${uploads.length}',
        text: categoryName(uploads.first.categoryId),
        percent: (uploadFraction * 100).round(),
      ),
    );
  }

  /// Sums up a finished batch in a notification and tells the other phones
  /// about the new uploads.
  void _finishUploads() {
    if (uploads.isEmpty) return;
    final category = categoryName(uploads.first.categoryId);
    if ((uploadsPaused || uploadsWaiting) && uploading) {
      unawaited(
        phone?.showDone(
          _uploadNotificationId,
          title: uploadsWaiting
              ? 'Uploads waiting for connection'
              : 'Uploads paused',
          text:
              uploadWaitMessage ??
              '$uploadsFinished of ${uploads.length} done · $category',
        ),
      );
      return;
    }
    final done = [
      for (final item in uploads)
        if (item.status == UploadStatus.done) item,
    ];
    final failed = uploadsFailed;
    final cancelled = uploadsCancelled;
    final title = switch ((done.length, failed)) {
      _ when cancelled > 0 && done.isEmpty => 'Uploads cancelled',
      _ when cancelled > 0 => '${done.length} uploaded, the rest cancelled',
      (0, 0) => 'Already in nexMusic',
      (1, 0) => 'Upload finished',
      (final ok, 0) => '$ok uploads finished',
      (final ok, final bad) => '$ok uploaded, $bad failed',
    };
    unawaited(
      phone?.showDone(
        _uploadNotificationId,
        title: title,
        text: done.length == 1 && failed == 0
            ? '${done.first.title} · $category'
            : category,
      ),
    );
    // A retried batch only reports the files that were not reported yet.
    final fresh = [
      for (final item in done)
        if (_reportedUploads.add(item)) item.title,
    ];
    if (fresh.isNotEmpty) {
      unawaited(phone?.report(uploadActivity(fresh, category)));
    }
  }

  // ── Account ──────────────────────────────────────────────────────────────

  Future<void> signInWithGoogle() async {
    final auth = _auth;
    if (auth == null) return;
    loading = true;
    notice = null;
    notifyListeners();
    try {
      if (kIsWeb) {
        await auth.signInWithRedirect(GoogleAuthProvider());
        return;
      }
      final googleUser = await GoogleSignIn.instance.authenticate();
      final credential = GoogleAuthProvider.credential(
        idToken: googleUser.authentication.idToken,
      );
      await auth.signInWithCredential(credential);
    } on GoogleSignInException catch (error) {
      notice = _googleSignInMessage(error);
    } on FirebaseAuthException catch (error) {
      notice = _googleLoginMessage(error);
    } catch (error) {
      notice = 'Google sign-in failed: $error';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    // The phone's push registration can only be removed while signed in.
    await phone?.disablePush();
    await playback.stop();
    unawaited(phone?.setSessionActive(false));
    _stopCatalog();
    if (_auth?.currentUser != null) {
      if (!kIsWeb) await GoogleSignIn.instance.signOut();
      await _auth!.signOut();
    }
    signedIn = false;
    guestMode = false;
    await _switchAccount('guest');
    current = null;
    queue = const [];
    if (!uploading) uploads = const [];
    mediaFolders = const [MediaFolder(id: 'local-imports', name: 'My Imports')];
    savedMedia = const [];
    notifyListeners();
  }

  // ── Playback ─────────────────────────────────────────────────────────────

  /// Plays an audio [song]. Videos open in their own player screen instead.
  Future<void> play(
    Song song, {
    List<Song>? from,
    Duration? initialPosition,
    MusicRandomScope? randomScope,
  }) async {
    if (song.isVideo) return;
    if (isStreamingLink(song.url)) {
      announce(
        'Streaming links are not supported. Choose a plain audio or video file.',
      );
      return;
    }
    if (song.url.startsWith('device:') && !song.isPrivate) {
      announce(
        'This file is on another device. Import it on this phone to play.',
      );
      return;
    }
    if (personal.settings.downloadedOnly &&
        !song.isLocal &&
        !isSongDownloaded(song)) {
      announce(
        'Downloaded-only mode is on. Download this track or turn the mode off.',
      );
      return;
    }
    _randomScope =
        randomScope ??
        (from == null && current?.id == song.id ? _randomScope : null);
    await playback.play(
      song,
      from: from,
      initialPosition:
          initialPosition ??
          (song.isLongform
              ? Duration(milliseconds: personal.resumePositions[song.id] ?? 0)
              : Duration.zero),
    );
  }

  Future<void> togglePlay() => playback.toggle();
  Future<void> pauseAudio() => playback.pause();
  Future<void> seek(Duration value) => playback.seek(value);
  Future<void> next() => playback.next();

  // Recommendations and radio from both music providers.

  /// Recommendations from both music catalogues, using the same seed track.
  Future<List<Song>> fetchRadioForSong(Song song, {int limit = 25}) =>
      discovery.radio(song, limit: limit);

  /// Plays [song] and loads recommendations from both providers into the queue.
  Future<void> startRadio(Song song) async {
    await play(song);
    try {
      final radioTracks = await fetchRadioForSong(song, limit: 30);
      final filtered = radioTracks.where((t) => t.id != song.id).toList();
      if (filtered.isNotEmpty && current?.id == song.id) {
        playback.queue.replace([song, ...filtered], song);
        await playback.queueChanged();
      }
    } catch (e) {
      debugPrint('startRadio error: $e');
    }
  }

  /// Returns songs similar to the user's last played stream track.
  Future<({String title, String artist, Song seedSong, List<Song> songs})?>
  fetchSimilarToLastPlayed({int limit = 20}) async {
    final seed = (current != null && current!.isProvider)
        ? current!
        : (_recentStreamSongs.isNotEmpty ? _recentStreamSongs.first : null);

    if (seed == null) return null;

    final radio = await fetchRadioForSong(seed, limit: limit);
    final filtered = rankForListener(
      radio.where((s) => s.id != seed.id).toList(),
    );
    if (filtered.isEmpty) return null;

    return (
      title: seed.title,
      artist: seed.artist.isNotEmpty ? seed.artist : 'Your taste',
      seedSong: seed,
      songs: filtered,
    );
  }

  /// Builds a personalized Quick Picks list based on recent stream tracks,
  /// falling back to a mix of both providers' featured tracks.
  Future<List<Song>> fetchQuickPicks({int limit = 20}) async {
    if (_recentStreamSongs.isNotEmpty) {
      final sample = _recentStreamSongs.take(3).toList();
      final futures = sample.map((s) => fetchRadioForSong(s, limit: 8));
      final candidateLists = await Future.wait(futures);
      final combined = mergeMusicResults(candidateLists, limit: limit);
      if (combined.isNotEmpty) return rankForListener(combined);
    }
    return rankForListener(
      (await discovery.browse(limit: limit)).songs,
    ).take(limit).toList();
  }

  List<Song> rankForListener(List<Song> tracks) => rankDiscovery(
    tracks,
    accepts: personal.accepts,
    recent: recentSongs.map((s) => s.id).toSet(),
    language: personal.settings.language,
    feedback: Map<String, int>.from(personal.stats()['feedback'] as Map),
  );

  Future<void> previous() => playback.previous();

  void toggleLike(Song song) {
    if (!liked.add(song.id)) liked.remove(song.id);
    unawaited(
      _prefs.setStringList(_accountKey('likedSongIds'), liked.toList()),
    );
    library.setSongLiked(song, liked.contains(song.id));
    personal.recordLike(song, liked.contains(song.id));
    notifyListeners();
  }

  List<Song> librarySongs(MediaCollection collection) {
    library.rememberSongs([
      ...songs,
      ..._recentStreamSongs,
      ...providerSongs,
      ...personal.localTracks.values,
      ...personal.offlineTracks.values,
    ]);
    return library.collection(collection).map((item) => item.song).toList();
  }

  void recordVideoPlay(Song song) {
    library.recordSongPlay(song);
    personal.recordPlay(song);
  }

  void toggleShuffle() {
    playback.queue.setShuffle(!playback.queue.shuffled);
    unawaited(playback.queueChanged());
  }

  Future<void> toggleRepeat() async {
    final modes = MusicRepeat.values;
    await playback.setRepeat(
      modes[(playback.queue.repeat.index + 1) % modes.length],
    );
  }

  void setDarkMode(bool value) {
    darkMode = value;
    _prefs.setBool('darkMode', value);
    notifyListeners();
  }

  void setBrowserPillText(int slot, String value) {
    if (slot == 1) {
      browserPillOne = value;
      _prefs.setString('browserPillOne', value);
    } else if (slot == 2) {
      browserPillTwo = value;
      _prefs.setString('browserPillTwo', value);
    }
  }

  /// Turns activity notifications on or off for this phone.
  Future<void> setPushEnabled(bool value) async {
    pushEnabled = value;
    unawaited(_prefs.setBool('pushEnabled', value));
    notifyListeners();
    await (value ? phone?.enablePush() : phone?.disablePush());
  }

  // ── Shared catalogue ─────────────────────────────────────────────────────

  Future<void> _startCatalog() async {
    if (_firestore == null || _catalogSubs.isNotEmpty || _catalogStarting) {
      return;
    }
    _catalogStarting = true;
    try {
      await _loadCatalogCache();
    } finally {
      _catalogStarting = false;
    }
    if (_auth?.currentUser == null) return;
    _listenToCatalog();
  }

  void _listenToCatalog() {
    final firestore = _firestore;
    if (firestore == null || _catalogSubs.isNotEmpty) return;
    // Only songs changed since the last sync are read. A two-minute overlap
    // covers writes that commit slightly out of order.
    final since = math.max(0, _catalogSyncedAt - 120000);
    _catalogSubs
      ..add(
        firestore.collection('categories').snapshots().listen((snapshot) {
          categories = snapshot.docs.map((doc) {
            final row = doc.data();
            return MusicCategory(
              id: doc.id,
              name: row['name'] as String? ?? 'Untitled',
              ownerUid: row['ownerUid'] as String? ?? '',
            );
          }).toList()..sort(_byName);
          notifyListeners();
        }, onError: _onCatalogError),
      )
      ..add(
        firestore
            .collection('songs')
            .where(
              'updatedAt',
              isGreaterThan: Timestamp.fromMillisecondsSinceEpoch(since),
            )
            .orderBy('updatedAt')
            .snapshots()
            .listen(_applySongChanges, onError: _onCatalogError),
      );
  }

  void _applySongChanges(QuerySnapshot<Map<String, dynamic>> snapshot) {
    if (snapshot.docChanges.isEmpty && catalogLoaded) return;
    final byId = {for (final song in songs) song.id: song};
    for (final change in snapshot.docChanges) {
      final doc = change.doc;
      final row = doc.data();
      if (change.type == DocumentChangeType.removed || row == null) {
        // Songs are soft-deleted, so this only happens when a document is
        // removed by hand in the Firebase console.
        byId.remove(doc.id);
        _dropOfflineSong(doc.id);
        continue;
      }
      final updatedAt = row['updatedAt'];
      if (updatedAt is Timestamp) {
        _catalogSyncedAt = math.max(
          _catalogSyncedAt,
          updatedAt.millisecondsSinceEpoch,
        );
      }
      if (row['deleted'] == true) {
        byId.remove(doc.id);
        _dropOfflineSong(doc.id);
      } else {
        byId[doc.id] = _songFromRow(doc.id, row);
      }
    }
    songs = byId.values.toList()..sort(_newestFirst);
    catalogLoaded = true;
    notifyListeners();
    _scheduleCatalogSave();
  }

  void _stopCatalog() {
    for (final subscription in _catalogSubs) {
      subscription.cancel();
    }
    _catalogSubs.clear();
    if (_catalogSaveTimer?.isActive ?? false) {
      _catalogSaveTimer!.cancel();
      unawaited(_saveCatalogCache());
    }
    categories = const [];
    songs = const [];
    _catalogSyncedAt = 0;
    catalogLoaded = _firestore == null;
  }

  /// Re-subscribes to the catalogue, e.g. after a network or rules error.
  Future<void> refreshCatalog() async {
    if (uid == null) return;
    for (final subscription in _catalogSubs) {
      await subscription.cancel();
    }
    _catalogSubs.clear();
    _listenToCatalog();
  }

  void _onCatalogError(Object error) {
    catalogLoaded = true;
    notice = error is FirebaseException
        ? _firebaseMessage(error, operation: 'Library load')
        : 'Could not load the library: $error';
    notifyListeners();
  }

  Future<File?> _catalogCacheFile() async {
    if (kIsWeb) return null;
    final directory = await getApplicationSupportDirectory();
    return File(path.join(directory.path, 'catalog_cache_v1.json'));
  }

  Future<void> _loadCatalogCache() async {
    try {
      final file = await _catalogCacheFile();
      if (file == null || !await file.exists()) return;
      final data = jsonDecode(await file.readAsString());
      if (data is! Map<String, dynamic>) return;
      final rows = data['songs'];
      songs = [
        if (rows is List)
          for (final row in rows)
            if (row is Map<String, dynamic>) Song.fromJson(row),
      ].whereType<Song>().toList()..sort(_newestFirst);
      _catalogSyncedAt = (data['syncedAt'] as num?)?.toInt() ?? 0;
      if (songs.isNotEmpty) catalogLoaded = true;
      notifyListeners();
    } catch (_) {
      // A damaged cache only costs one full re-sync.
      songs = const [];
      _catalogSyncedAt = 0;
    }
  }

  void _scheduleCatalogSave() {
    _catalogSaveTimer?.cancel();
    _catalogSaveTimer = Timer(
      const Duration(seconds: 2),
      () => unawaited(_saveCatalogCache()),
    );
  }

  Future<void> _saveCatalogCache() async {
    // Capture the state before any await so a sign-out cannot empty it.
    final payload = jsonEncode({
      'syncedAt': _catalogSyncedAt,
      'songs': [for (final song in songs) song.toJson()],
    });
    try {
      final file = await _catalogCacheFile();
      if (file == null) return;
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(payload, flush: true);
      await temporary.rename(file.path);
    } catch (error) {
      debugPrint('Catalogue cache save failed: $error');
    }
  }

  Future<MusicCategory?> createCategory(String name) async {
    final cleanName = name.trim();
    if (!_validCategoryName(cleanName)) {
      notifyListeners();
      return null;
    }
    for (final category in categories) {
      if (category.name.toLowerCase() == cleanName.toLowerCase()) {
        return category;
      }
    }
    final firestore = _firestore;
    final userId = uid;
    if (firestore == null || userId == null) {
      notice = 'Sign in with Google to create categories.';
      notifyListeners();
      return null;
    }
    try {
      final reference = await firestore.collection('categories').add({
        'name': cleanName,
        'ownerUid': userId,
        'createdAt': FieldValue.serverTimestamp(),
      });
      final category = MusicCategory(
        id: reference.id,
        name: cleanName,
        ownerUid: userId,
      );
      if (!categories.any((item) => item.id == category.id)) {
        categories = [...categories, category]..sort(_byName);
      }
      unawaited(phone?.report(categoryCreateActivity(cleanName)));
      notifyListeners();
      return category;
    } on FirebaseException catch (error) {
      notice = _firebaseMessage(error, operation: 'Category save');
      notifyListeners();
      return null;
    }
  }

  Future<bool> renameCategory(MusicCategory category, String name) async {
    final cleanName = name.trim();
    final firestore = _firestore;
    if (firestore == null || !ownsCategory(category)) {
      notice = 'Only the person who created this category can rename it.';
      notifyListeners();
      return false;
    }
    if (!_validCategoryName(cleanName)) {
      notifyListeners();
      return false;
    }
    if (categories.any(
      (item) =>
          item.id != category.id &&
          item.name.toLowerCase() == cleanName.toLowerCase(),
    )) {
      notice = 'A category named "$cleanName" already exists.';
      notifyListeners();
      return false;
    }
    try {
      await firestore.collection('categories').doc(category.id).update({
        'name': cleanName,
      });
      categories = [
        for (final item in categories)
          item.id == category.id
              ? MusicCategory(
                  id: item.id,
                  name: cleanName,
                  ownerUid: item.ownerUid,
                )
              : item,
      ]..sort(_byName);
      unawaited(
        phone?.report(categoryRenameActivity(category.name, cleanName)),
      );
      notice = 'Category renamed.';
      notifyListeners();
      return true;
    } on FirebaseException catch (error) {
      notice = _firebaseMessage(error, operation: 'Category rename');
      notifyListeners();
      return false;
    }
  }

  /// Deletes a category. One that still has songs is only deleted with
  /// [withSongs], which removes its songs for everyone first: the Firestore
  /// rules accept song changes only while their category exists. Only the
  /// category's creator can delete it.
  Future<bool> deleteCategory(
    MusicCategory category, {
    bool withSongs = false,
  }) async {
    final firestore = _firestore;
    if (firestore == null || !ownsCategory(category)) {
      notice = 'Only the person who created this category can delete it.';
      notifyListeners();
      return false;
    }
    final inCategory = songs
        .where((song) => song.categoryId == category.id)
        .toList();
    if (inCategory.isNotEmpty && !withSongs) {
      notice =
          'This category still has songs. Move them to another category first.';
      notifyListeners();
      return false;
    }
    final removed = <String>{};
    try {
      // Each song write makes the rules look up the category, and a batched
      // write allows 20 such lookups, so songs go 20 per batch, 5 at a time.
      final batches = [
        for (var start = 0; start < inCategory.length; start += 20)
          inCategory.sublist(start, math.min(start + 20, inCategory.length)),
      ];
      for (var i = 0; i < batches.length; i += 5) {
        await Future.wait([
          for (final batch in batches.skip(i).take(5))
            _softDeleteSongs(
              firestore,
              batch,
            ).then((_) => removed.addAll(batch.map((song) => song.id))),
        ]);
      }
      await firestore.collection('categories').doc(category.id).delete();
      categories = categories.where((item) => item.id != category.id).toList();
      await _forgetSongs(removed);
      unawaited(
        phone?.report(
          categoryDeleteActivity(category.name, songs: removed.length),
        ),
      );
      notice = removed.isEmpty
          ? 'Category deleted.'
          : 'Deleted "${category.name}" and its ${removed.length} song${removed.length == 1 ? '' : 's'}.';
      notifyListeners();
      return true;
    } on FirebaseException catch (error) {
      // Songs deleted before the failure stay deleted.
      await _forgetSongs(removed);
      notice = _firebaseMessage(error, operation: 'Category delete');
      notifyListeners();
      return false;
    }
  }

  Future<void> _softDeleteSongs(FirebaseFirestore firestore, List<Song> batch) {
    final writes = firestore.batch();
    for (final song in batch) {
      writes.update(firestore.collection('songs').doc(song.id), {
        'deleted': true,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
    return writes.commit();
  }

  /// Forgets deleted songs on this phone: the list, queue, downloads, likes
  /// and recents. Stops playback when one of them is playing.
  Future<void> _forgetSongs(Set<String> ids) async {
    if (ids.isEmpty) return;
    if (ids.contains(playback.queue.currentId)) {
      await playback.stop();
      playback.queue.currentId = null;
    }
    library.removeSongs(ids);
    for (final id in ids) {
      playback.queue.remove(id);
      personal.offlineTracks.remove(id);
    }
    personal.changed();
    await playback.queueChanged();
    songs = songs.where((item) => !ids.contains(item.id)).toList();
    queue = queue.where((item) => !ids.contains(item.id)).toList();
    for (final id in ids) {
      _dropOfflineSong(id);
    }
    if (liked.any(ids.contains)) {
      liked.removeAll(ids);
      unawaited(
        _prefs.setStringList(_accountKey('likedSongIds'), liked.toList()),
      );
    }
    final recentCount = recentSongIds.length;
    recentSongIds.removeWhere(ids.contains);
    if (recentSongIds.length != recentCount) {
      unawaited(
        _prefs.setStringList(_accountKey('recentSongIds'), recentSongIds),
      );
    }
    if (ids.contains(current?.id)) {
      await _audio.stop();
      await _audioHandler?.stop();
      unawaited(phone?.setSessionActive(false));
      current = null;
    }
    _scheduleCatalogSave();
  }

  // ── Public uploads ───────────────────────────────────────────────────────

  /// Uploads [items] into [categoryId], a few files at a time. Progress is
  /// reported through [uploads].
  Future<void> startUploads(
    List<UploadItem> items, {
    required String categoryId,
  }) async {
    if (items.isEmpty) return;
    if (categoryById(categoryId) == null) {
      notice = 'Choose a category.';
      notifyListeners();
      return;
    }
    if (_auth?.currentUser == null || _firestore == null) {
      notice = 'Sign in with Google to upload.';
      notifyListeners();
      return;
    }
    if (!uploadsConfigured) {
      notice =
          'Uploads are not set up yet. Add the Cloudinary cloud name and upload preset.';
      notifyListeners();
      return;
    }
    if (uploading) {
      notice = 'Wait for the current uploads to finish.';
      notifyListeners();
      return;
    }
    // The last batch's files are cleaned up, except ones picked again now.
    final keep = {
      for (final item in items) ...[item.path, ?item.original?.path],
    };
    for (final item in uploads) {
      discardPicked(item, keep: keep);
    }
    for (final item in items) {
      item
        ..categoryId = categoryId
        ..status = UploadStatus.queued
        ..progress = 0
        ..error = null;
    }
    _reportedUploads.clear();
    _uploadRecovery.clear(reset: true);
    uploadsPaused = false;
    uploads = List.of(items);
    notifyListeners();
    await _drainUploads();
  }

  Future<void> retryFailedUploads() async {
    for (final item in uploads) {
      if (item.status == UploadStatus.failed) {
        item
          ..status = UploadStatus.queued
          ..progress = 0
          ..error = null;
      }
    }
    notifyListeners();
    if (uploadsWaiting) {
      await resumeUploads();
      return;
    }
    await _drainUploads();
  }

  /// Pauses the batch: nothing new starts, and files in flight are pulled back
  /// to wait in the queue.
  void pauseUploads() {
    if (!uploading || uploadsPaused) return;
    uploadsPaused = true;
    _uploadRecovery.clear();
    _pullBack(UploadStatus.queued);
    notifyListeners();
  }

  Future<void> resumeUploads() async {
    if (_uploadsDisposed || (!uploadsPaused && !uploadsWaiting)) return;
    uploadsPaused = false;
    _uploadRecovery.clear();
    for (final item in uploads) {
      if (item.status == UploadStatus.queued) item.error = null;
    }
    notifyListeners();
    await _drainUploads();
  }

  /// Stops the batch for good. Songs already in nexMusic stay; the rest are
  /// not sent.
  void cancelUploads() {
    if (!uploading) return;
    uploadsPaused = false;
    _uploadRecovery.clear(reset: true);
    for (final item in uploads) {
      if (item.status == UploadStatus.queued) {
        item.status = UploadStatus.cancelled;
        discardPicked(item);
      }
    }
    _pullBack(UploadStatus.cancelled);
    notifyListeners();
    // A paused batch has no worker left to sum it up.
    if (!_drainingUploads) _finishUploads();
  }

  /// Pulls back every file still on its way to Cloudinary. A file that has
  /// already reached Cloudinary is left to finish, so no upload is stranded
  /// without its catalogue entry.
  void _pullBack(UploadStatus to) {
    for (final item in uploads) {
      if (item.status != UploadStatus.uploading || item.uploadedUrl != null) {
        continue;
      }
      _stopTo[item] = to;
      _uploadClients[item]?.close(force: true);
    }
  }

  /// Forgets a finished batch and removes the picker's copies from the cache.
  void clearUploads() {
    if (uploading) return;
    for (final item in uploads) {
      discardPicked(item);
    }
    uploads = const [];
    notifyListeners();
  }

  Future<void> _drainUploads() async {
    if (_uploadsDisposed || uploadsPaused || uploadsWaiting) return;
    if (_drainingUploads) {
      _uploadDrainAgain = true;
      return;
    }
    _drainingUploads = true;
    Future<void> worker() async {
      while (true) {
        if (_uploadsDisposed || uploadsPaused || uploadsWaiting) return;
        UploadItem? next;
        for (final item in uploads) {
          if (item.status == UploadStatus.queued) {
            next = item;
            break;
          }
        }
        if (next == null) return;
        await _uploadOne(next);
      }
    }

    try {
      // The network is the bottleneck, but per-file request overhead makes
      // strictly one-at-a-time uploads slow for large batches.
      await Future.wait([for (var i = 0; i < 3; i++) worker()]);
    } finally {
      // The upload screen and home banner show the summary inside the app;
      // the notification covers a phone that is in a pocket.
      _drainingUploads = false;
      if (!_uploadsDisposed) {
        notifyListeners();
        _finishUploads();
        if (_uploadDrainAgain && !uploadsPaused && !uploadsWaiting) {
          _uploadDrainAgain = false;
          scheduleMicrotask(() => unawaited(_drainUploads()));
        }
      }
    }
  }

  Future<void> _uploadOne(UploadItem item) async {
    item
      ..status = UploadStatus.uploading
      ..progress = 0
      ..error = null;
    notifyListeners();
    final user = _auth?.currentUser;
    final firestore = _firestore;
    try {
      if (user == null || firestore == null) {
        throw const _UploadFailure('Sign in with Google again.');
      }
      final kind = uploadKindFor(item.name);
      if (kind == null) {
        throw const _UploadFailure('This file type is not supported.');
      }
      if (item.sizeBytes >= maxUploadBytes) {
        throw const _UploadFailure('Files over 100 MB cannot be uploaded.');
      }
      var title = item.title.trim();
      if (title.isEmpty) title = path.basenameWithoutExtension(item.name);
      if (title.length > 160) title = title.substring(0, 160);

      // The same title and size already in the catalogue is a duplicate.
      final duplicate = songs.any(
        (song) =>
            song.sizeBytes == item.sizeBytes &&
            song.title.toLowerCase() == title.toLowerCase(),
      );
      if (duplicate && item.uploadedUrl == null) {
        item.status = UploadStatus.skipped;
        discardPicked(item);
        return;
      }

      if (item.uploadedUrl == null) {
        // Files from the native chooser are content URIs. Each is copied into
        // the cache only while it uploads, so a big batch never fills the
        // phone and Android cannot evict files still waiting in the queue.
        final chosen = item.path.startsWith('content://');
        final phone = this.phone;
        if (chosen && phone == null) {
          throw const _UploadFailure('Pick this file again to upload it.');
        }
        final localPath = chosen
            ? await phone!.copyToCache(item.path, item.name)
            : item.path;
        try {
          if (!item.artistRead && item.artist.isEmpty && phone != null) {
            item.artistRead = true;
            try {
              item.artist = await phone
                  .readMediaArtist(localPath)
                  .timeout(const Duration(seconds: 5));
            } catch (_) {}
          }
          final result = await _sendToCloudinary(
            item,
            localPath,
          ).timeout(const Duration(minutes: 20));
          item
            ..uploadedUrl = result.url
            ..uploadedPublicId = result.publicId
            ..durationMs = result.durationMs;
        } finally {
          if (chosen) discardTemporaryCopy(localPath);
        }
      }

      final reference = firestore.collection('songs').doc(item.catalogId);
      item.catalogId = reference.id;
      final ownerName = _ownerName(user);
      final url = playbackUrlFor(item.uploadedUrl!);
      Map<String, dynamic>? existingRow;
      await firestore
          .runTransaction((transaction) async {
            final existing = (await transaction.get(reference)).data();
            existingRow = existing;
            if (existing != null) {
              if (existing['ownerUid'] != user.uid ||
                  existing['publicId'] != item.uploadedPublicId) {
                throw const _UploadFailure(
                  'The saved upload does not match this file. Pick it again.',
                );
              }
              return;
            }
            transaction.set(reference, {
              'title': title,
              'kind': kind,
              'categoryId': item.categoryId,
              'url': url,
              'publicId': item.uploadedPublicId,
              'sizeBytes': item.sizeBytes,
              'durationMs': item.durationMs,
              'ownerUid': user.uid,
              'ownerName': ownerName,
              'createdAt': FieldValue.serverTimestamp(),
              'updatedAt': FieldValue.serverTimestamp(),
              'deleted': false,
            });
          })
          .timeout(const Duration(seconds: 45));
      if (_uploadsDisposed) return;
      if (existingRow?['deleted'] == true) {
        item
          ..status = UploadStatus.skipped
          ..progress = 1;
        discardPicked(item);
        return;
      }
      _upsertSong(
        existingRow != null
            ? _songFromRow(reference.id, existingRow!)
            : Song(
                id: reference.id,
                title: title,
                kind: kind,
                url: url,
                categoryId: item.categoryId,
                ownerUid: user.uid,
                ownerName: ownerName,
                publicId: item.uploadedPublicId,
                sizeBytes: item.sizeBytes,
                durationMs: item.durationMs,
                createdAt: DateTime.now(),
              ),
      );
      item
        ..title = existingRow?['title'] as String? ?? title
        ..status = UploadStatus.done
        ..progress = 1;
      if (item.artist.isNotEmpty) {
        setSongArtist(
          songs.firstWhere((song) => song.id == reference.id),
          item.artist,
        );
      }
      _uploadRecovery.clear(reset: true);
      discardPicked(item);
    } catch (error) {
      if (!_stopTo.containsKey(item) && !_uploadsDisposed) {
        final temporary =
            isTemporaryTransferError(error) ||
            (error is FirebaseException &&
                {
                  'unavailable',
                  'deadline-exceeded',
                  'resource-exhausted',
                  'aborted',
                }.contains(error.code));
        if (temporary) {
          if (!uploadsPaused) {
            _uploadRecovery.wait(
              error is FirebaseException
                  ? TimeoutException('The catalogue could not be reached.')
                  : error,
            );
          }
          item
            ..status = UploadStatus.queued
            ..progress = 0
            ..error = uploadsPaused
                ? 'Uploads paused'
                : _uploadRecovery.message;
          _uploadClients[item]?.close(force: true);
          _pullBack(UploadStatus.queued);
        } else {
          item
            ..status = UploadStatus.failed
            ..error = switch (error) {
              _UploadFailure() => error.message,
              FirebaseException() => _firebaseMessage(error, operation: 'Save'),
              PathNotFoundException() =>
                'The file is no longer on the phone. Pick it again.',
              FileSystemException() =>
                'Could not read the file: ${error.message}',
              FormatException() =>
                'Unexpected reply from Cloudinary. Try again.',
              _ => transferErrorMessage(error),
            };
        }
      }
    } finally {
      final stop = _stopTo.remove(item);
      if (stop != null && item.uploadedUrl == null) {
        item
          ..status = stop
          ..progress = 0
          ..error = null;
        if (stop == UploadStatus.cancelled) discardPicked(item);
      }
      if (!_uploadsDisposed) notifyListeners();
    }
  }

  /// Sends one file to Cloudinary as an unsigned upload with byte progress.
  Future<({String url, String publicId, int durationMs})> _sendToCloudinary(
    UploadItem item,
    String filePath,
  ) async {
    final file = File(filePath);
    final length = await file.length();
    if (length == 0) throw const _UploadFailure('The file is empty.');
    final boundary = '----nexmusic${DateTime.now().microsecondsSinceEpoch}';
    String field(String name, String value) =>
        '--$boundary\r\nContent-Disposition: form-data; name="$name"\r\n\r\n$value\r\n';
    // The original name can hold characters that break a header; Cloudinary
    // assigns its own id anyway.
    final extension = path.extension(item.name).toLowerCase();
    final head = utf8.encode(
      '${field('upload_preset', cloudinaryUploadPreset)}'
      '${field('folder', 'nexmusic')}'
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="file"; filename="upload$extension"\r\n'
      'Content-Type: application/octet-stream\r\n\r\n',
    );
    final tail = utf8.encode('\r\n--$boundary--\r\n');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    // Paused or cancelled before the file started on its way.
    if (_stopTo.containsKey(item)) {
      client.close(force: true);
      throw const _UploadFailure('Stopped.');
    }
    _uploadClients[item] = client;
    try {
      final request = await client.postUrl(
        Uri.https(
          'api.cloudinary.com',
          '/v1_1/$cloudinaryCloudName/video/upload',
        ),
      );
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'multipart/form-data; boundary=$boundary',
      );
      request.contentLength = head.length + length + tail.length;
      request.add(head);
      var sent = 0;
      var reported = 0.0;
      await request.addStream(
        file.openRead().map((chunk) {
          if (_uploadsDisposed) throw const _UploadFailure('Stopped.');
          sent += chunk.length;
          final fraction = sent / length;
          // Chunks arrive many times a second; repaint per 1% of progress.
          if (fraction - reported >= 0.01 || sent == length) {
            reported = fraction;
            item.progress = fraction;
            notifyListeners();
          }
          return chunk;
        }),
      );
      request.add(tail);
      final response = await request.close().timeout(
        const Duration(seconds: 60),
      );
      final body = await response
          .transform(utf8.decoder)
          .timeout(const Duration(seconds: 60))
          .join();
      if (TransferHttpException(response.statusCode).retryable) {
        throw TransferHttpException(response.statusCode);
      }
      final decoded = jsonDecode(body);
      final json = decoded is Map<String, dynamic>
          ? decoded
          : const <String, dynamic>{};
      if (response.statusCode != HttpStatus.ok) {
        final error = json['error'];
        final message = error is Map
            ? '${error['message']}'
            : 'HTTP ${response.statusCode}';
        throw _UploadFailure('Cloudinary: $message');
      }
      final url = json['secure_url'];
      final publicId = json['public_id'];
      if (url is! String || publicId is! String) {
        throw const _UploadFailure(
          'Cloudinary did not return a link for the file.',
        );
      }
      final seconds = json['duration'];
      return (
        url: url,
        publicId: publicId,
        durationMs: seconds is num ? (seconds * 1000).round() : 0,
      );
    } finally {
      if (identical(_uploadClients[item], client)) _uploadClients.remove(item);
      client.close(force: true);
    }
  }

  void _upsertSong(Song song) {
    songs = [
      song,
      for (final item in songs)
        if (item.id != song.id) item,
    ]..sort(_newestFirst);
    _scheduleCatalogSave();
  }

  /// Deletes an upload's copies in the cache and gives back read access to
  /// files chosen with the native chooser. Paths in [keep] are left alone.
  void discardPicked(UploadItem item, {Set<String> keep = const {}}) {
    for (final filePath in [item.path, ?item.original?.path]) {
      if (keep.contains(filePath)) continue;
      if (filePath.startsWith('content://')) {
        unawaited(phone?.releaseUri(filePath));
      } else {
        discardTemporaryCopy(filePath);
      }
    }
  }

  /// Renames an upload or moves it to another category. Anyone signed in can
  /// edit any upload.
  Future<bool> updateSong(
    Song song, {
    required String title,
    required String categoryId,
    String? artist,
  }) async {
    final cleanTitle = title.trim();
    final firestore = _firestore;
    if (firestore == null || uid == null) {
      notice = 'Sign in with Google to edit songs.';
      notifyListeners();
      return false;
    }
    if (!_validTitle(cleanTitle)) {
      notifyListeners();
      return false;
    }
    if (categoryById(categoryId) == null) {
      notice = 'Choose a category.';
      notifyListeners();
      return false;
    }
    try {
      await firestore.collection('songs').doc(song.id).update({
        'title': cleanTitle,
        'categoryId': categoryId,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      songs = [
        for (final item in songs)
          item.id == song.id
              ? item.copyWith(title: cleanTitle, categoryId: categoryId)
              : item,
      ];
      if (current?.id == song.id) {
        current = current!.copyWith(title: cleanTitle, categoryId: categoryId);
      }
      _scheduleCatalogSave();
      if (artist != null) setSongArtist(song, artist);
      final activity = songEditActivity(
        oldTitle: song.title,
        newTitle: cleanTitle,
        movedTo: categoryId == song.categoryId
            ? null
            : categoryName(categoryId),
      );
      if (activity != null) unawaited(phone?.report(activity));
      notice = 'Song updated.';
      notifyListeners();
      return true;
    } on FirebaseException catch (error) {
      notice = _firebaseMessage(error, operation: 'Update');
      notifyListeners();
      return false;
    }
  }

  /// Removes an upload from everyone's list. Anyone signed in can delete any
  /// upload. The file stays on Cloudinary because deleting it needs the
  /// account's API secret.
  Future<bool> deleteSong(Song song) async {
    final firestore = _firestore;
    if (firestore == null || uid == null) {
      notice = 'Sign in with Google to delete songs.';
      notifyListeners();
      return false;
    }
    try {
      // A soft delete lets other phones sync the removal cheaply.
      await firestore.collection('songs').doc(song.id).update({
        'deleted': true,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      await _forgetSongs({song.id});
      unawaited(phone?.report(songDeleteActivity(song.title)));
      notice = 'Song removed for everyone.';
      notifyListeners();
      return true;
    } on FirebaseException catch (error) {
      notice = _firebaseMessage(error, operation: 'Delete');
      notifyListeners();
      return false;
    }
  }

  // ── Offline songs ────────────────────────────────────────────────────────

  /// Saves a public song inside the app so it plays without internet.
  Future<void> downloadSong(Song song) async {
    try {
      await downloads.enqueue([song]);
      final job = downloads.jobs[song.id];
      announce(
        downloads.waitingMessage ??
            (downloads.paused
                ? 'Downloads paused. Resume from Downloads.'
                : job == null
                ? 'This song is already on your device.'
                : 'Download queued. View progress in Downloads.'),
      );
    } catch (e) {
      announce('$e');
    }
  }

  Future<void> removeSongDownload(Song song) => downloads.remove(song.id);

  void _dropOfflineSong(String id) {
    final localPath = offlineSongs.remove(id);
    if (localPath == null) return;
    unawaited(_saveOfflineSongs());
    if (!kIsWeb) {
      unawaited(
        File(localPath).delete().then<void>((_) {}, onError: (Object _) {}),
      );
    }
  }

  Future<void> _saveOfflineSongs() =>
      _prefs.setString(_accountKey('offlineSongs'), jsonEncode(offlineSongs));

  // ── Private library ──────────────────────────────────────────────────────

  CollectionReference<Map<String, dynamic>> _userCollection(String name) {
    final uid = _auth!.currentUser!.uid;
    return _firestore!.collection('users').doc(uid).collection(name);
  }

  Future<void> loadCloudLibrary() async {
    if (_auth?.currentUser == null || _firestore == null) return;
    try {
      final folderSnapshot = await _userCollection(
        'folders',
      ).orderBy('createdAt').get();
      final mediaSnapshot = await _userCollection(
        'media',
      ).orderBy('createdAt', descending: true).get();
      if (folderSnapshot.docs.isEmpty) {
        final reference = await _userCollection('folders').add({
          'name': 'My Imports',
          'createdAt': FieldValue.serverTimestamp(),
        });
        mediaFolders = [MediaFolder(id: reference.id, name: 'My Imports')];
      } else {
        mediaFolders = folderSnapshot.docs
            .map(
              (doc) => MediaFolder(
                id: doc.id,
                name: doc.data()['name'] as String? ?? 'Untitled',
              ),
            )
            .toList();
      }
      savedMedia = mediaSnapshot.docs.map((doc) {
        final row = doc.data();
        return SavedMedia(
          id: doc.id,
          title: row['title'] as String? ?? 'Untitled',
          kind: row['kind'] as String? ?? 'link',
          folderId: row['folderId'] as String? ?? '',
          sourceUrl: row['sourceUrl'] as String?,
          storagePath: row['storagePath'] as String?,
        );
      }).toList();
      notifyListeners();
    } catch (error) {
      notice = 'Could not load your private library: $error';
      notifyListeners();
    }
  }

  /// Resolves a private library file into a playable [Song], preferring the
  /// offline copy on this device.
  Future<Song?> privateSong(SavedMedia item) async {
    if (item.kind == 'link') return null;
    String? url;
    final offline = offlinePaths[item.id];
    if (!kIsWeb && offline != null && await File(offline).exists()) {
      url = Uri.file(offline).toString();
    } else if (item.storagePath != null && _storage != null) {
      try {
        url = await _storage.ref(item.storagePath!).getDownloadURL();
      } on FirebaseException catch (error) {
        notice = _firebaseMessage(error, operation: 'Playback');
        notifyListeners();
        return null;
      }
    }
    if (url == null) {
      notice = 'This item has no playable file.';
      notifyListeners();
      return null;
    }
    return Song(
      id: '$privateSongPrefix${item.id}',
      title: item.title,
      kind: item.kind,
      url: url,
      ownerName: 'Private library',
      ownerUid: _accountUid,
      storagePath: item.storagePath,
    );
  }

  Future<MediaFolder?> createMediaFolder(String name) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) return null;
    if (cleanName.length > 80) {
      notice = 'Folder names can be at most 80 characters.';
      notifyListeners();
      return null;
    }
    if (_auth?.currentUser == null || _firestore == null) {
      final folder = MediaFolder(
        id: 'local-${DateTime.now().millisecondsSinceEpoch}',
        name: cleanName,
      );
      mediaFolders = [...mediaFolders, folder];
      notifyListeners();
      return folder;
    }
    try {
      final reference = await _userCollection(
        'folders',
      ).add({'name': cleanName, 'createdAt': FieldValue.serverTimestamp()});
      final folder = MediaFolder(id: reference.id, name: cleanName);
      mediaFolders = [...mediaFolders, folder];
      notifyListeners();
      return folder;
    } on FirebaseException catch (error) {
      notice = _firebaseMessage(error, operation: 'Folder save');
      notifyListeners();
      return null;
    }
  }

  Future<bool> updateMediaFolder(MediaFolder folder, String name) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) return false;
    if (cleanName.length > 80) {
      notice = 'Folder names can be at most 80 characters.';
      notifyListeners();
      return false;
    }
    try {
      if (_auth?.currentUser != null && _firestore != null) {
        await _userCollection(
          'folders',
        ).doc(folder.id).update({'name': cleanName});
      }
      mediaFolders = mediaFolders
          .map(
            (item) =>
                item.id == folder.id ? item.copyWith(name: cleanName) : item,
          )
          .toList();
      notice = 'Folder renamed.';
      notifyListeners();
      return true;
    } on FirebaseException catch (error) {
      notice = _firebaseMessage(error, operation: 'Folder update');
      notifyListeners();
      return false;
    }
  }

  Future<bool> deleteMediaFolder(MediaFolder folder) async {
    if (mediaFolders.length <= 1) {
      notice = 'Keep at least one folder.';
      notifyListeners();
      return false;
    }
    if (savedMedia.any((item) => item.folderId == folder.id)) {
      notice = 'This folder is not empty. Move or delete its items first.';
      notifyListeners();
      return false;
    }
    try {
      if (_auth?.currentUser != null && _firestore != null) {
        await _userCollection('folders').doc(folder.id).delete();
      }
      mediaFolders = mediaFolders
          .where((item) => item.id != folder.id)
          .toList();
      notice = 'Folder deleted.';
      notifyListeners();
      return true;
    } on FirebaseException catch (error) {
      notice = _firebaseMessage(error, operation: 'Folder delete');
      notifyListeners();
      return false;
    }
  }

  Future<bool> saveSharedLink({
    required String url,
    required String title,
    required String folderId,
  }) async {
    final cleanUrl = url.trim();
    final cleanTitle = title.trim().isEmpty ? 'Shared video' : title.trim();
    final cleanFolderId = folderId.trim();
    final uri = Uri.tryParse(cleanUrl);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
      notice = 'Enter a valid web link.';
      notifyListeners();
      return false;
    }
    if (!_validMediaInput(title: cleanTitle, folderId: cleanFolderId)) {
      notifyListeners();
      return false;
    }
    if (_auth?.currentUser == null || _firestore == null) {
      notice =
          'Link saved on this device only. Sign in with Google to keep it.';
      savedMedia = [
        SavedMedia(
          id: 'local-${DateTime.now().millisecondsSinceEpoch}',
          title: cleanTitle,
          kind: 'link',
          folderId: cleanFolderId,
          sourceUrl: cleanUrl,
        ),
        ...savedMedia,
      ];
      notifyListeners();
      return true;
    }
    try {
      final reference = await _userCollection('media').add({
        'title': cleanTitle,
        'kind': 'link',
        'folderId': cleanFolderId,
        'sourceUrl': cleanUrl,
        'createdAt': FieldValue.serverTimestamp(),
      });
      savedMedia = [
        SavedMedia(
          id: reference.id,
          title: cleanTitle,
          kind: 'link',
          folderId: cleanFolderId,
          sourceUrl: cleanUrl,
        ),
        ...savedMedia,
      ];
      notice = 'Link saved.';
      notifyListeners();
      return true;
    } catch (error) {
      notice = 'Could not save the link: $error';
      notifyListeners();
      return false;
    }
  }

  Future<bool> updateMedia(
    SavedMedia item, {
    required String title,
    required String folderId,
    String? sourceUrl,
  }) async {
    final cleanTitle = title.trim();
    final cleanFolderId = folderId.trim();
    final cleanUrl = sourceUrl?.trim();
    if (!_validMediaInput(title: cleanTitle, folderId: cleanFolderId)) {
      notifyListeners();
      return false;
    }
    if (item.kind == 'link') {
      final uri = Uri.tryParse(cleanUrl ?? '');
      if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
        notice = 'Enter a valid web link.';
        notifyListeners();
        return false;
      }
    }

    try {
      if (_auth?.currentUser != null && _firestore != null) {
        final update = <String, dynamic>{
          'title': cleanTitle,
          'folderId': cleanFolderId,
        };
        if (item.kind == 'link') update['sourceUrl'] = cleanUrl;
        await _userCollection('media').doc(item.id).update(update);
      }
      savedMedia = savedMedia
          .map(
            (media) => media.id == item.id
                ? media.copyWith(
                    title: cleanTitle,
                    folderId: cleanFolderId,
                    sourceUrl: item.kind == 'link' ? cleanUrl : null,
                  )
                : media,
          )
          .toList();
      notice = 'Item updated.';
      notifyListeners();
      return true;
    } on FirebaseException catch (error) {
      notice = _firebaseMessage(error, operation: 'Update');
      notifyListeners();
      return false;
    } catch (error) {
      notice = 'Update failed: $error';
      notifyListeners();
      return false;
    }
  }

  Future<bool> uploadOwnedAudio({
    required String filePath,
    required String title,
    required String folderId,
  }) async {
    return uploadOwnedMedia(
      filePath: filePath,
      title: title,
      folderId: folderId,
      kind: 'audio',
      contentType: _contentTypeFor(filePath, kind: 'audio'),
    );
  }

  Future<bool> uploadOwnedMedia({
    required String filePath,
    required String title,
    required String folderId,
    required String kind,
    required String contentType,
  }) async {
    final cleanTitle = title.trim().isEmpty ? 'Imported media' : title.trim();
    final cleanFolderId = folderId.trim();
    if (!_validMediaInput(title: cleanTitle, folderId: cleanFolderId)) {
      notifyListeners();
      return false;
    }
    if (kind != 'audio' && kind != 'video') {
      notice = 'Unsupported media type.';
      notifyListeners();
      return false;
    }
    if (_auth?.currentUser == null || _firestore == null || _storage == null) {
      notice = 'Sign in with Google to upload.';
      notifyListeners();
      return false;
    }
    try {
      final userId = _auth!.currentUser!.uid;
      final (sourceFile, _) = await _readableFile(filePath);
      final sourceExtension = path.extension(sourceFile.path).toLowerCase();
      final extension = sourceExtension.isEmpty
          ? (kind == 'video' ? '.mp4' : '.m4a')
          : sourceExtension;
      final objectPath =
          'users/$userId/$cleanFolderId/${DateTime.now().millisecondsSinceEpoch}$extension';
      final uploadedReference = _storage.ref(objectPath);
      await uploadedReference.putFile(
        sourceFile,
        SettableMetadata(
          contentType: _contentTypeFor(
            sourceFile.path,
            kind: kind,
            fallback: contentType,
          ),
          customMetadata: {'ownerUid': userId, 'folderId': cleanFolderId},
        ),
      );

      DocumentReference<Map<String, dynamic>> reference;
      try {
        reference = await _userCollection('media').add({
          'title': cleanTitle,
          'kind': kind,
          'folderId': cleanFolderId,
          'storagePath': objectPath,
          'createdAt': FieldValue.serverTimestamp(),
        });
      } catch (error, stackTrace) {
        // Do not leave an inaccessible, billed Storage object behind when the
        // matching Firestore metadata write is rejected or interrupted.
        try {
          await uploadedReference.delete();
        } catch (_) {}
        Error.throwWithStackTrace(error, stackTrace);
      }
      savedMedia = [
        SavedMedia(
          id: reference.id,
          title: cleanTitle,
          kind: kind,
          folderId: cleanFolderId,
          storagePath: objectPath,
        ),
        ...savedMedia,
      ];
      notice =
          '${kind == 'video' ? 'Video' : 'Audio'} saved to your private library.';
      notifyListeners();
      return true;
    } on FirebaseException catch (error) {
      notice = _firebaseMessage(error, operation: 'Upload');
      notifyListeners();
      return false;
    } on FileSystemException catch (error) {
      notice = 'Upload failed: ${error.message}';
      notifyListeners();
      return false;
    } catch (error) {
      notice = 'Upload failed. Please try again. ($error)';
      notifyListeners();
      return false;
    }
  }

  Future<bool> downloadMedia(SavedMedia item) async {
    if (kIsWeb) {
      notice = 'Offline downloads work in the Android and iOS apps only.';
      notifyListeners();
      return false;
    }
    if (_storage == null || item.storagePath == null) {
      notice = 'This item has no cloud file to download.';
      notifyListeners();
      return false;
    }
    try {
      final documents = await getApplicationDocumentsDirectory();
      final directory = Directory(path.join(documents.path, 'offline_media'));
      await directory.create(recursive: true);
      final cloudExtension = path.extension(item.storagePath!);
      final extension = cloudExtension.isEmpty
          ? (item.kind == 'video' ? '.mp4' : '.m4a')
          : cloudExtension;
      final safeTitle = item.title.replaceAll(RegExp(r'[^a-zA-Z0-9 _-]'), '');
      final localFile = File(
        path.join(
          directory.path,
          '${safeTitle.isEmpty ? 'media' : safeTitle}-${item.id}$extension',
        ),
      );
      await _storage.ref(item.storagePath!).writeToFile(localFile);
      offlinePaths[item.id] = localFile.path;
      await _saveOfflinePaths();
      notice = 'Saved for offline listening.';
      notifyListeners();
      return true;
    } catch (error) {
      notice = 'Download failed: $error';
      notifyListeners();
      return false;
    }
  }

  Future<void> removeDownload(SavedMedia item) async {
    final localPath = offlinePaths.remove(item.id);
    if (!kIsWeb && localPath != null) {
      final file = File(localPath);
      if (await file.exists()) await file.delete();
    }
    await _saveOfflinePaths();
    notice = 'Offline copy removed.';
    notifyListeners();
  }

  Future<bool> deleteMedia(SavedMedia item) async {
    try {
      if (_auth?.currentUser != null && _firestore != null) {
        if (item.storagePath != null && _storage != null) {
          try {
            await _storage.ref(item.storagePath!).delete();
          } on FirebaseException catch (error) {
            if (error.code != 'object-not-found') rethrow;
          }
        }
        await _userCollection('media').doc(item.id).delete();
      }
      await removeDownload(item);
      savedMedia = savedMedia.where((media) => media.id != item.id).toList();
      notice = 'Item deleted.';
      notifyListeners();
      return true;
    } catch (error) {
      notice = 'Delete failed: $error';
      notifyListeners();
      return false;
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  Future<void> _saveOfflinePaths() =>
      _prefs.setString(_accountKey('offlineMedia'), jsonEncode(offlinePaths));

  bool _validTitle(String title) {
    if (title.isEmpty) {
      notice = 'Title cannot be empty.';
      return false;
    }
    if (title.length > 160) {
      notice = 'Titles can be at most 160 characters.';
      return false;
    }
    return true;
  }

  bool _validCategoryName(String name) {
    if (name.isEmpty) {
      notice = 'Category name cannot be empty.';
      return false;
    }
    if (name.length > 40) {
      notice = 'Category names can be at most 40 characters.';
      return false;
    }
    return true;
  }

  bool _validMediaInput({required String title, required String folderId}) {
    if (!_validTitle(title)) return false;
    if (folderId.isEmpty) {
      notice = 'Choose a folder.';
      return false;
    }
    return true;
  }

  void clearNotice() {
    if (notice == null) return;
    notice = null;
    notifyListeners();
  }

  /// Shows [message] like any other notice, for work that carries on after
  /// the screen that started it has closed.
  void announce(String message) {
    notice = message;
    notifyListeners();
  }

  static int _byName(MusicCategory a, MusicCategory b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());

  /// Newest uploads first; a song whose server time is still pending sorts
  /// to the top.
  static int _newestFirst(Song a, Song b) {
    const pending = 8640000000000000;
    return (b.createdAt?.millisecondsSinceEpoch ?? pending).compareTo(
      a.createdAt?.millisecondsSinceEpoch ?? pending,
    );
  }

  static Song _songFromRow(String id, Map<String, dynamic> row) {
    return Song(
      id: id,
      title: row['title'] as String? ?? 'Untitled',
      kind: row['kind'] == 'video' ? 'video' : 'audio',
      url: row['url'] as String? ?? '',
      categoryId: row['categoryId'] as String? ?? '',
      ownerUid: row['ownerUid'] as String? ?? '',
      ownerName: row['ownerName'] as String? ?? '',
      artist: row['artist'] as String? ?? '',
      publicId: row['publicId'] as String?,
      sizeBytes: (row['sizeBytes'] as num?)?.toInt() ?? 0,
      durationMs: (row['durationMs'] as num?)?.toInt() ?? 0,
      createdAt: (row['createdAt'] as Timestamp?)?.toDate(),
    );
  }

  static String _ownerName(User user) {
    final name = user.displayName?.trim();
    final fallback = user.email?.split('@').first ?? 'Listener';
    final value = name == null || name.isEmpty ? fallback : name;
    return value.length > 80 ? value.substring(0, 80) : value;
  }

  /// Checks that [filePath] points to a non-empty file under the upload limit.
  static Future<(File, int)> _readableFile(String filePath) async {
    final file = filePath.startsWith('file:')
        ? File.fromUri(Uri.parse(filePath))
        : File(filePath);
    if (!await file.exists()) {
      throw const FileSystemException('Selected media file is unavailable.');
    }
    final size = await file.length();
    if (size == 0) {
      throw const FileSystemException('Selected media file is empty.');
    }
    if (size >= maxUploadBytes) {
      throw const FileSystemException(
        'File is larger than the 100 MB upload limit.',
      );
    }
    return (file, size);
  }

  static String _contentTypeFor(
    String filePath, {
    required String kind,
    String? fallback,
  }) {
    return switch (path.extension(filePath).toLowerCase()) {
      '.mp3' => 'audio/mpeg',
      '.aac' => 'audio/aac',
      '.m4a' => 'audio/mp4',
      '.wav' => 'audio/wav',
      '.flac' => 'audio/flac',
      '.ogg' => 'audio/ogg',
      '.mov' => 'video/quicktime',
      '.webm' => 'video/webm',
      '.mp4' => kind == 'video' ? 'video/mp4' : 'audio/mp4',
      _ => fallback ?? (kind == 'video' ? 'video/mp4' : 'audio/mp4'),
    };
  }

  static String _firebaseMessage(
    FirebaseException error, {
    required String operation,
  }) {
    return switch (error.code) {
      'object-not-found' || 'bucket-not-found' =>
        '$operation failed: Firebase Storage bucket is not set up for this project. The project owner must enable Blaze billing and create the default Storage bucket.',
      'unauthorized' || 'permission-denied' =>
        '$operation failed: permission denied. Check that the latest Firestore and Storage rules are deployed.',
      'unauthenticated' =>
        '$operation failed: please sign in with Google again.',
      'quota-exceeded' || 'resource-exhausted' =>
        '$operation failed: Firebase free quota for today is used up. Try again tomorrow.',
      'canceled' => '$operation cancelled.',
      'retry-limit-exceeded' || 'unavailable' =>
        '$operation failed because Firebase is temporarily unreachable. Check the connection and retry.',
      _ => '$operation failed: ${error.message ?? error.code}',
    };
  }

  static String _googleSignInMessage(GoogleSignInException error) {
    final detail = error.description?.trim() ?? '';
    final suffix = detail.isEmpty ? '' : ' ($detail)';
    // Android reports an unregistered signing key either as a configuration
    // error or as a cancelled "[16] Account reauth failed" request.
    if (error.code == GoogleSignInExceptionCode.clientConfigurationError ||
        error.code == GoogleSignInExceptionCode.providerConfigurationError ||
        detail.contains('[16]')) {
      return 'Google sign-in is not set up for this app build. Add its SHA-1 fingerprint in Firebase project settings, then try again.$suffix';
    }
    if (detail.toLowerCase().contains('no credential')) {
      return 'No Google account was found on this phone. Add one in Settings → Accounts, then try again.';
    }
    return switch (error.code) {
      GoogleSignInExceptionCode.canceled =>
        'Google sign-in was cancelled.$suffix',
      GoogleSignInExceptionCode.uiUnavailable =>
        'Could not open the Google account picker. Try again.$suffix',
      _ => 'Google sign-in failed: ${error.code.name}$suffix',
    };
  }

  static String _googleLoginMessage(FirebaseAuthException error) {
    return switch (error.code) {
      'unauthorized-domain' =>
        'Google sign-in blocked: add this domain in Firebase Auth authorized domains. Use localhost for local testing.',
      'operation-not-allowed' =>
        'Google sign-in is turned off. Enable it in Firebase Authentication.',
      'popup-blocked' =>
        'The Google popup was blocked. Allow popups and try again.',
      'popup-closed-by-user' =>
        'The Google sign-in window was closed before finishing.',
      'network-request-failed' =>
        'Google sign-in failed because of a network problem. Check your connection and try again.',
      _ => error.message ?? 'Google sign-in failed (${error.code}).',
    };
  }

  @override
  void dispose() {
    _uploadsDisposed = true;
    _uploadRecovery.dispose();
    unawaited(_uploadNetwork?.cancel());
    for (final client in _uploadClients.values) {
      client.close(force: true);
    }
    _providerRequest++;
    for (final subscription in [..._subs, ..._catalogSubs]) {
      subscription.cancel();
    }
    _catalogSaveTimer?.cancel();
    _widgetTimer?.cancel();
    downloads
      ..removeListener(_downloadStateChanged)
      ..dispose();
    playback
      ..removeListener(_playerChanged)
      ..dispose();
    personal
      ..removeListener(notifyListeners)
      ..dispose();
    social
      ?..removeListener(notifyListeners)
      ..dispose();
    positionListenable.dispose();
    library
      ..removeListener(notifyListeners)
      ..dispose();
    super.dispose();
  }
}

class _UploadFailure implements Exception {
  const _UploadFailure(this.message);
  final String message;
}

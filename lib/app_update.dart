import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/digests/sha256.dart';

import 'music_transfer.dart';
import 'phone_services.dart';

/// Fallback installed version of nexMusic (matches pubspec.yaml).
const String currentAppVersion = '0.4.12+8035';

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.tagName,
    required this.versionName,
    required this.buildNumber,
    required this.downloadUrl,
    required this.releaseNotes,
    required this.sizeBytes,
    this.sha256 = '',
    this.publishedAt,
  });

  final String tagName;
  final String versionName;
  final int buildNumber;
  final String downloadUrl;
  final String releaseNotes;
  final int sizeBytes;

  /// Lowercase hex SHA-256 of the APK, when GitHub reports one.
  final String sha256;
  final DateTime? publishedAt;

  String get displayVersion => 'v$versionName (build $buildNumber)';

  String get formattedSize {
    if (sizeBytes <= 0) return '';
    final mb = sizeBytes / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }
}

class AppUpdateService {
  AppUpdateService([this._client]);

  final HttpClient? _client;
  static const _repoOwner = 'Vis-halG';
  static const _repoName = 'nexMusic';
  static const _releaseApiUrl =
      'https://api.github.com/repos/$_repoOwner/$_repoName/releases/latest';

  /// Parses a version string like '0.2.0+4002' or 'v0.2.1+4003' into (versionName, buildNumber).
  static ({String name, int build}) parseVersion(String versionString) {
    var raw = versionString.trim();
    if (raw.startsWith('v') || raw.startsWith('V')) {
      raw = raw.substring(1);
    }
    final parts = raw.split('+');
    final name = parts[0];
    final build = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    return (name: name, build: build);
  }

  /// Returns true if [remoteVersion] is strictly newer than [localVersion].
  static bool isNewerVersion(String remoteVersion, String localVersion) {
    final remote = parseVersion(remoteVersion);
    final local = parseVersion(localVersion);

    // If build numbers exist and differ, build number is the authoritative indicator.
    if (remote.build > 0 && local.build > 0) {
      return remote.build > local.build;
    }

    // Otherwise compare semver parts.
    final rSegments = remote.name
        .split('.')
        .map((s) => int.tryParse(s) ?? 0)
        .toList();
    final lSegments = local.name
        .split('.')
        .map((s) => int.tryParse(s) ?? 0)
        .toList();

    for (var i = 0; i < 3; i++) {
      final r = i < rSegments.length ? rSegments[i] : 0;
      final l = i < lSegments.length ? lSegments[i] : 0;
      if (r > l) return true;
      if (r < l) return false;
    }

    return remote.build > local.build;
  }

  /// Checks GitHub Releases for a newer version than [currentVersion].
  /// When [currentVersion] is null, queries [phone] for the real installed APK
  /// version via Android PackageManager, falling back to [currentAppVersion].
  /// If [force] is true, checks and returns the latest release regardless of version.
  Future<AppUpdateInfo?> checkForUpdate({
    String? currentVersion,
    PhoneServices? phone,
    bool force = false,
  }) async {
    String? effectiveVersion;
    if (phone != null) {
      try {
        final native = await phone.getAppVersion();
        if (native != null && native.version.isNotEmpty) {
          effectiveVersion = native.version;
        }
      } catch (e) {
        debugPrint('Failed to get native version: $e');
      }
    }
    effectiveVersion ??= currentVersion ?? currentAppVersion;

    final client = _client ?? HttpClient();
    final shouldClose = _client == null;
    try {
      final uri = Uri.parse(_releaseApiUrl);
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 15));
      request.headers.set(HttpHeaders.userAgentHeader, 'nexMusic-AppUpdate');
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );

      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != 200) {
        debugPrint('GitHub update check returned HTTP ${response.statusCode}');
        return null;
      }

      final body = await utf8.decoder.bind(response).join();
      final data = jsonDecode(body);
      if (data is! Map<String, dynamic>) return null;

      final tagName = data['tag_name'] as String? ?? '';
      if (tagName.isEmpty) return null;

      // Extract version without leading 'v'
      final versionCandidate =
          tagName.startsWith('v') || tagName.startsWith('V')
          ? tagName.substring(1)
          : tagName;

      if (!force && !isNewerVersion(versionCandidate, effectiveVersion)) {
        debugPrint(
          'App is up to date: local=$effectiveVersion, remote=$versionCandidate',
        );
        return null;
      }

      // Find matching APK asset for current device ABI (or universal fallback)
      final assets = data['assets'] as List? ?? [];
      String? matchedUrl;
      int matchedSize = 0;
      String matchedDigest = '';
      String? universalUrl;
      int universalSize = 0;
      String universalDigest = '';

      String targetAbi = '';
      try {
        if (Platform.isAndroid) {
          final abi = Abi.current();
          if (abi == Abi.androidArm) targetAbi = 'armeabi-v7a';
          if (abi == Abi.androidArm64) targetAbi = 'arm64-v8a';
          if (abi == Abi.androidX64) targetAbi = 'x86_64';
        }
      } catch (_) {}

      for (final asset in assets) {
        if (asset is Map<String, dynamic>) {
          final name = (asset['name'] as String? ?? '').toLowerCase();
          if (name.endsWith('.apk')) {
            final url = asset['browser_download_url'] as String?;
            final size = (asset['size'] as num?)?.toInt() ?? 0;
            final digest = asset['digest'] as String? ?? '';
            final sha256 = digest.startsWith('sha256:')
                ? digest.substring(7).toLowerCase()
                : '';
            if (url != null && url.isNotEmpty) {
              if (targetAbi.isNotEmpty && name.contains(targetAbi)) {
                matchedUrl = url;
                matchedSize = size;
                matchedDigest = sha256;
                break; // Exact device ABI match found!
              } else if (name.contains('universal') ||
                  // Recognize APKs from earlier releases as well.
                  name == 'nexapp.apk' ||
                  name == 'nexmusic.apk' ||
                  name == 'app-release.apk') {
                universalUrl = url;
                universalSize = size;
                universalDigest = sha256;
              } else if (universalUrl == null) {
                universalUrl = url;
                universalSize = size;
                universalDigest = sha256;
              }
            }
          }
        }
      }

      final apkUrl = matchedUrl ?? universalUrl;
      final apkSize = matchedUrl != null ? matchedSize : universalSize;

      if (apkUrl == null || apkUrl.isEmpty) {
        debugPrint('Release $tagName found but no APK asset attached');
        return null;
      }

      final parsed = parseVersion(versionCandidate);
      final notes = data['body'] as String? ?? 'Bug fixes and improvements.';
      final published = DateTime.tryParse(
        data['published_at'] as String? ?? '',
      );

      return AppUpdateInfo(
        tagName: tagName,
        versionName: parsed.name,
        buildNumber: parsed.build,
        downloadUrl: apkUrl,
        releaseNotes: notes,
        sizeBytes: apkSize,
        sha256: matchedUrl != null ? matchedDigest : universalDigest,
        publishedAt: published,
      );
    } catch (error) {
      debugPrint('Update check failed: $error');
      return null;
    } finally {
      if (shouldClose) client.close(force: true);
    }
  }

  /// Triggers the Android package installer for the downloaded APK file.
  Future<bool> installUpdate(File apkFile, PhoneServices? phone) async {
    if (!kIsWeb && Platform.isAndroid && phone != null) {
      return phone.installApk(apkFile.path);
    }
    return false;
  }
}

enum UpdateDownloadState { downloading, waiting, verifying, ready, failed }

/// Downloads an update APK while the app stays usable. A dropped connection,
/// a switch between Wi-Fi and mobile data or an app restart resumes from the
/// bytes already saved, and temporary failures are retried until it finishes.
class UpdateDownload extends ChangeNotifier {
  UpdateDownload._(
    this.info,
    this._folder,
    this._phone,
    this._openClient,
    this._networkChanges,
    this._retryDelay,
    this._network,
  ) : total = info.sizeBytes;

  /// The download the status bar shows, if any.
  static final current = ValueNotifier<UpdateDownload?>(null);

  /// Starts downloading [info], or returns the download of it already running.
  /// The installer opens by itself once the file is ready.
  static Future<UpdateDownload> start(
    AppUpdateInfo info, {
    PhoneServices? phone,
    Directory? folder,
    HttpClient Function()? client,
    Stream<List<ConnectivityResult>>? networkChanges,
    Duration retryDelay = const Duration(seconds: 2),
  }) async {
    final running = current.value;
    if (running != null &&
        running.info.tagName == info.tagName &&
        running.state != UpdateDownloadState.failed) {
      return running;
    }
    running?._stop();
    Set<ConnectivityResult>? network;
    if (networkChanges == null) {
      try {
        network = (await Connectivity().checkConnectivity()).toSet();
      } catch (_) {}
    }
    final download = UpdateDownload._(
      info,
      folder ?? await _defaultFolder(),
      phone,
      client ?? HttpClient.new,
      networkChanges ?? Connectivity().onConnectivityChanged,
      retryDelay,
      network,
    );
    current.value = download;
    download._done = download._run();
    return download;
  }

  /// Whether [info] was being downloaded before, so the app can carry on
  /// without asking again.
  static Future<bool> started(AppUpdateInfo info, {Directory? folder}) async {
    final dir = folder ?? await _defaultFolder();
    return await File(_path(dir, info, 'part')).exists() ||
        await File(_path(dir, info, 'apk')).exists();
  }

  /// Deletes update files of builds up to [installedBuild].
  static Future<void> removeOld(int installedBuild, {Directory? folder}) async {
    try {
      final dir = folder ?? await _defaultFolder();
      if (!await dir.exists()) return;
      await for (final entity in dir.list()) {
        final match = RegExp(
          r'nexMusic_(\d+)\.(part|apk)$',
        ).firstMatch(entity.path);
        final build = int.tryParse(match?.group(1) ?? '');
        if (build != null && build <= installedBuild) await entity.delete();
      }
    } catch (_) {}
  }

  // App files, not the cache, which Android clears when storage runs low.
  static Future<Directory> _defaultFolder() async => Directory(
    '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}updates',
  );

  static String _path(Directory dir, AppUpdateInfo info, String extension) =>
      '${dir.path}${Platform.pathSeparator}nexMusic_${info.buildNumber}.$extension';

  final AppUpdateInfo info;
  final Directory _folder;
  final PhoneServices? _phone;
  final HttpClient Function() _openClient;
  final Stream<List<ConnectivityResult>> _networkChanges;
  final Duration _retryDelay;
  Set<ConnectivityResult>? _network;

  UpdateDownloadState state = UpdateDownloadState.downloading;
  int received = 0;
  int total;

  /// Why the download is waiting or failed.
  String? message;

  Future<void> _done = Future.value();
  bool _stopped = false;
  bool _retryNow = false;
  HttpClient? _client;
  Completer<void>? _wake;
  final _sinceNotice = Stopwatch()..start();

  /// The finished APK.
  File get file => File(_path(_folder, info, 'apk'));
  File get _partial => File(_path(_folder, info, 'part'));

  double? get fraction =>
      total > 0 ? (received / total).clamp(0.0, 1.0).toDouble() : null;

  bool get _offline =>
      _network != null &&
      _network!.every((result) => result == ConnectivityResult.none);

  Future<void> _run() async {
    final network = _networkChanges.listen(_networkChanged);
    var stalled = 0, damaged = 0;
    try {
      await _folder.create(recursive: true);
      while (!_stopped) {
        if (await file.exists()) {
          if (await _intact(file)) break;
          await file.delete();
        }
        final before = received;
        try {
          _set(UpdateDownloadState.downloading);
          await _fetch();
          if (_stopped) return;
          _set(UpdateDownloadState.verifying);
          if (await _intact(_partial)) {
            await _partial.rename(file.path);
            break;
          }
          // The bad piece cannot be found, so the file starts again.
          await _partial.delete();
          received = 0;
          if (++damaged >= 2) {
            _fail('The update file arrived damaged twice. Try again later.');
            return;
          }
        } catch (error) {
          if (_stopped) return;
          if (!isTemporaryTransferError(error)) {
            _fail(transferErrorMessage(error));
            return;
          }
          stalled = received > before ? 0 : stalled + 1;
          message = _offline
              ? 'Waiting for network…'
              : 'Connection lost. Resuming…';
          _set(UpdateDownloadState.waiting);
          await _pause(_retryDelay * (1 << stalled.clamp(0, 4)));
        }
      }
      if (_stopped) return;
      message = null;
      _set(UpdateDownloadState.ready);
      await install();
    } catch (error) {
      if (!_stopped) _fail(transferErrorMessage(error));
    } finally {
      await network.cancel();
    }
  }

  /// Fetches the rest of the file into the partial file.
  Future<void> _fetch() async {
    received = await _partial.exists() ? await _partial.length() : 0;
    if (total > 0 && received > total) {
      await _partial.delete();
      received = 0;
    }
    if (total > 0 && received == total) return;
    final client = _client = _openClient()
      ..connectionTimeout = const Duration(seconds: 20);
    IOSink? sink;
    try {
      // GitHub answers with a fresh signed link each time, so retries never
      // hit an expired one.
      final request = await client
          .getUrl(Uri.parse(info.downloadUrl))
          .timeout(const Duration(seconds: 30));
      request.headers.set(HttpHeaders.userAgentHeader, 'nexMusic-AppUpdate');
      if (received > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$received-');
      }
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final status = response.statusCode;
      if (status != HttpStatus.ok && status != HttpStatus.partialContent) {
        unawaited(response.drain<void>().catchError((Object _) {}));
        if (status == HttpStatus.requestedRangeNotSatisfiable) {
          // The saved part does not fit the file any more.
          await _partial.delete();
          received = 0;
          throw const HttpException('The download restarted.');
        }
        throw TransferHttpException(status, uri: Uri.parse(info.downloadUrl));
      }
      final resumed = status == HttpStatus.partialContent;
      if (!resumed) received = 0;
      final whole = int.tryParse(
        response.headers
                .value(HttpHeaders.contentRangeHeader)
                ?.split('/')
                .last ??
            '',
      );
      final length =
          whole ??
          (response.contentLength >= 0 ? received + response.contentLength : 0);
      if (length > 0) total = length;
      sink = _partial.openWrite(
        mode: resumed ? FileMode.append : FileMode.write,
      );
      notifyListeners();
      // A connection that goes quiet without closing counts as dropped.
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        sink.add(chunk);
        received += chunk.length;
        if (_sinceNotice.elapsedMilliseconds >= 200) {
          _sinceNotice.reset();
          notifyListeners();
        }
      }
      if (total > 0 && received < total) {
        throw const HttpException('The download ended early.');
      }
    } finally {
      await sink?.close();
      client.close(force: true);
      if (identical(_client, client)) _client = null;
    }
  }

  void _networkChanged(List<ConnectivityResult> results) {
    final before = _network, now = results.toSet();
    _network = now;
    if (before == null || setEquals(before, now) || _offline) return;
    // Sockets of the old network often hang instead of failing, so reconnect
    // on the new one straight away.
    _retryNow = true;
    _client?.close(force: true);
    _wakeUp();
  }

  Future<void> _pause(Duration delay) async {
    if (!_retryNow) {
      final wake = _wake = Completer<void>();
      final timer = Timer(delay, _wakeUp);
      await wake.future;
      timer.cancel();
    }
    _retryNow = false;
  }

  void _wakeUp() {
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  Future<bool> _intact(File apk) async {
    final length = await apk.length();
    if (total > 0 && length != total) return false;
    final expected = info.sha256;
    if (expected.isEmpty) return true;
    final path = apk.path;
    return await Isolate.run(() => _sha256Of(path)) == expected;
  }

  /// Opens the Android installer for the finished file, or the release page
  /// in the browser when that is not possible.
  Future<void> install() async {
    if (state != UpdateDownloadState.ready) return;
    final phone = _phone;
    try {
      if (await AppUpdateService().installUpdate(file, phone)) return;
    } catch (_) {}
    await phone?.openUrl(info.downloadUrl);
  }

  /// Stops downloading and deletes the partial file.
  Future<void> cancel() async {
    _stop();
    if (identical(current.value, this)) current.value = null;
    await _done;
    try {
      if (await _partial.exists()) await _partial.delete();
    } catch (_) {}
  }

  /// Hides the status bar. A finished or partial file stays for later.
  void dismiss() {
    _stop();
    if (identical(current.value, this)) current.value = null;
  }

  void _stop() {
    _stopped = true;
    _client?.close(force: true);
    _wakeUp();
  }

  void _set(UpdateDownloadState value) {
    state = value;
    notifyListeners();
  }

  void _fail(String reason) {
    message = reason;
    _set(UpdateDownloadState.failed);
  }
}

/// Lowercase hex SHA-256 of the file at [path], read a megabyte at a time.
String _sha256Of(String path) {
  final digest = SHA256Digest();
  final input = File(path).openSync();
  try {
    final buffer = Uint8List(1 << 20);
    while (true) {
      final count = input.readIntoSync(buffer);
      if (count == 0) break;
      digest.update(buffer, 0, count);
    }
  } finally {
    input.closeSync();
  }
  final out = Uint8List(digest.digestSize);
  digest.doFinal(out, 0);
  return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

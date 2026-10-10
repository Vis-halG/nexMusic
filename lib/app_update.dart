import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'phone_services.dart';

/// Fallback installed version of nexMusic (matches pubspec.yaml).
const String currentAppVersion = '0.4.4+8027';

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.tagName,
    required this.versionName,
    required this.buildNumber,
    required this.downloadUrl,
    required this.releaseNotes,
    required this.sizeBytes,
    this.publishedAt,
  });

  final String tagName;
  final String versionName;
  final int buildNumber;
  final String downloadUrl;
  final String releaseNotes;
  final int sizeBytes;
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
      String? universalUrl;
      int universalSize = 0;

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
            if (url != null && url.isNotEmpty) {
              if (targetAbi.isNotEmpty && name.contains(targetAbi)) {
                matchedUrl = url;
                matchedSize = size;
                break; // Exact device ABI match found!
              } else if (name.contains('universal') ||
                  // Recognize APKs from earlier releases as well.
                  name == 'nexapp.apk' ||
                  name == 'nexmusic.apk' ||
                  name == 'app-release.apk') {
                universalUrl = url;
                universalSize = size;
              } else if (universalUrl == null) {
                universalUrl = url;
                universalSize = size;
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
        publishedAt: published,
      );
    } catch (error) {
      debugPrint('Update check failed: $error');
      return null;
    } finally {
      if (shouldClose) client.close(force: true);
    }
  }

  /// Downloads the APK from [info.downloadUrl] and notifies [onProgress] (0.0 to 1.0).
  Future<File?> downloadApk(
    AppUpdateInfo info, {
    void Function(double fraction)? onProgress,
  }) async {
    final client = _client ?? HttpClient();
    final shouldClose = _client == null;
    try {
      final tempDir = await getTemporaryDirectory();
      final targetFile = File('${tempDir.path}/nexMusic_update.apk');
      if (await targetFile.exists()) {
        await targetFile.delete();
      }

      final request = await client
          .getUrl(Uri.parse(info.downloadUrl))
          .timeout(const Duration(seconds: 20));
      request.headers.set(HttpHeaders.userAgentHeader, 'nexMusic-AppUpdate');
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );

      if (response.statusCode != 200) {
        throw HttpException('Download returned HTTP ${response.statusCode}');
      }

      final totalBytes = response.contentLength > 0
          ? response.contentLength
          : info.sizeBytes;
      var receivedBytes = 0;

      final sink = targetFile.openWrite();
      await for (final chunk in response) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        if (totalBytes > 0 && onProgress != null) {
          onProgress((receivedBytes / totalBytes).clamp(0.0, 1.0));
        }
      }
      await sink.flush();
      await sink.close();

      return targetFile;
    } catch (error) {
      debugPrint('APK download error: $error');
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

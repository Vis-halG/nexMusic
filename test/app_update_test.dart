import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nex_music/app_update.dart';
import 'package:nex_music/phone_services.dart';

const _apkSha256 =
    '571338683d2c71e04d57da40395e83d5e11ba144a70111fb1fccc0dfd2ac5514';

class _Headers extends Fake implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  @override
  int get statusCode => 200;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream<List<int>>.value(
        utf8.encode(
          jsonEncode({
            'tag_name': 'v$currentAppVersion',
            'body': 'Playback fixes',
            'assets': [
              {
                'name': 'nexMusic.apk',
                'browser_download_url': 'https://example.test/nexMusic.apk',
                'size': 21000000,
                'digest': 'sha256:$_apkSha256',
              },
            ],
          }),
        ),
      ).listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request extends Fake implements HttpClientRequest {
  @override
  final headers = _Headers();
  @override
  Future<HttpClientResponse> close() async => _Response();
}

class _Client extends Fake implements HttpClient {
  Uri? requestedUrl;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requestedUrl = url;
    return _Request();
  }
}

class _Phone extends Fake implements PhoneServices {
  _Phone(this.version);

  final String? version;

  @override
  Future<({String versionName, int buildNumber, String version})?>
  getAppVersion() async {
    final installed = version;
    if (installed == null) return null;
    final parsed = AppUpdateService.parseVersion(installed);
    return (
      versionName: parsed.name,
      buildNumber: parsed.build,
      version: installed,
    );
  }
}

void main() {
  final release = AppUpdateService.parseVersion(currentAppVersion);
  final previousVersion = '${release.name}+${release.build - 1}';

  test(
    'latest release selects the universal APK and its integrity digest',
    () async {
      final client = _Client();
      final service = AppUpdateService(client);
      final update = await service.checkForUpdate(
        currentVersion: previousVersion,
      );
      expect(update, isNotNull);
      expect(
        client.requestedUrl.toString(),
        'https://api.github.com/repos/Vis-halG/nexMusic/releases/latest',
      );
      expect(update!.tagName, 'v$currentAppVersion');
      expect(update.versionName, release.name);
      expect(update.buildNumber, release.build);
      expect(update.downloadUrl, 'https://example.test/nexMusic.apk');
      expect(update.sizeBytes, 21000000);
      expect(update.sha256, _apkSha256);
      expect(update.releaseNotes, 'Playback fixes');
    },
  );

  test(
    'older installed APK gets update despite a newer compiled fallback',
    () async {
      final service = AppUpdateService(_Client());
      final phone = _Phone(previousVersion);

      // A hot reload can update Dart's fallback while the installed APK stays old.
      final update = await service.checkForUpdate(phone: phone);
      expect(update?.buildNumber, release.build);
      expect(
        (await service.checkForUpdate(
          phone: phone,
          currentVersion: currentAppVersion,
        ))?.buildNumber,
        release.build,
      );
    },
  );

  test(
    'installed current build suppresses update despite an older fallback',
    () async {
      final service = AppUpdateService(_Client());
      expect(
        await service.checkForUpdate(
          phone: _Phone(currentAppVersion),
          currentVersion: previousVersion,
        ),
        isNull,
      );
      expect(
        await service.checkForUpdate(currentVersion: currentAppVersion),
        isNull,
      );
    },
  );

  test(
    'missing native version uses the supplied version or compiled fallback',
    () async {
      final service = AppUpdateService(_Client());
      expect(
        (await service.checkForUpdate(
          phone: _Phone(null),
          currentVersion: previousVersion,
        ))?.buildNumber,
        release.build,
      );
      expect(await service.checkForUpdate(phone: _Phone(null)), isNull);
    },
  );

  test('compiled update fallback matches the packaged release version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final packagedVersion = RegExp(
      r'^version:\s*(\S+)',
      multiLine: true,
    ).firstMatch(pubspec)?.group(1);
    expect(currentAppVersion, packagedVersion);
    expect(release.build, greaterThan(0));
  });

  test('isNewerVersion logic', () {
    expect(
      AppUpdateService.isNewerVersion('0.2.9+4013', '0.2.9+4013'),
      isFalse,
    );
    expect(AppUpdateService.isNewerVersion('0.2.9+4013', '0.2.9+4011'), isTrue);
    expect(
      AppUpdateService.isNewerVersion('0.2.9+4011', '0.2.9+4013'),
      isFalse,
    );
    expect(AppUpdateService.isNewerVersion('0.3.0', '0.2.9+4013'), isTrue);
  });
}

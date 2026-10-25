import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_music/app_update.dart';
import 'package:pointycastle/digests/sha256.dart';

/// A bare HTTP server, so tests can cut a response off half way.
class _ApkServer {
  _ApkServer(this.body, this.respond);
  final Uint8List body;

  /// Answers request number [attempt], given the range start it asked for.
  final Future<void> Function(Socket socket, int attempt, int? from) respond;
  final ranges = <int?>[];
  late final ServerSocket _server;

  String get url => 'http://127.0.0.1:${_server.port}/nexMusic.apk';

  Future<void> open() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((socket) {
      final head = StringBuffer();
      var answered = false;
      socket.listen((bytes) {
        head.write(latin1.decode(bytes));
        if (answered || !head.toString().contains('\r\n\r\n')) return;
        answered = true;
        final from = int.tryParse(
          RegExp(
                r'range: bytes=(\d+)-',
                caseSensitive: false,
              ).firstMatch(head.toString())?.group(1) ??
              '',
        );
        ranges.add(from);
        unawaited(respond(socket, ranges.length - 1, from));
      }, onError: (Object _) {});
    });
  }

  Future<void> close() => _server.close();
}

/// Sends [body] from [from], optionally stopping after [limit] bytes.
void _send(Socket socket, Uint8List body, int from, {int? limit}) {
  final rest = body.length - from;
  socket.write(
    from == 0
        ? 'HTTP/1.1 200 OK\r\n'
        : 'HTTP/1.1 206 Partial Content\r\n'
              'Content-Range: bytes $from-${body.length - 1}/${body.length}\r\n',
  );
  socket.write('Content-Length: $rest\r\nConnection: close\r\n\r\n');
  socket.add(body.sublist(from, limit == null ? null : from + limit));
}

String _sha256(Uint8List bytes) {
  final out = SHA256Digest().process(bytes);
  return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

AppUpdateInfo _info(_ApkServer server, {bool digest = true}) => AppUpdateInfo(
  tagName: 'v9.9.9+9999',
  versionName: '9.9.9',
  buildNumber: 9999,
  downloadUrl: server.url,
  releaseNotes: '',
  sizeBytes: server.body.length,
  sha256: digest ? _sha256(server.body) : '',
);

Future<void> _settled(UpdateDownload download) async {
  final done = Completer<void>();
  void check() {
    if ((download.state == UpdateDownloadState.ready ||
            download.state == UpdateDownloadState.failed) &&
        !done.isCompleted) {
      done.complete();
    }
  }

  download.addListener(check);
  check();
  await done.future.timeout(const Duration(seconds: 10));
  download.removeListener(check);
}

void main() {
  late Directory folder;
  late StreamController<List<ConnectivityResult>> network;
  final body = Uint8List.fromList(
    List.generate(300 * 1024, (i) => (i * 31 + 7) % 256),
  );

  setUp(() {
    folder = Directory.systemTemp.createTempSync('nexmusic_update_');
    network = StreamController<List<ConnectivityResult>>.broadcast();
  });

  tearDown(() async {
    UpdateDownload.current.value?.dismiss();
    UpdateDownload.current.value = null;
    await network.close();
    folder.deleteSync(recursive: true);
  });

  Future<UpdateDownload> start(_ApkServer server, {bool digest = true}) =>
      UpdateDownload.start(
        _info(server, digest: digest),
        folder: folder,
        networkChanges: network.stream,
        retryDelay: const Duration(milliseconds: 10),
      );

  test('a dropped connection resumes from the saved bytes', () async {
    final server = _ApkServer(body, (socket, attempt, from) async {
      if (attempt == 0) {
        _send(socket, body, 0, limit: 100 * 1024);
        await socket.flush();
        socket.destroy();
      } else {
        _send(socket, body, from ?? 0);
        await socket.flush();
        await socket.close();
      }
    });
    await server.open();
    final download = await start(server);
    await _settled(download);
    expect(download.state, UpdateDownloadState.ready);
    expect(server.ranges.first, isNull);
    expect(server.ranges[1], greaterThan(0));
    expect(download.file.readAsBytesSync(), body);
    expect(download.received, body.length);
    await server.close();
  });

  test('switching networks reconnects at once instead of timing out', () async {
    final stalled = Completer<void>();
    final server = _ApkServer(body, (socket, attempt, from) async {
      if (attempt == 0) {
        // Sends a part and then goes quiet, like a socket on a lost network.
        _send(socket, body, 0, limit: 64 * 1024);
        await socket.flush();
        stalled.complete();
      } else {
        _send(socket, body, from ?? 0);
        await socket.flush();
        await socket.close();
      }
    });
    await server.open();
    final watch = Stopwatch()..start();
    final download = await start(server);
    network.add([ConnectivityResult.wifi]);
    await stalled.future;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    network.add([ConnectivityResult.mobile]);
    await _settled(download);
    expect(download.state, UpdateDownloadState.ready);
    expect(server.ranges.length, 2);
    expect(server.ranges[1], greaterThan(0));
    // Well under the 20 second wait for a silent connection.
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    expect(download.file.readAsBytesSync(), body);
    await server.close();
  });

  test('a download cut short by an app restart carries on', () async {
    final server = _ApkServer(body, (socket, attempt, from) async {
      _send(socket, body, from ?? 0);
      await socket.flush();
      await socket.close();
    });
    await server.open();
    final info = _info(server);
    File(
      '${folder.path}${Platform.pathSeparator}nexMusic_9999.part',
    ).writeAsBytesSync(body.sublist(0, 1234));
    expect(await UpdateDownload.started(info, folder: folder), isTrue);
    final download = await start(server);
    await _settled(download);
    expect(download.state, UpdateDownloadState.ready);
    expect(server.ranges, [1234]);
    expect(download.file.readAsBytesSync(), body);
    await UpdateDownload.removeOld(9999, folder: folder);
    expect(download.file.existsSync(), isFalse);
    await server.close();
  });

  test('a missing file fails instead of retrying forever', () async {
    final server = _ApkServer(body, (socket, attempt, from) async {
      socket.write(
        'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n',
      );
      await socket.flush();
      await socket.close();
    });
    await server.open();
    final download = await start(server);
    await _settled(download);
    expect(download.state, UpdateDownloadState.failed);
    expect(download.message, 'This file is no longer available.');
    await server.close();
  });
}

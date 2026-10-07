import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nex_music/music_data.dart';
import 'package:nex_music/music_sharing.dart';
import 'package:path/path.dart' as path;

Song song(String id, {String? url, String provider = ''}) => Song(
  id: id,
  title: 'Same/name?',
  artist: 'Artist',
  kind: 'audio',
  url: url ?? 'https://music.test/$id.mp3',
  providerId: provider,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(
    () async =>
        root = await Directory.systemTemp.createTemp('song-share-test-'),
  );
  tearDown(() async => root.delete(recursive: true));

  SongFilePreparation preparation({
    Future<String> Function(Song)? resolve,
    HttpClient Function()? client,
    Future<File> Function(File)? extract,
    Future<File> Function(String, String)? copy,
    Future<void> Function()? beforeDownload,
    void Function(Song, int, int, double?)? progress,
    int budget = 1024,
  }) => SongFilePreparation(
    resolve: resolve ?? (song) async => song.url,
    headers: (_) => {'User-Agent': 'Audio-test'},
    maxBytes: budget,
    clientFactory: client ?? () => _Client((_) async => _Response([1, 2, 3])),
    temporaryDirectory: () async => root,
    extractAudio: extract,
    copyContentUri: copy,
    beforeDownload: beforeDownload,
    onProgress: progress,
  );

  Iterable<File> shares() => root
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.contains('song_shares'));

  test(
    'downloads every selected audio file in order with real bytes and audio MIME',
    () async {
      final requests = <Uri>[];
      final client = _Client((uri) async {
        requests.add(uri);
        return _Response(uri.path.contains('a') ? [1, 2] : [3, 4]);
      });
      final operation = preparation(client: () => client);
      final video = song('video').copyWith(kind: 'video');
      final batch = await operation.prepare([
        song('a'),
        song('b'),
        song('a'),
        video,
      ]);
      expect(requests.map((uri) => uri.path), ['/a.mp3', '/b.mp3']);
      expect(batch.files.length, 2);
      expect(await batch.files[0].readAsBytes(), [1, 2]);
      expect(await batch.files[1].readAsBytes(), [3, 4]);
      expect(batch.files.map((file) => file.mimeType), [
        'audio/mpeg',
        'audio/mpeg',
      ]);
      expect(batch.files[0].name, '1 Same name - Artist.mp3');
      expect(batch.files[1].name, '2 Same name - Artist.mp3');
      expect(client.headers.values['User-Agent'], 'Audio-test');
      expect(
        shares().length,
        2,
        reason: 'Raw downloads must not double cache usage',
      );
      await batch.dispose();
      expect(shares(), isEmpty);
    },
  );

  test(
    'reuses downloaded/local files without network and preserves originals',
    () async {
      final source = await File(
        '${root.path}/offline.mp3',
      ).writeAsBytes([9, 8]);
      final batch =
          await preparation(
            client: () => throw StateError('Unexpected network request'),
            beforeDownload: () async =>
                throw StateError('Unexpected network check'),
          ).prepare([
            song('a', url: source.uri.toString()),
            song('b', url: source.path),
          ]);
      expect(batch.files.length, 2);
      expect(await batch.files.last.readAsBytes(), [9, 8]);
      await batch.dispose();
      expect(await source.readAsBytes(), [9, 8]);
    },
  );

  test(
    'content URI copies retain audio extension and remove only the owned copy',
    () async {
      final device = await File(
        '${root.path}/original.flac',
      ).writeAsBytes([8, 7]);
      late File temporary;
      final batch = await preparation(
        copy: (uri, _) async {
          expect(uri, 'content://media/audio/123');
          return temporary = await device.copy('${root.path}/copy.flac');
        },
      ).prepare([song('local:123', url: 'content://media/audio/123')]);
      expect(batch.files.single.mimeType, 'audio/flac');
      expect(await batch.files.single.readAsBytes(), [8, 7]);
      expect(await temporary.exists(), false);
      expect(await device.exists(), true);
      await batch.dispose();
    },
  );

  test(
    'muxed provider/downloaded MP4 is extracted into an audio-only M4A',
    () async {
      final source = await File(
        '${root.path}/offline.mp4',
      ).writeAsBytes([1, 2, 3]);
      late File exported;
      final batch =
          await preparation(
            extract: (input) async {
              expect(path.normalize(input.path), path.normalize(source.path));
              return exported = await File(
                '${root.path}/export.m4a',
              ).writeAsBytes([4, 5]);
            },
          ).prepare([
            song('youtube', url: source.uri.toString(), provider: 'ytmusic'),
          ]);
      expect(batch.files.single.name, endsWith('.m4a'));
      expect(batch.files.single.mimeType, 'audio/mp4');
      expect(await batch.files.single.readAsBytes(), [4, 5]);
      expect(await exported.exists(), false);
      expect(await source.readAsBytes(), [1, 2, 3]);
      await batch.dispose();
    },
  );

  test('response MIME chooses M4A when URL has no file extension', () async {
    final batch = await preparation(
      client: () => _Client((_) async => _Response([1, 2], mime: 'audio/mp4')),
    ).prepare([song('a', url: 'https://music.test/play?id=a')]);
    expect(batch.files.single.name, endsWith('.m4a'));
    await batch.dispose();
  });

  test(
    'long Hindi and emoji titles produce portable audio filenames',
    () async {
      final titled = song(
        'a',
      ).copyWith(title: List.filled(100, 'गीत🎵').join());
      final batch = await preparation().prepare([titled]);
      final name = batch.files.single.name;
      expect(utf8.encode(name).length, lessThan(255));
      expect(name, endsWith('.mp3'));
      expect(await batch.files.single.readAsBytes(), [1, 2, 3]);
      await batch.dispose();
    },
  );

  test(
    'failure in any song discards the whole batch instead of sharing partial audio',
    () async {
      final operation = preparation(
        client: () => _Client(
          (uri) async =>
              _Response([1, 2], statusCode: uri.path.contains('b') ? 404 : 200),
        ),
      );
      await expectLater(
        operation.prepare([song('a'), song('b')]),
        throwsA(isA<HttpException>()),
      );
      expect(shares(), isEmpty);
    },
  );

  test('HTML and incomplete downloads are rejected and cleaned', () async {
    for (final response in [
      _Response([60, 62], mime: 'text/html'),
      _Response([1], length: 5),
      _Response([]),
    ]) {
      final operation = preparation(
        client: () => _Client((_) async => response),
      );
      await expectLater(
        operation.prepare([song('a')]),
        throwsA(isA<Exception>()),
      );
      expect(shares(), isEmpty);
    }
  });

  test(
    'cancelling an active batch closes network and never returns files',
    () async {
      late SongFilePreparation operation;
      final client = _Client((_) async => _Response([1, 2]));
      operation = preparation(
        client: () => client,
        progress: (_, _, _, fraction) {
          if (fraction != null) operation.cancel();
        },
      );
      await expectLater(
        operation.prepare([song('a'), song('b')]),
        throwsA(isA<SongShareCancelled>()),
      );
      expect(client.closed, true);
      expect(shares(), isEmpty);
    },
  );

  test(
    'storage limit covers total batch bytes including unknown-length responses',
    () async {
      final operation = preparation(
        budget: 3,
        client: () => _Client((_) async => _Response([1, 2], length: -1)),
      );
      await expectLater(
        operation.prepare([song('a'), song('b')]),
        throwsA(isA<FileSystemException>()),
      );
      expect(shares(), isEmpty);
    },
  );

  test(
    'expired provider URLs refresh once and preserve required request headers',
    () async {
      var attempts = 0, resolutions = 0;
      final operation = preparation(
        resolve: (_) async => 'https://music.test/${++resolutions}.m4a',
        client: () => _Client(
          (_) async =>
              _Response([1, 2], statusCode: ++attempts == 1 ? 403 : 200),
        ),
      );
      final batch = await operation.prepare([song('a', provider: 'ytmusic')]);
      expect(attempts, 2);
      expect(resolutions, 2);
      await batch.dispose();
    },
  );

  test(
    'Wi-Fi-only rejection makes no audio download or leftover copies',
    () async {
      await expectLater(
        preparation(
          beforeDownload: () async => throw StateError('Waiting for Wi-Fi'),
          client: () => throw StateError('Unexpected download'),
        ).prepare([song('a')]),
        throwsStateError,
      );
      expect(shares(), isEmpty);
    },
  );
}

class _Client extends Fake implements HttpClient {
  _Client(this.respond);
  final Future<_Response> Function(Uri) respond;
  final _Headers headers = _Headers();
  bool closed = false;
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async =>
      _Request(headers, () => respond(uri));
  @override
  void close({bool force = false}) {
    closed = true;
  }
}

class _Request extends Fake implements HttpClientRequest {
  _Request(this.headers, this.respond);
  @override
  final HttpHeaders headers;
  final Future<HttpClientResponse> Function() respond;
  @override
  Future<HttpClientResponse> close() => respond();
}

class _Headers extends Fake implements HttpHeaders {
  _Headers({this.mime = 'audio/mpeg'});
  final String mime;
  final values = <String, Object>{};
  @override
  ContentType? get contentType => ContentType.parse(mime);
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name] = value;
  }
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(
    this.bytes, {
    this.statusCode = 200,
    String mime = 'audio/mpeg',
    int? length,
  }) : headers = _Headers(mime: mime),
       contentLength = length ?? bytes.length;
  final List<int> bytes;
  @override
  final int statusCode;
  @override
  final HttpHeaders headers;
  @override
  final int contentLength;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

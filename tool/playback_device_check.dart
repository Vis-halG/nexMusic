// Run with: flutter run -d emulator-5554 -t tool/playback_device_check.dart
// Then: node tool/run_playback_device_check.mjs
// Uses generated audio, the real Android decoder and production media service.
// No account, catalogue or saved preferences are changed.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:nex_music/listening_models.dart';
import 'package:nex_music/listening_player.dart';
import 'package:nex_music/music_data.dart';
import 'package:nex_music/music_provider.dart';
import 'package:nex_music/phone_services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final initial = AudioPlayer();
  final handler = await AudioService.init(
    builder: () => NexAudioHandler(initial),
    config: nexAudioServiceConfig,
  );
  runApp(
    const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text(
            'Playback device checks\nGenerated test audio',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    ),
  );
  final check = _DeviceCheck(handler, initial);
  await check.start();
}

class _DeviceCheck {
  _DeviceCheck(this.handler, this.initial);
  final NexAudioHandler handler;
  final AudioPlayer initial;
  ListeningPlayer? engine;
  late HttpServer server;
  final results = <Map<String, dynamic>>[];
  final errors = <String>[];
  final selections = <String>[];
  final shortAudio = _wave(2), longAudio = _wave(45);
  String phase = 'ready';
  int resolves = 0, flakyRequests = 0;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8766);
    unawaited(initial.dispose());
    server.listen((request) async {
      try {
        final path = request.uri.path;
        if (path == '/status') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'phase': phase,
              'results': results,
              'errors': errors,
              'selections': selections,
              'resolves': resolves,
              'playing': engine?.playing ?? false,
              'state': engine?.player.processingState.name,
              'positionMs': engine?.player.position.inMilliseconds ?? 0,
              'volume': engine?.player.volume,
              'current': engine?.queue.currentId,
            }),
          );
        } else if (path == '/run' && phase == 'ready') {
          phase = 'suite';
          unawaited(_suite());
          request.response.write('started');
        } else if (path == '/scenario') {
          await _scenario(request.uri.queryParameters['mode'] ?? 'gapless');
          request.response.write('started');
        } else if (path == '/stop') {
          await engine?.stop();
          request.response.write('stopped');
        } else if (path.endsWith('.wav')) {
          await _audio(request);
          return;
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      } catch (error) {
        errors.add('HTTP harness: ${error.runtimeType}');
        try {
          await request.response.close();
        } catch (_) {}
      }
    });
    debugPrint('NEX_PLAYBACK_CHECK_READY');
  }

  List<Song> _tracks(String prefix, {bool long = false}) => [
    for (var i = 0; i < 3; i++)
      Song(
        id: '$prefix-$i',
        title: 'Generated $i',
        kind: 'audio',
        url: 'http://127.0.0.1:8766/${long ? 'long' : 'short'}.wav',
      ),
  ];

  Future<ListeningPlayer> _new({
    bool gapless = false,
    int crossfade = 0,
    MusicSourceResolver? resolve,
  }) async {
    await engine?.stop();
    engine?.dispose();
    final native = AudioPlayer();
    handler.bindPlayer(native);
    selections.clear();
    resolves = 0;
    late ListeningPlayer value;
    value = ListeningPlayer(
      player: native,
      resolve:
          resolve ??
          (song) async => AudioSource.uri(Uri.parse(song.url), tag: song),
      settings: () => ListeningSettings({
        'gapless': gapless,
        'crossfade': crossfade,
        'autoplay': false,
      }),
      onTrack: (song) {
        selections.add(song.id);
        handler.mediaItem.add(MediaItem(id: song.id, title: song.title));
      },
      onListening: (_, _, {skipped = false, completed = false}) {},
      onError: errors.add,
      onPlayerChanged: handler.bindPlayer,
    );
    handler
      ..onPlay = value.resume
      ..onPause = value.pause
      ..onStop = value.stop
      ..onNext = value.next
      ..onPrevious = value.previous
      ..onSeek = value.seek;
    engine = value;
    return value;
  }

  Future<void> _case(String name, Future<void> Function() body) async {
    final started = DateTime.now();
    try {
      await body().timeout(const Duration(seconds: 45));
      results.add({
        'name': name,
        'pass': true,
        'ms': DateTime.now().difference(started).inMilliseconds,
      });
    } catch (error) {
      results.add({'name': name, 'pass': false, 'error': '$error'});
    }
    debugPrint('NEX_PLAYBACK_CHECK ${jsonEncode(results.last)}');
  }

  Future<void> _suite() async {
    await _case('sequential queue without preloading', () async {
      final value = await _new();
      final local = await File(
        '${Directory.systemTemp.path}/nex-playback-${DateTime.now().microsecondsSinceEpoch}.wav',
      ).writeAsBytes(shortAudio);
      try {
        final tracks = _tracks(
          'sequential',
        ).map((s) => s.copyWith(url: local.uri.toString())).toList();
        _require(
          await value.play(tracks.first, from: tracks),
          'first start failed',
        );
        await _until(() => selections.length == 3 && !value.playing);
        _require(
          selections.join(',') == tracks.map((s) => s.id).join(','),
          'queue order',
        );
      } finally {
        await local.delete();
      }
    });
    await _case('gapless repeat all: twelve native transitions', () async {
      final value = await _new(gapless: true);
      final tracks = _tracks('gapless');
      await value.play(tracks.first, from: tracks);
      await value.setRepeat(MusicRepeat.all);
      await _until(() => selections.length >= 13);
      _require(value.playing, 'repeat stopped');
    });
    await _case(
      'crossfade: eight handoffs retain playback and volume',
      () async {
        final value = await _new(crossfade: 1);
        final tracks = _tracks('crossfade');
        await value.setVolume(0.6);
        await value.play(tracks.first, from: tracks);
        await value.setRepeat(MusicRepeat.all);
        await _until(() => selections.length >= 9);
        _require(value.playing, 'crossfade stopped');
        _require((value.player.volume - 0.6).abs() < 0.02, 'crossfade volume');
      },
    );
    await _case('pause and immediate resume during a real crossfade', () async {
      final value = await _new(crossfade: 1);
      final tracks = _tracks('pause-fade');
      await value.play(tracks.first, from: tracks);
      await _until(() => value.player.position.inMilliseconds >= 1250);
      await value.pause();
      await value.resume();
      await _until(() => selections.length >= 2);
      _require(
        value.playing && value.player.volume > 0,
        'paused incoming promoted',
      );
    });
    await _case('HTTP 404 next track is skipped automatically', () async {
      final value = await _new();
      final tracks = _tracks('unavailable');
      tracks[1] = tracks[1].copyWith(url: 'http://127.0.0.1:8766/missing.wav');
      await value.play(tracks.first, from: tracks);
      await _until(
        () => value.queue.currentId == tracks.last.id && value.playing,
      );
    });
    await _case('HTTP interruption reloads with a refreshed source', () async {
      flakyRequests = 0;
      final value = await _new(
        resolve: (song) async {
          resolves++;
          return AudioSource.uri(
            Uri.parse(
              'http://127.0.0.1:8766/${resolves == 1 ? 'flaky' : 'long'}.wav',
            ),
            tag: song,
          );
        },
      );
      final track = _tracks('recover', long: true).first;
      await value.play(track);
      await _until(
        () =>
            resolves >= 2 &&
            value.player.processingState == ProcessingState.ready &&
            value.playing,
      );
      final before = value.player.position;
      await Future<void>.delayed(const Duration(seconds: 2));
      _require(value.player.position > before, 'recovery did not progress');
      _require(resolves == 2, 'recovery exceeded one retry');
    });
    await _case('sleep after track pauses intentionally', () async {
      final value = await _new(gapless: true);
      final tracks = _tracks('sleep');
      await value.play(tracks.first, from: tracks);
      value.setSleep(null, afterTrack: true);
      await _until(() => !value.playing);
      _require(value.queue.currentId == tracks.first.id, 'sleep advanced');
    });
    for (final provider in [JioSaavnProvider(), YouTubeMusicProvider()]) {
      await _case(
        '${provider.id}: actual stream start, middle and ending',
        () async {
          final songs = await provider.searchSongs('Arijit Singh', limit: 1);
          _require(songs.isNotEmpty, 'provider returned no tracks');
          final song = songs.first;
          final value = await _new(
            resolve: (track) async => AudioSource.uri(
              Uri.parse(await provider.resolveStreamUrl(track)),
              headers: provider.playbackHeaders(track),
              tag: track,
            ),
          );
          _require(await value.play(song), 'provider track did not start');
          await _until(() => value.player.position.inSeconds >= 2);
          final middle = Duration(
            milliseconds: value.duration.inMilliseconds ~/ 2,
          );
          await value.seek(middle);
          await _until(
            () => value.player.position > middle + const Duration(seconds: 1),
          );
          await value.seek(value.duration - const Duration(seconds: 3));
          await _until(() => !value.playing);
        },
      );
    }
    await engine?.stop();
    phase = 'interactive';
    debugPrint('NEX_PLAYBACK_CHECK_SUITE_DONE');
  }

  Future<void> _scenario(String mode) async {
    final recovering = mode == 'recover';
    flakyRequests = 0;
    final value = await _new(
      gapless: mode == 'gapless',
      crossfade: mode == 'crossfade' ? 1 : 0,
      resolve: recovering
          ? (song) async {
              resolves++;
              return AudioSource.uri(
                Uri.parse(
                  'http://127.0.0.1:8766/${resolves == 1 ? 'flaky' : 'long'}.wav',
                ),
                tag: song,
              );
            }
          : null,
    );
    final tracks = _tracks(mode, long: recovering);
    await value.play(tracks.first, from: recovering ? [tracks.first] : tracks);
    if (!recovering) await value.setRepeat(MusicRepeat.all);
    phase = mode;
  }

  Future<void> _audio(HttpRequest request) async {
    final response = request.response;
    final flaky = request.uri.path == '/flaky.wav';
    if (request.uri.path == '/missing.wav' || (flaky && flakyRequests++ > 0)) {
      response.statusCode = flaky ? 403 : 404;
      await response.close();
      return;
    }
    final bytes = request.uri.path == '/short.wav' ? shortAudio : longAudio;
    final range = RegExp(
      r'bytes=(\d+)-(\d*)',
    ).firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
    final start = range == null ? 0 : int.parse(range[1]!);
    final end = range == null || range[2]!.isEmpty
        ? bytes.length - 1
        : math.min(int.parse(range[2]!), bytes.length - 1);
    response.headers
      ..contentType = ContentType('audio', 'wav')
      ..set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (range != null) {
      response.statusCode = 206;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${bytes.length}',
      );
    }
    response.contentLength = end - start + 1;
    if (flaky) {
      response.add(bytes.sublist(start, math.min(start + 96000, end + 1)));
      await response.flush();
      await Future<void>.delayed(const Duration(seconds: 3));
      (await response.detachSocket(writeHeaders: false)).destroy();
    } else {
      response.add(bytes.sublist(start, end + 1));
      await response.close();
    }
  }
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 40));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Playback condition timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void _require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Uint8List _wave(int seconds) {
  const sampleRate = 22050;
  final count = seconds * sampleRate;
  final data = ByteData(44 + count * 2);
  void text(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      data.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  data.setUint32(4, 36 + count * 2, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, count * 2, Endian.little);
  for (var i = 0; i < count; i++) {
    data.setInt16(
      44 + i * 2,
      (math.sin(2 * math.pi * 440 * i / sampleRate) * 800).round(),
      Endian.little,
    );
  }
  return data.buffer.asUint8List();
}

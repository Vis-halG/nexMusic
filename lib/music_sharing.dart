import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'music_data.dart';
import 'music_transfer.dart';

class SongShareCancelled implements Exception {}

/// Owns only the temporary, named copies handed to the share plugin.
class PreparedSongFiles {
  PreparedSongFiles(this.directory, this.files);
  final Directory directory;
  final List<XFile> files;

  Future<void> dispose() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

/// Downloads complete files before opening the share sheet. Failed or cancelled
/// batches never share a partial selection or remove original/offline files.
class SongFilePreparation {
  SongFilePreparation({
    required this.resolve,
    required this.headers,
    required this.maxBytes,
    this.copyContentUri,
    this.extractAudio,
    this.beforeDownload,
    this.onProgress,
    HttpClient Function()? clientFactory,
    Future<Directory> Function()? temporaryDirectory,
  }) : _clientFactory = clientFactory ?? HttpClient.new,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  final Future<String> Function(Song) resolve;
  final Map<String, String> Function(Song) headers;
  final int maxBytes;
  // These callbacks return new cache copies owned by this operation.
  final Future<File> Function(String uri, String name)? copyContentUri;
  final Future<File> Function(File source)? extractAudio;
  final Future<void> Function()? beforeDownload;
  final void Function(Song song, int index, int total, double? fraction)?
  onProgress;
  final HttpClient Function() _clientFactory;
  final Future<Directory> Function() _temporaryDirectory;
  HttpClient? _client;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  void _checkCancelled() {
    if (_cancelled) throw SongShareCancelled();
  }

  Future<PreparedSongFiles> prepare(Iterable<Song> selected) async {
    if (kIsWeb) {
      throw UnsupportedError('Share audio files from the installed app.');
    }
    final songs = {
      for (final song in selected.where((s) => !s.isVideo)) song.id: song,
    }.values.toList();
    if (songs.isEmpty) throw StateError('Select an audio song to share.');
    _checkCancelled();
    final root = await _temporaryDirectory();
    final directory = await Directory(
      path.join(root.path, 'song_shares'),
    ).create(recursive: true);
    final batch = await directory.createTemp('batch-');
    final files = <XFile>[];
    var bytes = 0;
    try {
      for (var index = 0; index < songs.length; index++) {
        final song = songs[index];
        _checkCancelled();
        onProgress?.call(song, index, songs.length, null);
        final source = await resolve(song).timeout(const Duration(seconds: 45));
        _checkCancelled();
        final uri = path.isAbsolute(source)
            ? Uri.file(source)
            : Uri.tryParse(source);
        if (source.isEmpty || uri == null || uri.scheme == 'device') {
          throw StateError('This song is not available on this device.');
        }
        File input;
        File? ownedInput;
        File? extracted;
        try {
          if (uri.scheme == 'https' || uri.scheme == 'http') {
            await beforeDownload?.call();
            _checkCancelled();
            ownedInput = await _download(
              song,
              uri,
              batch,
              index,
              songs.length,
              maxBytes - bytes,
            );
            input = ownedInput;
          } else if (uri.scheme == 'content') {
            final copy = copyContentUri;
            if (copy == null) {
              throw StateError('This device file could not be read.');
            }
            ownedInput = await copy(source, '${index + 1} ${_title(song)}');
            input = ownedInput;
          } else if (uri.scheme == 'file' || uri.scheme.isEmpty) {
            input = uri.scheme == 'file' ? File.fromUri(uri) : File(source);
          } else {
            throw StateError(
              'This source does not provide a downloadable file.',
            );
          }
          _checkCancelled();
          if (_containers.contains(path.extension(input.path).toLowerCase())) {
            final extract = extractAudio;
            if (extract == null) {
              throw UnsupportedError(
                'Audio extraction is unavailable on this device.',
              );
            }
            onProgress?.call(song, index, songs.length, null);
            extracted = await extract(input);
            _checkCancelled();
            input = extracted;
          }
          final size = await input.length();
          if (size == 0) {
            throw const FormatException('The audio file is empty.');
          }
          if (bytes + size > maxBytes) {
            throw const FileSystemException(
              'Selected audio exceeds the download storage limit. Share fewer songs or increase the limit.',
            );
          }
          final extension = path.extension(input.path).toLowerCase();
          final mime = _audioTypes[extension];
          if (mime == null) {
            throw const FormatException(
              'This source did not provide a supported audio file.',
            );
          }
          final target = File(
            path.join(batch.path, '${index + 1} ${_title(song)}$extension'),
          );
          await input.copy(target.path);
          _checkCancelled();
          bytes += size;
          files.add(XFile(target.path, mimeType: mime));
          onProgress?.call(song, index, songs.length, 1);
        } finally {
          for (final temporary in [ownedInput, extracted]) {
            if (temporary != null && await temporary.exists()) {
              await temporary.delete();
            }
          }
        }
      }
      _checkCancelled();
      return PreparedSongFiles(batch, files);
    } catch (_) {
      await batch.delete(recursive: true);
      _checkCancelled();
      rethrow;
    }
  }

  Future<File> _download(
    Song song,
    Uri uri,
    Directory batch,
    int index,
    int total,
    int remaining,
  ) async {
    // An expired provider URL can be resolved once more, without looping.
    for (var attempt = 0; attempt < 2; attempt++) {
      _checkCancelled();
      final client = _clientFactory()
        ..connectionTimeout = const Duration(seconds: 20);
      _client = client;
      try {
        final request = await client
            .getUrl(uri)
            .timeout(const Duration(seconds: 30));
        headers(song).forEach(request.headers.set);
        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
        if ({401, 403}.contains(response.statusCode) &&
            song.isProvider &&
            attempt == 0) {
          final refreshed = await resolve(
            song,
          ).timeout(const Duration(seconds: 45));
          uri = Uri.parse(refreshed);
          if (uri.scheme != 'https' && uri.scheme != 'http') {
            throw const FormatException('The source cannot be downloaded.');
          }
          continue;
        }
        if (response.statusCode != 200) {
          throw TransferHttpException(
            response.statusCode,
            message:
                'Could not download ${song.title} (HTTP ${response.statusCode}).',
          );
        }
        final type = response.headers.contentType?.mimeType ?? '';
        final extension = _extensionFor(uri.path, type);
        if (extension == null) {
          throw const FormatException(
            'The source returned a page instead of an audio file.',
          );
        }
        if (response.contentLength > remaining) {
          throw const FileSystemException(
            'Selected audio exceeds the download storage limit.',
          );
        }
        final file = File(
          path.join(batch.path, 'source-${index + 1}$extension'),
        );
        final sink = file.openWrite();
        var received = 0;
        var lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
        try {
          await for (final chunk in response.timeout(
            const Duration(seconds: 30),
          )) {
            _checkCancelled();
            received += chunk.length;
            if (received > remaining) {
              throw const FileSystemException(
                'Selected audio exceeds the download storage limit.',
              );
            }
            sink.add(chunk);
            final now = DateTime.now();
            if (now.difference(lastProgress).inMilliseconds >= 150) {
              lastProgress = now;
              onProgress?.call(
                song,
                index,
                total,
                response.contentLength > 0
                    ? received / response.contentLength
                    : null,
              );
            }
          }
        } finally {
          await sink.close();
        }
        _checkCancelled();
        if (received == 0 ||
            (response.contentLength > 0 &&
                received != response.contentLength)) {
          throw const HttpException(
            'The audio download was incomplete. Try sharing again.',
          );
        }
        return file;
      } finally {
        client.close(force: true);
        _client = null;
      }
    }
    throw StateError('The audio source is unavailable.');
  }

  static String _title(Song song) {
    var title = '${song.title}${song.artist.isEmpty ? '' : ' - ${song.artist}'}'
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (title.isEmpty) title = 'Song';
    // Android/Linux filenames have a byte limit, so character counts are not
    // enough for Hindi titles or emoji. Leave room for the index and extension.
    final shortened = StringBuffer();
    var bytes = 0;
    for (final rune in title.runes) {
      final character = String.fromCharCode(rune);
      final length = utf8.encode(character).length;
      if (bytes + length > 180) break;
      shortened.write(character);
      bytes += length;
    }
    return shortened.toString().trimRight();
  }

  static String? _extensionFor(String source, String mime) {
    if (mime.startsWith('text/') ||
        mime.contains('json') ||
        mime.contains('mpegurl')) {
      return null;
    }
    final matched = _audioTypes.entries
        .where((entry) => entry.value == mime)
        .firstOrNull;
    if (matched != null) return matched.key;
    if (mime == 'video/mp4') return '.mp4';
    if (mime == 'video/webm') return '.webm';
    final ext = path.extension(source).toLowerCase();
    return _audioTypes.containsKey(ext) || _containers.contains(ext)
        ? ext
        : null;
  }

  static const _containers = {
    '.mp4',
    '.m4v',
    '.mov',
    '.webm',
    '.mkv',
    '.mka',
    '.3ga',
    '.3gp',
    '.3g2',
    '.avi',
    '.flv',
    '.wmv',
  };
  static const _audioTypes = {
    '.mp3': 'audio/mpeg',
    '.m4a': 'audio/mp4',
    '.aac': 'audio/aac',
    '.wav': 'audio/wav',
    '.flac': 'audio/flac',
    '.ogg': 'audio/ogg',
    '.oga': 'audio/ogg',
    '.opus': 'audio/opus',
    '.amr': 'audio/amr',
    '.aiff': 'audio/aiff',
    '.aif': 'audio/aiff',
  };
}

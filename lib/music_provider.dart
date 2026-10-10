import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/desede_engine.dart';

import 'music_data.dart';
import 'music_transfer.dart';

typedef ProviderJsonFetcher = Future<Map<String, dynamic>> Function(Uri uri);
typedef ProviderJsonPoster =
    Future<Map<String, dynamic>> Function(
      Uri uri,
      Map<String, dynamic> body,
      Map<String, String> headers,
    );

/// A searchable music source whose final playback URL may be resolved lazily.
abstract class MusicProvider {
  String get id;
  String get displayName;

  Map<String, String> playbackHeaders(Song song);
  Future<List<Song>> loadFeatured({int limit = 20, int page = 1});
  Future<List<Song>> searchSongs(String query, {int limit = 20, int page = 1});
  Future<String> resolveStreamUrl(Song song);
  Future<List<Song>> loadRadio(String sourceId, {int limit = 25});
}

/// JioSaavn catalogue and song radio source.
///
/// Search results do not contain a directly playable URL. The service returns
/// an encrypted media address, so it is resolved only when playback/download
/// starts. No account credentials or API keys are stored by this class.
class JioSaavnProvider implements MusicProvider {
  int quality = 320;
  JioSaavnProvider({ProviderJsonFetcher? fetchJson})
    : _fetchJson = fetchJson ?? _httpGetJson;

  static const _api = 'https://www.jiosaavn.com/api.php';
  final ProviderJsonFetcher _fetchJson;

  @override
  String get id => 'jiosaavn';

  @override
  String get displayName => 'JioSaavn';

  @override
  Map<String, String> playbackHeaders(Song song) => const {};

  @override
  Future<List<Song>> loadFeatured({int limit = 20, int page = 1}) async {
    final data = await _fetchJson(_uri({'__call': 'webapi.getLaunchData'}));
    final items = data['new_trending'];
    if (items is! List) return const [];
    return items
        .whereType<Map>()
        .where((item) => _string(item['type']) == 'song')
        .map((item) => _songFrom(Map<String, dynamic>.from(item)))
        .whereType<Song>()
        .take(limit)
        .toList(growable: false);
  }

  @override
  Future<List<Song>> searchSongs(
    String query, {
    int limit = 20,
    int page = 1,
  }) async {
    final value = query.trim();
    if (value.isEmpty) return const [];
    final data = await _fetchJson(
      _uri({
        '__call': 'search.getResults',
        'q': value,
        'p': '$page',
        'n': '${limit.clamp(1, 50)}',
      }),
    );
    final raw = data['results'];
    if (raw is! List) return const [];

    return raw
        .whereType<Map>()
        .map((item) => _songFrom(Map<String, dynamic>.from(item)))
        .whereType<Song>()
        .take(limit)
        .toList(growable: false);
  }

  @override
  Future<String> resolveStreamUrl(Song song) async {
    if (song.providerId != id || song.sourceId.isEmpty) {
      throw const FormatException('This song does not belong to JioSaavn.');
    }
    final data = await _fetchJson(
      _uri({'__call': 'song.getDetails', 'pids': song.sourceId}),
    );
    Map<String, dynamic>? detail;
    final songs = data['songs'];
    if (songs is List && songs.isNotEmpty && songs.first is Map) {
      detail = Map<String, dynamic>.from(songs.first as Map);
    } else if (data[song.sourceId] is Map) {
      detail = Map<String, dynamic>.from(data[song.sourceId] as Map);
    }
    if (detail == null) throw const FormatException('Song was not found.');

    final more = _map(detail['more_info']);
    final encrypted = _string(
      more?['encrypted_media_url'] ?? detail['encrypted_media_url'],
    );
    if (encrypted.isEmpty) {
      throw const FormatException('No playable source is available.');
    }
    final decoded = decodeJioSaavnMediaUrl(encrypted);
    final hasHighQuality = _string(more?['320kbps']).toLowerCase() == 'true';
    return _withQuality(
      decoded,
      quality <= 96
          ? '96'
          : quality <= 160 || !hasHighQuality
          ? '160'
          : '320',
    );
  }

  @override
  Future<List<Song>> loadRadio(String sourceId, {int limit = 25}) async {
    if (sourceId.trim().isEmpty) return const [];
    final station = await _fetchJson(
      _uri({
        '__call': 'webradio.createEntityStation',
        'ctx': 'android',
        'entity_id': jsonEncode([sourceId]),
        'entity_type': 'queue',
      }),
    );
    final stationId = _string(station['stationid']);
    if (stationId.isEmpty) return const [];
    final data = await _fetchJson(
      _uri({
        '__call': 'webradio.getSong',
        'ctx': 'android',
        'stationid': stationId,
        'k': '${limit.clamp(1, 50)}',
        'next': '1',
      }),
    );
    final songs = <Song>[];
    final seen = <String>{sourceId};
    for (final value in [
      if (data['song'] is Map) data,
      ...data.values.whereType<Map>(),
    ]) {
      final raw = value['song'];
      if (raw is! Map) continue;
      final song = _songFrom(Map<String, dynamic>.from(raw));
      if (song != null && seen.add(song.sourceId)) songs.add(song);
    }
    return songs.take(limit).toList();
  }

  Song? _songFrom(Map<String, dynamic> item) {
    final sourceId = _string(item['id']);
    final title = decodeHtmlText(item['title'] ?? item['name']);
    if (sourceId.isEmpty || title.isEmpty) return null;
    final more = _map(item['more_info']);
    final artists = _map(more?['artistMap'] ?? more?['artist_map']);
    final primary = artists?['primary_artists'];
    final artistNames = <String>[];
    if (primary is List) {
      for (final value in primary.whereType<Map>()) {
        final name = decodeHtmlText(value['name']);
        if (name.isNotEmpty) artistNames.add(name);
      }
    }
    if (artistNames.isEmpty) {
      final fallback = decodeHtmlText(more?['music'] ?? item['subtitle']);
      if (fallback.isNotEmpty) artistNames.add(fallback);
    }
    final durationSeconds = int.tryParse(_string(more?['duration'])) ?? 0;
    return Song(
      id: 'provider:$id:$sourceId',
      title: title,
      kind: 'audio',
      url: '',
      categoryId: 'provider:$id',
      providerId: id,
      sourceId: sourceId,
      artist: artistNames.join(', '),
      album: decodeHtmlText(more?['album']),
      albumId: _string(more?['album_id']),
      artistId: primary is List && primary.isNotEmpty && primary.first is Map
          ? _string((primary.first as Map)['id'])
          : '',
      language: _string(more?['language'] ?? item['language']),
      artworkUrl: _highResolutionArtwork(_string(item['image'])),
      durationMs: durationSeconds * 1000,
    );
  }

  static Uri _uri(Map<String, String> operation) => Uri.parse(_api).replace(
    queryParameters: {
      '_format': 'json',
      '_marker': '0',
      'ctx': 'web6dot0',
      'api_version': '4',
      ...operation,
    },
  );

  static Future<Map<String, dynamic>> _httpGetJson(Uri uri) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(uri);
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/json')
        ..set(
          HttpHeaders.userAgentHeader,
          'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/124 Mobile Safari/537.36',
        );
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw TransferHttpException(
          response.statusCode,
          message: 'JioSaavn returned HTTP ${response.statusCode}.',
          uri: uri,
        );
      }
      final body = await utf8.decoder.bind(response).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        throw const FormatException('JioSaavn returned an invalid response.');
      }
      return Map<String, dynamic>.from(decoded);
    } finally {
      client.close(force: true);
    }
  }
}

/// Anonymous YouTube Music search and audio playback provider.
///
/// The web music client is used for discovery and the Android player client
/// for playback. URLs are deliberately resolved at play time because YouTube
/// signs them with an expiry timestamp.
class YouTubeMusicProvider implements MusicProvider {
  bool preferLowBitrate = false;
  YouTubeMusicProvider({ProviderJsonPoster? postJson})
    : _postJson = postJson ?? _httpPostJson;

  static const _apiKey = 'AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30';
  static const _webClientVersion = '1.20260222.01.00';
  static const _webUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 Chrome/129.0.0.0 Safari/537.36';
  static const _trackSearchParams = 'EgWKAQIIAWoMEA4QChADEAQQCRAF';

  final ProviderJsonPoster _postJson;

  @override
  String get id => 'ytmusic';

  @override
  String get displayName => 'YouTube Music';

  @override
  Map<String, String> playbackHeaders(Song song) => const {};

  @override
  Future<List<Song>> loadFeatured({int limit = 20, int page = 1}) async {
    final data = await _postJson(
      Uri.parse(
        'https://music.youtube.com/youtubei/v1/browse'
        '?alt=json&key=$_apiKey',
      ),
      {
        'context': {
          'client': {
            'clientName': 'WEB_REMIX',
            'clientVersion': _webClientVersion,
            'hl': 'en',
            'gl': 'IN',
          },
          'user': <String, dynamic>{},
        },
        'browseId': 'FEmusic_home',
      },
      const {
        HttpHeaders.userAgentHeader: _webUserAgent,
        'Origin': 'https://music.youtube.com',
        'Referer': 'https://music.youtube.com/',
      },
    );
    final responsive = <Map<String, dynamic>>[];
    final twoRow = <Map<String, dynamic>>[];
    _collectNamedMaps(data, 'musicResponsiveListItemRenderer', responsive);
    _collectNamedMaps(data, 'musicTwoRowItemRenderer', twoRow);
    final seen = <String>{};
    final results = <Song>[];
    for (final renderer in [...responsive, ...twoRow]) {
      final song = renderer.containsKey('flexColumns')
          ? _songFromRenderer(renderer)
          : _songFromTwoRow(renderer);
      if (song != null && seen.add(song.sourceId)) results.add(song);
      if (results.length >= limit.clamp(1, 50)) break;
    }
    // Anonymous home responses sometimes contain only album/playlist cards.
    // Fall back to a regional chart query so the browse tab still opens with
    // immediately playable tracks rather than an empty screen.
    return results.isEmpty
        ? searchSongs('Top songs India', limit: limit, page: page)
        : results;
  }

  final Map<String, String> _continuations = {};

  @override
  Future<List<Song>> searchSongs(
    String query, {
    int limit = 20,
    int page = 1,
  }) async {
    final value = query.trim();
    if (value.isEmpty) return const [];

    final cacheKey = '$value:$page';
    final token = page > 1 ? _continuations[cacheKey] : null;
    if (page > 1 && token == null) return const [];

    final Uri searchUri;
    final Map<String, dynamic> payload;

    if (token != null && token.isNotEmpty) {
      searchUri = Uri.parse(
        'https://music.youtube.com/youtubei/v1/search'
        '?continuation=$token&alt=json&key=$_apiKey',
      );
      payload = {
        'context': {
          'client': {
            'clientName': 'WEB_REMIX',
            'clientVersion': _webClientVersion,
            'hl': 'en',
            'gl': 'IN',
          },
          'user': <String, dynamic>{},
        },
      };
    } else {
      searchUri = Uri.parse(
        'https://music.youtube.com/youtubei/v1/search'
        '?alt=json&key=$_apiKey',
      );
      payload = {
        'context': {
          'client': {
            'clientName': 'WEB_REMIX',
            'clientVersion': _webClientVersion,
            'hl': 'en',
            'gl': 'IN',
          },
          'user': <String, dynamic>{},
        },
        'query': value,
        'params': _trackSearchParams,
      };
    }

    final data = await _postJson(searchUri, payload, const {
      HttpHeaders.userAgentHeader: _webUserAgent,
      'Origin': 'https://music.youtube.com',
      'Referer': 'https://music.youtube.com/',
    });

    final nextToken = _extractContinuationToken(data);
    if (nextToken != null && nextToken.isNotEmpty) {
      _continuations['$value:${page + 1}'] = nextToken;
    }

    final renderers = <Map<String, dynamic>>[];
    _collectNamedMaps(data, 'musicResponsiveListItemRenderer', renderers);
    final seen = <String>{};
    final results = <Song>[];
    for (final renderer in renderers) {
      final song = _songFromRenderer(renderer);
      if (song != null && seen.add(song.sourceId)) results.add(song);
      if (results.length >= limit.clamp(1, 50)) break;
    }
    return results;
  }

  String? _extractContinuationToken(dynamic data) {
    final commands = <Map<String, dynamic>>[];
    _collectNamedMaps(data, 'continuationCommand', commands);
    if (commands.isNotEmpty && commands.first['token'] is String) {
      return commands.first['token'] as String;
    }
    try {
      final jsonStr = jsonEncode(data);
      final match = RegExp(r'"continuation":\s*"([^"]+)"').firstMatch(jsonStr);
      return match?.group(1);
    } catch (_) {
      return null;
    }
  }

  /// YouTube withholds full-length audio-only streams from anonymous clients
  /// (reads past the first megabyte return 403 without a proof-of-origin
  /// token), so the muxed MP4 is used and just_audio plays its AAC track.
  @override
  Future<String> resolveStreamUrl(Song song) async {
    if (song.providerId != id || song.sourceId.isEmpty) {
      throw const FormatException(
        'This song does not belong to YouTube Music.',
      );
    }
    return _resolveYouTubeMuxedStream(
      _postJson,
      song.sourceId,
      lowBitrate: preferLowBitrate,
    );
  }

  Song? _songFromRenderer(Map<String, dynamic> renderer) {
    final sourceId = _findFirstString(renderer, 'videoId');
    final columns = renderer['flexColumns'];
    if (sourceId == null || columns is! List || columns.isEmpty) return null;

    Map<String, dynamic>? columnRenderer(int index) {
      if (index >= columns.length || columns[index] is! Map) return null;
      final column = Map<String, dynamic>.from(columns[index] as Map);
      return _map(column['musicResponsiveListItemFlexColumnRenderer']);
    }

    final title = _text(columnRenderer(0)?['text']);
    if (title.isEmpty) return null;
    final subtitle = columnRenderer(1)?['text'];
    final runs = _map(subtitle)?['runs'];
    final artists = <String>[];
    final runTexts = <String>[];
    var durationMs = 0;
    if (runs is List) {
      for (final raw in runs.whereType<Map>()) {
        final run = Map<String, dynamic>.from(raw);
        final text = _string(run['text']);
        if (text.isEmpty) continue;
        runTexts.add(text);
        final browseId = _string(
          _at(run, ['navigationEndpoint', 'browseEndpoint', 'browseId']),
        );
        if (browseId.startsWith('UC')) artists.add(text);
        final parsedDuration = _durationMs(text);
        if (parsedDuration != null) durationMs = parsedDuration;
      }
    }
    if (artists.isEmpty && runTexts.isNotEmpty) {
      final beforeAlbum = runTexts.takeWhile((text) => text != ' • ');
      artists.addAll(
        beforeAlbum.where(
          (text) => text != ' & ' && text != ', ' && text.trim().isNotEmpty,
        ),
      );
    }

    return Song(
      id: 'provider:$id:$sourceId',
      title: title,
      kind: 'audio',
      url: '',
      categoryId: 'provider:$id',
      providerId: id,
      sourceId: sourceId,
      artist: artists.toSet().join(', '),
      artworkUrl: _largestThumbnail(renderer),
      durationMs: durationMs,
    );
  }

  Song? _songFromTwoRow(Map<String, dynamic> renderer) {
    final sourceId = _findFirstString(renderer, 'videoId');
    final title = _text(renderer['title']);
    if (sourceId == null || title.isEmpty) return null;
    final subtitle = _map(renderer['subtitle']);
    final runs = subtitle?['runs'];
    final artists = <String>[];
    if (runs is List) {
      for (final raw in runs.whereType<Map>()) {
        final run = Map<String, dynamic>.from(raw);
        final browseId = _string(
          _at(run, ['navigationEndpoint', 'browseEndpoint', 'browseId']),
        );
        if (browseId.startsWith('UC')) {
          final name = _string(run['text']);
          if (name.isNotEmpty) artists.add(name);
        }
      }
    }
    if (artists.isEmpty) {
      final first = _text(renderer['subtitle']).split(' • ').first.trim();
      if (first.isNotEmpty && first != 'Song' && first != 'Video') {
        artists.add(first);
      }
    }
    return Song(
      id: 'provider:$id:$sourceId',
      title: title,
      kind: 'audio',
      url: '',
      categoryId: 'provider:$id',
      providerId: id,
      sourceId: sourceId,
      artist: artists.toSet().join(', '),
      artworkUrl: _largestThumbnail(renderer),
    );
  }

  @override
  Future<List<Song>> loadRadio(String sourceId, {int limit = 25}) async {
    final videoId = sourceId.trim();
    if (videoId.isEmpty) return const [];
    try {
      final data = await _postJson(
        Uri.parse(
          'https://music.youtube.com/youtubei/v1/next'
          '?alt=json&key=$_apiKey',
        ),
        {
          'context': {
            'client': {
              'clientName': 'WEB_REMIX',
              'clientVersion': _webClientVersion,
              'hl': 'en',
              'gl': 'IN',
            },
            'user': <String, dynamic>{},
          },
          'videoId': videoId,
          'playlistId': 'RDAMVM$videoId',
        },
        const {
          HttpHeaders.userAgentHeader: _webUserAgent,
          'Origin': 'https://music.youtube.com',
          'Referer': 'https://music.youtube.com/',
        },
      );

      final renderers = <Map<String, dynamic>>[];
      _collectNamedMaps(data, 'playlistPanelVideoRenderer', renderers);
      final seen = <String>{};
      final results = <Song>[];
      for (final renderer in renderers) {
        final song = _songFromPlaylistPanel(renderer);
        if (song != null && seen.add(song.sourceId)) {
          results.add(song);
        }
        if (results.length >= limit.clamp(1, 50)) break;
      }
      return results;
    } catch (e) {
      debugPrint('YouTube Music loadRadio error: $e');
      return const [];
    }
  }

  Song? _songFromPlaylistPanel(Map<String, dynamic> renderer) {
    final sourceId = _string(renderer['videoId']);
    if (sourceId.isEmpty) return null;

    final title = _text(renderer['title']);
    if (title.isEmpty) return null;

    final byline = renderer['longBylineText'] ?? renderer['shortBylineText'];
    final runs = _map(byline)?['runs'];
    final artists = <String>[];
    var album = '', albumId = '';
    if (runs is List) {
      for (final raw in runs.whereType<Map>()) {
        final text = _string(raw['text']).trim();
        final browseId = _string(
          _at(Map<String, dynamic>.from(raw), [
            'navigationEndpoint',
            'browseEndpoint',
            'browseId',
          ]),
        );
        if (browseId.startsWith('UC') && text.isNotEmpty) artists.add(text);
        if (browseId.startsWith('MPRE') && text.isNotEmpty) {
          album = text;
          albumId = browseId;
        }
      }
    }
    if (artists.isEmpty) {
      final first = _text(byline).split('•').first.trim();
      if (first.isNotEmpty) artists.add(first);
    }

    final durationMs = _durationMs(_text(renderer['lengthText'])) ?? 0;

    return Song(
      id: 'provider:$id:$sourceId',
      title: title,
      kind: 'audio',
      url: '',
      categoryId: 'provider:$id',
      providerId: id,
      sourceId: sourceId,
      artist: artists.toSet().join(', '),
      album: album,
      albumId: albumId,
      artworkUrl: _largestThumbnail(renderer),
      durationMs: durationMs,
    );
  }

  static Future<Map<String, dynamic>> _httpPostJson(
    Uri uri,
    Map<String, dynamic> body,
    Map<String, String> headers,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      for (final entry in headers.entries) {
        request.headers.set(entry.key, entry.value);
      }
      request.write(jsonEncode(body));
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw TransferHttpException(
          response.statusCode,
          message: 'YouTube Music returned HTTP ${response.statusCode}.',
          uri: uri,
        );
      }
      final decoded = jsonDecode(await utf8.decoder.bind(response).join());
      if (decoded is! Map) {
        throw const FormatException(
          'YouTube Music returned an invalid response.',
        );
      }
      return Map<String, dynamic>.from(decoded);
    } finally {
      client.close(force: true);
    }
  }
}

/// Standard YouTube video search with a directly playable muxed MP4 stream.
class YouTubeVideoProvider implements MusicProvider {
  YouTubeVideoProvider({ProviderJsonPoster? postJson})
    : _postJson = postJson ?? YouTubeMusicProvider._httpPostJson;

  static const _apiKey = 'AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30';
  static const _webClientVersion = '2.20260222.01.00';
  static const _webUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 Chrome/129.0.0.0 Safari/537.36';

  final ProviderJsonPoster _postJson;

  @override
  String get id => 'ytvideo';

  @override
  String get displayName => 'YouTube Videos';

  @override
  Map<String, String> playbackHeaders(Song song) => const {
    'User-Agent': _youtubeAndroidUserAgent,
  };

  @override
  Future<List<Song>> loadFeatured({int limit = 20, int page = 1}) async {
    final data = await _postJson(
      Uri.parse(
        'https://www.youtube.com/youtubei/v1/browse'
        '?alt=json&key=$_apiKey',
      ),
      {
        'context': {
          'client': {
            'clientName': 'WEB',
            'clientVersion': _webClientVersion,
            'hl': 'en',
            'gl': 'IN',
          },
          'user': <String, dynamic>{},
        },
        'browseId': 'UC-9-kyTW8ZkZNDHQJ6FgpwQ',
      },
      const {
        HttpHeaders.userAgentHeader: _webUserAgent,
        'Origin': 'https://www.youtube.com',
        'Referer': 'https://www.youtube.com/',
      },
    );
    final lockups = <Map<String, dynamic>>[];
    _collectNamedMaps(data, 'lockupViewModel', lockups);
    final seen = <String>{};
    final results = <Song>[];
    for (final lockup in lockups) {
      final song = _songFromLockup(lockup);
      if (song != null && seen.add(song.sourceId)) results.add(song);
      if (results.length >= limit.clamp(1, 50)) break;
    }
    return results;
  }

  final Map<String, String> _continuations = {};

  @override
  Future<List<Song>> searchSongs(
    String query, {
    int limit = 20,
    int page = 1,
  }) async {
    final value = query.trim();
    if (value.isEmpty) return const [];

    final cacheKey = '$value:$page';
    final token = page > 1 ? _continuations[cacheKey] : null;
    if (page > 1 && token == null) return const [];

    final Uri searchUri;
    final Map<String, dynamic> payload;

    if (token != null && token.isNotEmpty) {
      searchUri = Uri.parse(
        'https://www.youtube.com/youtubei/v1/search'
        '?continuation=$token&alt=json&key=$_apiKey',
      );
      payload = {
        'context': {
          'client': {
            'clientName': 'WEB',
            'clientVersion': _webClientVersion,
            'hl': 'en',
            'gl': 'IN',
          },
          'user': <String, dynamic>{},
        },
      };
    } else {
      searchUri = Uri.parse(
        'https://www.youtube.com/youtubei/v1/search'
        '?alt=json&key=$_apiKey',
      );
      payload = {
        'context': {
          'client': {
            'clientName': 'WEB',
            'clientVersion': _webClientVersion,
            'hl': 'en',
            'gl': 'IN',
          },
          'user': <String, dynamic>{},
        },
        'query': value,
        'params': 'EgIQAQ%3D%3D',
      };
    }

    final data = await _postJson(searchUri, payload, const {
      HttpHeaders.userAgentHeader: _webUserAgent,
      'Origin': 'https://www.youtube.com',
      'Referer': 'https://www.youtube.com/',
    });

    final nextToken = _extractVideoContinuationToken(data);
    if (nextToken != null && nextToken.isNotEmpty) {
      _continuations['$value:${page + 1}'] = nextToken;
    }

    final renderers = <Map<String, dynamic>>[];
    _collectNamedMaps(data, 'videoRenderer', renderers);
    final seen = <String>{};
    final results = <Song>[];
    for (final renderer in renderers) {
      final sourceId = _string(renderer['videoId']);
      final title = _text(renderer['title']);
      if (sourceId.isEmpty || title.isEmpty || !seen.add(sourceId)) continue;
      final artist = _text(renderer['ownerText']).isNotEmpty
          ? _text(renderer['ownerText'])
          : _text(renderer['shortBylineText']);
      results.add(
        Song(
          id: 'provider:$id:$sourceId',
          title: title,
          kind: 'video',
          url: '',
          categoryId: 'provider:$id',
          providerId: id,
          sourceId: sourceId,
          artist: artist,
          artworkUrl: _largestThumbnail(renderer),
          durationMs: _durationMs(_text(renderer['lengthText'])) ?? 0,
        ),
      );
      if (results.length >= limit.clamp(1, 50)) break;
    }
    return results;
  }

  String? _extractVideoContinuationToken(dynamic data) {
    final commands = <Map<String, dynamic>>[];
    _collectNamedMaps(data, 'continuationCommand', commands);
    if (commands.isNotEmpty && commands.first['token'] is String) {
      return commands.first['token'] as String;
    }
    try {
      final jsonStr = jsonEncode(data);
      final match = RegExp(r'"token":\s*"([^"]+)"').firstMatch(jsonStr);
      return match?.group(1);
    } catch (_) {
      return null;
    }
  }

  Song? _songFromLockup(Map<String, dynamic> renderer) {
    if (_string(renderer['contentType']) != 'LOCKUP_CONTENT_TYPE_VIDEO') {
      return null;
    }
    final sourceId = _string(renderer['contentId']);
    final metadata = _map(renderer['metadata']);
    final lockupMetadata = _map(metadata?['lockupMetadataViewModel']);
    final title = _string(_map(lockupMetadata?['title'])?['content']);
    if (sourceId.isEmpty || title.isEmpty) return null;

    var artist = '';
    final detail = _map(lockupMetadata?['metadata']);
    final contentMetadata = _map(detail?['contentMetadataViewModel']);
    final rows = contentMetadata?['metadataRows'];
    if (rows is List && rows.isNotEmpty && rows.first is Map) {
      final firstRow = Map<String, dynamic>.from(rows.first as Map);
      final parts = firstRow['metadataParts'];
      if (parts is List && parts.isNotEmpty && parts.first is Map) {
        final firstPart = Map<String, dynamic>.from(parts.first as Map);
        artist = _string(_map(firstPart['text'])?['content']);
      }
    }
    final durationText = _findFirstDuration(renderer);
    return Song(
      id: 'provider:$id:$sourceId',
      title: title,
      kind: 'video',
      url: '',
      categoryId: 'provider:$id',
      providerId: id,
      sourceId: sourceId,
      artist: artist,
      artworkUrl: _largestThumbnail(renderer),
      durationMs: durationText == null ? 0 : _durationMs(durationText) ?? 0,
    );
  }

  @override
  Future<String> resolveStreamUrl(Song song) async {
    if (song.providerId != id || song.sourceId.isEmpty) {
      throw const FormatException(
        'This video does not belong to YouTube Videos.',
      );
    }
    return _resolveYouTubeMuxedStream(_postJson, song.sourceId);
  }

  @override
  Future<List<Song>> loadRadio(String sourceId, {int limit = 25}) async {
    return YouTubeMusicProvider(
      postJson: _postJson,
    ).loadRadio(sourceId, limit: limit);
  }
}

const _youtubeAndroidClientVersion = '21.26.364';
const _youtubeAndroidUserAgent =
    'com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip';

/// Resolves the highest-bitrate MP4 stream carrying both video and AAC audio
/// through the Android player client. It is the only full-length stream
/// YouTube serves to anonymous clients, and needs no signature deciphering.
Future<String> _resolveYouTubeMuxedStream(
  ProviderJsonPoster postJson,
  String videoId, {
  bool lowBitrate = false,
}) async {
  final data = await postJson(
    Uri.parse('https://www.youtube.com/youtubei/v1/player?prettyPrint=false'),
    {
      'context': {
        'client': {
          'clientName': 'ANDROID',
          'clientVersion': _youtubeAndroidClientVersion,
          'androidSdkVersion': 30,
          'userAgent': _youtubeAndroidUserAgent,
          'hl': 'en',
          'platform': 'MOBILE',
          'osName': 'Android',
          'osVersion': '11',
          'timeZone': 'Asia/Calcutta',
          'gl': 'IN',
          'utcOffsetMinutes': 330,
        },
      },
      'videoId': videoId,
      'playbackContext': {
        'contentPlaybackContext': {'html5Preference': 'HTML5_PREF_WANTS'},
      },
      'contentCheckOk': true,
      'racyCheckOk': true,
    },
    const {
      HttpHeaders.userAgentHeader: _youtubeAndroidUserAgent,
      'Origin': 'https://www.youtube.com',
      'X-YouTube-Client-Name': '3',
      'X-YouTube-Client-Version': _youtubeAndroidClientVersion,
    },
  );

  final status = _string(_at(data, ['playabilityStatus', 'status']));
  if (status != 'OK') {
    final reason = _string(_at(data, ['playabilityStatus', 'reason']));
    throw FormatException(reason.isEmpty ? 'This is not playable.' : reason);
  }
  final formats = _at(data, ['streamingData', 'formats']);
  if (formats is! List) {
    throw const FormatException('No playable stream is available.');
  }
  final muxed =
      formats
          .whereType<Map>()
          .map((value) => Map<String, dynamic>.from(value))
          .where(
            (format) =>
                _string(format['mimeType']).startsWith('video/') &&
                _string(format['mimeType']).contains('mp4a') &&
                _string(format['url']).isNotEmpty,
          )
          .toList()
        ..sort(
          (a, b) => ((b['bitrate'] as num?)?.toInt() ?? 0).compareTo(
            (a['bitrate'] as num?)?.toInt() ?? 0,
          ),
        );
  if (muxed.isEmpty) {
    throw const FormatException('No compatible stream is available.');
  }
  return _string((lowBitrate ? muxed.last : muxed.first)['url']);
}

void _collectNamedMaps(
  Object? value,
  String key,
  List<Map<String, dynamic>> output,
) {
  if (value is Map) {
    final map = Map<String, dynamic>.from(value);
    final match = map[key];
    if (match is Map) output.add(Map<String, dynamic>.from(match));
    for (final child in map.values) {
      _collectNamedMaps(child, key, output);
    }
  } else if (value is List) {
    for (final child in value) {
      _collectNamedMaps(child, key, output);
    }
  }
}

String? _findFirstString(Object? value, String key) {
  if (value is Map) {
    final direct = value[key];
    if (direct is String && direct.isNotEmpty) return direct;
    for (final child in value.values) {
      final found = _findFirstString(child, key);
      if (found != null) return found;
    }
  } else if (value is List) {
    for (final child in value) {
      final found = _findFirstString(child, key);
      if (found != null) return found;
    }
  }
  return null;
}

Object? _at(Map<String, dynamic> root, List<String> path) {
  Object? value = root;
  for (final key in path) {
    if (value is! Map) return null;
    value = value[key];
  }
  return value;
}

String _text(Object? value) {
  if (value is! Map) return '';
  final simple = _string(value['simpleText']);
  if (simple.isNotEmpty) return simple;
  final runs = value['runs'];
  if (runs is! List) return '';
  return runs
      .whereType<Map>()
      .map((run) => _string(run['text']))
      .where((text) => text.isNotEmpty)
      .join();
}

int? _durationMs(String value) {
  if (!RegExp(r'^\d{1,2}:\d{2}(?::\d{2})?$').hasMatch(value.trim())) {
    return null;
  }
  final parts = value.trim().split(':').map(int.parse).toList();
  final seconds = parts.length == 3
      ? parts[0] * 3600 + parts[1] * 60 + parts[2]
      : parts[0] * 60 + parts[1];
  return seconds * 1000;
}

String? _findFirstDuration(Object? value) {
  if (value is String &&
      RegExp(r'^\d{1,2}:\d{2}(?::\d{2})?$').hasMatch(value.trim())) {
    return value.trim();
  }
  if (value is Map) {
    for (final child in value.values) {
      final found = _findFirstDuration(child);
      if (found != null) return found;
    }
  } else if (value is List) {
    for (final child in value) {
      final found = _findFirstDuration(child);
      if (found != null) return found;
    }
  }
  return null;
}

String _largestThumbnail(Object? root) {
  String best = '';
  var bestWidth = -1;

  void visit(Object? value) {
    if (value is Map) {
      for (final images in [value['thumbnails'], value['sources']]) {
        if (images is! List) continue;
        for (final raw in images.whereType<Map>()) {
          final url = _string(raw['url']);
          final width = (raw['width'] as num?)?.toInt() ?? 0;
          if (url.isNotEmpty && width >= bestWidth) {
            best = url.startsWith('//') ? 'https:$url' : url;
            bestWidth = width;
          }
        }
      }
      for (final child in value.values) {
        visit(child);
      }
    } else if (value is List) {
      for (final child in value) {
        visit(child);
      }
    }
  }

  visit(root);
  return best;
}

/// Decodes the DES-ECB media address returned by JioSaavn.
String decodeJioSaavnMediaUrl(String encryptedUrl) {
  final encrypted = base64Decode(encryptedUrl.trim());
  if (encrypted.isEmpty || encrypted.length % 8 != 0) {
    throw const FormatException('Invalid encrypted media URL.');
  }

  // DES-EDE with K1=K2=K3 is mathematically equivalent to single DES. This
  // lets us use PointyCastle's maintained DESede primitive for the legacy URL
  // format without implementing cryptography in the app.
  final key = utf8.encode('38346591');
  final repeatedKey = Uint8List.fromList([...key, ...key, ...key]);
  final cipher = DESedeEngine()..init(false, KeyParameter(repeatedKey));
  final decrypted = Uint8List(encrypted.length);
  for (var offset = 0; offset < encrypted.length; offset += cipher.blockSize) {
    cipher.processBlock(encrypted, offset, decrypted, offset);
  }

  var length = decrypted.length;
  final padding = decrypted.last;
  if (padding > 0 && padding <= 8 && padding <= length) {
    final valid = decrypted
        .sublist(length - padding)
        .every((value) => value == padding);
    if (valid) length -= padding;
  }
  var url = utf8.decode(decrypted.sublist(0, length));
  url = url.replaceFirst(RegExp(r'\.mp4.*$'), '.mp4');
  url = url.replaceFirst(RegExp(r'\.m4a.*$'), '.m4a');
  return url.replaceFirst(RegExp(r'^http:'), 'https:');
}

String _withQuality(String url, String quality) =>
    url.replaceFirst(RegExp(r'_(?:96|160|320)\.'), '_$quality.');

String _highResolutionArtwork(String url) =>
    url.replaceFirst('50x50', '500x500').replaceFirst('150x150', '500x500');

Map<String, dynamic>? _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : null;

String _string(Object? value) => value?.toString().trim() ?? '';

/// Decodes the small HTML entity subset used in JioSaavn metadata.
String decodeHtmlText(Object? value) {
  var text = _string(value);
  text = text.replaceAllMapped(RegExp(r'&#(x?[0-9a-fA-F]+);'), (match) {
    final raw = match.group(1)!;
    final radix = raw.startsWith('x') || raw.startsWith('X') ? 16 : 10;
    final digits = radix == 16 ? raw.substring(1) : raw;
    final code = int.tryParse(digits, radix: radix);
    return code == null ? match.group(0)! : String.fromCharCode(code);
  });
  const entities = {
    '&amp;': '&',
    '&quot;': '"',
    '&#39;': "'",
    '&apos;': "'",
    '&lt;': '<',
    '&gt;': '>',
    '&nbsp;': ' ',
  };
  for (final entry in entities.entries) {
    text = text.replaceAll(entry.key, entry.value);
  }
  return text.trim();
}

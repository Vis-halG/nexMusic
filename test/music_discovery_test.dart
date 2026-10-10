import 'package:flutter_test/flutter_test.dart';
import 'package:nex_music/music_data.dart';
import 'package:nex_music/music_discovery.dart';
import 'package:nex_music/music_provider.dart';

Song track(
  String provider,
  String id, {
  String? title,
  String kind = 'audio',
}) => Song(
  id: '$provider:$id',
  providerId: provider,
  sourceId: id,
  title: title ?? id,
  artist: 'Artist',
  kind: kind,
  url: '',
);

class FakeMusicProvider implements MusicProvider {
  FakeMusicProvider(this.id, this.songs, {this.fail = false});
  @override
  final String id;
  final List<Song> songs;
  bool fail;
  int calls = 0;
  String? radioSeed;
  @override
  String get displayName => id;
  @override
  Future<List<Song>> loadFeatured({int limit = 20, int page = 1}) async {
    calls++;
    if (fail) throw StateError('offline');
    return songs.take(limit).toList();
  }

  @override
  Future<List<Song>> searchSongs(
    String query, {
    int limit = 20,
    int page = 1,
  }) => loadFeatured(limit: limit, page: page);
  @override
  Future<List<Song>> loadRadio(String sourceId, {int limit = 25}) async {
    radioSeed = sourceId;
    if (fail) throw StateError('offline');
    return songs;
  }

  @override
  Map<String, String> playbackHeaders(Song song) => {};
  @override
  Future<String> resolveStreamUrl(Song song) async =>
      'https://example.com/audio.mp3';
}

void main() {
  test(
    'balances providers and removes duplicate recordings without dropping videos',
    () {
      final merged = mergeMusicResults([
        [track('jiosaavn', 'one'), track('jiosaavn', 'two')],
        [
          track('ytmusic', 'three'),
          track('ytmusic', 'duplicate', title: 'one'),
          track('ytvideo', 'video', title: 'one', kind: 'video'),
        ],
      ]);
      expect(merged.map((s) => s.id), [
        'jiosaavn:one',
        'ytmusic:three',
        'jiosaavn:two',
        'ytvideo:video',
      ]);
    },
  );
  test(
    'one unavailable provider preserves the other results and reports the failure',
    () async {
      final jio = FakeMusicProvider('jiosaavn', [], fail: true);
      final youtube = FakeMusicProvider('ytmusic', [track('ytmusic', 'ok')]);
      final discovery = MusicDiscovery([jio, youtube]);
      final result = await discovery.browse();
      expect(result.songs.single.sourceId, 'ok');
      expect(result.unavailable, ['jiosaavn']);
      jio.fail = false;
      await discovery.browse();
      expect(jio.calls, 2); // failed responses are not cached
      expect(youtube.calls, 1);
    },
  );
  test('videos never leak into the merged songs feed', () async {
    final discovery = MusicDiscovery([
      FakeMusicProvider('jiosaavn', [track('jiosaavn', 'audio')]),
      FakeMusicProvider('ytvideo', [track('ytvideo', 'video', kind: 'video')]),
    ]);
    expect((await discovery.browse()).songs.single.isVideo, false);
    expect((await discovery.browse(videos: true)).songs.single.isVideo, true);
  });
  test(
    'radio maps seeds to each provider, excludes seed and mixes recommendations',
    () async {
      final seed = track('jiosaavn', 'seed');
      final jio = FakeMusicProvider('jiosaavn', [
        seed,
        track('jiosaavn', 'jio-radio'),
      ]);
      final yt = FakeMusicProvider('ytmusic', [
        track('ytmusic', 'yt-match', title: 'seed'),
        track('ytmusic', 'yt-radio'),
      ]);
      final songs = await MusicDiscovery([jio, yt]).radio(seed);
      expect(jio.radioSeed, 'seed');
      expect(yt.radioSeed, 'yt-match');
      expect(songs.any((s) => s.id == seed.id), false);
      expect(songs.map((s) => s.providerId).toSet(), {'jiosaavn', 'ytmusic'});
    },
  );
  test(
    'exhausted YouTube pagination does not invent a different search query',
    () async {
      var calls = 0;
      final provider = YouTubeMusicProvider(
        postJson: (_, _, _) async {
          calls++;
          return {};
        },
      );
      await provider.searchSongs('My song');
      expect(await provider.searchSongs('My song', page: 2), isEmpty);
      expect(calls, 1);
    },
  );
  test(
    'JioSaavn radio creates a station from the song rather than returning global trending',
    () async {
      final provider = JioSaavnProvider(
        fetchJson: (uri) async {
          switch (uri.queryParameters['__call']) {
            case 'webradio.createEntityStation':
              expect(uri.queryParameters['entity_id'], '["seed"]');
              return {'stationid': 'station'};
            case 'webradio.getSong':
              expect(uri.queryParameters['stationid'], 'station');
              return {
                '0': {
                  'song': {'id': 'seed', 'title': 'Seed'},
                },
                '1': {
                  'song': {'id': 'similar', 'title': 'Similar'},
                },
              };
            default:
              fail('Unexpected call');
          }
        },
      );
      expect((await provider.loadRadio('seed')).single.sourceId, 'similar');
    },
  );
}

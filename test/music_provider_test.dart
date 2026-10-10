import 'package:flutter_test/flutter_test.dart';
import 'package:nex_music/music_data.dart';
import 'package:nex_music/music_provider.dart';

void main() {
  group('JioSaavnProvider', () {
    test('loads playable songs from the trending feed', () async {
      final provider = JioSaavnProvider(
        fetchJson: (_) async => {
          'new_trending': [
            {'id': 'playlist-1', 'title': 'Mix', 'type': 'playlist'},
            {
              'id': 'track-1',
              'title': 'Trending Song',
              'type': 'song',
              'more_info': {'duration': '180', 'music': 'Singer'},
            },
          ],
        },
      );

      final results = await provider.loadFeatured();

      expect(results, hasLength(1));
      expect(results.single.title, 'Trending Song');
    });

    test('maps search metadata without exposing a stream URL', () async {
      late Uri requested;
      final provider = JioSaavnProvider(
        fetchJson: (uri) async {
          requested = uri;
          return {
            'results': [
              {
                'id': 'track-1',
                'title': 'Rock &amp; Roll',
                'image': 'https://img.example/150x150.jpg',
                'more_info': {
                  'duration': '123',
                  'artistMap': {
                    'primary_artists': [
                      {'name': 'A &amp; B'},
                    ],
                  },
                },
              },
            ],
          };
        },
      );

      final results = await provider.searchSongs('test query');

      expect(requested.queryParameters['__call'], 'search.getResults');
      expect(requested.queryParameters['q'], 'test query');
      expect(results, hasLength(1));
      expect(results.single.id, 'provider:jiosaavn:track-1');
      expect(results.single.title, 'Rock & Roll');
      expect(results.single.artist, 'A & B');
      expect(results.single.artworkUrl, contains('500x500'));
      expect(results.single.durationMs, 123000);
      expect(results.single.url, isEmpty);
      expect(results.single.isProvider, isTrue);
    });

    test('resolves the encrypted URL and selects high quality', () async {
      final provider = JioSaavnProvider(
        fetchJson: (_) async => {
          'songs': [
            {
              'more_info': {
                'encrypted_media_url':
                    'ID2ieOjCrwfgWvL5sXl4B1ImC5QfbsDySan+n+AW12BvOaQj7cuGfg8Ed085rYUtqDj8DQY3nIMQdr42ScGdtRw7tS9a8Gtq',
                '320kbps': 'true',
              },
            },
          ],
        },
      );
      // Use a direct provider item because this fetcher serves the details
      // endpoint in this test.
      const providerSong = _ProviderSong.song;

      expect(
        await provider.resolveStreamUrl(providerSong),
        'https://aac.saavncdn.com/450/f467e05e2825cec2203546333e0d0550_320.mp4',
      );
    });

    test('does not require custom playback headers', () {
      final provider = JioSaavnProvider();

      expect(provider.playbackHeaders(_ProviderSong.song), isEmpty);
    });
  });

  group('YouTubeMusicProvider', () {
    test('loads tracks from the music home feed', () async {
      final provider = YouTubeMusicProvider(
        postJson: (uri, body, headers) async => {
          'musicResponsiveListItemRenderer': {
            'overlay': {
              'watchEndpoint': {'videoId': 'home-track'},
            },
            'flexColumns': [
              {
                'musicResponsiveListItemFlexColumnRenderer': {
                  'text': {
                    'runs': [
                      {'text': 'Home Track'},
                    ],
                  },
                },
              },
              {
                'musicResponsiveListItemFlexColumnRenderer': {
                  'text': {
                    'runs': [
                      {
                        'text': 'Home Artist',
                        'navigationEndpoint': {
                          'browseEndpoint': {'browseId': 'UC-home'},
                        },
                      },
                    ],
                  },
                },
              },
            ],
          },
        },
      );

      final results = await provider.loadFeatured();

      expect(results.single.title, 'Home Track');
      expect(results.single.artist, 'Home Artist');
    });

    test('maps track search results', () async {
      late Uri requested;
      late Map<String, dynamic> requestBody;
      final provider = YouTubeMusicProvider(
        postJson: (uri, body, headers) async {
          requested = uri;
          requestBody = body;
          expect(headers['Origin'], 'https://music.youtube.com');
          return {
            'contents': {
              'sectionListRenderer': {
                'contents': [
                  {
                    'musicShelfRenderer': {
                      'contents': [
                        {
                          'musicResponsiveListItemRenderer': {
                            'thumbnail': {
                              'musicThumbnailRenderer': {
                                'thumbnail': {
                                  'thumbnails': [
                                    {
                                      'url': 'https://img.example/120.jpg',
                                      'width': 120,
                                    },
                                    {
                                      'url': 'https://img.example/500.jpg',
                                      'width': 500,
                                    },
                                  ],
                                },
                              },
                            },
                            'overlay': {
                              'watchEndpoint': {'videoId': 'video-1'},
                            },
                            'flexColumns': [
                              {
                                'musicResponsiveListItemFlexColumnRenderer': {
                                  'text': {
                                    'runs': [
                                      {'text': 'Test Track'},
                                    ],
                                  },
                                },
                              },
                              {
                                'musicResponsiveListItemFlexColumnRenderer': {
                                  'text': {
                                    'runs': [
                                      {
                                        'text': 'Singer One',
                                        'navigationEndpoint': {
                                          'browseEndpoint': {
                                            'browseId': 'UC-singer',
                                          },
                                        },
                                      },
                                      {'text': ' • '},
                                      {'text': '3:45'},
                                    ],
                                  },
                                },
                              },
                            ],
                          },
                        },
                      ],
                    },
                  },
                ],
              },
            },
          };
        },
      );

      final results = await provider.searchSongs('test track');

      expect(requested.path, contains('/youtubei/v1/search'));
      expect(requestBody['query'], 'test track');
      expect(results, hasLength(1));
      expect(results.single.id, 'provider:ytmusic:video-1');
      expect(results.single.artist, 'Singer One');
      expect(results.single.artworkUrl, endsWith('/500.jpg'));
      expect(results.single.durationMs, 225000);
    });

    test('plays the full-length stream that carries AAC audio', () async {
      final provider = YouTubeMusicProvider(
        postJson: (uri, body, headers) async {
          expect(uri.path, contains('/youtubei/v1/player'));
          expect(body['videoId'], 'video-1');
          expect(headers['X-YouTube-Client-Name'], '3');
          return {
            'playabilityStatus': {'status': 'OK'},
            'streamingData': {
              'formats': [
                {
                  'mimeType': 'video/mp4; codecs="avc1.42001E, mp4a.40.2"',
                  'bitrate': 440000,
                  'url': 'https://media.example/with-audio.mp4',
                },
              ],
              // Anonymous audio-only URLs stop after the first megabyte.
              'adaptiveFormats': [
                {
                  'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
                  'bitrate': 130000,
                  'url': 'https://media.example/audio-only.m4a',
                },
              ],
            },
          };
        },
      );

      expect(
        await provider.resolveStreamUrl(_ProviderSong.youtubeSong),
        'https://media.example/with-audio.mp4',
      );
    });

    test('reports why YouTube refused a track', () async {
      final provider = YouTubeMusicProvider(
        postJson: (uri, body, headers) async => {
          'playabilityStatus': {
            'status': 'UNPLAYABLE',
            'reason': 'Video unavailable',
          },
        },
      );

      expect(
        provider.resolveStreamUrl(_ProviderSong.youtubeSong),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Video unavailable',
          ),
        ),
      );
    });

    test('streams without custom playback headers', () {
      final provider = YouTubeMusicProvider();

      expect(provider.playbackHeaders(_ProviderSong.youtubeSong), isEmpty);
    });

    test('loads radio recommendations from youtubei next', () async {
      late Uri requested;
      late Map<String, dynamic> sentBody;
      final provider = YouTubeMusicProvider(
        postJson: (uri, body, headers) async {
          requested = uri;
          sentBody = body;
          return {
            'contents': {
              'singleColumnMusicWatchNextResultsRenderer': {
                'tabbedRenderer': {
                  'watchNextTabbedResultsRenderer': {
                    'tabs': [
                      {
                        'tabRenderer': {
                          'content': {
                            'musicQueueRenderer': {
                              'content': {
                                'playlistPanelRenderer': {
                                  'contents': [
                                    {
                                      'playlistPanelVideoRenderer': {
                                        'videoId': 'radio-1',
                                        'title': {
                                          'runs': [
                                            {'text': 'Recommended Track 1'},
                                          ],
                                        },
                                        'longBylineText': {
                                          'runs': [
                                            {'text': 'Artist 1'},
                                          ],
                                        },
                                        'thumbnail': {
                                          'thumbnails': [
                                            {
                                              'url':
                                                  'https://img.example/radio-1.jpg',
                                              'width': 544,
                                            },
                                          ],
                                        },
                                        'lengthText': {
                                          'runs': [
                                            {'text': '3:15'},
                                          ],
                                        },
                                      },
                                    },
                                  ],
                                },
                              },
                            },
                          },
                        },
                      },
                    ],
                  },
                },
              },
            },
          };
        },
      );

      final results = await provider.loadRadio('track-seed');

      expect(requested.path, endsWith('/next'));
      expect(sentBody['videoId'], 'track-seed');
      expect(sentBody['playlistId'], 'RDAMVMtrack-seed');
      expect(results, hasLength(1));
      expect(results.first.id, 'provider:ytmusic:radio-1');
      expect(results.first.title, 'Recommended Track 1');
      expect(results.first.artist, 'Artist 1');
      expect(results.first.durationMs, 195000);
    });

    test('radio metadata separates album names from artists', () async {
      final provider = YouTubeMusicProvider(
        postJson: (_, _, _) async => {
          'playlistPanelVideoRenderer': {
            'videoId': 'one',
            'title': {'simpleText': 'Song'},
            'longBylineText': {
              'runs': [
                {
                  'text': 'Arijit Singh',
                  'navigationEndpoint': {
                    'browseEndpoint': {'browseId': 'UCartist'},
                  },
                },
                {'text': ' • '},
                {
                  'text': 'Movie Album',
                  'navigationEndpoint': {
                    'browseEndpoint': {'browseId': 'MPREalbum'},
                  },
                },
              ],
            },
            'lengthText': {'simpleText': '3:30'},
          },
        },
      );
      final songs = await provider.loadRadio('seed');
      expect(songs.single.artist, 'Arijit Singh');
      expect(songs.single.album, 'Movie Album');
      expect(songs.single.durationMs, 210000);
    });
  });

  group('YouTubeVideoProvider', () {
    test('loads videos from the browse feed', () async {
      final provider = YouTubeVideoProvider(
        postJson: (uri, body, headers) async => {
          'lockupViewModel': {
            'contentId': 'home-video',
            'contentType': 'LOCKUP_CONTENT_TYPE_VIDEO',
            'contentImage': {
              'thumbnailViewModel': {
                'image': {
                  'sources': [
                    {'url': 'https://img.example/home-video.jpg', 'width': 720},
                  ],
                },
                'badge': {'text': '3:20'},
              },
            },
            'metadata': {
              'lockupMetadataViewModel': {
                'title': {'content': 'Featured Video'},
                'metadata': {
                  'contentMetadataViewModel': {
                    'metadataRows': [
                      {
                        'metadataParts': [
                          {
                            'text': {'content': 'Featured Artist'},
                          },
                        ],
                      },
                    ],
                  },
                },
              },
            },
          },
        },
      );

      final results = await provider.loadFeatured();

      expect(results.single.title, 'Featured Video');
      expect(results.single.artist, 'Featured Artist');
      expect(results.single.durationMs, 200000);
      expect(results.single.artworkUrl, endsWith('home-video.jpg'));
    });

    test('maps standard YouTube video results', () async {
      final provider = YouTubeVideoProvider(
        postJson: (uri, body, headers) async => {
          'contents': {
            'twoColumnSearchResultsRenderer': {
              'primaryContents': {
                'sectionListRenderer': {
                  'contents': [
                    {
                      'itemSectionRenderer': {
                        'contents': [
                          {
                            'videoRenderer': {
                              'videoId': 'video-2',
                              'title': {
                                'runs': [
                                  {'text': 'Official Music Video'},
                                ],
                              },
                              'ownerText': {
                                'runs': [
                                  {'text': 'Official Artist'},
                                ],
                              },
                              'lengthText': {'simpleText': '4:10'},
                              'thumbnail': {
                                'thumbnails': [
                                  {
                                    'url': 'https://img.example/video.jpg',
                                    'width': 720,
                                  },
                                ],
                              },
                            },
                          },
                        ],
                      },
                    },
                  ],
                },
              },
            },
          },
        },
      );

      final results = await provider.searchSongs('official video');

      expect(results, hasLength(1));
      expect(results.single.id, 'provider:ytvideo:video-2');
      expect(results.single.kind, 'video');
      expect(results.single.artist, 'Official Artist');
      expect(results.single.durationMs, 250000);
    });

    test('selects a muxed MP4 video-with-audio stream', () async {
      final provider = YouTubeVideoProvider(
        postJson: (uri, body, headers) async => {
          'playabilityStatus': {'status': 'OK'},
          'streamingData': {
            'formats': [
              {
                'mimeType': 'video/mp4; codecs="avc1.42001E, mp4a.40.2"',
                'bitrate': 440000,
                'url': 'https://media.example/video-with-audio.mp4',
              },
            ],
          },
        },
      );

      expect(
        await provider.resolveStreamUrl(_ProviderSong.youtubeVideo),
        'https://media.example/video-with-audio.mp4',
      );
    });

    test('uses the matching Android client user agent for playback', () {
      final provider = YouTubeVideoProvider();

      expect(
        provider.playbackHeaders(_ProviderSong.youtubeVideo)['User-Agent'],
        contains('com.google.android.youtube'),
      );
    });
  });

  test('provider songs survive local JSON serialization with an empty URL', () {
    const original = _ProviderSong.song;
    final copy = Song.fromJson(original.toJson());

    expect(copy, isNotNull);
    expect(copy!.providerId, 'jiosaavn');
    expect(copy.sourceId, 'track-1');
  });
}

abstract final class _ProviderSong {
  static const song = Song(
    id: 'provider:jiosaavn:track-1',
    title: 'Song',
    kind: 'audio',
    url: '',
    providerId: 'jiosaavn',
    sourceId: 'track-1',
  );

  static const youtubeSong = Song(
    id: 'provider:ytmusic:video-1',
    title: 'Test Track',
    kind: 'audio',
    url: '',
    providerId: 'ytmusic',
    sourceId: 'video-1',
  );

  static const youtubeVideo = Song(
    id: 'provider:ytvideo:video-2',
    title: 'Official Music Video',
    kind: 'video',
    url: '',
    providerId: 'ytvideo',
    sourceId: 'video-2',
  );
}

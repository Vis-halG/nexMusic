import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_music/listening_models.dart';
import 'package:nex_music/media_library.dart';
import 'package:nex_music/music_controller.dart';
import 'package:nex_music/music_data.dart';
import 'package:nex_music/music_lyrics.dart';
import 'package:nex_music/music_longform.dart';
import 'package:nex_music/music_downloads.dart';
import 'package:nex_music/personal_music.dart';
import 'package:nex_music/music_portability.dart';
import 'package:nex_music/music_catalog.dart';
import 'package:nex_music/music_provider.dart';
import 'package:nex_music/listening_player.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

Song song(
  String id, {
  String url = 'https://example.com/song.mp3',
  String provider = '',
}) => Song(
  id: id,
  title: 'Song $id',
  artist: 'Artist',
  kind: 'audio',
  url: url,
  providerId: provider,
  sourceId: id,
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'random play keeps Stream and Library queues separate and Home combines them',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final native = _PlaybackFake();
      final music = MusicController(
        prefs,
        player: native,
        musicProvider: _HeaderProvider(),
      );
      music.personal.settings.values['gapless'] = false;
      music.personal.settings.values['crossfade'] = false;
      final upload = song('upload'),
          stream = song('online', provider: 'header'),
          local = song('local:device', url: 'content://media/audio/1'),
          liked = song('liked', provider: 'header');
      music.songs = [upload, song('video').copyWith(kind: 'video')];
      music.providerSongs = [stream];
      music.personal.localTracks[local.id] = local;
      music.library.rememberSongs([liked]);
      music.library.setSongLiked(liked, true);
      expect(
        music.randomSongsFor(MusicRandomScope.stream).map((s) => s.id).toSet(),
        {'online', 'liked'},
      );
      expect(
        music.randomSongsFor(MusicRandomScope.library).map((s) => s.id).toSet(),
        {'upload', 'local:device', 'liked'},
      );
      expect(
        music.randomSongsFor(MusicRandomScope.home).map((s) => s.id).toSet(),
        {'upload', 'online', 'local:device', 'liked'},
      );
      await music.playRandom(MusicRandomScope.library, random: Random(4));
      expect(music.playback.queue.tracks.map((s) => s.id).toSet(), {
        'upload',
        'local:device',
        'liked',
      });
      expect(music.playback.queue.shuffled, true);
      await music.playback.onQueueEnd!();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(
        jsonDecode(prefs.getString('playback_queue_v1')!)['randomScope'],
        'library',
      );
      final restored = MusicController(
        prefs,
        player: _PlaybackFake(),
        musicProvider: _HeaderProvider(),
      );
      await restored.playback.onQueueEnd!();
      expect(
        restored.playback.queue.tracks.any((s) => s.id == 'online'),
        false,
      );
      restored.dispose();
      music.dispose();
    },
  );
  test('random play from a list shuffles only that list', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final music = MusicController(
      prefs,
      player: _PlaybackFake(),
      musicProvider: _HeaderProvider(),
    );
    music.personal.settings.values['gapless'] = false;
    music.personal.settings.values['crossfade'] = false;
    music.songs = [song('elsewhere')];
    final list = [
      song('a'),
      song('b'),
      song('a'),
      song('clip').copyWith(kind: 'video'),
    ];
    await music.playRandomFrom(list, random: Random(1));
    expect(music.playback.queue.tracks.map((s) => s.id).toSet(), {'a', 'b'});
    expect(music.playback.queue.shuffled, true);
    expect(['a', 'b'], contains(music.current?.id));
    final first = music.current!.id;
    await music.playRandomFrom(list, random: Random(1));
    expect(music.current?.id, isNot(first));
    await music.playRandomFrom([song('clip').copyWith(kind: 'video')]);
    expect(music.notice, 'No playable songs here.');
    music.dispose();
  });

  test(
    'main Library random play switches categories and avoids overlapping memberships',
    () async {
      SharedPreferences.setMockInitialValues({});
      final music = MusicController(
        await SharedPreferences.getInstance(),
        player: _PlaybackFake(),
      );
      music.personal.settings.values['gapless'] = false;
      final a = song('a').copyWith(categoryId: 'a'),
          b = song('b').copyWith(categoryId: 'b'),
          overlap = song(
            'overlap',
          ).copyWith(categoryId: 'a', extraCategoryIds: ['b']);
      music.songs = [a, b, overlap];
      await music.play(a, from: [a, overlap]);
      for (var i = 0; i < 12; i++) {
        final previous = music.current!;
        await music.playRandom(MusicRandomScope.library, random: Random(i));
        expect(
          music.current!.categoryIds.toSet().intersection(
            previous.categoryIds.toSet(),
          ),
          isEmpty,
        );
        expect(music.playback.queue.tracks.length, 3);
      }
      music.dispose();
    },
  );

  test('main Library random play switches playlists', () async {
    SharedPreferences.setMockInitialValues({});
    final music = MusicController(
      await SharedPreferences.getInstance(),
      player: _PlaybackFake(),
    );
    music.personal.settings.values['gapless'] = false;
    final first = [song('one'), song('two')],
        second = [song('three'), song('four')];
    music.personal.createPlaylist('First', tracks: first);
    music.personal.createPlaylist('Second', tracks: second);
    await music.play(first.first, from: first);
    for (var i = 0; i < 10; i++) {
      final wasFirst = first.any((s) => s.id == music.current!.id);
      await music.playRandom(MusicRandomScope.library, random: Random(i));
      expect(first.any((s) => s.id == music.current!.id), !wasFirst);
    }
    music.dispose();
  });

  test(
    'main Stream random play changes online albums and excludes library-only songs',
    () async {
      SharedPreferences.setMockInitialValues({});
      final music = MusicController(
        await SharedPreferences.getInstance(),
        player: _PlaybackFake(),
        musicProvider: _HeaderProvider(),
      );
      music.personal.settings.values['gapless'] = false;
      final a = song('sa', provider: 'header').copyWith(album: 'First album'),
          b = song('sb', provider: 'header').copyWith(album: 'Second album');
      music.providerSongs = [
        a,
        b,
        a.copyWith(id: 'sa2', title: 'Another recording'),
      ];
      music.songs = [song('library-only')];
      await music.play(a, from: [a]);
      for (var i = 0; i < 10; i++) {
        final previousAlbum = music.current!.album;
        await music.playRandom(MusicRandomScope.stream, random: Random(i));
        expect(music.current!.album, isNot(previousAlbum));
        expect(music.current!.isProvider, true);
      }
      music.dispose();
    },
  );

  test(
    'a scoped shuffle cannot append radio outside its list, including after restore',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final music = MusicController(
        prefs,
        player: _PlaybackFake(),
        musicProvider: _HeaderProvider(),
      );
      music.personal.settings.values['gapless'] = false;
      final tracks = [
        song('pa', provider: 'header'),
        song('pb', provider: 'header'),
      ];
      await music.playRandomFrom(tracks, random: Random(0));
      await music.playback.onQueueEnd!();
      expect(music.playback.queue.tracks.map((s) => s.id).toSet(), {
        'pa',
        'pb',
      });
      expect(
        jsonDecode(prefs.getString('playback_queue_v1')!)['restrictToQueue'],
        true,
      );
      final restored = MusicController(
        prefs,
        player: _PlaybackFake(),
        musicProvider: _HeaderProvider(),
      );
      await restored.playback.onQueueEnd!();
      expect(restored.playback.queue.tracks.map((s) => s.id).toSet(), {
        'pa',
        'pb',
      });
      restored.dispose();
      music.dispose();
    },
  );
  test(
    'play after completion restarts from the beginning, while an idle saved queue resumes its position',
    () async {
      final native = _PlaybackFake();
      final errors = <String>[];
      final engine = ListeningPlayer(
        player: native,
        resolve: (s) async => AudioSource.uri(Uri.parse(s.url), tag: s),
        settings: () => ListeningSettings({'gapless': false}),
        onTrack: (_) {},
        onListening: (s, ms, {bool skipped = false, bool completed = false}) {},
        onError: errors.add,
      );
      final track = song('test');
      engine.queue.replace([track], track);
      engine.restoredPosition = const Duration(seconds: 10);
      native.state = ProcessingState.completed;
      await engine.toggle();
      expect(native.startedAt, Duration.zero);
      native.state = ProcessingState.idle;
      await engine.resume();
      expect(native.startedAt, const Duration(seconds: 10));
      expect(errors, isEmpty);
      engine.dispose();
    },
  );
  test(
    'device and downloaded audio bypass the network headers proxy',
    () async {
      SharedPreferences.setMockInitialValues({});
      final music = MusicController(
        await SharedPreferences.getInstance(),
        musicProvider: _HeaderProvider(),
      );
      final track = song(
        'local:scan',
        url: 'content://media/external/audio/media/1',
      );
      expect(music.audioHeadersFor(track, track.url), isNull);
      expect(
        music.audioHeadersFor(track, 'file:///downloads/track.mp3'),
        isNull,
      );
      expect(
        music.audioHeadersFor(track, 'https://example.com/track.mp3'),
        isNull,
      );
      final yt = song('provider:header:1', provider: 'header');
      expect(music.audioHeadersFor(yt, 'file:///downloads/track.mp4'), isNull);
      expect(
        music.audioHeadersFor(yt, 'https://example.com/track.mp4'),
        isNotEmpty,
      );
      music.dispose();
    },
  );
  test(
    'rejected playlist edits leave the saved name and ordering intact',
    () async {
      SharedPreferences.setMockInitialValues({});
      final personal = PersonalMusic(
        await SharedPreferences.getInstance(),
        uid: 'editor',
      );
      final playlist = personal.createPlaylist(
        'Original',
        tracks: [song('a'), song('b')],
      );
      expect(
        () => personal.updatePlaylist(playlist, (p) {
          p.name = '';
          p.tracks.clear();
        }),
        throwsFormatException,
      );
      expect(playlist.name, 'Original');
      expect(playlist.tracks.map((s) => s.id), ['a', 'b']);
      personal.dispose();
    },
  );
  test(
    'listened time, completed and skip events drive artist recap and discovery ordering',
    () async {
      SharedPreferences.setMockInitialValues({});
      final personal = PersonalMusic(
        await SharedPreferences.getInstance(),
        uid: 'u',
      );
      final a = song('a'), b = song('b'), hidden = song('hidden');
      personal.recordListening(a, 30000, completed: true);
      personal.recordListening(a, 30000);
      personal.recordListening(b, 5000, skipped: true);
      personal.hide(hidden);
      final stats = personal.stats();
      expect(stats['minutes'], 1);
      expect(stats['completed'], 1);
      expect((stats['topArtists'] as List).single, {
        'artist': 'Artist',
        'ms': 65000,
      });
      final tracks = rankDiscovery(
        [b, hidden, a],
        accepts: personal.accepts,
        feedback: Map<String, int>.from(stats['feedback'] as Map),
      );
      expect(tracks.map((s) => s.id), ['a', 'b']);
      personal.dispose();
    },
  );
  test('lyrics matching keeps non-Latin recording titles distinct', () async {
    SharedPreferences.setMockInitialValues({});
    final service = MusicLyricsService(
      await SharedPreferences.getInstance(),
      fetch: (uri) async => uri.path.endsWith('/get')
          ? null
          : [
              {
                'trackName': '世界',
                'artistName': '歌手',
                'plainLyrics': 'Wrong recording',
              },
              {
                'trackName': '未来',
                'artistName': '歌手',
                'plainLyrics': 'Correct recording',
              },
            ],
    );
    final result = await service.get(
      song('jp').copyWith(title: '未来', artist: '歌手'),
    );
    expect(result.plain, 'Correct recording');
  });
  test(
    'CSV round-trip preserves quoted titles, newlines and provider identities',
    () {
      final track = Song(
        id: 'provider:jiosaavn:x',
        title: 'A, "B"\nC',
        artist: 'Artist',
        kind: 'audio',
        url: '',
        providerId: 'jiosaavn',
        sourceId: 'x',
      );
      final p = MusicPlaylist(
        id: 'p',
        name: 'Mix',
        ownerUid: 'u',
        tracks: [track],
      );
      final rows = importPlaylistCsv(exportPlaylistCsv(p));
      expect(rows.single['title'], track.title);
      expect(csvReferencedSong(rows.single)?.id, track.id);
      expect(importPlaylistCsv('Track Name,Artist Name\nSong,Artist').single, {
        'title': 'Song',
        'artist': 'Artist',
      });
      expect(() => parseMusicCsv('title\n"Unclosed'), throwsFormatException);
    },
  );
  test(
    'a paused download queue restores its track metadata without starting work',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      MusicDownloads manager() => MusicDownloads(
        prefs: prefs,
        storageKey: 'queue-test',
        paths: {},
        tracks: {},
        settings: () => ListeningSettings(),
        resolve: (_) async => throw StateError('Must not start'),
        headers: (_) => {},
        onSaved: () {},
        wifiCheck: () async => false,
      );
      final first = manager();
      first.pause();
      await first.enqueue([song('provider:jiosaavn:x', provider: 'jiosaavn')]);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      first.dispose();
      final restored = manager();
      expect(restored.paused, true);
      expect(restored.jobs.values.single.song.id, 'provider:jiosaavn:x');
      restored.dispose();
    },
  );
  test(
    'shuffle visits every track once, preserves back history and restores traversal',
    () {
      final tracks = List.generate(8, (i) => song('$i'));
      final queue = ListeningQueue(random: Random(42))
        ..replace(tracks, tracks.first)
        ..setShuffle(true);
      final visited = <String>{queue.currentId!};
      for (var i = 0; i < 7; i++) {
        final next = queue.peekNext()!;
        expect(visited.add(next.id), true);
        queue.select(next);
      }
      expect(queue.peekNext(), isNull);
      expect(visited.length, 8);
      final previous = queue.history[queue.history.length - 2];
      expect(queue.previous()?.id, previous);
      final restored = ListeningQueue()
        ..restore(jsonDecode(jsonEncode(queue.toJson())));
      expect(restored.currentId, queue.currentId);
      expect(restored.history, queue.history);
      restored.repeat = MusicRepeat.all;
      expect(restored.peekNext(), isNotNull);
    },
  );
  test(
    'play next moves an already queued track and excludes duplicate/video items',
    () {
      final a = song('a'), b = song('b'), c = song('c');
      final queue = ListeningQueue()
        ..replace([a, b, c, a, a.copyWith(id: 'video', kind: 'video')], a);
      expect(queue.tracks.length, 3);
      queue.add(c, next: true);
      expect(queue.peekNext()?.id, 'c');
      queue.select(c);
      queue.repeat = MusicRepeat.one;
      expect(queue.peekNext(completed: true)?.id, 'c');
      expect(queue.peekNext()?.id, 'b');
    },
  );
  test(
    'legacy migration claims activity once and two accounts keep libraries separate',
    () async {
      SharedPreferences.setMockInitialValues({
        'likedSongIds': ['old'],
        'offlineSongs': '{"old":"/old.mp3"}',
      });
      final prefs = await SharedPreferences.getInstance();
      await migrateMusicAccount(prefs, 'alice');
      await migrateMusicAccount(prefs, 'bob');
      expect(prefs.getStringList('user:alice:likedSongIds'), ['old']);
      expect(prefs.getStringList('user:bob:likedSongIds'), isNull);
      final alice = PersonalMusic(prefs, uid: 'alice'),
          bob = PersonalMusic(prefs, uid: 'bob');
      alice.createPlaylist('My library', tracks: [song('a')]);
      alice.recordLike(song('a'), true);
      await alice.saved;
      expect(bob.playlists, isEmpty);
      expect(bob.activity, isEmpty);
      final restarted = PersonalMusic(prefs, uid: 'alice');
      expect(restarted.playlists.single.tracks.single.id, 'a');
      alice.dispose();
      bob.dispose();
      restarted.dispose();
    },
  );
  test(
    'playlist export strips private files and transient provider URLs without changing original',
    () {
      final local = song('local:1', url: 'file:///secret.mp3'),
          remote = song(
            'provider:ytmusic:a',
            url: 'https://expired.test/token',
            provider: 'ytmusic',
          );
      final playlist = MusicPlaylist(
        id: 'p',
        name: 'Mix',
        ownerUid: 'alice',
        tracks: [local, remote],
      );
      final exported = exportPlaylist(playlist);
      expect(jsonDecode(exported)['format'], 'nexMusic-playlist');
      final imported = importPlaylist(exported, 'bob');
      final legacy = importPlaylist(
        exported.replaceFirst('nexMusic-playlist', 'nexApp-playlist'),
        'bob',
      );
      expect(legacy.name, 'Mix');
      expect(legacy.tracks.length, 2);
      expect(imported.ownerUid, 'bob');
      expect(imported.id, isNot('p'));
      expect(imported.tracks.first.url, 'device:local:1');
      expect(imported.tracks.last.url, '');
      expect(local.url, 'file:///secret.mp3');
      expect(
        () => importPlaylist('{"format":"foreign"}', 'bob'),
        throwsFormatException,
      );
    },
  );
  test(
    'provider downloads remain discoverable after restart without a feed and missing files are excluded',
    () async {
      final dir = await Directory.systemTemp.createTemp('nex-offline-test');
      addTearDown(() => dir.delete(recursive: true));
      final file = await File('${dir.path}/track.mp3').writeAsBytes([1, 2, 3]);
      final track = song('provider:jiosaavn:x', provider: 'jiosaavn');
      SharedPreferences.setMockInitialValues({
        'offlineSongs': jsonEncode({track.id: file.path}),
      });
      final prefs = await SharedPreferences.getInstance();
      final personal = PersonalMusic(prefs, uid: 'guest', legacy: true);
      personal.offlineTracks[track.id] = track;
      personal.changed();
      await personal.saved;
      personal.dispose();
      final music = MusicController(prefs);
      expect(music.downloadedSongs.single.id, track.id);
      expect(music.playableUrl(track), file.uri.toString());
      await file.delete();
      expect(music.downloadedSongs, isEmpty);
      music.dispose();
    },
  );
  test(
    'LRC seeks correctly before start, between lines and with repeated timestamps/offsets',
    () {
      final lyrics = SongLyrics(
        plain: '',
        synced:
            '[offset:-500]\n[00:01.50][00:05.000]Hello\n[00:03.0]World\n[00:99.0]Invalid',
      );
      expect(lyrics.lines.map((l) => l.at.inMilliseconds), [1000, 2500, 4500]);
      expect(lyrics.activeLine(const Duration(milliseconds: 999)), -1);
      expect(lyrics.activeLine(const Duration(seconds: 3)), 1);
      expect(lyrics.activeLine(const Duration(seconds: 6)), 2);
    },
  );
  test(
    'lyric requests coalesce and cached lyrics remain usable offline',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var calls = 0;
      final service = MusicLyricsService(
        prefs,
        fetch: (uri) async {
          calls++;
          return {'plainLyrics': 'Hello', 'syncedLyrics': '[00:01.0]Hello'};
        },
      );
      final track = song('a');
      await Future.wait([service.get(track), service.get(track)]);
      expect(calls, 1);
      final offline = MusicLyricsService(
        prefs,
        fetch: (uri) async => throw const SocketException('offline'),
      );
      expect((await offline.get(track)).lines.single.text, 'Hello');
    },
  );
  test(
    'RSS stable IDs survive URL changes, skip insecure media, parse duration and artwork',
    () {
      String rss(String audio) =>
          '<rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>Show</title><itunes:image href="https://a.test/art.jpg"/><item><title>Episode</title><guid>stable</guid><itunes:duration>1:02:03</itunes:duration><enclosure url="$audio" type="audio/mpeg"/></item><item><title>Unsafe</title><enclosure url="http://a.test/song"/></item></channel></rss>';
      final a = parsePodcastFeed(
        rss('https://a.test/one.mp3'),
        Uri.parse('https://a.test/feed'),
      );
      final b = parsePodcastFeed(
        rss('https://a.test/two.mp3'),
        Uri.parse('https://a.test/feed'),
      );
      expect(a.episodes.length, 1);
      expect(a.episodes.single.id, b.episodes.single.id);
      expect(a.episodes.single.id.length, lessThan(100));
      expect(a.episodes.single.durationMs, 3723000);
      expect(a.episodes.single.artworkUrl, 'https://a.test/art.jpg');
    },
  );
  test(
    'cloud recents merge without inventing local play counts or exposing another account',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final a = MediaLibrary(prefs, namespace: 'user:a'),
          b = MediaLibrary(prefs, namespace: 'user:b');
      a.applyCloudPlay(song('remote'), 1000);
      a.applyCloudPlay(song('remote'), 500);
      await a.saved;
      expect(a.collection(MediaCollection.recent).single.lastPlayed, 1000);
      expect(a.collection(MediaCollection.mostPlayed), isEmpty);
      expect(b.entries, isEmpty);
      a.dispose();
      b.dispose();
    },
  );
  test(
    'Wi-Fi policy pauses downloads without invoking resolution and cancellation clears queue',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var resolves = 0;
      final manager = MusicDownloads(
        prefs: prefs,
        storageKey: 'test',
        paths: {},
        tracks: {},
        settings: () => ListeningSettings(),
        resolve: (s) async {
          resolves++;
          return 'https://a.test/a.mp3';
        },
        headers: (_) => {},
        onSaved: () {},
        wifiCheck: () async => false,
      );
      await manager.enqueue([song('x')]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(manager.jobs['x']!.status, MusicDownloadStatus.paused);
      expect(resolves, 0);
      manager.cancel('x');
      expect(manager.jobs['x']!.status, MusicDownloadStatus.cancelled);
      manager.dispose();
    },
  );
}

class _HeaderProvider extends Fake implements MusicProvider {
  @override
  String get id => 'header';
  @override
  Map<String, String> playbackHeaders(Song song) => const {
    'User-Agent': 'nexMusic test',
  };
}

class _PlaybackFake extends Fake implements AudioPlayer {
  ProcessingState state = ProcessingState.idle;
  Duration? startedAt;
  @override
  ProcessingState get processingState => state;
  @override
  bool get playing => false;
  @override
  Duration get duration => const Duration(seconds: 12);
  @override
  Stream<int?> get androidAudioSessionIdStream => const Stream.empty();
  @override
  Stream<PlayerState> get playerStateStream => const Stream.empty();
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<int?> get currentIndexStream => const Stream.empty();
  @override
  Stream<PlayerException> get errorStream => const Stream.empty();
  @override
  Future<Duration?> setAudioSources(
    List<AudioSource> sources, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
    ShuffleOrder? shuffleOrder,
  }) async {
    startedAt = initialPosition;
    state = ProcessingState.ready;
    return const Duration(seconds: 12);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if ([
      #pause,
      #setVolume,
      #setSpeed,
      #setLoopMode,
      #play,
      #dispose,
    ].contains(invocation.memberName)) {
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

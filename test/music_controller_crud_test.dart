import 'package:flutter_test/flutter_test.dart';
import 'package:nex_music/music_controller.dart';
import 'package:nex_music/music_data.dart';
import 'package:nex_music/media_library.dart';
import 'package:nex_music/phone_services.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('local preview media CRUD keeps controller state consistent', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final controller = MusicController(preferences);
    addTearDown(controller.dispose);

    final sourceFolder = await controller.createMediaFolder('Clips');
    expect(sourceFolder, isNotNull);
    expect(
      controller.mediaFolders.map((folder) => folder.name),
      contains('Clips'),
    );

    final created = await controller.saveSharedLink(
      url: 'https://example.com/video',
      title: 'Demo clip',
      folderId: sourceFolder!.id,
    );
    expect(created, isTrue);
    expect(controller.savedMedia, hasLength(1));
    expect(controller.savedMedia.single.title, 'Demo clip');

    final targetFolder = await controller.createMediaFolder('Archive');
    expect(targetFolder, isNotNull);

    final updated = await controller.updateMedia(
      controller.savedMedia.single,
      title: 'Renamed clip',
      folderId: targetFolder!.id,
      sourceUrl: 'https://example.com/new-video',
    );
    expect(updated, isTrue);
    expect(controller.savedMedia.single.title, 'Renamed clip');
    expect(controller.savedMedia.single.folderId, targetFolder.id);
    expect(
      controller.savedMedia.single.sourceUrl,
      'https://example.com/new-video',
    );

    final deleted = await controller.deleteMedia(controller.savedMedia.single);
    expect(deleted, isTrue);
    expect(controller.savedMedia, isEmpty);

    final folderDeleted = await controller.deleteMediaFolder(sourceFolder);
    expect(folderDeleted, isTrue);
    expect(
      controller.mediaFolders.map((folder) => folder.id),
      isNot(contains(sourceFolder.id)),
    );
  });

  test('local preview CRUD rejects invalid media input', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final controller = MusicController(preferences);
    addTearDown(controller.dispose);

    final invalidLink = await controller.saveSharedLink(
      url: 'not-a-url',
      title: 'Invalid clip',
      folderId: controller.mediaFolders.first.id,
    );
    expect(invalidLink, isFalse);
    expect(controller.savedMedia, isEmpty);

    final tooLongTitle = await controller.saveSharedLink(
      url: 'https://example.com/video',
      title: 'x' * 161,
      folderId: controller.mediaFolders.first.id,
    );
    expect(tooLongTitle, isFalse);
    expect(controller.savedMedia, isEmpty);
  });

  test('catalogue helpers resolve categories, likes and recents', () async {
    SharedPreferences.setMockInitialValues({
      'recentSongIds': ['deleted-song', 's1'],
      'likedSongIds': ['s2'],
    });
    final controller = MusicController(await SharedPreferences.getInstance())
      ..categories = const [
        MusicCategory(id: 'c1', name: 'Bollywood', ownerUid: 'u1'),
      ]
      ..songs = const [
        Song(id: 's1', title: 'One', kind: 'audio', url: 'u', categoryId: 'c1'),
        Song(id: 's2', title: 'Two', kind: 'video', url: 'u', categoryId: 'x'),
      ];
    addTearDown(controller.dispose);

    // Ids of songs that no longer exist are skipped instead of throwing.
    expect(controller.recentSongs.map((song) => song.id), ['s1']);
    expect(controller.likedSongs, isEmpty);
    expect(controller.librarySongs(MediaCollection.liked).map((s) => s.id), [
      's2',
    ]);
    expect(controller.songsIn('c1').map((song) => song.id), ['s1']);
    expect(controller.songsIn(null), hasLength(2));
    expect(controller.categoryName('x'), 'Uncategorized');
    expect(controller.myUploads, isEmpty);
  });

  test('catalogue writes require sign-in and valid input', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = MusicController(await SharedPreferences.getInstance())
      ..categories = const [
        MusicCategory(id: 'c1', name: 'Bollywood', ownerUid: 'u1'),
      ];
    addTearDown(controller.dispose);

    expect(await controller.createCategory('   '), isNull);
    expect(await controller.createCategory('x' * 41), isNull);

    // An existing name is reused instead of creating a duplicate.
    final existing = await controller.createCategory('bollywood');
    expect(existing?.id, 'c1');

    expect(await controller.createCategory('Lo-fi'), isNull);
    expect(controller.notice, contains('Sign in'));

    final item = UploadItem(
      path: 'song.mp3',
      name: 'song.mp3',
      sizeBytes: 3000000,
      title: 'Song',
    );
    await controller.startUploads([item], categoryId: 'missing');
    expect(controller.uploads, isEmpty);
    expect(controller.notice, contains('Choose a category'));

    await controller.startUploads([item], categoryId: 'c1');
    expect(controller.uploads, isEmpty);
    expect(controller.notice, contains('Sign in'));
    expect(controller.uploading, isFalse);

    const song = Song(
      id: 's1',
      title: 'One',
      kind: 'audio',
      url: 'u',
      categoryId: 'c1',
      ownerUid: 'someone-else',
    );
    expect(
      await controller.updateSong(song, title: 'Two', categoryIds: ['c1']),
      isFalse,
    );
    expect(await controller.deleteSong(song), isFalse);

    // Anyone may rename or delete any category, but only while signed in.
    expect(
      await controller.deleteCategory(
        controller.categories.first,
        withSongs: true,
      ),
      isFalse,
    );
    expect(controller.notice, contains('Sign in'));
    expect(
      await controller.renameCategory(controller.categories.first, 'Pop'),
      isFalse,
    );
    expect(controller.notice, contains('Sign in'));
  });

  test('a song can be listed in several categories', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = MusicController(await SharedPreferences.getInstance())
      ..categories = const [
        MusicCategory(id: 'c1', name: 'Bollywood', ownerUid: 'u1'),
        MusicCategory(id: 'c2', name: 'Rain', ownerUid: 'u2'),
      ]
      ..songs = const [
        Song(
          id: 'both',
          title: 'Both',
          kind: 'audio',
          url: 'u',
          categoryId: 'c1',
          extraCategoryIds: ['c2', 'c1'],
        ),
        Song(
          id: 'one',
          title: 'One',
          kind: 'audio',
          url: 'u',
          categoryId: 'c1',
        ),
      ];
    addTearDown(controller.dispose);

    expect(controller.songsIn('c1').map((s) => s.id), ['both', 'one']);
    expect(controller.songsIn('c2').map((s) => s.id), ['both']);
    expect(controller.songs.first.categoryIds, ['c1', 'c2']);
    expect(controller.songSource(controller.songs.first), 'Bollywood, Rain');
    // Deleting Bollywood would remove only the song listed nowhere else.
    expect(
      controller.songsOnlyIn(controller.categories.first).map((s) => s.id),
      ['one'],
    );
    final copy = Song.fromJson(controller.songs.first.toJson())!;
    expect(copy.categoryId, 'c1');
    expect(copy.categoryIds, ['c1', 'c2']);
    // Entries written by older app versions have only the main category.
    expect(
      Song.fromJson({'id': 'old', 'url': 'u', 'categoryId': 'c2'})!.categoryIds,
      ['c2'],
    );
  });

  test('upload batch progress counts finished and in-flight bytes', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = MusicController(await SharedPreferences.getInstance());
    addTearDown(controller.dispose);

    UploadItem item(UploadStatus status, {double progress = 0}) =>
        UploadItem(path: 'a.mp3', name: 'a.mp3', sizeBytes: 1000, title: 'A')
          ..status = status
          ..progress = progress;

    controller.uploads = [
      item(UploadStatus.done),
      item(UploadStatus.uploading, progress: 0.5),
      item(UploadStatus.queued),
      item(UploadStatus.failed),
    ];
    expect(controller.uploading, isTrue);
    expect(controller.uploadsFinished, 2);
    expect(controller.uploadsFailed, 1);
    expect(controller.uploadFraction, closeTo(0.625, 0.0001));
  });

  test('songs survive the JSON round trip used by the device cache', () {
    final song = Song(
      id: 's1',
      title: 'Tum Hi Ho',
      kind: 'audio',
      url: 'https://res.cloudinary.com/demo/video/upload/nexmusic/a.mp3',
      categoryId: 'c1',
      ownerUid: 'u1',
      ownerName: 'Vishal',
      publicId: 'nexmusic/a',
      sizeBytes: 3100000,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1726000000000),
    );
    final copy = Song.fromJson(song.toJson())!;
    expect(copy.id, song.id);
    expect(copy.title, song.title);
    expect(copy.url, song.url);
    expect(copy.categoryId, song.categoryId);
    expect(copy.publicId, song.publicId);
    expect(copy.sizeBytes, song.sizeBytes);
    expect(copy.createdAt, song.createdAt);
    expect(Song.fromJson({'id': '', 'url': 'x'}), isNull);
  });

  test('upload kinds follow the file extension', () {
    expect(uploadKindFor('Song.MP3'), 'audio');
    expect(uploadKindFor('voice.opus'), 'audio');
    expect(uploadKindFor('studio.AIFF'), 'audio');
    expect(uploadKindFor('clip.mp4'), 'video');
    expect(uploadKindFor('Live.MKV'), 'video');
    expect(uploadKindFor('old.avi'), 'video');
    expect(uploadKindFor('notes.txt'), isNull);
  });

  test('formats phones cannot play are streamed as MP3 or MP4', () {
    const base = 'https://res.cloudinary.com/demo/video/upload/v1/nexmusic/abc';
    expect(playbackUrlFor('$base.mp3'), '$base.mp3');
    expect(playbackUrlFor('$base.flac'), '$base.flac');
    expect(playbackUrlFor('$base.mkv'), '$base.mkv');
    expect(playbackUrlFor('$base.aiff'), '$base.mp3');
    expect(playbackUrlFor('$base.AVI'), '$base.mp4');
    expect(playbackUrlFor('$base.wmv'), '$base.mp4');
  });

  test('YouTube links are found in shared text', () {
    expect(
      youtubeLinkIn('Watch this https://youtu.be/abc123?si=x'),
      'https://youtu.be/abc123?si=x',
    );
    expect(
      youtubeLinkIn('https://www.youtube.com/watch?v=abc123.'),
      'https://www.youtube.com/watch?v=abc123',
    );
    expect(
      youtubeLinkIn('https://music.youtube.com/watch?v=abc'),
      'https://music.youtube.com/watch?v=abc',
    );
    expect(youtubeLinkIn('https://example.com/youtube.com'), isNull);
    expect(youtubeLinkIn('no link here'), isNull);
  });

  test('activity notifications describe changes without names', () {
    expect(uploadActivity(['Tum Hi Ho'], 'Bollywood'), (
      title: 'New upload in Bollywood',
      body: 'Tum Hi Ho',
    ));
    expect(uploadActivity(['A', 'B'], 'Lo-fi').body, 'A and B');
    expect(uploadActivity(['A', 'B', 'C', 'D'], 'Lo-fi'), (
      title: '4 new uploads in Lo-fi',
      body: 'A, B and 2 more',
    ));
    expect(songEditActivity(oldTitle: 'A', newTitle: 'A'), isNull);
    expect(songEditActivity(oldTitle: 'A', newTitle: 'B'), (
      title: 'Song renamed',
      body: 'A → B',
    ));
    expect(songEditActivity(oldTitle: 'A', newTitle: 'A', movedTo: 'Old'), (
      title: 'Song moved to Old',
      body: 'A',
    ));
    expect(
      songEditActivity(oldTitle: 'A', newTitle: 'B', movedTo: 'Old')?.body,
      'A → B · moved to Old',
    );
    expect(categoryRenameActivity('Old', 'Retro').body, 'Old → Retro');
    expect(categoryDeleteActivity('Old').body, 'Old');
    expect(
      categoryDeleteActivity('Old', songs: 1).body,
      'Old · 1 song removed',
    );
    expect(
      categoryDeleteActivity('Old', songs: 12).body,
      'Old · 12 songs removed',
    );
  });

  test('streaming links are refused before they reach a player', () async {
    expect(isStreamingLink('https://cdn.example.com/live/index.m3u8'), isTrue);
    expect(
      isStreamingLink('https://cdn.example.com/a/Manifest.MPD?t=1'),
      isTrue,
    );
    expect(isStreamingLink('https://example.com/video.ism/Manifest'), isTrue);
    expect(isStreamingLink('rtsp://camera.local/stream'), isTrue);
    expect(
      isStreamingLink('https://res.cloudinary.com/demo/video/upload/one.mp3'),
      isFalse,
    );
    expect(isStreamingLink('file:///data/offline_songs/s1.m4a'), isFalse);

    SharedPreferences.setMockInitialValues({});
    final controller = MusicController(await SharedPreferences.getInstance());
    addTearDown(controller.dispose);
    await controller.play(
      const Song(
        id: 'live',
        title: 'Live',
        kind: 'audio',
        url: 'https://cdn.example.com/live/index.m3u8',
      ),
    );
    expect(controller.current, isNull);
    expect(controller.notice, contains('Streaming links'));
  });

  test('browser download names come from headers, URL and MIME type', () {
    expect(
      downloadFileName(
        Uri.parse('https://cdn.example.com/dl?id=1'),
        'attachment; filename="My Song (128 kbps).mp3"',
        'audio/mpeg',
      ),
      'My Song (128 kbps).mp3',
    );
    expect(
      downloadFileName(
        Uri.parse('https://cdn.example.com/dl'),
        "attachment; filename*=UTF-8''Tum%20Hi%20Ho.m4a",
        'application/octet-stream',
      ),
      'Tum Hi Ho.m4a',
    );
    expect(
      downloadFileName(
        Uri.parse('https://cdn.example.com/files/track.mp3'),
        null,
        'application/octet-stream',
      ),
      'track.mp3',
    );
    expect(
      downloadFileName(
        Uri.parse('https://cdn.example.com/get/abc123'),
        null,
        'audio/mpeg',
      ),
      'abc123.mp3',
    );
    expect(
      downloadFileName(
        Uri.parse('https://cdn.example.com/get'),
        'attachment; filename="a/b:c.mp3"',
        'audio/mpeg',
      ),
      'a b c.mp3',
    );
    expect(
      downloadFileName(
        Uri.parse('https://cdn.example.com/get/concert'),
        null,
        'video/x-matroska',
      ),
      'concert.mkv',
    );
  });

  test('trimming an upload keeps the original so it can be undone', () {
    final item = UploadItem(
      path: '/cache/file_picker/1/Song.mp3',
      name: 'Song.mp3',
      sizeBytes: 5000,
      title: 'Song',
    );

    item.applyTrim(
      trimmedPath: '/cache/nexmusic_exports/abc.m4a',
      trimmedSize: 2000,
      start: const Duration(seconds: 10),
      end: const Duration(seconds: 70),
    );
    expect(item.trimmed, isTrue);
    expect(item.path, '/cache/nexmusic_exports/abc.m4a');
    expect(item.name, 'Song.m4a');
    expect(item.sizeBytes, 2000);
    expect(item.title, 'Song');

    // Trimming again starts from the original file, not the first copy.
    item.applyTrim(
      trimmedPath: '/cache/nexmusic_exports/def.mp3',
      trimmedSize: 1500,
      start: Duration.zero,
      end: const Duration(seconds: 30),
    );
    expect(item.original?.path, '/cache/file_picker/1/Song.mp3');
    expect(item.name, 'Song.mp3');

    expect(item.undoTrim(), '/cache/nexmusic_exports/def.mp3');
    expect(item.path, '/cache/file_picker/1/Song.mp3');
    expect(item.sizeBytes, 5000);
    expect(item.trimmed, isFalse);
    expect(item.trimStart, isNull);
  });

  test('downloaded songs are remembered on this device', () async {
    SharedPreferences.setMockInitialValues({
      'offlineSongs': '{"s1":"/missing/offline_songs/s1.mp3"}',
    });
    final controller = MusicController(await SharedPreferences.getInstance())
      ..songs = const [
        Song(
          id: 's1',
          title: 'One',
          kind: 'audio',
          url: 'https://res.cloudinary.com/demo/video/upload/one.mp3',
        ),
        Song(
          id: 's2',
          title: 'Two',
          kind: 'audio',
          url: 'https://res.cloudinary.com/demo/video/upload/two.mp3',
        ),
      ];
    addTearDown(controller.dispose);

    expect(controller.isSongDownloaded(controller.songs.first), isFalse);
    expect(controller.downloadedSongs, isEmpty);
    // A download whose file is gone falls back to streaming.
    expect(
      controller.playableUrl(controller.songs.first),
      'https://res.cloudinary.com/demo/video/upload/one.mp3',
    );
  });
}

part of 'music_controller.dart';

/// Owns preparation after the upload form closes, including temporary files.
class StreamUploadJob extends ChangeNotifier {
  StreamUploadJob(this.music, this.song) : account = music.personal;
  final MusicController music;
  final PersonalMusic account;
  final Song song;
  final String id = newMusicId();
  SongFilePreparation? _preparation;
  UploadItem? item;
  bool busy = false, submitted = false, queued = false, cancelled = false;
  double? progress;
  String? error;
  String title = '', artist = '';
  List<String> categories = [];

  Future<void> prepare() async {
    if (busy || cancelled || queued) return;
    busy = true;
    if (item != null) music.discardPicked(item!);
    item = null;
    error = null;
    notifyListeners();
    PreparedSongFiles? prepared;
    File? copy;
    try {
      await music.phone?.setTransferActive('stream-upload:$id', true);
      if (music.uid == null) {
        throw StateError('Sign in with Google to upload songs.');
      }
      if (account != music.personal) {
        throw StateError('Your account changed. Open the song again.');
      }
      _preparation = music.createAudioFilePreparation(
        maxBytes: math.min(
          maxUploadBytes - 1,
          account.settings.storageBudgetMb * 1024 * 1024,
        ),
        onProgress: (_, _, _, fraction) {
          if (!cancelled) {
            progress = fraction;
            notifyListeners();
          }
        },
      );
      prepared = await _preparation!.prepare([song]);
      if (cancelled || account != music.personal) throw SongShareCancelled();
      final source = prepared.files.single;
      final directory = await Directory(
        path.join((await getTemporaryDirectory()).path, 'nexmusic_uploads'),
      ).create(recursive: true);
      copy = await File(
        source.path,
      ).copy(path.join(directory.path, '$id${path.extension(source.path)}'));
      if (cancelled || account != music.personal) throw SongShareCancelled();
      final bytes = await copy.length();
      if (bytes == 0 ||
          bytes >= maxUploadBytes ||
          uploadKindFor(source.path) != 'audio') {
        throw StateError(
          'The prepared audio is empty, unsupported or too large.',
        );
      }
      item =
          UploadItem(
              path: copy.path,
              name: path.basename(source.path),
              sizeBytes: bytes,
              title: song.title,
            )
            ..artist = song.artist
            ..artistRead = true
            ..durationMs = song.durationMs;
      copy = null; // Ownership moves to the job, then the upload queue.
    } on SongShareCancelled {
      error = 'Audio preparation cancelled.';
    } catch (failure) {
      error = 'Could not prepare this song. $failure';
    } finally {
      if (copy != null) {
        try {
          await copy.delete();
        } catch (_) {}
      }
      await prepared?.dispose();
      _preparation = null;
      busy = false;
      if (account != music.personal) {
        error = 'Your account changed. Open the song again.';
      }
      notifyListeners();
      if (!submitted || error != null || cancelled) {
        await music.phone?.setTransferActive('stream-upload:$id', false);
      }
    }
  }

  void submit({
    required String title,
    required String artist,
    required List<String> categories,
  }) {
    if (cancelled || queued || categories.isEmpty) return;
    this.title = title;
    this.artist = artist;
    this.categories = List.of(categories);
    submitted = true;
    notifyListeners();
  }

  void cancel() {
    if (queued || cancelled) return;
    cancelled = true;
    busy = false;
    _preparation?.cancel();
    if (item != null) music.discardPicked(item!);
    item = null;
    error = 'Audio preparation cancelled.';
    notifyListeners();
    unawaited(music.phone?.setTransferActive('stream-upload:$id', false));
  }
}

extension StreamUploadActions on MusicController {
  StreamUploadJob prepareStreamUpload(Song song) {
    final job = StreamUploadJob(this, song);
    streamUploadJobs.add(job);
    job.addListener(_streamUploadChanged);
    scheduleMicrotask(() {
      if (!_uploadsDisposed) unawaited(job.prepare());
    });
    return job;
  }

  void _streamUploadChanged() {
    for (final job in List.of(streamUploadJobs)) {
      if (job.cancelled || job.account != personal) {
        job.removeListener(_streamUploadChanged);
        streamUploadJobs.remove(job);
        job.cancel();
      }
    }
    if (!_uploadsDisposed) notifyListeners();
  }

  void _queuePreparedStreamUploads() {
    if (_streamQueueScheduled ||
        _uploadsDisposed ||
        uploading ||
        _drainingUploads) {
      return;
    }
    final job = streamUploadJobs
        .where(
          (j) =>
              j.submitted &&
              !j.queued &&
              !j.cancelled &&
              j.item != null &&
              j.error == null &&
              !j.busy,
        )
        .firstOrNull;
    if (job == null) return;
    _streamQueueScheduled = true;
    scheduleMicrotask(() async {
      _streamQueueScheduled = false;
      if (_uploadsDisposed ||
          uploading ||
          _drainingUploads ||
          job.cancelled ||
          job.account != personal) {
        return;
      }
      final item = job.item!;
      item.title = job.title;
      item.artist = job.artist;
      job.queued = true;
      final pending = startUploads(
        [item],
        categoryId: job.categories.first,
        extraCategoryIds: job.categories.skip(1).toList(),
      );
      if (uploads.contains(item)) {
        streamUploadJobs.remove(job);
        job.removeListener(_streamUploadChanged);
      } else {
        job.queued = false;
        job.error =
            'Could not queue this upload. Check your account and category.';
      }
      unawaited(phone?.setTransferActive('stream-upload:${job.id}', false));
      notifyListeners();
      await pending;
    });
  }
}

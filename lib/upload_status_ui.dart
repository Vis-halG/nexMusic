part of 'music_ui.dart';

/// Shows preparation and actual uploading as separate stages on every page.
class UploadStatusHost extends StatelessWidget {
  const UploadStatusHost({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final music = context.read<MusicController>();
    return ValueListenableBuilder<List<SharedAudioJob>>(
      valueListenable: SharedAudioJob.running,
      builder: (context, shared, _) => AnimatedBuilder(
        animation: Listenable.merge([music, ...shared]),
        child: child,
        builder: (context, page) {
          final stream = music.streamUploadJobs
              .where((j) => j.submitted && !j.cancelled)
              .firstOrNull;
          final converting = shared.where((j) => j.waiting).firstOrNull;
          String? title, detail;
          double? progress;
          bool error = false;
          VoidCallback? onTap, onCancel;
          if (stream != null) {
            error = stream.error != null;
            title = error
                ? 'Audio preparation failed'
                : stream.busy
                ? 'Preparing audio'
                : 'Waiting to upload';
            detail = stream.error ?? stream.title;
            progress = stream.progress;
            onCancel = stream.cancel;
            if (error) onTap = () => unawaited(stream.prepare());
          } else if (converting != null) {
            title = 'Preparing shared audio';
            detail = converting.status;
            progress = converting.fraction;
            onCancel = converting.cancel;
          } else if (music.uploads.isNotEmpty) {
            error = music.uploadsFailed > 0 && !music.uploading;
            title = music.uploading
                ? music.uploadsPaused
                      ? 'Uploads paused'
                      : music.uploadsWaiting
                      ? 'Waiting for connection'
                      : 'Uploading'
                : error
                ? 'Some uploads failed'
                : 'Upload complete';
            detail =
                '${music.uploadsFinished} of ${music.uploads.length} processed';
            progress = music.uploadFraction;
            onTap = () => musicNavigatorKey.currentState?.push<void>(
              NexPageRoute(
                builder: (_) => const UploadScreen(),
                reducedMotion: MediaQuery.disableAnimationsOf(context),
              ),
            );
            onCancel = music.uploading
                ? music.cancelUploads
                : music.clearUploads;
          }
          if (title == null) return page!;
          return Column(
            children: [
              Material(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                child: SafeArea(
                  bottom: false,
                  child: InkWell(
                    onTap: onTap,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 4, 6),
                      child: Row(
                        children: [
                          Icon(
                            error
                                ? Icons.error_outline_rounded
                                : Icons.cloud_upload_outlined,
                            color: error
                                ? Theme.of(context).colorScheme.error
                                : NexMusic.violet,
                            size: 22,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  detail ?? '',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: _muted(context),
                                  ),
                                ),
                                const SizedBox(height: 5),
                                LinearProgressIndicator(
                                  value: error ? 0 : progress,
                                  minHeight: 2,
                                ),
                              ],
                            ),
                          ),
                          Semantics(
                            label: 'Dismiss or cancel transfer',
                            button: true,
                            child: IconButton(
                              onPressed: onCancel,
                              icon: const Icon(Icons.close_rounded, size: 18),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: MediaQuery.removePadding(
                  context: context,
                  removeTop: true,
                  child: page!,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

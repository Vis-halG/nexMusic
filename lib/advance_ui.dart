part of 'music_ui.dart';

class AdvanceScreen extends StatefulWidget {
  const AdvanceScreen({super.key, this.loadStatus});
  final Future<CloudinaryStatus> Function()? loadStatus;
  @override
  State<AdvanceScreen> createState() => _AdvanceScreenState();
}

class _AdvanceScreenState extends State<AdvanceScreen>
    with WidgetsBindingObserver {
  CloudinaryStatus? _status;
  Object? _account;
  String? _error;
  bool _busy = false;
  int _request = 0;
  Timer? _refreshTimer;
  bool _autoRefresh = true;
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (_autoRefresh &&
          _lifecycle == AppLifecycleState.resumed &&
          !_busy &&
          _status != null &&
          ModalRoute.of(context)?.isCurrent == true) {
        unawaited(_refresh(manual: false));
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
  }

  @override
  void dispose() {
    ++_request;
    _refreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final account = context.watch<MusicController>().personal;
    if (!identical(account, _account)) {
      _account = account;
      _status = null;
      unawaited(_refresh());
    }
  }

  Future<void> _refresh({bool manual = true}) async {
    final request = ++_request;
    final music = context.read<MusicController>();
    final account = music.personal;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final status = widget.loadStatus != null
          ? await widget.loadStatus!()
          : await music.loadCloudinaryStatus(refresh: manual);
      if (!mounted ||
          request != _request ||
          !identical(account, music.personal)) {
        return;
      }
      setState(() => _status = status);
    } catch (error) {
      if (!mounted ||
          request != _request ||
          !identical(account, music.personal)) {
        return;
      }
      setState(
        () => _error = error is CloudinaryStatusException
            ? error.message
            : 'Could not load Cloudinary usage. Try again.',
      );
    } finally {
      if (mounted &&
          request == _request &&
          identical(account, music.personal)) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final music = context.watch<MusicController>();
    final status = _status;
    final listed = music.songs
        .where((song) => _isCloudinarySong(song))
        .toList();
    final audio = listed.where((song) => !song.isVideo).length;
    final bytes = listed.fold<int>(0, (total, song) => total + song.sizeBytes);
    final now = DateTime.now();
    final day =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    var listenedMs = 0, completed = 0;
    final heard = <String>{};
    for (final row in music.personal.days.values.where(
      (row) => row['date'] == day,
    )) {
      for (final entry in (row['tracks'] as Map? ?? {}).entries) {
        final track = entry.value;
        if (track is! Map || track['song'] is! Map) continue;
        final song = Song.fromJson(
          Map<String, dynamic>.from(track['song'] as Map),
        );
        if (song == null || !_isCloudinarySong(song)) continue;
        final ms = (track['ms'] as num? ?? 0).toInt();
        listenedMs += ms;
        completed += (track['completed'] as num? ?? 0).toInt();
        if (ms > 0) heard.add(song.id);
      }
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Advance'),
        actions: [
          IconButton(
            tooltip: 'Refresh Cloudinary status',
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          if (!_busy) await _refresh();
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            Row(
              children: [
                const Icon(
                  Icons.cloud_outlined,
                  color: NexMusic.violet,
                  size: 32,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Cloudinary',
                        style: TextStyle(
                          fontSize: 23,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        status?.cloudName ?? cloudinaryCloudName,
                        style: TextStyle(color: _muted(context)),
                      ),
                    ],
                  ),
                ),
                if (status?.plan != null)
                  Flexible(
                    child: Chip(
                      label: Text(
                        status!.plan!,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Auto refresh'),
              subtitle: const Text(
                'Check the account report every minute while this screen is open',
              ),
              value: _autoRefresh,
              onChanged: (value) => setState(() => _autoRefresh = value),
            ),
            if (status != null)
              Text(
                '${status.cached ? 'Cached account report' : 'Account report'} · fetched ${status.fetchedAt?.toLocal().toString().split('.').first ?? 'at an unknown time'}',
                style: TextStyle(color: _muted(context), fontSize: 12),
              ),
            const SizedBox(height: 12),
            if (_busy) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 12),
              const Text('Checking account usage…'),
              const SizedBox(height: 12),
            ],
            if (_error != null) ...[
              _cloudCard(
                context,
                icon: Icons.info_outline_rounded,
                title: status == null
                    ? 'Account usage unavailable'
                    : 'Showing previous report',
                value: _error!,
                detail: status == null
                    ? 'The app catalogue below is still available. Connect account reporting to see Cloudinary totals and limits.'
                    : 'The refresh failed. Values below are from the previous successful check.',
                footer: TextButton.icon(
                  onPressed: _busy ? null : _refresh,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ),
              const SizedBox(height: 12),
            ],
            _cloudCard(
              context,
              icon: Icons.library_music_outlined,
              title: 'Files on Cloudinary',
              value: status?.mediaCount == null
                  ? 'Not available'
                  : '${status!.mediaCount} media files',
              detail: status?.songCount != null
                  ? '${status!.songCount} songs (audio formats) · ${status.otherMediaCount ?? '—'} videos / other media\nIn the nexmusic upload folder, including files removed from the app list.'
                  : status == null
                  ? 'The actual Cloudinary file count needs account reporting.'
                  : 'Cloudinary could not return the audio/media counts. Try refreshing later.',
            ),
            const SizedBox(height: 12),
            _cloudCard(
              context,
              icon: Icons.music_note_rounded,
              title: 'Cloudinary files in app catalogue',
              value: music.catalogLoaded
                  ? '${listed.length} listed ${listed.length == 1 ? 'file' : 'files'}'
                  : 'Loading catalogue…',
              detail:
                  '$audio songs · ${listed.length - audio} videos\n${_cloudBytes(bytes.toDouble())} of listed original files. This is not total account storage.',
            ),
            const SizedBox(height: 12),
            _cloudCard(
              context,
              icon: Icons.cloud_upload_outlined,
              title: 'Uploads today',
              value:
                  '${listed.where((s) => s.createdAt != null && s.createdAt!.toLocal().year == now.year && s.createdAt!.toLocal().month == now.month && s.createdAt!.toLocal().day == now.day).length} listed files',
              detail:
                  'Files uploaded today in the app catalogue, across signed-in users ($day, local time). Deleted entries are excluded. The account file total above includes retained files.',
            ),
            const SizedBox(height: 12),
            _metricCard(
              context,
              'Storage used',
              Icons.storage_rounded,
              status?.storage,
              bytes: true,
              extra: status?.storage.remaining == null
                  ? status?.credits.remaining == null
                        ? status == null
                              ? 'Remaining space needs account reporting.'
                              : 'Cloudinary did not supply a storage limit in this report.'
                        : 'Approx. ${_cloudNumber(status!.credits.remaining!)} GB additional storage budget from ${_cloudNumber(status.credits.remaining!)} remaining shared credits (1 storage credit per GB). Streaming and transformations also consume this pool; this is an estimate, not a reserved storage allowance.'
                  : '${_cloudBytes(status!.storage.remaining!)} space remaining.',
            ),
            const SizedBox(height: 12),
            _metricCard(
              context,
              'Playback bandwidth',
              Icons.network_check_rounded,
              status?.bandwidth,
              bytes: true,
              extra:
                  'Rolling 30-day delivery usage across the account, including songs, videos and downloads. This is not a daily song-play allowance.',
            ),
            const SizedBox(height: 12),
            _metricCard(
              context,
              'Shared credits',
              Icons.donut_large_rounded,
              status?.credits,
              extra:
                  'Storage, bandwidth and transformations share this allowance. Bandwidth and transformations use a rolling 30-day window.',
            ),
            const SizedBox(height: 12),
            _cloudCard(
              context,
              icon: Icons.today_rounded,
              title: "Today's playback usage",
              value: 'Daily Cloudinary total unavailable',
              detail:
                  'Cloudinary account reporting does not provide a live daily song-play count here. The playback allowance above is reported over 30 days.\n\nYour Cloudinary listening today ($day, local time): ${heard.length} songs · ${listenedMs ~/ 60000} min · $completed completed plays. These listening stats can include downloaded songs and are not bandwidth usage.',
            ),
            const SizedBox(height: 12),
            _metricCard(
              context,
              'Transformations',
              Icons.auto_fix_high_rounded,
              status?.transformations,
              extra:
                  'Rolling 30-day processing usage, including format conversions.',
            ),
            if (status?.accountResources != null ||
                status?.requests != null) ...[
              const SizedBox(height: 12),
              _cloudCard(
                context,
                icon: Icons.query_stats_rounded,
                title: 'Account totals',
                value: '${status?.accountResources ?? '—'} stored resources',
                detail:
                    '${status?.requests ?? '—'} delivery requests in the account report. These include all media types, not only song plays.',
              ),
            ],
            if (status?.adminApi.limit != null) ...[
              const SizedBox(height: 12),
              _metricCard(
                context,
                'Admin API requests',
                Icons.api_rounded,
                status?.adminApi,
                extra:
                    'Hourly reporting API quota. This does not limit song playback.${status?.adminResetAt == null ? '' : '\nResets: ${status!.adminResetAt!.toLocal().toString().split('.').first} (local time)'}',
              ),
            ],
            const SizedBox(height: 16),
            Text(
              status == null
                  ? 'Account limits will appear when Cloudinary reporting is connected.'
                  : 'Cloudinary report updated: ${status.lastUpdated ?? 'Not supplied'}\nFetched: ${status.fetchedAt?.toLocal().toString().split('.').first ?? 'Not supplied'}\nAutomatic checks reuse reports for up to 5 minutes. Manual refresh requests the latest available report, at most once per minute. Cloudinary updates usage periodically; account figures are not instantaneous.',
              style: TextStyle(color: _muted(context), fontSize: 12),
            ),
            if (_webViewSupported) ...[
              const SizedBox(height: 24),
              OutlinedButton.icon(
                onPressed: () => _push(
                  context,
                  const NexBrowserScreen(
                    sharedLink: '',
                    showCloudinaryStats: true,
                  ),
                ),
                icon: const Icon(Icons.travel_explore_rounded),
                label: const Text('Open web browser'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

bool _isCloudinarySong(Song song) {
  if (song.isLocal || song.isPrivate || song.isProvider) return false;
  final uri = Uri.tryParse(song.url);
  return uri?.host == 'res.cloudinary.com' &&
      uri!.pathSegments.isNotEmpty &&
      uri.pathSegments.first == cloudinaryCloudName;
}

String _cloudNumber(double value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toStringAsFixed(2);

String _cloudBytes(double value) {
  if (value >= 1024 * 1024 * 1024) {
    return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
  if (value >= 1024 * 1024) {
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (value >= 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
  return '${value.toInt()} B';
}

Widget _metricCard(
  BuildContext context,
  String title,
  IconData icon,
  CloudinaryMetric? metric, {
  bool bytes = false,
  required String extra,
}) {
  String format(double value) =>
      bytes ? _cloudBytes(value) : _cloudNumber(value);
  final fraction = metric?.fraction;
  return _cloudCard(
    context,
    icon: icon,
    title: title,
    value: metric?.usage == null ? 'Not available' : format(metric!.usage!),
    detail: [
      if (metric?.limit != null) 'Limit: ${format(metric!.limit!)}',
      if (metric?.remaining != null) 'Remaining: ${format(metric!.remaining!)}',
      if (fraction != null) '${(fraction * 100).toStringAsFixed(1)}% used',
      extra,
    ].join('\n'),
    footer: fraction == null
        ? null
        : LinearProgressIndicator(
            value: fraction.clamp(0, 1),
            color: fraction >= 0.9
                ? Theme.of(context).colorScheme.error
                : NexMusic.violet,
            borderRadius: BorderRadius.circular(8),
            minHeight: 6,
          ),
  );
}

Widget _cloudCard(
  BuildContext context, {
  required IconData icon,
  required String title,
  required String value,
  required String detail,
  Widget? footer,
}) => Card(
  margin: EdgeInsets.zero,
  child: Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: NexMusic.violet, size: 21),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          value,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          detail,
          style: TextStyle(color: _muted(context), fontSize: 13, height: 1.5),
        ),
        if (footer != null) ...[const SizedBox(height: 12), footer],
      ],
    ),
  ),
);

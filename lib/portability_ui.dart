part of 'music_ui.dart';

class PlaylistCsvReviewScreen extends StatefulWidget {
  const PlaylistCsvReviewScreen({super.key, required this.rows});
  final List<Map<String, String>> rows;
  @override
  State<PlaylistCsvReviewScreen> createState() =>
      _PlaylistCsvReviewScreenState();
}

class _PlaylistCsvReviewScreenState extends State<PlaylistCsvReviewScreen> {
  final options = <int, List<Song>>{}, selected = <int, Song>{};
  int processed = 0;
  bool busy = true, cancelled = false;
  Future<void> match() async {
    final music = context.read<MusicController>();
    for (var i = 0; i < widget.rows.length; i++) {
      if (!mounted || cancelled) return;
      final row = widget.rows[i],
          referenced = csvReferencedSong(widget.rows[i]);
      if (referenced != null) {
        options[i] = [referenced];
        selected[i] = referenced;
      } else {
        try {
          final found = await music.discovery.browse(
            query: '${row['title']} ${row['artist'] ?? ''}',
          );
          options[i] = found.songs;
          String normal(String s) =>
              s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\u0900-\u0dff]'), '');
          final exact = found.songs
              .where(
                (s) =>
                    normal(s.title) == normal(row['title'] ?? '') &&
                    normal(s.artist) == normal(row['artist'] ?? ''),
              )
              .toList();
          if (exact.length == 1) selected[i] = exact.single;
        } catch (_) {
          options[i] = [];
        }
      }
      if (mounted) setState(() => processed = i + 1);
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => match());
  }

  @override
  void dispose() {
    cancelled = true;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Review imported tracks')),
    body: Column(
      children: [
        if (busy)
          LinearProgressIndicator(
            value: widget.rows.isEmpty ? 0 : processed / widget.rows.length,
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '${selected.length} selected · $processed/${widget.rows.length} checked. Review recording versions before importing.',
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: widget.rows.length,
            itemBuilder: (_, i) => ListTile(
              title: Text(widget.rows[i]['title'] ?? ''),
              subtitle: Text(widget.rows[i]['artist'] ?? ''),
              trailing: IconButton(
                tooltip: 'Choose recording',
                icon: Icon(
                  selected.containsKey(i)
                      ? Icons.check_circle
                      : Icons.help_outline,
                ),
                onPressed: () => _sheet(
                  context,
                  title: 'Choose recording',
                  (sheet) => [
                    ListTile(
                      title: const Text('Skip this track'),
                      onTap: () {
                        setState(() => selected.remove(i));
                        Navigator.pop(sheet);
                      },
                    ),
                    for (final song in options[i] ?? <Song>[])
                      ListTile(
                        title: Text(song.title),
                        subtitle: Text('${song.artist} · ${song.providerId}'),
                        onTap: () {
                          setState(() => selected[i] = song);
                          Navigator.pop(sheet);
                        },
                      ),
                    if ((options[i] ?? []).isEmpty)
                      const ListTile(
                        title: Text(
                          'No candidates found. Add this track manually after import.',
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () async {
                      cancelled = true;
                      final name = await _nameDialog(
                        context,
                        title: 'Imported playlist name',
                        action: 'Create',
                      );
                      if (name == null || !context.mounted) return;
                      final p = context
                          .read<MusicController>()
                          .personal
                          .createPlaylist(
                            name,
                            tracks:
                                (selected.entries.toList()
                                      ..sort((a, b) => a.key.compareTo(b.key)))
                                    .map((e) => e.value)
                                    .toList(),
                          );
                      Navigator.of(context).pushReplacement<void, void>(
                        NexPageRoute(
                          reducedMotion: MediaQuery.disableAnimationsOf(
                            context,
                          ),
                          builder: (_) => PlaylistScreen(id: p.id),
                        ),
                      );
                    },
              child: Text('Import ${selected.length} tracks'),
            ),
          ),
        ),
      ],
    ),
  );
}

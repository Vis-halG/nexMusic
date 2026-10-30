part of 'music_ui.dart';

class SongLanguagesScreen extends StatelessWidget {
  const SongLanguagesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final music = context.watch<MusicController>();
    final selected = music.personal.settings.selectedLanguages;
    return Scaffold(
      appBar: AppBar(title: const Text('Song languages')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Choose the languages you listen to',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            'Your choices apply to Home, Stream, Library and playback. Hindi and English are selected by default.',
            style: TextStyle(color: _muted(context)),
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              for (final language in [
                'Hindi',
                'English',
                ...music.availableSongLanguages.where(
                  (l) => l != 'Hindi' && l != 'English',
                ),
              ])
                FilterChip(
                  label: Text(language),
                  selected: selected.contains(language),
                  onSelected: (value) {
                    final next = {...selected};
                    value ? next.add(language) : next.remove(language);
                    if (next.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Keep at least one language selected.'),
                        ),
                      );
                      return;
                    }
                    unawaited(
                      music.setListeningSetting(
                        'songLanguages',
                        next.toList()..sort(),
                      ),
                    );
                  },
                ),
            ],
          ),
          const SizedBox(height: 24),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.info_outline_rounded),
            title: Text('Songs with unknown language stay available'),
            subtitle: Text(
              'Only songs with a saved language are filtered. We never guess a song’s language from its name or artist.',
            ),
          ),
        ],
      ),
      bottomNavigationBar: const MiniPlayer(),
    );
  }
}

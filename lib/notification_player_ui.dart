part of 'music_ui.dart';

class NotificationPlayerSettingsScreen extends StatelessWidget {
  const NotificationPlayerSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final music = context.watch<MusicController>();
    final settings = music.personal.settings;
    final first = NotificationPlayerAction.parse(
      settings.text('notificationShortcut1', 'like'),
    );
    final second = NotificationPlayerAction.parse(
      settings.text('notificationShortcut2', 'close'),
    );
    IconData icon(NotificationPlayerAction action) => switch (action) {
      NotificationPlayerAction.like => Icons.favorite_border_rounded,
      NotificationPlayerAction.shuffle => Icons.shuffle_rounded,
      NotificationPlayerAction.repeat => Icons.repeat_rounded,
      NotificationPlayerAction.close => Icons.close_rounded,
      NotificationPlayerAction.none => Icons.remove_rounded,
    };
    Widget shortcut(
      int slot,
      NotificationPlayerAction value,
      NotificationPlayerAction other,
    ) => ListTile(
      title: Text('Shortcut $slot'),
      leading: Icon(icon(value)),
      trailing: DropdownButton<NotificationPlayerAction>(
        key: ValueKey('notification-shortcut-$slot'),
        value: value,
        underline: const SizedBox.shrink(),
        items: [
          for (final action in NotificationPlayerAction.values)
            DropdownMenuItem(
              value: action,
              enabled:
                  action == NotificationPlayerAction.none ||
                  action != other ||
                  action == value,
              child: Text(action.label),
            ),
        ],
        onChanged: (action) {
          if (action != null) {
            unawaited(
              music.setListeningSetting(
                'notificationShortcut$slot',
                action.name,
              ),
            );
          }
        },
      ),
    );
    final song = music.current;
    return Scaffold(
      appBar: AppBar(title: const Text('Notification player')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Controls preview',
                      style: TextStyle(color: _muted(context), fontSize: 12),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: _Thumb(
                            size: 48,
                            icon: Icons.music_note_rounded,
                            imageUrl: song?.artworkUrl ?? '',
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                song?.title ?? 'Your music',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                song?.artist.isNotEmpty == true
                                    ? song!.artist
                                    : 'Your playback shortcuts',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: _muted(context),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        const Icon(Icons.skip_previous_rounded, size: 26),
                        Icon(
                          music.playing
                              ? Icons.pause_circle_filled_rounded
                              : Icons.play_circle_filled_rounded,
                          size: 40,
                          color: NexMusic.violet,
                        ),
                        const Icon(Icons.skip_next_rounded, size: 26),
                        for (final action in {first, second})
                          if (action != NotificationPlayerAction.none)
                            Icon(icon(action), size: 22),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Text(
              'Previous, play/pause and next are always available. Choose two extra shortcuts for Android 13 or later. Your phone controls the final notification layout.',
              style: TextStyle(fontSize: 12),
            ),
          ),
          shortcut(1, first, second),
          shortcut(2, second, first),
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text(
              'Changes apply to the notification and lock-screen player while your music keeps playing.',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

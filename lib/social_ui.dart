part of 'music_ui.dart';

Future<void> _invitePlaylist(
  BuildContext context,
  MusicPlaylist playlist,
) => _featureTask(context, () async {
  final music = context.read<MusicController>();
  await music.personal.syncNow();
  if (!context.mounted) return;
  final editor = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: const Text('Invite collaborators'),
      content: const Text('Choose what people using this invitation can do.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog, false),
          child: const Text('Listen only'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialog, true),
          child: const Text('Edit playlist'),
        ),
      ],
    ),
  );
  if (editor == null) return;
  final token = await music.social!.invitePlaylist(playlist, editor: editor);
  final link = '$pushWorkerUrl/share/invite/$token';
  if (context.mounted) {
    await _invitationDialog(context, playlist.name, link);
  }
});
Future<void> _manageCollaborators(
  BuildContext context,
  MusicPlaylist playlist,
) async {
  final music = context.read<MusicController>();
  await _sheet(
    context,
    title: 'Collaborators',
    (sheet) => [
      for (final member in playlist.members.where(
        (id) => id != playlist.ownerUid,
      ))
        ListTile(
          title: Text(
            'Listener ${member.substring(0, member.length.clamp(0, 8))}',
          ),
          subtitle: Text(
            playlist.editors.contains(member) ? 'Editor' : 'Viewer',
          ),
          trailing: PopupMenuButton<String>(
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'editor', child: Text('Make editor')),
              PopupMenuItem(value: 'viewer', child: Text('Listen only')),
              PopupMenuItem(
                value: 'remove',
                child: Text('Remove collaborator'),
              ),
            ],
            onSelected: (action) {
              Navigator.pop(sheet);
              _featureTask(
                context,
                () => music.social!.setPlaylistMember(
                  playlist,
                  member,
                  editor: action == 'editor',
                  remove: action == 'remove',
                ),
              );
            },
          ),
        ),
      if (playlist.members.length == 1)
        const ListTile(
          title: Text('Invite people from Playlist options to listen or edit.'),
        ),
    ],
  );
}

Future<void> _invitationDialog(
  BuildContext context,
  String name,
  String link,
) => showDialog<void>(
  context: context,
  builder: (dialog) => AlertDialog(
    title: Text(name),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          QrImageView(data: link, size: 200, backgroundColor: Colors.white),
          SelectableText(link),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () {
          Clipboard.setData(ClipboardData(text: link));
          Navigator.pop(dialog);
        },
        child: const Text('Copy'),
      ),
      TextButton(
        onPressed: () => _shareMusic(dialog, link),
        child: const Text('Share'),
      ),
    ],
  ),
);

class SocialMusicScreen extends StatefulWidget {
  const SocialMusicScreen({super.key});
  @override
  State<SocialMusicScreen> createState() => _SocialMusicScreenState();
}

class _SocialMusicScreenState extends State<SocialMusicScreen> {
  bool follow = false, syncing = false, shareTaste = false;
  String? lastId;
  MusicSocial? connected;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final music = context.read<MusicController>();
      connected = music.social;
      connected?.onState = _follow;
    });
  }

  Future<void> _follow(Map<String, dynamic> state) async {
    if (!mounted ||
        !follow ||
        syncing ||
        connected?.isHost == true ||
        state['active'] != true) {
      return;
    }
    final song = state['current'] is Map
        ? Song.fromJson(Map<String, dynamic>.from(state['current'] as Map))
        : null;
    if (song == null || song.isLocal) return;
    syncing = true;
    try {
      final music = context.read<MusicController>();
      if (music.current?.id != song.id) await music.play(song, from: [song]);
      var ms = (state['positionMs'] as num? ?? 0).toInt();
      final updated = state['updatedAt'];
      if (state['playing'] == true && updated is Timestamp) {
        ms += DateTime.now()
            .difference(updated.toDate())
            .inMilliseconds
            .clamp(0, 15000);
      }
      if ((music.position.inMilliseconds - ms).abs() > 2000) {
        await music.seek(Duration(milliseconds: ms));
      }
      if (state['playing'] == true) {
        await music.playback.resume();
      } else {
        await music.pauseAudio();
      }
    } catch (e) {
      if (mounted) {
        context.read<MusicController>().announce(
          'Could not follow this track.',
        );
      }
    } finally {
      syncing = false;
    }
  }

  @override
  void dispose() {
    connected?.onState = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final music = context.watch<MusicController>(), social = music.social;
    if (social == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Listen with friends')),
        body: Center(
          child: FilledButton(
            onPressed: () {
              music.guestMode = false;
              music.notifyListeners();
            },
            child: const Text('Sign in to connect'),
          ),
        ),
      );
    }
    final room = social.room;
    return Scaffold(
      appBar: AppBar(title: const Text('Listen with friends')),
      body: ListView(
        children: [
          if (social.roomId == null) ...[
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('Create a listening room'),
              onTap: () async {
                final name = await _nameDialog(
                  context,
                  title: 'Room name',
                  action: 'Create',
                );
                if (name != null && context.mounted) {
                  await _featureTask(context, () async {
                    await social.createRoom(name);
                    await social.publish(
                      music.current,
                      music.playing,
                      music.position,
                    );
                  });
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.login),
              title: const Text('Join a room'),
              onTap: () async {
                final code = await _nameDialog(
                  context,
                  title: 'Room code or invite link',
                  action: 'Join',
                );
                if (code != null && context.mounted) {
                  await _featureTask(
                    context,
                    () => social.join(
                      Uri.tryParse(code)?.pathSegments.lastOrNull ?? code,
                    ),
                  );
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add),
              title: const Text('Accept playlist invitation'),
              onTap: () async {
                final link = await _nameDialog(
                  context,
                  title: 'Invitation link',
                  action: 'Join',
                );
                if (link != null && context.mounted) {
                  await _featureTask(context, () async {
                    final id = await social.acceptPlaylistInvite(
                      Uri.tryParse(link)?.pathSegments.lastOrNull ?? link,
                    );
                    if (context.mounted) _push(context, PlaylistScreen(id: id));
                  });
                }
              },
            ),
          ] else ...[
            ListTile(
              leading: const Icon(Icons.groups),
              title: Text('${room?['name'] ?? 'Connecting…'}'),
              subtitle: Text(
                '${(room?['members'] as List? ?? []).length} people · ${social.isHost ? 'You are the host' : 'Guest'}',
              ),
              trailing: IconButton(
                tooltip: 'Invite friends',
                icon: const Icon(Icons.share),
                onPressed: () => _invitationDialog(
                  context,
                  '${room?['name'] ?? 'Music room'}',
                  '$pushWorkerUrl/share/room/${social.roomId}',
                ),
              ),
            ),
            if (room?['active'] == false)
              const ListTile(title: Text('The host ended this room.')),
            if (!social.isHost)
              SwitchListTile(
                title: const Text('Follow host playback'),
                subtitle: const Text('Each device streams the same track'),
                value: follow,
                onChanged: (v) {
                  setState(() => follow = v);
                  if (v && room != null) _follow(room);
                },
              ),
            if (room?['current'] is Map)
              ListTile(
                leading: const Icon(Icons.equalizer),
                title: Text('${(room!['current'] as Map)['title']}'),
                subtitle: const Text('Host is playing'),
              ),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('Request a track'),
              onTap: () => _push(context, RoomRequestScreen(social: social)),
            ),
            SwitchListTile(
              title: const Text('Share my taste with this room'),
              subtitle: const Text('Blend up to 20 of your liked tracks'),
              value: shareTaste,
              onChanged: (v) => _featureTask(context, () async {
                await social.shareTaste(music.likedSongs, enabled: v);
                if (mounted) setState(() => shareTaste = v);
              }),
            ),
            ListTile(
              leading: const Icon(Icons.auto_awesome),
              title: const Text('Make a group mix'),
              subtitle: const Text(
                'Blend your likes with the room’s requested tracks',
              ),
              onTap: () => _featureTask(context, () async {
                final songs = [
                  for (final request in social.requests)
                    ...readSongs([request['song']]),
                  ...social.groupTaste,
                  ...music.likedSongs.take(20),
                ];
                if (songs.isEmpty) {
                  throw StateError('Like or request a few tracks first.');
                }
                final p = music.personal.createPlaylist(
                  'Group mix',
                  tracks: {for (final s in songs) s.id: s}.values.toList(),
                );
                _push(context, PlaylistScreen(id: p.id));
              }),
            ),
            for (final request in social.requests)
              Builder(
                builder: (context) {
                  final song = readSongs([request['song']]).firstOrNull;
                  if (song == null) return const SizedBox.shrink();
                  final votes = request['votes'] as Map? ?? {};
                  return ListTile(
                    title: Text(song.title),
                    subtitle: Text(
                      '${song.artist} · ${votes.values.where((v) => v == true).length} votes',
                    ),
                    leading: IconButton(
                      tooltip: 'Vote',
                      icon: Icon(
                        votes[social.uid] == true
                            ? Icons.thumb_up
                            : Icons.thumb_up_outlined,
                      ),
                      onPressed: () => _featureTask(
                        context,
                        () => social.vote(
                          request['id'] as String,
                          votes[social.uid] != true,
                        ),
                      ),
                    ),
                    trailing: social.isHost
                        ? IconButton(
                            tooltip: 'Play request',
                            icon: const Icon(Icons.play_arrow),
                            onPressed: () => _featureTask(context, () async {
                              await music.play(song);
                              await social.removeRequest(
                                request['id'] as String,
                              );
                              await social.publish(
                                song,
                                music.playing,
                                music.position,
                              );
                            }),
                          )
                        : null,
                  );
                },
              ),
            TextButton(
              onPressed: () => _featureTask(context, social.leave),
              child: Text(social.isHost ? 'End room' : 'Leave room'),
            ),
          ],
          if (social.error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(social.error!),
            ),
        ],
      ),
    );
  }
}

class RoomRequestScreen extends StatefulWidget {
  const RoomRequestScreen({super.key, required this.social});
  final MusicSocial social;
  @override
  State<RoomRequestScreen> createState() => _RoomRequestScreenState();
}

class _RoomRequestScreenState extends State<RoomRequestScreen> {
  List<Song> tracks = [];
  bool busy = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Request a track')),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'Search and press enter',
              prefixIcon: Icon(Icons.search),
            ),
            onSubmitted: (v) async {
              setState(() => busy = true);
              final result = await context
                  .read<MusicController>()
                  .discovery
                  .browse(query: v);
              if (mounted) {
                setState(() {
                  tracks = result.songs;
                  busy = false;
                });
              }
            },
          ),
        ),
        _LoadingSlot(active: busy, height: 24),
        Expanded(
          child: ListView.builder(
            itemCount: tracks.length,
            itemBuilder: (_, i) => ListTile(
              title: Text(tracks[i].title),
              subtitle: Text(tracks[i].artist),
              trailing: IconButton(
                tooltip: 'Request',
                icon: const Icon(Icons.add),
                onPressed: () => _featureTask(context, () async {
                  await widget.social.request(tracks[i]);
                  if (context.mounted) Navigator.pop(context);
                }),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

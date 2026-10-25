part of 'music_ui.dart';

class AdminUsersScreen extends StatefulWidget {
  const AdminUsersScreen({super.key});
  @override
  State<AdminUsersScreen> createState() => _AdminUsersScreenState();
}

class _AdminUsersScreenState extends State<AdminUsersScreen> {
  final _search = TextEditingController();
  final _busy = <String>{};
  List<AppUser> _users = [];
  String _filter = 'All', _cursor = '';
  String? _error;
  bool _loading = true;

  /// Only the owner can let others manage users.
  bool _canGrant = false;
  int _request = 0;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    _load();
    _refresh = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!_loading && _busy.isEmpty && _cursor.isEmpty) _load();
    });
  }

  @override
  void dispose() {
    _request++;
    _refresh?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    final music = context.read<MusicController>();
    if (!music.isAdmin) {
      setState(() => _loading = false);
      return;
    }
    final account = music.personal;
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await music.adminRequest(
        '/admin/users',
        query: {if (more && _cursor.isNotEmpty) 'pageToken': _cursor},
      );
      if (!mounted ||
          request != _request ||
          account != music.personal ||
          !music.isAdmin) {
        return;
      }
      final rows = (result['users'] as List).map(
        (e) => AppUser.fromJson(Map<String, dynamic>.from(e as Map)),
      );
      setState(() {
        _users = {
          for (final row in [...(more ? _users : <AppUser>[]), ...rows])
            row.uid: row,
        }.values.toList()..sort((a, b) => b.lastLogin.compareTo(a.lastLogin));
        _cursor = result['nextPageToken'] as String? ?? '';
        _canGrant = result['canGrant'] == true;
      });
    } catch (error) {
      if (mounted && request == _request) {
        setState(() => _error = '$error'.replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  Future<void> _change(AppUser user, bool blocked) async {
    if (_busy.contains(user.uid) || user.protected) return;
    if (blocked && !user.blocked) {
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Block ${user.name.isEmpty ? user.email : user.name}?'),
          content: const Text(
            'They will lose access to NexMusic and cannot sign in until you unblock them.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Block'),
            ),
          ],
        ),
      );
      if (approved != true || !mounted) return;
    }
    final music = context.read<MusicController>(),
        account = context.read<MusicController>().personal;
    setState(() => _busy.add(user.uid));
    try {
      await music.adminRequest(
        '/admin/users/status',
        body: {'uid': user.uid, 'blocked': blocked},
      );
      if (!mounted || account != music.personal) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(blocked ? 'User blocked' : 'User unblocked')),
      );
    } catch (error) {
      if (mounted && account == music.personal) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$error'.replaceFirst('Bad state: ', ''))),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy.remove(user.uid));
        await _load();
      }
    }
  }

  Future<void> _setManager(AppUser user, bool manager) async {
    if (_busy.contains(user.uid) || user.protected || !_canGrant) return;
    final music = context.read<MusicController>(), account = music.personal;
    setState(() => _busy.add(user.uid));
    try {
      await music.adminRequest(
        '/admin/users/manager',
        body: {'uid': user.uid, 'manager': manager},
      );
      if (!mounted || account != music.personal) return;
      final who = user.name.isEmpty ? user.email : user.name;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            manager
                ? '$who can now manage users'
                : '$who can no longer manage users',
          ),
        ),
      );
    } catch (error) {
      if (mounted && account == music.personal) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$error'.replaceFirst('Bad state: ', ''))),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy.remove(user.uid));
        await _load();
      }
    }
  }

  String _time(int timestamp) {
    if (timestamp <= 0) return 'No login recorded';
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal();
    return '${date.day}/${date.month}/${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = context.select<MusicController, bool>((m) => m.isAdmin);
    if (!isAdmin) {
      return Scaffold(
        appBar: AppBar(title: const Text('Manage users')),
        body: const Center(child: Text('Administrator access required.')),
      );
    }
    final query = _search.text.trim().toLowerCase();
    final users = _users
        .where(
          (u) =>
              '${u.name} ${u.email} ${u.uid}'.toLowerCase().contains(query) &&
              switch (_filter) {
                'Online' => u.online,
                'Signed in' => u.signedIn,
                'Blocked' => u.blocked,
                _ => true,
              },
        )
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage users'),
        actions: [
          IconButton(
            tooltip: 'Refresh users',
            onPressed: _loading ? null : () => _load(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search name, email or user ID',
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${_users.length} users · ${_users.where((u) => u.online).length} online · ${_users.where((u) => u.blocked).length} blocked',
              ),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                for (final label in ['All', 'Online', 'Signed in', 'Blocked'])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(label),
                      selected: _filter == label,
                      onSelected: (_) => setState(() => _filter = label),
                    ),
                  ),
              ],
            ),
          ),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(16), child: Text(_error!)),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _load(),
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: users.length + 1,
                itemBuilder: (context, index) {
                  if (index == users.length) {
                    return _cursor.isNotEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(16),
                            child: OutlinedButton(
                              onPressed: _loading
                                  ? null
                                  : () => _load(more: true),
                              child: const Text('Load more users'),
                            ),
                          )
                        : users.isEmpty && !_loading
                        ? const Padding(
                            padding: EdgeInsets.all(32),
                            child: Center(child: Text('No matching users.')),
                          )
                        : const SizedBox(height: 24);
                  }
                  final user = users[index];
                  final status = user.blocked
                      ? 'Blocked'
                      : user.online
                      ? 'Online now'
                      : user.signedIn
                      ? 'Signed in · Offline'
                      : 'Offline';
                  return Card(
                    margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            user.name.isEmpty ? user.email : user.name,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          if (user.email.isNotEmpty) SelectableText(user.email),
                          const SizedBox(height: 6),
                          Text(
                            '$status${user.protected
                                ? ' · Administrator'
                                : user.manager
                                ? ' · Manages users'
                                : ''}',
                          ),
                          Text(
                            'Last login: ${_time(user.lastLogin)}',
                            style: TextStyle(color: _muted(context)),
                          ),
                          if (user.lastSeen > 0)
                            Text(
                              'Last seen: ${_time(user.lastSeen)}',
                              style: TextStyle(color: _muted(context)),
                            ),
                          SelectableText(
                            'ID: ${user.uid}',
                            style: TextStyle(
                              fontSize: 11,
                              color: _muted(context),
                            ),
                          ),
                          if (_canGrant && !user.protected)
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('Can manage users'),
                              value: user.manager,
                              onChanged: _busy.contains(user.uid)
                                  ? null
                                  : (value) => _setManager(user, value),
                            ),
                          // Only the owner can block someone who manages users.
                          if (!user.protected && (_canGrant || !user.manager))
                            Align(
                              alignment: Alignment.centerRight,
                              child: _busy.contains(user.uid)
                                  ? const SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Wrap(
                                      spacing: 8,
                                      children: [
                                        if (user.blocked &&
                                            !user.signInDisabled)
                                          TextButton(
                                            onPressed: () =>
                                                _change(user, true),
                                            child: const Text('Retry block'),
                                          ),
                                        OutlinedButton.icon(
                                          onPressed: () =>
                                              _change(user, !user.blocked),
                                          icon: Icon(
                                            user.blocked
                                                ? Icons.lock_open
                                                : Icons.block,
                                          ),
                                          label: Text(
                                            user.blocked ? 'Unblock' : 'Block',
                                          ),
                                        ),
                                      ],
                                    ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

const nexMusicAdminEmail = 'vishalgupta25980@gmail.com';
bool isNexMusicAdmin(String email, {required bool verified}) =>
    verified && email.toLowerCase() == nexMusicAdminEmail;

class AppUser {
  const AppUser({
    required this.uid,
    required this.email,
    required this.name,
    this.blocked = false,
    this.online = false,
    this.signedIn = false,
    this.protected = false,
    this.signInDisabled = false,
    this.manager = false,
    this.lastLogin = 0,
    this.lastSeen = 0,
    this.createdAt = 0,
  });
  factory AppUser.fromJson(Map<String, dynamic> data) => AppUser(
    uid: data['uid'] as String,
    email: data['email'] as String? ?? '',
    name: data['name'] as String? ?? '',
    blocked: data['blocked'] == true,
    online: data['online'] == true,
    signedIn: data['signedIn'] == true,
    protected: data['protected'] == true,
    signInDisabled: data['signInDisabled'] == true,
    manager: data['manager'] == true,
    lastLogin: (data['lastLogin'] as num? ?? 0).toInt(),
    lastSeen: (data['lastSeen'] as num? ?? 0).toInt(),
    createdAt: (data['createdAt'] as num? ?? 0).toInt(),
  );
  final String uid, email, name;
  final bool blocked, online, signedIn, protected, signInDisabled;

  /// The owner let this account manage users.
  final bool manager;
  final int lastLogin, lastSeen, createdAt;
}

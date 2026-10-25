export const ADMIN_EMAIL = 'vishalgupta25980@gmail.com';
/** The owner, who alone can let other accounts manage users. */
export const isAdmin = identity => identity.email_verified === true &&
  typeof identity.email === 'string' && identity.email.toLowerCase() === ADMIN_EMAIL;
const reply = (data, status = 200) => Response.json(data, { status,
  headers: { 'Cache-Control': 'no-store' } });

/** Whether the owner let [uid] manage users. Only this Worker writes the flag. */
async function isManager(root, uid, headers, fetcher) {
  const response = await fetcher(`https://firestore.googleapis.com/v1/${root}/appUsers/${encodeURIComponent(uid)}`, { headers });
  if (response.status === 404) return false;
  if (!response.ok) throw new Error('Could not check user management access.');
  return (await response.json()).fields?.manager?.booleanValue === true;
}

/** Existing ID tokens are also checked against the server-managed app block. */
export async function accountAccess(projectId, uid, idToken, fetcher = fetch) {
  const response = await fetcher(`https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default)/documents/appUsers/${encodeURIComponent(uid)}`, {
    headers: { Authorization: `Bearer ${idToken}` },
  });
  if (response.status === 404) return null;
  if (!response.ok) return reply({ error: 'Could not verify account access. Try again.' }, 503);
  if ((await response.json()).fields?.blocked?.booleanValue === true) {
    return reply({ error: 'Your NexMusic account has been blocked.', blocked: true }, 403);
  }
  return null;
}

export async function adminUsers(request, { identity, projectId, getToken, fetcher = fetch, now = Date.now() }) {
  const owner = isAdmin(identity);
  const url = new URL(request.url);
  const authRoot = `https://identitytoolkit.googleapis.com/v1/projects/${projectId}`;
  const root = `projects/${projectId}/databases/(default)/documents`;
  try {
    const token = await getToken();
    const headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
    if (!owner && !(await isManager(root, identity.sub, headers, fetcher))) {
      return reply({ error: 'Administrator access required.' }, 403);
    }
    const api = async (path, body) => {
      const response = await fetcher(`${authRoot}/${path}`, { headers,
        ...(body ? { method: 'POST', body: JSON.stringify(body) } : {}),
      });
      if (!response.ok) throw new Error('User management is unavailable.');
      return response.json();
    };
    if (request.method === 'GET' && url.pathname === '/admin/users') {
      const query = new URLSearchParams({ maxResults: '100' });
      const cursor = url.searchParams.get('pageToken');
      if (cursor) {
        if (cursor.length > 2000) return reply({ error: 'Invalid page token.' }, 400);
        query.set('nextPageToken', cursor);
      }
      const page = await api(`accounts:batchGet?${query}`);
      const users = page.users || [];
      const metadata = new Map();
      if (users.length) {
        const documents = users.flatMap(user => [
          `${root}/appUsers/${user.localId}`, `${root}/appPresence/${user.localId}`,
        ]);
        const response = await fetcher(`https://firestore.googleapis.com/v1/${root}:batchGet`, {
          method: 'POST', headers, body: JSON.stringify({ documents }),
        });
        if (!response.ok) throw new Error('User status is unavailable.');
        for (const row of await response.json()) {
          if (row.found) metadata.set(row.found.name, row.found.fields || {});
        }
      }
      return reply({ users: users.map(user => {
        const status = metadata.get(`${root}/appUsers/${user.localId}`);
        const presence = metadata.get(`${root}/appPresence/${user.localId}`);
        const sessions = Object.values(presence?.sessions?.mapValue?.fields || {}).map(v => v.mapValue?.fields || {});
        const signedIn = sessions.filter(s => s.signedIn?.booleanValue === true);
        const lastSeen = Math.max(0, ...sessions.map(s => Date.parse(s.lastSeen?.timestampValue || '') || 0));
        const online = signedIn.some(s => now - (Date.parse(s.lastSeen?.timestampValue || '') || 0) < 150000);
        const blocked = user.disabled === true || status?.blocked?.booleanValue === true;
        return {
          uid: user.localId, name: user.displayName || '', email: user.email || '',
          photoUrl: user.photoUrl || '', createdAt: Number(user.createdAt) || 0,
          lastLogin: Number(user.lastLoginAt) || 0, lastSeen,
          blocked, signedIn: !blocked && signedIn.length > 0, online: !blocked && online,
          signInDisabled: user.disabled === true,
          protected: (user.email || '').toLowerCase() === ADMIN_EMAIL,
          manager: status?.manager?.booleanValue === true,
        };
      }), nextPageToken: page.nextPageToken || '', canGrant: owner });
    }
    if (request.method !== 'POST') return reply({ error: 'Route not found.' }, 404);
    let input;
    try { input = await request.json(); } catch { return reply({ error: 'Invalid request.' }, 400); }
    if (typeof input.uid !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(input.uid)) {
      return reply({ error: 'A valid user is required.' }, 400);
    }
    if (url.pathname === '/admin/users/manager') {
      if (!owner) return reply({ error: 'Only the owner can change who manages users.' }, 403);
      if (typeof input.manager !== 'boolean') return reply({ error: 'A valid manager state is required.' }, 400);
      const user = (await api('accounts:lookup', { localId: [input.uid] })).users?.[0];
      if (!user) return reply({ error: 'User not found.' }, 404);
      if ((user.email || '').toLowerCase() === ADMIN_EMAIL) {
        return reply({ error: 'The owner always manages users.' }, 400);
      }
      const response = await fetcher(`https://firestore.googleapis.com/v1/${root}/appUsers/${encodeURIComponent(input.uid)}?updateMask.fieldPaths=manager&updateMask.fieldPaths=updatedAt`, {
        method: 'PATCH', headers, body: JSON.stringify({ fields: {
          manager: { booleanValue: input.manager }, updatedAt: { integerValue: String(now) },
        } }),
      });
      if (!response.ok) throw new Error('Could not update user management access.');
      return reply({ uid: input.uid, manager: input.manager });
    }
    if (url.pathname !== '/admin/users/status') return reply({ error: 'Route not found.' }, 404);
    if (typeof input.blocked !== 'boolean') {
      return reply({ error: 'A valid user and block state are required.' }, 400);
    }
    const user = (await api('accounts:lookup', { localId: [input.uid] })).users?.[0];
    if (!user) return reply({ error: 'User not found.' }, 404);
    if (input.uid === identity.sub || (user.email || '').toLowerCase() === ADMIN_EMAIL) {
      return reply({ error: 'The administrator account cannot be blocked.' }, 400);
    }
    // Managers cannot lock each other out; only the owner can block one.
    if (!owner && await isManager(root, input.uid, headers, fetcher)) {
      return reply({ error: 'Only the owner can block someone who manages users.' }, 403);
    }
    const saveBlock = async blocked => {
      const response = await fetcher(`https://firestore.googleapis.com/v1/${root}/appUsers/${encodeURIComponent(input.uid)}?updateMask.fieldPaths=blocked&updateMask.fieldPaths=updatedAt`, {
        method: 'PATCH', headers, body: JSON.stringify({ fields: {
          blocked: { booleanValue: blocked }, updatedAt: { integerValue: String(now) },
        } }),
      });
      if (!response.ok) throw new Error('Could not update account access.');
    };
    // Block cloud access before disabling sign-in. Unblocking enables sign-in
    // first and only then reopens cloud access. Partial failures can be retried.
    if (input.blocked) await saveBlock(true);
    await api('accounts:update', { localId: input.uid, disableUser: input.blocked,
      ...(input.blocked ? { validSince: String(Math.floor(now / 1000)) } : {}),
    });
    if (!input.blocked) await saveBlock(false);
    return reply({ uid: input.uid, blocked: input.blocked });
  } catch {
    return reply({ error: 'Could not finish user management. Refresh and retry.' }, 503);
  }
}

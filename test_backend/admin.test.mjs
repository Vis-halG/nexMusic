import { test } from 'node:test';
import assert from 'node:assert/strict';
import { adminUsers, accountAccess, ADMIN_EMAIL, isAdmin } from '../push_worker/admin_users.js';

const identity = { sub: 'owner', email: ADMIN_EMAIL, email_verified: true };
const request = (body, url = 'https://worker/admin/users') => new Request(url,
  body ? { method: 'POST', body: JSON.stringify(body) } : {});
const context = fetcher => ({ identity, projectId: 'test', getToken: async () => 'service-token', fetcher });

test('the admin role requires the exact verified email and cannot be forged in a request body', async () => {
  for (const claimant of [ { ...identity, email_verified: false },
    { ...identity, email: 'vishalgupta25989@gmail.com' },
    { ...identity, email: `${ADMIN_EMAIL}.fake` } ]) {
    assert.equal(isAdmin(claimant), false);
    // Only the claimant's own server-managed access record is read.
    const fetcher = async url => {
      if (!url.includes('/appUsers/owner')) throw Error('Should never contact Google');
      return new Response('', { status: 404 });
    };
    const response = await adminUsers(request({ ...identity }), { ...context(fetcher), identity: claimant });
    assert.equal(response.status, 403);
  }
});

const manager = { sub: 'mira', email: 'mira@example.com', email_verified: true };
const managers = new Set(['mira', 'max']);
const lookup = (uid, email = `${uid}@example.com`) => Response.json({ users: [{ localId: uid, email }] });
// Answers access records from `managers`, user lookups and writes.
const directory = calls => async (url, options = {}) => {
  const body = options.body && JSON.parse(options.body);
  const record = url.match(/\/appUsers\/([^?]+)$/);
  if (record && !options.method) {
    return managers.has(record[1]) ? Response.json({ fields: { manager: { booleanValue: true } } }) : new Response('', { status: 404 });
  }
  if (url.endsWith('accounts:lookup')) return lookup(body.localId[0], body.localId[0] === 'owner' ? ADMIN_EMAIL : undefined);
  calls.push({ url, body }); return Response.json({});
};

test('someone the owner allowed can manage users but not grant access or block another manager', async () => {
  const calls = [];
  const as = { ...context(directory(calls)), identity: manager };
  const list = await adminUsers(request(), { ...as, fetcher: async (url, options) => {
    if (url.includes('accounts:batchGet')) return Response.json({ users: [{ localId: 'max', email: 'max@example.com' }] });
    if (url.endsWith(':batchGet')) return Response.json([{ found: { name: 'projects/test/databases/(default)/documents/appUsers/max', fields: { manager: { booleanValue: true } } } }]);
    return directory(calls)(url, options);
  } });
  assert.equal(list.status, 200);
  const data = await list.json();
  assert.equal(data.canGrant, false);
  assert.equal(data.users[0].manager, true);
  assert.equal((await adminUsers(request({ uid: 'alice', blocked: true }, 'https://worker/admin/users/status'), as)).status, 200);
  calls.length = 0;
  assert.equal((await adminUsers(request({ uid: 'max', blocked: true }, 'https://worker/admin/users/status'), as)).status, 403);
  assert.equal((await adminUsers(request({ uid: 'alice', manager: true }, 'https://worker/admin/users/manager'), as)).status, 403);
  assert.equal(calls.length, 0);
});

test('the owner grants and revokes user management, but not for the owner account', async () => {
  const calls = [];
  const as = context(directory(calls));
  let response = await adminUsers(request({ uid: 'alice', manager: true }, 'https://worker/admin/users/manager'), as);
  assert.equal(response.status, 200);
  assert.ok(calls[0].url.includes('/appUsers/alice?updateMask.fieldPaths=manager'));
  assert.equal(calls[0].body.fields.manager.booleanValue, true);
  response = await adminUsers(request({ uid: 'alice', manager: false }, 'https://worker/admin/users/manager'), as);
  assert.equal(calls[1].body.fields.manager.booleanValue, false);
  assert.equal((await adminUsers(request({ uid: 'owner', manager: false }, 'https://worker/admin/users/manager'), as)).status, 400);
  assert.equal((await adminUsers(request({ uid: 'alice', manager: 'yes' }, 'https://worker/admin/users/manager'), as)).status, 400);
  // The owner may still block a manager.
  assert.equal((await adminUsers(request({ uid: 'max', blocked: true }, 'https://worker/admin/users/status'), as)).status, 200);
});
test('listing returns minimal account and per-device login status without password hashes or tokens', async () => {
  const fetcher = async url => {
    if (url.includes('accounts:batchGet')) return Response.json({ users: [{ localId: 'alice', email: 'alice@example.com',
      displayName: 'Alice', lastLoginAt: '123', passwordHash: 'secret', passwordSalt: 'secret', customAttributes: 'secret' }], nextPageToken: 'next' });
    return Response.json([{ found: { name: 'projects/test/databases/(default)/documents/appPresence/alice', fields: {
      sessions: { mapValue: { fields: {
        phone1: { mapValue: { fields: { signedIn: { booleanValue: false }, lastSeen: { timestampValue: new Date().toISOString() } } } },
        phone2: { mapValue: { fields: { signedIn: { booleanValue: true }, lastSeen: { timestampValue: new Date().toISOString() } } } },
      } } },
    } } }]);
  };
  const response = await adminUsers(request(), context(fetcher));
  assert.equal(response.status, 200);
  const data = await response.json();
  assert.equal(data.users[0].online, true);
  assert.equal(data.users[0].signedIn, true);
  assert.equal(data.nextPageToken, 'next');
  assert.ok(!JSON.stringify(data).includes('secret'));
});
test('blocking writes app access first, disables sign-in and revokes sessions; unblocking reverses the order', async () => {
  const calls = [];
  const fetcher = async (url, options) => {
    const body = options.body && JSON.parse(options.body);
    if (url.endsWith('accounts:lookup')) return Response.json({ users: [{ localId: 'alice', email: 'alice@example.com' }] });
    calls.push({ url, body }); return Response.json({});
  };
  let response = await adminUsers(request({ uid: 'alice', blocked: true }, 'https://worker/admin/users/status'), context(fetcher));
  assert.equal(response.status, 200);
  assert.ok(calls[0].url.includes('/appUsers/alice'));
  assert.equal(calls[0].body.fields.blocked.booleanValue, true);
  assert.equal(calls[1].body.disableUser, true);
  assert.ok(Number(calls[1].body.validSince) > 0);
  calls.length = 0;
  response = await adminUsers(request({ uid: 'alice', blocked: false }, 'https://worker/admin/users/status'), context(fetcher));
  assert.equal(response.status, 200);
  assert.equal(calls[0].body.disableUser, false);
  assert.equal(calls[1].body.fields.blocked.booleanValue, false);
});
test('administrator cannot be blocked and an existing blocked token cannot use protected APIs', async () => {
  const response = await adminUsers(request({ uid: 'owner', blocked: true }, 'https://worker/admin/users/status'), context(async () => Response.json({ users: [{ localId: 'owner', email: ADMIN_EMAIL }] })));
  assert.equal(response.status, 400);
  const denied = await accountAccess('test', 'alice', 'old-id-token', async () => Response.json({ fields: { blocked: { booleanValue: true } } }));
  assert.equal(denied.status, 403);
  assert.equal(await accountAccess('test', 'alice', 'token', async () => new Response('', { status: 404 })), null);
  assert.equal((await accountAccess('test', 'alice', 'token', async () => new Response('', { status: 500 }))).status, 503);
});

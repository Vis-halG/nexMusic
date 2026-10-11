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
    const response = await adminUsers(request({ ...identity }), { ...context(() => { throw Error('Should never contact Google'); }), identity: claimant });
    assert.equal(response.status, 403);
  }
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

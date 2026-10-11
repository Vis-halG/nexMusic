import { readFile } from 'node:fs/promises';
import { before, after, beforeEach, test } from 'node:test';
import assert from 'node:assert/strict';
import { initializeTestEnvironment, assertSucceeds, assertFails } from '@firebase/rules-unit-testing';
import { collection, getDocs, doc, getDoc, setDoc } from 'firebase/firestore';
import { communityActivity } from '../push_worker/community_activity.js';

let env;
before(async () => {
  env = await initializeTestEnvironment({ projectId: 'demo-nexmusic-community', firestore: {
    host: '127.0.0.1', port: 8086, rules: await readFile(new URL('../firestore.rules', import.meta.url), 'utf8'),
  } });
});
beforeEach(async () => env.clearFirestore());
after(async () => env?.cleanup());
const song = { id: 'provider:ytmusic:abc', providerId: 'ytmusic', sourceId: 'abc',
  title: 'Test song', kind: 'audio', url: '', artist: 'Artist' };
const now = 1800000000000;
const event = (type, eventId, extra = {}) => ({ type, eventId, song, at: now, ...extra });
const request = events => new Request('https://worker/community/activity', {
  method: 'POST', body: JSON.stringify({ events }),
});
const fetcher = (url, options) => fetch(url.replace('https://firestore.googleapis.com/v1/', 'http://127.0.0.1:8086/v1/'), options);
const send = (uid, events) => communityActivity(request(events), {
  projectId: 'demo-nexmusic-community', uid, now: now + 60000, getToken: async () => 'owner', fetcher,
});
async function aggregate() {
  let result;
  await env.withSecurityRulesDisabled(async context => {
    const rows = await getDocs(collection(context.firestore(), 'globalMusic'));
    assert.equal(rows.size, 1);
    result = rows.docs[0];
  });
  return result;
}

test('two accounts share likes and plays; replayed requests do not duplicate counts', async () => {
  assert.equal((await send('alice', [event('like', 'a-like', { liked: true }), event('play', 'a-play')])).status, 200);
  assert.equal((await send('bob', [event('like', 'b-like', { liked: true }), event('play', 'b-play')])).status, 200);
  assert.equal((await send('alice', [event('like', 'a-like', { liked: true }), event('play', 'a-play')])).status, 200);
  const row = await aggregate();
  assert.equal(row.data().likes, 2);
  assert.equal(row.data().plays, 2);
  assert.equal(row.data().lastPlayed, now);
  assert.equal((await send('alice', [event('like', 'a-unlike', { liked: false, at: now + 1000 })])).status, 200);
  assert.equal((await aggregate()).data().likes, 1);
  assert.equal((await send('alice', [event('like', 'stale-like', { liked: true, at: now - 1000 })])).status, 200);
  assert.equal((await aggregate()).data().likes, 1);
});

test('concurrent same-account likes stay atomic, and historical imports happen once', async () => {
  const responses = await Promise.all(Array.from({ length: 4 }, (_, i) => send('alice', [event('like', `same-${i}`, { liked: true })])));
  assert.ok(responses.every(r => r.status === 200));
  assert.equal((await aggregate()).data().likes, 1);
  const seed = event('seed', 'history', { liked: true, likedAt: 0, lastPlayed: now - 60000, plays: 7 });
  assert.equal((await send('alice', [seed])).status, 200);
  assert.equal((await send('alice', [{ ...seed, eventId: 'history-other-phone' }])).status, 200);
  assert.equal((await aggregate()).data().plays, 7);
  assert.equal((await send('alice', [event('play', 'new')])).status, 200);
  assert.equal((await aggregate()).data().plays, 8);
});

test('global reads expose aggregates only; counters and listener receipts cannot be forged', async () => {
  await send('alice', [event('like', 'a', { liked: true })]);
  const row = await aggregate();
  const bob = env.authenticatedContext('bob').firestore();
  const guest = env.unauthenticatedContext().firestore();
  const visible = await assertSucceeds(getDoc(doc(bob, row.ref.path)));
  assert.deepEqual(Object.keys(visible.data()).sort(), ['likes', 'plays', 'song']);
  assert.ok(!('ownerUid' in visible.data().song));
  await assertFails(getDoc(doc(guest, row.ref.path)));
  await assertFails(getDocs(collection(bob, `${row.ref.path}/listeners`)));
  await assertFails(getDocs(collection(bob, `${row.ref.path}/events`)));
  await assertFails(setDoc(doc(bob, row.ref.path), { likes: 100000 }));
});

test('private files, unknown providers, forged uploads and malformed batches fail safely', async () => {
  for (const invalid of [ { ...song, id: 'private-file' }, { ...song, id: 'local:file' },
    { ...song, providerId: 'other' }, { ...song, id: 'forged' } ]) {
    assert.equal((await send('alice', [event('play', 'bad', { song: invalid })])).status, 400);
  }
  assert.equal((await send('alice', [event('play', 'bad-upload', { song: { id: 'missing', title: 'Missing', providerId: '', url: 'https://example.com/private' } })])).status, 200);
  await env.withSecurityRulesDisabled(async context => {
    assert.equal((await getDocs(collection(context.firestore(), 'globalMusic'))).size, 0);
  });
  assert.equal((await send('alice', [])).status, 400);
  assert.equal((await send('alice', Array(21).fill(event('play', 'too-many')))).status, 400);
});

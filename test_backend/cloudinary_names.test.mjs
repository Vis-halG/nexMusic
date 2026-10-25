import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import worker from '../push_worker/worker.js';
import { cloudinaryNames, displayName, resetCloudinaryNames, MAX_NAMES } from '../push_worker/cloudinary_names.js';

const env = { CLOUDINARY_API_KEY: 'key', CLOUDINARY_API_SECRET: 'secret' };
const request = body => new Request('https://worker/cloudinary/names', { method: 'POST', body: JSON.stringify(body) });
const song = (id, name = `Song ${id}`) => ({ publicId: `nexmusic/${id}`, name });
beforeEach(resetCloudinaryNames);

test('names are signed with the API secret and sent through the Upload API', async () => {
  const calls = [];
  const fetcher = async (url, options) => { calls.push({ url, form: Object.fromEntries(options.body) }); return Response.json({ display_name: options.body.get("display_name") }); };
  const response = await cloudinaryNames(request({ songs: [song('abc', 'Aane Wali Hai Bahar & More')] }), env, fetcher);
  assert.deepEqual(await response.json(), { named: 1, failed: [] });
  assert.equal(calls[0].url, 'https://api.cloudinary.com/v1_1/j0fu6gju/video/explicit');
  const { signature, api_key, ...signed } = calls[0].form;
  assert.equal(api_key, 'key');
  assert.equal(signed.display_name, 'Aane Wali Hai Bahar & More');
  const expected = Object.keys(signed).sort().map(key => `${key}=${signed[key]}`).join('&');
  assert.equal(signature, createHash('sha1').update(expected + 'secret').digest('hex'));
  assert.ok(!JSON.stringify(calls).includes('"secret"'));
});

test('an account that rejects display_name on the Upload API uses the Admin API from then on', async () => {
  const calls = [];
  const fetcher = async (url, options) => {
    calls.push(url);
    if (url.endsWith('/explicit')) return Response.json({ error: { message: 'Display name parameter is not allowed' } }, { status: 400 });
    assert.equal(options.headers.Authorization, `Basic ${btoa('key:secret')}`);
    return Response.json({});
  };
  const response = await cloudinaryNames(request({ songs: [song('a'), song('b')] }), env, fetcher);
  assert.deepEqual(await response.json(), { named: 2, failed: [] });
  assert.deepEqual(calls.map(url => url.split('/v1_1/j0fu6gju/')[1]).sort(),
    ['resources/video/upload/nexmusic/a', 'resources/video/upload/nexmusic/b', 'video/explicit', 'video/explicit']);
  calls.length = 0;
  await cloudinaryNames(request({ songs: [song('c')] }), env, fetcher);
  assert.deepEqual(calls, ['https://api.cloudinary.com/v1_1/j0fu6gju/resources/video/upload/nexmusic/c']);
});

test('a missing file fails alone and a rate limit asks to retry later', async () => {
  const fetcher = async (url, options) => {
    const id = new URLSearchParams(options.body).get('public_id');
    if (id === 'nexmusic/a') return Response.json({ error: { message: 'Resource not found' } }, { status: 404 });
    if (id === 'nexmusic/c') return new Response('', { status: 420 });
    return Response.json({ display_name: new URLSearchParams(options.body).get('display_name') });
  };
  let response = await cloudinaryNames(request({ songs: [song('a'), song('b')] }), env, fetcher);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { named: 1, failed: ['nexmusic/a'] });
  response = await cloudinaryNames(request({ songs: [song('b'), song('c'), song('d')] }), env, fetcher);
  assert.equal(response.status, 429);
  assert.deepEqual(await response.json(), { error: 'Cloudinary is busy. Try again in an hour.', named: 2, failed: ['nexmusic/c'] });
});

test('an Upload API that answers without the name counts as not supporting it', async () => {
  const calls = [];
  const fetcher = async url => { calls.push(url); return Response.json({ public_id: 'nexmusic/a' }); };
  const response = await cloudinaryNames(request({ songs: [song('a')] }), env, fetcher);
  assert.deepEqual(await response.json(), { named: 1, failed: [] });
  assert.ok(calls[1].endsWith('/resources/video/upload/nexmusic/a'));
});

test('only files in the nexmusic folder with a usable name are accepted', async () => {
  const fetcher = () => { throw new Error('Must not contact Cloudinary'); };
  for (const songs of [[], Array.from({ length: MAX_NAMES + 1 }, (_, i) => song(`s${i}`)),
    [{ publicId: 'other/abc', name: 'Song' }], [{ publicId: 'nexmusic/../x', name: 'Song' }],
    [{ publicId: 'nexmusic/abc', name: '   ' }], [{ publicId: 'nexmusic/abc' }]]) {
    assert.equal((await cloudinaryNames(request({ songs }), env, fetcher)).status, 400);
  }
  assert.equal((await cloudinaryNames(request({ songs: [song('a')] }), {}, fetcher)).status, 503);
  assert.equal(displayName(' AC/DC\n\tLive  '), 'AC-DC Live');
  assert.equal(displayName('x'.repeat(200)).length, 160);
});

test('the names route needs a signed-in account', async (t) => {
  t.mock.method(globalThis, 'fetch', () => { throw new Error('Must not contact Cloudinary'); });
  const response = await worker.fetch(request({ songs: [song('a')] }), { SERVICE_ACCOUNT: '{"project_id":"demo-test"}', ...env });
  assert.equal(response.status, 401);
});

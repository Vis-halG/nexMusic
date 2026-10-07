import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../push_worker/worker.js';
import { cloudinaryStatus } from '../push_worker/cloudinary_status.js';

test('capabilities reflect configured services without exposing secrets', async () => {
  const response = await worker.fetch(new Request('https://app.test/capabilities'),{AUDD_API_TOKEN:'secret'});
  assert.deepEqual(await response.json(),{recognition:true,humming:false});
});
test('share pages escape hostile metadata and expose only valid application links', async () => {
  const data = Buffer.from(JSON.stringify({id:'track',title:'<script>alert(1)</script>'})).toString('base64url');
  const response = await worker.fetch(new Request(`https://app.test/share/track?data=${data}`),{});
  const html = await response.text(); assert.equal(response.status,200); assert.ok(!html.includes('<script>')); assert.ok(html.includes('&lt;script&gt;')); assert.ok(html.includes('nexmusic://share/track'));
  assert.equal(response.headers.get('Referrer-Policy'),'no-referrer');
});
test('malformed, private and oversized share links fail', async () => {
  for (const id of ['local:1','private:1']) { const data=Buffer.from(JSON.stringify({id,title:'Private'})).toString('base64url'); assert.equal((await worker.fetch(new Request(`https://app.test/share/track?data=${data}`),{})).status,400); }
  assert.equal((await worker.fetch(new Request('https://app.test/share/track?data=bad'),{})).status,400);
  assert.equal((await worker.fetch(new Request('https://app.test/share/room/short'),{})).status,400);
});
test('recognition rejects unauthenticated requests before sending audio to a provider', async () => {
  const response = await worker.fetch(new Request('https://app.test/recognize',{method:'POST',body:'RIFFaudio'}),{SERVICE_ACCOUNT:'{"project_id":"demo-test"}',AUDD_API_TOKEN:'secret'});
  assert.equal(response.status,401);
});
test('Android association includes only valid public certificate fingerprints', async () => {
  const response = await worker.fetch(new Request('https://app.test/.well-known/assetlinks.json'),{APP_SHA256:Array(32).fill('AB').join(':')});
  assert.equal((await response.json())[0].target.package_name,'com.thenex.nex_music');
  assert.deepEqual(await (await worker.fetch(new Request('https://app.test/.well-known/assetlinks.json'),{APP_SHA256:'bad'})).json(),[]);
});

test('Cloudinary route denies unsigned requests without accessing the account', async (t) => {
  t.mock.method(globalThis, 'fetch', () => { throw new Error('Must not contact Cloudinary'); });
  const response = await worker.fetch(new Request('https://app.test/cloudinary/status'), {
    SERVICE_ACCOUNT: '{"project_id":"demo-test"}', CLOUDINARY_API_KEY: 'key', CLOUDINARY_API_SECRET: 'secret',
  });
  assert.equal(response.status, 401);
});

test('Cloudinary configuration failure is explicit and does not fetch', async (t) => {
  t.mock.method(globalThis, 'fetch', () => { throw new Error('Must not fetch'); });
  const response = await cloudinaryStatus({});
  assert.equal(response.status, 503);
  assert.equal((await response.json()).code, 'not_configured');
});

test('authenticated Cloudinary reports whitelist data and cache concurrent refreshes', async (t) => {
  const pair = await crypto.subtle.generateKey(
    { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
    true, ['sign', 'verify'],
  );
  const jwk = { ...await crypto.subtle.exportKey('jwk', pair.publicKey), kid: 'cloudinary-test' };
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const claims = encode({ aud: 'demo-test', iss: 'https://securetoken.google.com/demo-test', sub: 'listener', iat: now, exp: now + 3600 });
  const unsigned = `${encode({ alg: 'RS256', kid: jwk.kid })}.${claims}`;
  const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', pair.privateKey, new TextEncoder().encode(unsigned));
  const token = `${unsigned}.${Buffer.from(signature).toString('base64url')}`;
  let accountCalls = 0;
  const usage = { plan: 'Free', last_updated: '2026-10-01', storage: { usage: 123 },
    bandwidth: { usage: 456 }, credits: { usage: 1.5, limit: 25 }, resources: 110,
    api_secret: 'must-not-leak', transformations: { usage: 20 }, requests: 789 };
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    if (String(url).includes('googleapis.com')) return Response.json({ keys: [jwk] });
    accountCalls++;
    assert.equal(options.headers.Authorization, `Basic ${Buffer.from('key:secret').toString('base64')}`);
    if (String(url).endsWith('/usage')) return Response.json(usage, { headers: {
      'x-featureratelimit-limit': '500', 'x-featureratelimit-remaining': '497',
      'x-featureratelimit-reset': 'Fri, 02 Oct 2026 10:00:00 GMT',
    } });
    const body = JSON.parse(options.body);
    assert.equal(body.max_results, 1);
    assert.ok(body.expression.includes('public_id:nexmusic/*'));
    return Response.json({ total_count: body.expression.includes('format:mp3') ? 105 : 110,
      resources: [{ secure_url: 'private-metadata-must-not-leak' }], next_cursor: 'more' });
  });
  const env = { SERVICE_ACCOUNT: '{"project_id":"demo-test"}', CLOUDINARY_API_KEY: 'key', CLOUDINARY_API_SECRET: 'secret' };
  const request = () => new Request('https://app.test/cloudinary/status', { headers: { Authorization: `Bearer ${token}` } });
  const responses = await Promise.all([worker.fetch(request(), env), worker.fetch(request(), env)]);
  assert.ok(responses.every(response => response.status === 200));
  const report = await responses[0].json();
  assert.equal(report.mediaCount, 110);
  assert.equal(report.songCount, 105);
  assert.equal(report.otherMediaCount, 5);
  assert.equal(report.storage.limit, null);
  assert.equal(report.dailyPlayback, null);
  assert.equal(report.period, 'rolling_30_days');
  assert.equal(report.adminApi.resetAt, '2026-10-02T10:00:00.000Z');
  assert.equal(responses[0].headers.get('Cache-Control'), 'no-store');
  const serialized = JSON.stringify(report);
  assert.ok(!serialized.includes('secret'));
  assert.ok(!serialized.includes('private-metadata'));
  await worker.fetch(request(), env);
  assert.equal(accountCalls, 3);
});

test('Cloudinary count failures preserve usage and missing counts stay unknown', async (t) => {
  t.mock.method(globalThis, 'fetch', async url => String(url).endsWith('/usage')
    ? Response.json({ storage: { usage: 0 }, credits: { usage: 0, limit: 25 } })
    : Response.json({ error: { message: 'sensitive provider details' } }, { status: 420 }));
  const response = await cloudinaryStatus({ CLOUDINARY_API_KEY: 'partial', CLOUDINARY_API_SECRET: 'secret' });
  assert.equal(response.status, 200);
  const report = await response.json();
  assert.equal(report.storage.usage, 0);
  assert.equal(report.mediaCount, null);
  assert.equal(report.songCount, null);
  assert.equal(report.countsAvailable, false);
  assert.equal(report.adminApi.remaining, null);
});

test('failed concurrent reports do not escape errors or get cached as success', async (t) => {
  let calls = 0;
  t.mock.method(globalThis, 'fetch', async () => { calls++; throw new Error('secret-provider-error'); });
  const env = { CLOUDINARY_API_KEY: 'outage', CLOUDINARY_API_SECRET: 'secret' };
  const responses = await Promise.all([cloudinaryStatus(env), cloudinaryStatus(env)]);
  assert.ok(responses.every(response => response.status === 502));
  assert.ok(!(await responses[0].text()).includes('secret-provider-error'));
  assert.equal(calls, 3);
  assert.equal((await cloudinaryStatus(env)).status, 502);
  assert.equal(calls, 6);
});

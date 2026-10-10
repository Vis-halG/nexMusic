// nexMusic activity notifications, deployed as a Cloudflare Worker.
//
// The app POSTs {"title", "body"} with the signed-in user's Firebase ID token
// in the Authorization header. The Worker checks the token, then sends the
// notification through Firebase Cloud Messaging to every phone registered in
// the Firestore `pushTokens` collection, except the sender's own phones.
//
// Required secret: SERVICE_ACCOUNT, the JSON key of the Firebase project's
// service account (Project settings → Service accounts → Generate new private
// key). Keep it only in the Worker; never put it in the app.

import { cloudinaryStatus } from './cloudinary_status.js';

const GOOGLE_KEYS_URL =
  'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com';
const SCOPES =
  'https://www.googleapis.com/auth/firebase.messaging https://www.googleapis.com/auth/datastore';

let googleKeys = { keys: [], expiresAt: 0 };
let accessToken = { token: '', expiresAt: 0 };

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === 'GET' && url.pathname === '/capabilities') {
      return reply({ recognition: Boolean(env.AUDD_API_TOKEN), humming: Boolean(env.HUMMING_ENDPOINT && env.HUMMING_API_TOKEN) });
    }
    if (request.method === 'GET' && url.pathname.startsWith('/share/')) return sharePage(url);
    if (request.method === 'GET' && url.pathname === '/.well-known/assetlinks.json') {
      const fingerprints = (env.APP_SHA256 || '').split(',').map(s => s.trim()).filter(s => /^[0-9A-Fa-f:]{95}$/.test(s));
      return reply(fingerprints.length ? [{ relation: ['delegate_permission/common.handle_all_urls'], target: { namespace: 'android_app', package_name: 'com.thenex.nex_music', sha256_cert_fingerprints: fingerprints } }] : []);
    }
    const cloudinaryReport = request.method === 'GET' && url.pathname === '/cloudinary/status';
    if (request.method !== 'POST' && !cloudinaryReport) {
      return reply({ error: 'Use POST.' }, 405);
    }
    let account;
    try {
      account = JSON.parse(env.SERVICE_ACCOUNT);
    } catch {
      return reply({ error: 'The SERVICE_ACCOUNT secret is missing or is not valid JSON.' }, 500);
    }
    const projectId = account.project_id;

    let senderUid;
    try {
      const header = request.headers.get('Authorization') || '';
      senderUid = await verifyIdToken(header.replace(/^Bearer\s+/i, ''), projectId);
    } catch {
      return reply({ error: 'Sign in to nexMusic first.' }, 401);
    }

    if (cloudinaryReport) return cloudinaryStatus(env, { refresh: url.searchParams.get('refresh') === '1' });
    if (url.pathname === '/recognize') return recognize(request, env, account, senderUid, url.searchParams.get('mode') === 'humming');
    if (url.pathname !== '/' && url.pathname !== '/notify') return reply({error:'Route not found.'},404);

    let input;
    try {
      input = await request.json();
    } catch {
      return reply({ error: 'The request body must be JSON.' }, 400);
    }
    const title = text(input.title, 100);
    const body = text(input.body, 300);
    if (!title) return reply({ error: 'A title is required.' }, 400);

    try {
      const token = await getAccessToken(account);
      const phones = (await listPhones(projectId, token)).filter(
        (phone) => phone.uid !== senderUid,
      );
      const results = await Promise.all(
        phones.map((phone) => notify(projectId, token, phone, title, body)),
      );
      return reply({ phones: phones.length, sent: results.filter(Boolean).length });
    } catch (error) {
      return reply({ error: String(error) }, 502);
    }
  },
};

async function notify(projectId, token, phone, title, body) {
  const response = await fetch(
    `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
    {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        message: {
          token: phone.token,
          notification: { title, body },
          android: {
            priority: 'HIGH',
            // The channel is created by the app (NexPhone.kt).
            notification: { channel_id: 'activity', icon: 'ic_notification', color: '#7C3AED' },
          },
        },
      }),
    },
  );
  if (response.ok) return true;
  const details = await response.text();
  // The app was uninstalled or the token expired: forget this phone.
  if (details.includes('UNREGISTERED') || details.includes('not a valid FCM registration token')) {
    await fetch(`https://firestore.googleapis.com/v1/${phone.name}`, {
      method: 'DELETE',
      headers: { Authorization: `Bearer ${token}` },
    });
  }
  return false;
}

async function listPhones(projectId, token) {
  const phones = [];
  let pageToken = '';
  do {
    const url = new URL(
      `https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default)/documents/pushTokens`,
    );
    url.searchParams.set('pageSize', '300');
    if (pageToken) url.searchParams.set('pageToken', pageToken);
    const response = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
    if (!response.ok) {
      throw new Error(`Firestore ${response.status}: ${await response.text()}`);
    }
    const page = await response.json();
    for (const document of page.documents || []) {
      const fields = document.fields || {};
      if (!fields.token?.stringValue) continue;
      phones.push({
        name: document.name,
        token: fields.token.stringValue,
        uid: fields.uid?.stringValue || '',
      });
    }
    pageToken = page.nextPageToken || '';
  } while (pageToken);
  return phones;
}

/** Returns the user id of a valid Firebase ID token for [projectId]. */
async function verifyIdToken(idToken, projectId) {
  const [headerPart, payloadPart, signaturePart] = idToken.split('.');
  if (!signaturePart) throw new Error('Malformed token');
  const header = JSON.parse(new TextDecoder().decode(fromBase64Url(headerPart)));
  const payload = JSON.parse(new TextDecoder().decode(fromBase64Url(payloadPart)));
  const now = Math.floor(Date.now() / 1000);
  if (
    header.alg !== 'RS256' ||
    payload.aud !== projectId ||
    payload.iss !== `https://securetoken.google.com/${projectId}` ||
    typeof payload.sub !== 'string' ||
    !payload.sub ||
    !Number.isFinite(payload.exp) || payload.exp <= now ||
    !Number.isFinite(payload.iat) || payload.iat > now + 300
  ) {
    throw new Error('Invalid token claims');
  }
  const jwk = (await getGoogleKeys()).find((key) => key.kid === header.kid);
  if (!jwk) throw new Error('Unknown signing key');
  const key = await crypto.subtle.importKey(
    'jwk',
    jwk,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['verify'],
  );
  const valid = await crypto.subtle.verify(
    'RSASSA-PKCS1-v1_5',
    key,
    fromBase64Url(signaturePart),
    new TextEncoder().encode(`${headerPart}.${payloadPart}`),
  );
  if (!valid) throw new Error('Bad signature');
  return payload.sub;
}

async function getGoogleKeys() {
  if (googleKeys.expiresAt > Date.now()) return googleKeys.keys;
  const response = await fetch(GOOGLE_KEYS_URL);
  if (!response.ok) throw new Error(`Google keys ${response.status}`);
  const data = await response.json();
  const maxAge = Number(/max-age=(\d+)/.exec(response.headers.get('Cache-Control') || '')?.[1] || 3600);
  googleKeys = { keys: data.keys || [], expiresAt: Date.now() + maxAge * 1000 };
  return googleKeys.keys;
}

/** OAuth access token for the service account, cached for about an hour. */
async function getAccessToken(account) {
  const now = Math.floor(Date.now() / 1000);
  if (accessToken.expiresAt > now + 60) return accessToken.token;
  const header = toBase64Url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claims = toBase64Url(
    JSON.stringify({
      iss: account.client_email,
      scope: SCOPES,
      aud: 'https://oauth2.googleapis.com/token',
      iat: now,
      exp: now + 3600,
    }),
  );
  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToBytes(account.private_key),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const signature = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    key,
    new TextEncoder().encode(`${header}.${claims}`),
  );
  const response = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${header}.${claims}.${toBase64Url(signature)}`,
    }),
  });
  if (!response.ok) throw new Error(`OAuth ${response.status}: ${await response.text()}`);
  const data = await response.json();
  accessToken = { token: data.access_token, expiresAt: now + (data.expires_in || 3600) };
  return accessToken.token;
}

function pemToBytes(pem) {
  const base64 = pem.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
  return Uint8Array.from(atob(base64), (character) => character.charCodeAt(0));
}

function fromBase64Url(value) {
  const base64 = value.replace(/-/g, '+').replace(/_/g, '/');
  const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
  return Uint8Array.from(atob(padded), (character) => character.charCodeAt(0));
}

function toBase64Url(value) {
  const bytes = typeof value === 'string' ? new TextEncoder().encode(value) : new Uint8Array(value);
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function text(value, max) {
  return typeof value === 'string' ? value.trim().slice(0, max) : '';
}

function reply(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}


function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}
function sharePage(url) {
  const match = /^\/share\/(track|room|playlist|invite)(?:\/([a-z0-9]{16,40}))?$/.exec(url.pathname);
  if (!match || (match[1] !== 'track' && !match[2])) return reply({error:'Invalid music link.'},400);
  let title = {room:'Join a music room',playlist:'Open a playlist',invite:'Join a shared playlist',track:'Open this song'}[match[1]];
  if (match[1] === 'track') {
    const encoded = url.searchParams.get('data') || '';
    if (!encoded || encoded.length > 16000) return reply({error:'Invalid song link.'},400);
    try { const song = JSON.parse(new TextDecoder().decode(fromBase64Url(encoded))); if (typeof song.title !== 'string' || song.title.length > 160 || !song.id || song.id.startsWith('local:') || song.id.startsWith('private:')) throw Error(); title = song.title; } catch { return reply({error:'Invalid song link.'},400); }
  }
  const deep = `nexmusic://share/${match[1]}${match[2] ? '/'+match[2] : ''}${url.search}`;
  const intent = `intent://share/${match[1]}${match[2] ? '/'+match[2] : ''}${url.search}#Intent;scheme=nexmusic;package=com.thenex.nex_music;end`;
  return new Response(`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escapeHtml(title)} ? nexMusic</title><style>body{font:18px system-ui;background:#171120;color:#fff;max-width:520px;margin:12vh auto;padding:24px}a{display:block;background:#7c3aed;color:#fff;padding:16px;border-radius:16px;margin:16px 0;text-align:center;text-decoration:none}</style><h1>${escapeHtml(title)}</h1><p>Listen together on nexMusic.</p><a href="${escapeHtml(intent)}">Open nexMusic on Android</a><a href="${escapeHtml(deep)}">Open in the app</a><p>If the app is not installed, install nexMusic and open this link again.</p></html>`,{headers:{'Content-Type':'text/html; charset=utf-8','Content-Security-Policy':"default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'",'X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer','Cache-Control':'no-store'}});
}
async function recognize(request, env, account, uid, humming) {
  if (humming ? !(env.HUMMING_ENDPOINT && env.HUMMING_API_TOKEN) : !env.AUDD_API_TOKEN) return reply({error:humming ? 'Humming recognition is not configured yet.' : 'Song recognition service is not configured yet.'},503);
  const length = Number(request.headers.get('Content-Length'));
  if (!Number.isFinite(length) || length < 44 || length > 2*1024*1024) return reply({error:'Send a WAV recording of up to 2 MB.'},413);
  if (!(request.headers.get('Content-Type') || '').startsWith('audio/wav')) return reply({error:'A WAV recording is required.'},415);
  const audio = await request.arrayBuffer();
  if (audio.byteLength > 2*1024*1024 || new TextDecoder().decode(audio.slice(0,4)) !== 'RIFF' || new TextDecoder().decode(audio.slice(8,12)) !== 'WAVE') return reply({error:'Invalid WAV recording.'},400);
  try {
    const allowed = await reserveRecognition(account,uid);
    if (!allowed) return reply({error:'Your daily recognition limit has been reached. Try again tomorrow.'},429);
    let response;
    if (humming) {
      const endpoint = new URL(env.HUMMING_ENDPOINT);
      if (endpoint.protocol !== 'https:') return reply({error:'Recognition configuration is invalid.'},503);
      response = await fetch(endpoint,{method:'POST',headers:{Authorization:`Bearer ${env.HUMMING_API_TOKEN}`,'Content-Type':'audio/wav'},body:audio,signal:AbortSignal.timeout(30000)});
    } else {
      const form = new FormData(); form.set('api_token',env.AUDD_API_TOKEN); form.set('file',new Blob([audio],{type:'audio/wav'}),'sample.wav');
      response = await fetch('https://api.audd.io/',{method:'POST',body:form,signal:AbortSignal.timeout(30000)});
    }
    if (!response.ok) return reply({error:'The recognition provider is unavailable. Try again later.'},502);
    const data = await response.json();
    if (!humming && data.status !== 'success') return reply({error:'The recognition provider could not process this sample.'},502);
    const song = humming ? data : data.result;
    if (!song) return reply({error:'No matching song found. Try again near the music.'},404);
    return reply({title:text(song.title,160),artist:text(song.artist,160),album:text(song.album,160)});
  } catch { return reply({error:'Recognition is unavailable. Try again later.'},502); }
}
async function reserveRecognition(account,uid) {
  const token = await getAccessToken(account);
  const day = new Date().toISOString().slice(0,10);
  const base = `https://firestore.googleapis.com/v1/projects/${account.project_id}/databases/(default)/documents`;
  const path = `/users/${encodeURIComponent(uid)}/recognitionUsage/${day}`;
  for (let attempt=0;attempt<3;attempt++) {
    const response = await fetch(base+path,{headers:{Authorization:`Bearer ${token}`}});
    if (!response.ok && response.status !== 404) throw Error('Usage check failed');
    const doc = response.ok ? await response.json() : null;
    const count = Number(doc?.fields?.count?.integerValue || 0);
    if (count >= 20) return false;
    const write = {name:`projects/${account.project_id}/databases/(default)/documents${path}`,fields:{count:{integerValue:String(count+1)}}};
    const commit = await fetch(base+':commit',{method:'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:JSON.stringify({writes:[{update:write,currentDocument:doc ? {updateTime:doc.updateTime} : {exists:false}}]})});
    if (commit.ok) return true;
    if (commit.status !== 409 && commit.status !== 412) throw Error('Usage reservation failed');
  }
  return false;
}

// Shows each upload's song title as its name in the Cloudinary Media Library.
// Unsigned uploads cannot set a display name, so the app sends the titles
// here and the Worker sets them with the account's API secret.
// Each name can take two Cloudinary calls, and a free Worker request may make 50.
export const MAX_NAMES = 20;
const PUBLIC_ID = /^nexmusic\/[A-Za-z0-9_-]{1,120}$/;

// The Upload API's explicit method has no hourly limit. Accounts that reject
// display_name there fall back to the Admin API, which allows 500 calls an hour.
let adminOnly = false;

export async function cloudinaryNames(request, env, fetcher = fetch) {
  const cloud = env.CLOUDINARY_CLOUD_NAME || 'j0fu6gju';
  if (!env.CLOUDINARY_API_KEY || !env.CLOUDINARY_API_SECRET || !/^[a-zA-Z0-9_-]+$/.test(cloud)) {
    return response({ error: 'Cloudinary has not been connected yet.' }, 503);
  }
  let input;
  try { input = await request.json(); } catch { return response({ error: 'The request body must be JSON.' }, 400); }
  const songs = Array.isArray(input?.songs) ? input.songs : [];
  if (!songs.length || songs.length > MAX_NAMES) return response({ error: `Send 1 to ${MAX_NAMES} songs.` }, 400);
  const names = [];
  for (const song of songs) {
    const name = displayName(song?.name);
    if (typeof song?.publicId !== 'string' || !PUBLIC_ID.test(song.publicId) || !name) {
      return response({ error: 'Each song needs a nexMusic file id and a name.' }, 400);
    }
    names.push({ publicId: song.publicId, name });
  }
  const account = { cloud, key: env.CLOUDINARY_API_KEY, secret: env.CLOUDINARY_API_SECRET, fetcher };
  const statuses = await Promise.all(names.map(song => rename(account, song)));
  const named = statuses.filter(status => status === 'ok').length;
  const failed = names.filter((_, i) => statuses[i] !== 'ok').map(song => song.publicId);
  console.log(JSON.stringify({ names: names.length, named, api: adminOnly ? 'admin' : 'upload' }));
  if (statuses.includes('limited')) {
    return response({ error: 'Cloudinary is busy. Try again in an hour.', named, failed }, 429);
  }
  return response({ named, failed });
}

/** A title Cloudinary accepts as a Media Library name, or '' if none is left. */
export function displayName(value) {
  if (typeof value !== 'string') return '';
  return value.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/[\\/]/g, '-')
    .replace(/\s+/g, ' ').trim().slice(0, 160).trim();
}

async function rename(account, song) {
  if (!adminOnly) {
    const result = await explicit(account, song);
    if (result.ok) return 'ok';
    if (result.status === 420 || result.status === 429) return 'limited';
    // Only a rejected parameter means this account needs the Admin API.
    if (!/display.?name/i.test(result.message)) return 'failed';
    adminOnly = true;
  }
  const result = await account.fetcher(
    `https://api.cloudinary.com/v1_1/${account.cloud}/resources/video/upload/${song.publicId}`, {
      method: 'POST',
      headers: { Authorization: `Basic ${btoa(`${account.key}:${account.secret}`)}` },
      body: new URLSearchParams({ display_name: song.name }),
      signal: AbortSignal.timeout(15000),
    });
  if (result.ok) return 'ok';
  return result.status === 420 || result.status === 429 ? 'limited' : 'failed';
}

async function explicit(account, song) {
  const params = { display_name: song.name, public_id: song.publicId, timestamp: String(Math.floor(Date.now() / 1000)), type: 'upload' };
  const signed = Object.keys(params).sort().map(key => `${key}=${params[key]}`).join('&');
  const digest = await crypto.subtle.digest('SHA-1', new TextEncoder().encode(signed + account.secret));
  const signature = [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('');
  const result = await account.fetcher(`https://api.cloudinary.com/v1_1/${account.cloud}/video/explicit`, {
    method: 'POST',
    body: new URLSearchParams({ ...params, api_key: account.key, signature }),
    signal: AbortSignal.timeout(15000),
  });
  let reply = {};
  try { reply = await result.json(); } catch {}
  // A method that ignores display_name answers OK without it.
  if (result.ok) return reply?.display_name === song.name ? { ok: true } : { ok: false, message: 'display_name ignored' };
  return { ok: false, status: result.status, message: String(reply?.error?.message || '') };
}

/** Lets tests start from the Upload API again. */
export function resetCloudinaryNames() { adminOnly = false; }

function response(data, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json' } });
}

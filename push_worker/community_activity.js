// Shared public-song counters. Listener state and event receipts remain private.
const json = (body, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { 'Content-Type': 'application/json' },
});
const str = value => ({ stringValue: value });
const integer = value => ({ integerValue: String(value) });
const number = (fields, key) => Number(fields?.[key]?.integerValue || 0);
async function digest(value) {
  const bytes = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return [...new Uint8Array(bytes)].map(v => v.toString(16).padStart(2, '0')).join('');
}
function safeText(value, max, required = false) {
  if (typeof value !== 'string' || value.length > max || (required && !value.trim())) {
    throw new Error('Invalid song metadata.');
  }
  return value.trim();
}
function publicSong(input) {
  const id = safeText(input?.id, 250, true);
  if (id.startsWith('private-') || id.startsWith('local:')) throw new Error('Only public songs can be shared.');
  const providerId = input.providerId || '';
  if (providerId && !['jiosaavn', 'ytmusic', 'ytvideo'].includes(providerId)) throw new Error('Unknown provider.');
  const sourceId = safeText(input.sourceId || '', 150);
  if (providerId && (!sourceId || id !== `provider:${providerId}:${sourceId}`)) throw new Error('Invalid provider song.');
  const song = {
    id, title: safeText(input.title, 160, true),
    kind: input.kind === 'video' ? 'video' : 'audio',
    providerId, sourceId, url: '',
  };
  for (const key of ['artist', 'album', 'albumId', 'artistId', 'language', 'genre']) {
    song[key] = safeText(input[key] || '', 200);
  }
  const artwork = safeText(input.artworkUrl || '', 2000);
  song.artworkUrl = artwork.startsWith('https://') ? artwork : '';
  song.durationMs = Math.trunc(Math.max(0, Math.min(86400000, Number(input.durationMs) || 0)));
  song.contentType = 'music';
  return song;
}
function fieldsFor(song) {
  return Object.fromEntries(Object.entries(song).map(([key, value]) => [key,
    typeof value === 'number' ? integer(value) : str(value)]));
}

export async function communityActivity(request, { projectId, uid, getToken,
  fetcher = fetch, now = Date.now(), cloudName = 'j0fu6gju' }) {
  let events;
  try {
    const input = await request.json();
    if (!Array.isArray(input.events) || !input.events.length || input.events.length > 10) throw new Error('Send 1–10 events.');
    events = input.events.map(event => {
      if (!['like', 'play', 'seed'].includes(event.type)) throw new Error('Unknown activity.');
      const eventId = safeText(event.eventId, 120, true);
      if (event.type !== 'play' && typeof event.liked !== 'boolean') throw new Error('A like state is required.');
      if (!Number.isSafeInteger(event.at) || event.at <= 0) throw new Error('Invalid activity time.');
      if (event.type === 'seed' && (!Number.isSafeInteger(event.plays) || event.plays < 0 || event.plays > 1000000)) throw new Error('Invalid play count.');
      if (event.type === 'seed' && ['lastPlayed', 'likedAt'].some(key => !Number.isSafeInteger(event[key]) || event[key] < 0)) throw new Error('Invalid history time.');
      return { ...event, eventId, at: Math.min(event.at, now), song: publicSong(event.song) };
    });
  } catch (error) {
    return json({ error: error.message || 'Invalid activity.' }, 400);
  }
  try {
    const token = await getToken();
    const network = fetcher;
    let calls = 0;
    fetcher = (...args) => {
      // Reserve capacity for authentication and OAuth on the free Worker.
      if (++calls > 43) throw new Error('Retry the remaining activity.');
      return network(...args);
    };
    const database = `projects/${projectId}/databases/(default)`;
    const root = `${database}/documents`;
    const headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
    const read = async name => {
      const response = await fetcher(`https://firestore.googleapis.com/v1/${name}`, { headers });
      if (response.status === 404) { await response.body?.cancel(); return null; }
      if (!response.ok) throw new Error('Activity storage unavailable.');
      return response.json();
    };
    let accepted = 0;
    for (const event of events) {
      let song = event.song;
      // An uploaded track must exist in the shared catalogue. Never trust a
      // client-supplied storage URL or private library metadata.
      if (!song.providerId) {
        const catalogue = await read(`${root}/songs/${encodeURIComponent(song.id)}`);
        if (!catalogue || catalogue.fields?.deleted?.booleanValue === true) continue;
        const data = catalogue.fields;
        const url = data.url?.stringValue || '';
        const parsed = new URL(url);
        if (parsed.protocol !== 'https:' || parsed.hostname !== 'res.cloudinary.com' ||
            !parsed.pathname.startsWith(`/${cloudName}/`)) continue;
        song = { ...song, title: data.title?.stringValue || song.title,
          kind: data.kind?.stringValue || song.kind, url,
          categoryId: data.categoryId?.stringValue || '' };
      }
      const songKey = await digest(song.id);
      const listenerKey = await digest(uid);
      const receiptKey = await digest(`${uid}:${event.type === 'seed' ? 'history-v1' : event.eventId}`);
      const aggregate = `${root}/globalMusic/${songKey}`;
      const listener = `${aggregate}/listeners/${listenerKey}`;
      const receipt = `${aggregate}/events/${receiptKey}`;
      let committed = false;
      for (let attempt = 0; attempt < 5; attempt++) {
        const [oldReceipt, oldListener] = await Promise.all([read(receipt), read(listener)]);
        if (oldReceipt) { committed = true; break; }
        const old = oldListener?.fields || {};
        const oldLiked = old.liked?.booleanValue === true;
        const likedAt = number(old, 'likedAt');
        const likeTime = event.type === 'seed' ? Math.min(event.likedAt || 0, now) : event.at;
        const liked = event.type !== 'play' && likeTime >= likedAt ? event.liked : oldLiked;
        const oldPlays = number(old, 'plays');
        const lastPlayed = number(old, 'lastPlayed');
        const playDelta = event.type === 'seed' ? Math.max(0, event.plays - oldPlays)
          : event.type === 'play' && event.at - lastPlayed >= 10000 ? 1 : 0;
        const playTime = event.type === 'seed' ? Math.min(event.lastPlayed || 0, now) : event.at;
        const nextPlayed = playDelta > 0 ? Math.max(lastPlayed, playTime) : lastPlayed;
        const transforms = [
          { fieldPath: 'likes', increment: integer(Number(liked) - Number(oldLiked)) },
          { fieldPath: 'plays', increment: integer(playDelta) },
        ];
        if (nextPlayed > lastPlayed) transforms.push({ fieldPath: 'lastPlayed', maximum: integer(nextPlayed) });
        const response = await fetcher(`https://firestore.googleapis.com/v1/${root}:commit`, {
          method: 'POST', headers, body: JSON.stringify({ writes: [
            { update: { name: receipt, fields: { at: integer(now) } }, currentDocument: { exists: false } },
            { update: { name: listener, fields: {
              liked: { booleanValue: liked }, likedAt: integer(Math.max(likedAt, event.type === 'play' ? 0 : likeTime)),
              plays: integer(oldPlays + playDelta), lastPlayed: integer(nextPlayed),
            } }, currentDocument: oldListener ? { updateTime: oldListener.updateTime } : { exists: false } },
            { update: { name: aggregate, fields: { song: { mapValue: { fields: fieldsFor(song) } } } },
              updateMask: { fieldPaths: ['song'] }, updateTransforms: transforms },
          ] }),
        });
        if (response.ok) { await response.body?.cancel(); committed = true; break; }
        if (![400, 409, 412].includes(response.status)) throw new Error('Could not save shared activity.');
        const error = await response.json();
        if (!['ALREADY_EXISTS', 'ABORTED', 'FAILED_PRECONDITION'].includes(error.error?.status)) throw new Error('Could not save shared activity.');
      }
      if (!committed) throw new Error('Activity is busy. Retry shortly.');
      accepted++;
    }
    return json({ accepted });
  } catch {
    return json({ error: 'Shared activity is temporarily unavailable.' }, 503);
  }
}

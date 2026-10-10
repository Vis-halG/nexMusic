// Read-only Cloudinary reporting. Credentials stay in Worker secrets.
const reports = new Map();
const CACHE_MS = 5 * 60 * 1000;
const MANUAL_REFRESH_MS = 60 * 1000;
const AUDIO_FORMATS = ['mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg', 'oga', 'opus', 'amr', '3ga', 'mka', 'aiff', 'aif'];

export async function cloudinaryStatus(env, { refresh = false } = {}) {
  const cloud = env.CLOUDINARY_CLOUD_NAME || 'j0fu6gju';
  if (!env.CLOUDINARY_API_KEY || !env.CLOUDINARY_API_SECRET) {
    return response({ error: 'Cloudinary account reporting has not been connected yet.', code: 'not_configured' }, 503);
  }
  if (!/^[a-zA-Z0-9_-]+$/.test(cloud)) {
    return response({ error: 'Cloudinary account reporting is not configured correctly.' }, 503);
  }
  const cacheKey = JSON.stringify([cloud, env.CLOUDINARY_API_KEY, env.CLOUDINARY_API_SECRET]);
  const cached = reports.get(cacheKey);
  const now = Date.now();
  const reuse = cached && cached.expiresAt > now &&
    (!refresh || now - cached.startedAt < MANUAL_REFRESH_MS);
  const promise = reuse ? cached.promise : loadReport(cloud, env);
  if (promise !== cached?.promise) {
    // Coalesce refreshes from different phones and protect the hourly Admin quota.
    reports.clear();
    reports.set(cacheKey, { promise, startedAt: now, expiresAt: now + CACHE_MS });
  }
  try {
    const report = await promise;
    return response({ ...report, cached: Boolean(reuse),
      cacheExpiresAt: new Date(reports.get(cacheKey)?.expiresAt ?? now + CACHE_MS).toISOString(),
      manualRefreshAfter: new Date((reports.get(cacheKey)?.startedAt ?? now) + MANUAL_REFRESH_MS).toISOString(),
    });
  } catch {
    if (reports.get(cacheKey)?.promise === promise) reports.delete(cacheKey);
    return response({ error: 'Could not read Cloudinary usage. Try again later.' }, 502);
  }
}

async function loadReport(cloud, env) {
  const base = `https://api.cloudinary.com/v1_1/${cloud}`;
  const headers = { Authorization: `Basic ${btoa(`${env.CLOUDINARY_API_KEY}:${env.CLOUDINARY_API_SECRET}`)}` };
  async function read(path, body) {
    const result = await fetch(base + path, {
      method: body ? 'POST' : 'GET',
      headers: { ...headers, ...(body ? { 'Content-Type': 'application/json' } : {}) },
      ...(body ? { body: JSON.stringify(body) } : {}),
      signal: AbortSignal.timeout(15000),
    });
    if (!result.ok) throw new Error('Cloudinary reporting unavailable');
    const json = await result.json();
    if (!json || typeof json !== 'object' || Array.isArray(json)) throw new Error('Invalid report');
    return { json, headers: result.headers };
  }
  const expression = 'resource_type:video AND type:upload AND public_id:nexmusic/*';
  const [usageResult, mediaResult, audioResult] = await Promise.allSettled([
    read('/usage'),
    read('/resources/search', { expression, max_results: 1 }),
    read('/resources/search', {
      expression: `${expression} AND (${AUDIO_FORMATS.map(format => `format:${format}`).join(' OR ')})`,
      max_results: 1,
    }),
  ]);
  if (usageResult.status !== 'fulfilled') throw new Error('Usage unavailable');
  const { json: usage, headers: usageHeaders } = usageResult.value;
  if (!['storage', 'bandwidth', 'credits', 'transformations'].some(key => usage[key] && typeof usage[key] === 'object')) {
    throw new Error('Invalid usage report');
  }
  const mediaCount = mediaResult.status === 'fulfilled' ? number(mediaResult.value.json.total_count) : null;
  const songCount = audioResult.status === 'fulfilled' ? number(audioResult.value.json.total_count) : null;
  // Whitelist fields: never return resource URLs, metadata, provider errors or credentials.
  return {
    cloudName: cloud,
    plan: typeof usage.plan === 'string' ? usage.plan.slice(0, 80) : null,
    fetchedAt: new Date().toISOString(),
    lastUpdated: typeof usage.last_updated === 'string' ? usage.last_updated : null,
    period: 'rolling_30_days',
    mediaCount,
    songCount,
    otherMediaCount: mediaCount !== null && songCount !== null ? Math.max(0, mediaCount - songCount) : null,
    accountResources: number(usage.resources),
    storage: metric(usage.storage),
    bandwidth: metric(usage.bandwidth),
    credits: metric(usage.credits),
    transformations: metric(usage.transformations),
    requests: number(usage.requests),
    dailyPlayback: null,
    adminApi: {
      limit: headerNumber(usageHeaders, 'x-featureratelimit-limit'),
      remaining: headerNumber(usageHeaders, 'x-featureratelimit-remaining'),
      resetAt: resetTime(usageHeaders.get('x-featureratelimit-reset')),
    },
    countsAvailable: mediaCount !== null && songCount !== null,
  };
}

function number(value) {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : null;
}
function headerNumber(headers, name) {
  const value = headers.get(name);
  return value === null || value.trim() === '' ? null : number(Number(value));
}
function metric(value) {
  return {
    usage: number(value?.usage),
    limit: number(value?.limit),
    usedPercent: number(value?.used_percent),
    creditsUsage: number(value?.credits_usage),
  };
}
function resetTime(value) {
  const milliseconds = value ? Date.parse(value) : NaN;
  return Number.isFinite(milliseconds) ? new Date(milliseconds).toISOString() : null;
}
function response(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}

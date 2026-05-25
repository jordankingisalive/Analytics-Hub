/**
 * Analytics Hub Copilot — Azure Function proxy
 *
 * POST /api/chat
 *   body: { messages: [{role, content}, ...] }
 *   returns: Azure OpenAI chat-completions response (passthrough)
 *
 * Removes BYOK friction: the visitor never sees an API key. The key
 * lives in App Settings (AOAI_KEY) and is injected server-side.
 *
 * Defences:
 *   - CORS allowlist (ALLOWED_ORIGINS, comma-separated)
 *   - Per-IP rate limit (RATE_LIMIT_PER_HOUR, in-memory, per-instance)
 *   - Max messages per request (hard-coded 20)
 *   - max_tokens cap (MAX_TOKENS)
 *   - Request body must parse as JSON and contain messages[]
 */
const { app } = require('@azure/functions');

const AOAI_ENDPOINT     = process.env.AOAI_ENDPOINT;
const AOAI_KEY          = process.env.AOAI_KEY;
const AOAI_DEPLOYMENT   = process.env.AOAI_DEPLOYMENT;
const AOAI_API_VERSION  = process.env.AOAI_API_VERSION || '2024-10-21';
const ALLOWED_ORIGINS   = (process.env.ALLOWED_ORIGINS || '*')
  .split(',').map(s => s.trim()).filter(Boolean);
const RATE_LIMIT_PER_HOUR = parseInt(process.env.RATE_LIMIT_PER_HOUR || '15', 10);
const MAX_TOKENS          = parseInt(process.env.MAX_TOKENS || '800', 10);

const buckets = new Map(); // ip -> [timestamp, ...]

function pickAllowOrigin(origin) {
  if (ALLOWED_ORIGINS.includes('*')) return '*';
  if (origin && ALLOWED_ORIGINS.includes(origin)) return origin;
  return ALLOWED_ORIGINS[0] || '';
}

function corsHeaders(origin) {
  return {
    'Access-Control-Allow-Origin':  pickAllowOrigin(origin),
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'content-type',
    'Access-Control-Max-Age':       '86400',
    'Vary':                         'Origin',
  };
}

function rateLimit(ip) {
  const now = Date.now();
  const windowMs = 60 * 60 * 1000;
  const arr = (buckets.get(ip) || []).filter(t => now - t < windowMs);
  if (arr.length >= RATE_LIMIT_PER_HOUR) return false;
  arr.push(now);
  buckets.set(ip, arr);
  // crude pruning so the map doesn't grow forever
  if (buckets.size > 5000) {
    for (const [k, v] of buckets) {
      if (!v.length || now - v[v.length - 1] > windowMs) buckets.delete(k);
    }
  }
  return true;
}

function json(status, cors, payload) {
  return {
    status,
    headers: { ...cors, 'content-type': 'application/json' },
    body: JSON.stringify(payload),
  };
}

app.http('chat', {
  methods: ['POST', 'OPTIONS'],
  authLevel: 'anonymous',
  route: 'chat',
  handler: async (request, context) => {
    const origin = request.headers.get('origin') || '';
    const cors   = corsHeaders(origin);

    if (request.method === 'OPTIONS') {
      return { status: 204, headers: cors };
    }

    const ip =
      (request.headers.get('x-forwarded-for') || '').split(',')[0].trim() ||
      request.headers.get('x-azure-clientip') ||
      'unknown';

    if (!rateLimit(ip)) {
      return json(429, cors, { error: 'Rate limit exceeded. Try again in an hour.' });
    }

    let body;
    try { body = await request.json(); }
    catch (_) { return json(400, cors, { error: 'Invalid JSON' }); }

    const messages = Array.isArray(body?.messages) ? body.messages : null;
    if (!messages || !messages.length) {
      return json(400, cors, { error: 'messages[] required' });
    }
    if (messages.length > 20) {
      return json(400, cors, { error: 'too many messages' });
    }

    if (!AOAI_ENDPOINT || !AOAI_KEY || !AOAI_DEPLOYMENT) {
      context.error('Missing AOAI_* configuration');
      return json(500, cors, { error: 'Server not configured' });
    }

    const url =
      `${AOAI_ENDPOINT.replace(/\/+$/, '')}` +
      `/openai/deployments/${encodeURIComponent(AOAI_DEPLOYMENT)}` +
      `/chat/completions?api-version=${encodeURIComponent(AOAI_API_VERSION)}`;

    let upstream;
    try {
      upstream = await fetch(url, {
        method:  'POST',
        headers: { 'content-type': 'application/json', 'api-key': AOAI_KEY },
        body:    JSON.stringify({ messages, max_completion_tokens: MAX_TOKENS }),
      });
    } catch (err) {
      context.error('Upstream fetch failed', err);
      return json(502, cors, { error: 'Upstream error' });
    }

    const text = await upstream.text();
    return {
      status:  upstream.status,
      headers: { ...cors, 'content-type': 'application/json' },
      body:    text,
    };
  },
});

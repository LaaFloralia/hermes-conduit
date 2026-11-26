const ITEM_ID = /^[1-9][0-9]{0,15}$/;
const NOTE_ID = /^[A-Za-z0-9_-]{1,80}$/;
const KINDS = new Set(['brief', 'update', 'done', 'needs_owner']);
export const MAX_NOTE = 2000;

export const atMost = (value, limit) => typeof value === 'string' && value.length <= limit * 2 && [...value].length <= limit;
const itemId = (id) => typeof id === 'string' && ITEM_ID.test(id) && Number.isSafeInteger(Number(id));
const validTime = (date) => typeof date === 'string' && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/.test(date) && Number.isFinite(Date.parse(date));

function validLink(link) {
  if (link === null || link === undefined) return true;
  if (!atMost(link, 500) || !link.startsWith('https://') || /[\s\\\p{C}]/u.test(link)) return false;
  try { const url = new URL(link); return Boolean(url.hostname) && !url.username && !url.password; } catch { return false; }
}

function sanitizeItem(value) {
  if (!value || !itemId(value.id) || !KINDS.has(value.kind) || !atMost(value.title, 120)
    || !atMost(value.body, 4000) || !validLink(value.link) || !validTime(value.createdAt)) throw new Error('invalid worker response');
  const { id, kind, title, body, link = null, createdAt } = value;
  return { id, kind, title, body, link, createdAt };
}

export function duetOrigin(value) {
  try {
    const url = new URL(value);
    if (!/^laa-duet-connector\.[a-z0-9-]+\.workers\.dev$/.test(url.hostname)
      || url.protocol !== 'https:' || !['/', '/mcp'].includes(url.pathname) || url.port
      || url.username || url.password || url.search || url.hash) return null;
    return url.origin;
  } catch { return null; }
}

async function readJson(response) {
  const chunks = [];
  let size = 0;
  for await (const chunk of response.body) {
    size += chunk.byteLength;
    if (size > 1_500_000) throw new Error('oversize worker response');
    chunks.push(chunk);
  }
  return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks, size)));
}

export function createDuetClient({ origin, token, request = fetch }) {
  async function call(path, payload) {
    const headers = { Authorization: `Bearer ${token}`, 'User-Agent': 'Hortensia-Bridge/1.0' };
    if (payload !== undefined) headers['Content-Type'] = 'application/json';
    const response = await request(new URL(path, origin), { headers, redirect: 'error', signal: AbortSignal.timeout(7000),
      ...(payload === undefined ? {} : { method: 'POST', body: JSON.stringify(payload) }) });
    if (!response.ok) {
      await response.body?.cancel();
      throw new Error('worker rejected request');
    }
    return readJson(response);
  }
  return {
    async pull(after) {
      const data = await call(`/pull?after=${encodeURIComponent(after)}`);
      if (!Array.isArray(data?.items) || data.items.length > 50) throw new Error('invalid worker response');
      return data.items.map(sanitizeItem);
    },
    async ack(through) {
      if ((await call('/ack', { through }))?.ok !== true) throw new Error('invalid worker response');
    },
    async send({ id, text }) {
      if ((await call('/notes', { id, text }))?.id !== id) throw new Error('invalid worker response');
    },
    async readStatus() {
      const data = await call('/notes/status');
      if (!Array.isArray(data?.read) || data.read.length > 200 || data.read.some((id) => typeof id !== 'string' || !NOTE_ID.test(id))) {
        throw new Error('invalid worker response');
      }
      return new Set(data.read);
    },
  };
}

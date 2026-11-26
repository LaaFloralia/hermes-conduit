export const KINDS = ['brief', 'update', 'done', 'needs_owner'];
export const NOTE_ID = /^[A-Za-z0-9_-]{1,80}$/;
export const object = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const bounded = (value, length) => typeof value === 'string' && value.length <= length * 2 && [...value].length <= length;

export class InputError extends Error {
  constructor(message, status = 400) {
    super(message);
    this.status = status;
  }
}

export async function readBytes(request, limit) {
  if (Number(request.headers.get('content-length')) > limit) throw new InputError('Request is too large.', 413);
  const reader = request.body?.getReader();
  const bytes = new Uint8Array(limit);
  let size = 0;
  if (reader) {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      if (size + value.length > limit) {
        void reader.cancel().catch(() => {});
        throw new InputError('Request is too large.', 413);
      }
      bytes.set(value, size);
      size += value.length;
    }
  }
  return bytes.subarray(0, size);
}

export function decodeObject(bytes) {
  let parsed;
  try { parsed = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); } catch {
    throw new InputError('Expected a JSON object.');
  }
  if (!object(parsed)) throw new InputError('Expected a JSON object.');
  return parsed;
}

export async function jsonObject(request, limit) {
  if (request.headers.get('content-type')?.split(';')[0].trim().toLowerCase() !== 'application/json') {
    throw new InputError('Content-Type must be application/json.', 415);
  }
  return decodeObject(await readBytes(request, limit));
}

export function validatePost(value) {
  if (!object(value) || Object.keys(value).some((key) => !['kind', 'title', 'body', 'link'].includes(key))) {
    throw new InputError('Expected kind, title, body and optional link.');
  }
  if (!KINDS.includes(value.kind)) throw new InputError('kind must be brief, update, done, or needs_owner.');
  if (!bounded(value.title, 120)) throw new InputError('title must be a string of at most 120 characters.');
  if (!bounded(value.body, 4000)) throw new InputError('body must be a string of at most 4000 characters.');
  if (value.link !== undefined) {
    let url;
    try {
      if (bounded(value.link, 500) && value.link.startsWith('https://') && !/[\s\\\p{C}]/u.test(value.link)) url = new URL(value.link);
    } catch { /* invalid URL */ }
    if (!url || url.protocol !== 'https:' || !url.hostname || url.username || url.password) {
      throw new InputError('link must be an HTTPS URL of at most 500 characters, without credentials.');
    }
  }
  return { kind: value.kind, title: value.title, body: value.body, link: value.link ?? null };
}

export function validateNote(value) {
  if (Object.keys(value).some((key) => key !== 'id' && key !== 'text') || typeof value.id !== 'string' || !NOTE_ID.test(value.id)) {
    throw new InputError('id must be a URL-safe identifier of 1–80 characters.');
  }
  if (!bounded(value.text, 2000)) throw new InputError('text must be a string of at most 2000 characters.');
  return value;
}

export function cursor(value, { zero = false } = {}) {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]{0,15})$/.test(value) || !Number.isSafeInteger(Number(value)) || (!zero && value === '0')) {
    throw new InputError('Invalid cursor.');
  }
  return Number(value);
}

// One IPv6 host usually holds a whole /64, so it counts as one client. The
// address is expanded first so every spelling of a /64 gives the same key.
export function clientKey(request) {
  const ip = (request.headers.get('CF-Connecting-IP') ?? '').trim().toLowerCase();
  if (!ip.includes(':')) return /^\d{1,3}(\.\d{1,3}){3}$/.test(ip) ? ip : 'unknown';
  const mapped = /^(?:0{0,4}:){0,5}(?:0{0,4}:)?ffff:(\d{1,3}(?:\.\d{1,3}){3})$/.exec(ip.replace(/^::/, '0:'));
  if (mapped) return mapped[1];
  const halves = ip.split('::');
  if (halves.length > 2) return 'unknown';
  const head = halves[0] ? halves[0].split(':') : [];
  const tail = halves.length === 2 && halves[1] ? halves[1].split(':') : [];
  const groups = halves.length === 2 ? [...head, ...Array(8 - head.length - tail.length).fill('0'), ...tail] : head;
  if (groups.length !== 8 || groups.some((g) => !/^[0-9a-f]{1,4}$/.test(g))) return 'unknown';
  return groups.slice(0, 4).map((g) => g.padStart(4, '0')).join(':');
}

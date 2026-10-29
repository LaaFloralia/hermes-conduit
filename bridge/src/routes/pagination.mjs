// Offset cursors shared by the list endpoints. The cursor is opaque to the
// client and only carries an offset: the collections are small (projects) or
// re-scanned (workspaces), and a stable key cursor would need an ordering the
// filesystem does not guarantee.

import { badRequest } from '../errors.mjs';

export function parseLimit(raw, { max = 100, fallback = 50 } = {}) {
  if (raw === undefined || raw === null || raw === '') return fallback;
  const limit = Number(raw);
  if (!Number.isInteger(limit) || limit < 1 || limit > max) {
    throw badRequest('limit_invalid', `limit must be an integer between 1 and ${max}`);
  }
  return limit;
}

export function encodeCursor(offset) {
  return Buffer.from(JSON.stringify({ offset }), 'utf8').toString('base64url');
}

export function parseCursor(raw) {
  if (raw === undefined || raw === null || raw === '') return 0;
  try {
    const parsed = JSON.parse(Buffer.from(raw, 'base64url').toString('utf8'));
    if (Number.isInteger(parsed?.offset) && parsed.offset >= 0) return parsed.offset;
  } catch {
    // fall through
  }
  throw badRequest('cursor_invalid', 'cursor is not recognised');
}

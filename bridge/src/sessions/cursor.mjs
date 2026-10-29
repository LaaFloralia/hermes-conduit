// Resume cursors for `/v1/sessions/{id}/events`.
//
// A cursor carries the session id, the last sequence number the client has and
// the time it was issued. It is opaque (base64url JSON), contains no secrets or
// message content, and expires after the journal retention window (24 hours by
// default, BRIDGE.md section 9). An expired cursor is a 410: the client has to
// re-read the session instead of pretending it saw every event.

import { badRequest, BridgeError } from '../errors.mjs';

export function encodeEventCursor({ sessionId, seq, now }) {
  const payload = { v: 1, s: sessionId, q: seq, t: now };
  return Buffer.from(JSON.stringify(payload), 'utf8').toString('base64url');
}

export function parseEventCursor(raw, { sessionId, now, retentionMs }) {
  if (typeof raw !== 'string' || raw === '') return null;
  let parsed;
  try {
    parsed = JSON.parse(Buffer.from(raw, 'base64url').toString('utf8'));
  } catch {
    throw badRequest('cursor_invalid', 'cursor is not recognised');
  }
  if (parsed?.v !== 1 || !Number.isInteger(parsed?.q) || parsed.q < 0 || typeof parsed?.s !== 'string') {
    throw badRequest('cursor_invalid', 'cursor is not recognised');
  }
  if (parsed.s !== sessionId) {
    throw badRequest('cursor_session_mismatch', 'cursor belongs to another session');
  }
  if (!Number.isInteger(parsed.t) || parsed.t > now + 60_000 || now - parsed.t > retentionMs) {
    throw new BridgeError(410, 'cursor_expired', 'cursor has expired; re-read the session and its artifacts');
  }
  return parsed.q;
}

// Idempotency ledger for state-changing requests (BRIDGE.md sections 2 and 9).
//
// Key: device id + method + path + Idempotency-Key. Value: a hash of the raw
// request bytes plus the stored response, kept for seven days.
//
//   same key, same request bytes   -> replay the stored response
//   same key, different bytes      -> 409, never execute
//   same key, still executing      -> 409, never execute twice
//   same key, abandoned > 60s ago  -> 409 outcome unknown, never auto-retry
//
// Entries are reserved before the handler runs, so a concurrent duplicate sees
// an in-flight row instead of racing the handler.

import { createHash } from 'node:crypto';

export function requestFingerprint(method, path, rawBody) {
  return createHash('sha256')
    .update(`${method}\n${path}\n`, 'utf8')
    .update(rawBody ?? Buffer.alloc(0))
    .digest('hex');
}

export function ledgerKey(deviceId, key) {
  return `${deviceId}|${key}`;
}

export const IDEMPOTENCY_KEY_PATTERN = /^[A-Za-z0-9._:-]{1,200}$/;

// Reserve a row. Returns one of:
//   { action: 'execute', entry }
//   { action: 'replay', entry }
//   { action: 'conflict', entry }
//   { action: 'in_flight' }
//   { action: 'unresolved', entry }
export function reserve(state, { deviceId, key, method, path, fingerprint, now, inflightGraceMs }) {
  const id = ledgerKey(deviceId, key);
  const existing = state.idempotency[id];
  if (existing) {
    if (existing.fingerprint !== fingerprint) {
      return { action: 'conflict', entry: existing };
    }
    if (existing.status === 'in_progress') {
      const age = now - existing.createdAt;
      return age > inflightGraceMs
        ? { action: 'unresolved', entry: existing }
        : { action: 'in_flight' };
    }
    return { action: 'replay', entry: existing };
  }
  const entry = {
    deviceId,
    key,
    method,
    path,
    fingerprint,
    status: 'in_progress',
    httpStatus: null,
    response: null,
    createdAt: now,
    completedAt: null,
  };
  state.idempotency[id] = entry;
  return { action: 'execute', entry };
}

export function complete(state, { deviceId, key, httpStatus, response, now }) {
  const entry = state.idempotency[ledgerKey(deviceId, key)];
  if (!entry) return null;
  entry.status = 'succeeded';
  entry.httpStatus = httpStatus;
  entry.response = response;
  entry.completedAt = now;
  return entry;
}

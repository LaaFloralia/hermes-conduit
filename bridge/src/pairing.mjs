// Pairing and revocation operations, shared by the CLI and the tests so the
// operator path and the tested path cannot drift apart.

import { hashPairingCode, normalizePairingCode, createPairingCode } from './auth.mjs';

export function issuePairing(store, { name, scopes, ttlMs, now = Date.now() }) {
  const code = createPairingCode();
  const expiresAt = now + ttlMs;
  const normalized = normalizePairingCode(code);
  store.mutate((state) => {
    state.pairings[hashPairingCode(normalized)] = {
      name,
      scopes: [...scopes],
      createdAt: now,
      expiresAt,
      usedAt: null,
      deviceId: null,
    };
  });
  return { code, name, scopes: [...scopes], expiresAt };
}

// Returns { device, alreadyRevoked } or { error }.
export function revokeDevice(store, { target, reason = null, now = Date.now() }) {
  return store.mutate((state) => {
    const ids = Object.keys(state.devices);
    const matches = target.length >= 4 ? ids.filter((id) => id.startsWith(target)) : [];
    if (matches.length === 0) return { error: 'no device matches that id' };
    if (matches.length > 1) return { error: `ambiguous id, matches ${matches.join(', ')}` };
    const device = state.devices[matches[0]];
    if (device.revokedAt) return { device, alreadyRevoked: true };
    device.revokedAt = new Date(now).toISOString();
    device.revokedReason = reason ? String(reason).slice(0, 200) : null;
    // The next request with this token gets 401 token_revoked. In-flight or
    // external work is left for the operator to reconcile; the Bridge does not
    // re-run it.
    return { device, alreadyRevoked: false };
  });
}

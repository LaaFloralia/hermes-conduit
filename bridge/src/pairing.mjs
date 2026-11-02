// Pairing and revocation operations, shared by the CLI and the tests so the
// operator path and the tested path cannot drift apart.

import { hashPairingCode, normalizePairingCode, createPairingCode } from './auth.mjs';
import { OPERATOR_GRANT_SCOPES, STUDIO_SCOPES } from './config.mjs';

export function issuePairing(store, { name, scopes, ttlMs, now = Date.now() }) {
  if (scopes.some((scope) => STUDIO_SCOPES.includes(scope))) {
    throw new Error('Studio scopes must be granted to an enrolled device using grant-studio');
  }
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

// A narrow operator grant: existing tokens remain unchanged and revoked devices
// cannot be revived. The store lock makes CLI and Bridge updates atomic.
export function grantStudio(store, { target, reason, now = Date.now(), operatorUid = process.getuid?.() ?? null }) {
  if (typeof reason !== 'string' || !reason.trim() || reason.length > 200 || /[\u0000-\u001f\u007f]/u.test(reason)) {
    return { error: 'reason must be 1-200 printable characters on one line' };
  }
  return store.mutate((state) => {
    const matches = target.length >= 4 ? Object.keys(state.devices).filter((id) => id.startsWith(target)) : [];
    if (!matches.length) return { error: 'no device matches that id' };
    if (matches.length > 1) return { error: `ambiguous id, matches ${matches.join(', ')}` };
    const device = state.devices[matches[0]];
    if (device.revokedAt) return { error: 'cannot grant scopes to a revoked device' };
    const previousScopes = [...device.scopes];
    const alreadyGranted = STUDIO_SCOPES.every((scope) => device.scopes.includes(scope));
    if (!alreadyGranted || !device.studioGrant) {
      device.scopes = [...new Set([...device.scopes, ...STUDIO_SCOPES])].sort();
      device.studioGrant = { grantedAt: new Date(now).toISOString(), operatorUid, reason: reason.trim(), wasAlreadyGranted: alreadyGranted };
    }
    return { device, alreadyGranted, previousScopes };
  });
}

// The operator's narrow grant for the two opt-in scopes. Every requested scope
// is checked against the allowlist before the store is touched, so a mixed
// request such as `calendar:read,brain:write` grants neither. The audit record
// is append-only per device: a later grant of the other scope keeps the earlier
// one visible.
export function grantScopes(store, { target, scopes, reason, now = Date.now(), operatorUid = process.getuid?.() ?? null }) {
  if (typeof reason !== 'string' || !reason.trim() || reason.length > 200 || /[\u0000-\u001f\u007f]/u.test(reason)) {
    return { error: 'reason must be 1-200 printable characters on one line' };
  }
  if (typeof target !== 'string' || target.length < 4) {
    return { error: 'grant needs a device id or an unambiguous prefix of 4+ characters' };
  }
  const requested = [...new Set((Array.isArray(scopes) ? scopes : []).map((scope) => String(scope).trim()).filter(Boolean))].sort();
  if (requested.length === 0) return { error: 'grant needs at least one scope' };
  const refused = requested.filter((scope) => !OPERATOR_GRANT_SCOPES.includes(scope));
  if (refused.length > 0) {
    return { error: `scope not grantable: ${refused.join(', ')}; grantable: ${OPERATOR_GRANT_SCOPES.join(', ')}` };
  }
  return store.mutate((state) => {
    const matches = Object.keys(state.devices).filter((id) => id.startsWith(target));
    if (!matches.length) return { error: 'no device matches that id' };
    if (matches.length > 1) return { error: `ambiguous id, matches ${matches.join(', ')}` };
    const device = state.devices[matches[0]];
    if (device.revokedAt) return { error: 'cannot grant scopes to a revoked device' };
    const previousScopes = [...device.scopes];
    const alreadyGranted = requested.every((scope) => device.scopes.includes(scope));
    const recorded = (device.scopeGrants ?? []).some((grant) => (
      Array.isArray(grant?.scopes) && requested.every((scope) => grant.scopes.includes(scope))
    ));
    if (!alreadyGranted || !recorded) {
      device.scopes = [...new Set([...device.scopes, ...requested])].sort();
      device.scopeGrants = [
        ...(device.scopeGrants ?? []),
        {
          scopes: requested,
          grantedAt: new Date(now).toISOString(),
          operatorUid,
          reason: reason.trim(),
          wasAlreadyGranted: alreadyGranted,
        },
      ];
    }
    return { device, alreadyGranted, previousScopes, requested };
  });
}

// This grant is opt-in for one already enrolled device. Session scopes do not
// imply access to the owner's instruction sources.
export function grantInstructions(store, { target, reason, now = Date.now(), operatorUid = process.getuid?.() ?? null }) {
  if (typeof reason !== 'string' || !reason.trim() || reason.length > 200 || /[\u0000-\u001f\u007f]/u.test(reason)) {
    return { error: 'reason must be 1-200 printable characters on one line' };
  }
  return store.mutate((state) => {
    const matches = target.length >= 4 ? Object.keys(state.devices).filter((id) => id.startsWith(target)) : [];
    if (!matches.length) return { error: 'no device matches that id' };
    if (matches.length > 1) return { error: `ambiguous id, matches ${matches.join(', ')}` };
    const device = state.devices[matches[0]];
    if (device.revokedAt) return { error: 'cannot grant scopes to a revoked device' };
    const scopes = ['instructions:read', 'instructions:write'];
    const previousScopes = [...device.scopes];
    const alreadyGranted = scopes.every((scope) => device.scopes.includes(scope));
    if (!alreadyGranted || !device.instructionsGrant) {
      device.scopes = [...new Set([...device.scopes, ...scopes])].sort();
      device.instructionsGrant = { grantedAt: new Date(now).toISOString(), operatorUid, reason: reason.trim(), wasAlreadyGranted: alreadyGranted };
    }
    return { device, alreadyGranted, previousScopes };
  });
}

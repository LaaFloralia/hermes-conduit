// Device credentials: 256-bit random bearer tokens, stored only as SHA-256
// hashes, plus one-time pairing codes (also stored hashed).

import { createHash, randomBytes } from 'node:crypto';

// Crockford-like alphabet: no I, O, 0 or 1, so a code read off the Mac screen
// cannot be mistyped into a neighbouring character.
const PAIRING_ALPHABET = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';

export function randomToken() {
  return randomBytes(32).toString('base64url');
}

export function hashToken(token) {
  return createHash('sha256').update(token, 'utf8').digest('hex');
}

export function randomDeviceId() {
  return `dev_${randomBytes(8).toString('hex')}`;
}

export function createPairingCode() {
  const bytes = randomBytes(8);
  let out = '';
  for (const byte of bytes) out += PAIRING_ALPHABET[byte % PAIRING_ALPHABET.length];
  return `${out.slice(0, 4)}-${out.slice(4)}`;
}

export function normalizePairingCode(input) {
  if (typeof input !== 'string') return null;
  const normalized = input.replace(/[\s-]/g, '').toUpperCase();
  if (normalized.length !== 8) return null;
  for (const ch of normalized) {
    if (!PAIRING_ALPHABET.includes(ch)) return null;
  }
  return normalized;
}

export function hashPairingCode(code) {
  return createHash('sha256').update(`pair:${code}`, 'utf8').digest('hex');
}

export function parseBearer(headerValue) {
  if (typeof headerValue !== 'string') return null;
  const match = /^Bearer\s+([A-Za-z0-9._~+/=-]{20,200})$/.exec(headerValue.trim());
  return match ? match[1] : null;
}

// Returns { device } or { reason: 'missing' | 'invalid_token' | 'token_revoked' }.
// Unknown and revoked are separated so an operator can tell a stale device from
// a mistyped token, but both are 401 to the client.
export function authenticate(state, authorizationHeader) {
  const token = parseBearer(authorizationHeader);
  if (!token) return { reason: 'missing' };
  const hash = hashToken(token);
  const device = Object.values(state.devices).find((candidate) => candidate.tokenHash === hash);
  if (!device) return { reason: 'invalid_token' };
  if (device.revokedAt) return { reason: 'token_revoked' };
  return { device };
}

export function hasScope(device, scope) {
  return Array.isArray(device.scopes) && device.scopes.includes(scope);
}

export function newDevice({ id, name, scopes, platform, now }) {
  return {
    id,
    name,
    scopes: [...scopes],
    platform: platform ?? null,
    createdAt: new Date(now).toISOString(),
    revokedAt: null,
  };
}

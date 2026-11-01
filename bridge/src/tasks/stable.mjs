// Deterministic helpers shared by the owner-task store, its service and the
// Linear importer. All three need to hash the same bytes to answer "is this the
// same request / the same manifest / the same document?".

import { createHash } from 'node:crypto';

// JSON with object keys sorted at every depth. Arrays keep their order (the
// caller sorts any list whose order is not meaningful). This is the only form
// that is hashed, so a retry that re-serialises the same values matches.
export function canonicalJson(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map((item) => canonicalJson(item)).join(',')}]`;
  const keys = Object.keys(value).sort();
  return `{${keys.map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`;
}

export function sha256Hex(value) {
  return createHash('sha256').update(value, 'utf8').digest('hex');
}

// RFC 4122 version 5 (SHA-1, name-based) with the nil namespace. A dry-run that
// sees the same Linear issue twice proposes the same task UUID, so the approved
// manifest keeps its hash and a re-run cannot create a second task for it.
const NIL_NAMESPACE = '00000000-0000-0000-0000-000000000000';

function namespaceBytes(uuid) {
  return Buffer.from(uuid.replace(/-/g, ''), 'hex');
}

export function uuidv5(name) {
  const digest = createHash('sha1').update(namespaceBytes(NIL_NAMESPACE)).update(name, 'utf8').digest();
  const bytes = Buffer.from(digest.subarray(0, 16));
  bytes[6] = (bytes[6] & 0x0f) | 0x50; // version 5
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

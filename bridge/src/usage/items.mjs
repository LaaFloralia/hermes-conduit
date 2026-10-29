// Shared item helpers for /v1/usage and /v1/mac/status (docs/laa/USAGE.md §4).
//
// One item shape covers every reading:
//   {id, kind, label, value, unit, source, observedAt, availability, stale,
//    estimated, expired, nullReason?, detail?}
// `value` is a number or null and null is the only way to say "no value": a
// missing reading is never coerced to 0. `availability: unavailable` always
// carries `nullReason`, `availability: available` never does.
//
// Labels, ids and sources are code-owned. Text that comes from a source (window
// labels, findings, recorded model names) goes through `safeText`, so a source
// cannot smuggle a path, a token-shaped string, an email or control characters
// into the app.

export const USAGE_SOURCE = 'codexbar-usage-proxy';
export const HOST_SAMPLER_SOURCE = 'bridge-host-sampler';
export const DISK_SOURCE = 'laa-storage-guard';

export const ITEM_KINDS = Object.freeze(['quota', 'balance', 'usage', 'cost']);
export const HOST_ITEM_KINDS = Object.freeze(['host.cpu', 'host.memory', 'host.disk']);
export const ITEM_UNITS = Object.freeze(['percent', 'usd', 'jpy', 'tokens', 'count', 'credits', 'bytes', 'gb']);
export const NULL_REASONS = Object.freeze(['not_configured', 'fetch_failed', 'unsupported', 'auth_required']);

const CONTROL_CHARS = /[\u0000-\u001f\u007f]/g;
// Anything that looks like a credential, a home path or an address is dropped
// rather than shown: these readings are display data, not a debugging channel.
const UNSAFE_TEXT = /(?:op:\/\/|Bearer\s|\/Users\/|[\w.+-]+@[\w.-]+\.[A-Za-z]{2,})/i;

export function safeText(value, max = 64) {
  if (typeof value !== 'string') return null;
  const text = value.replace(CONTROL_CHARS, ' ').trim();
  if (text === '' || text.length > max * 4) return null;
  if (UNSAFE_TEXT.test(text)) return null;
  return text.slice(0, max);
}

export function finiteNumber(value, { min = 0, max = Number.MAX_SAFE_INTEGER } = {}) {
  if (typeof value !== 'number' || !Number.isFinite(value)) return null;
  if (value < min || value > max) return null;
  return value;
}

export function round(value, digits = 1) {
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
}

// Timestamps are accepted as ISO 8601 with an offset (the proxy mixes `Z` and
// `+00:00`, and the storage guard writes `+0900`) and re-emitted as UTC ISO 8601
// at second precision, which is what the contract and the fixtures use.
export function isoFromMs(ms) {
  return new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
}

export function isoTime(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T/.test(value)) return null;
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed)) return null;
  return isoFromMs(parsed);
}

// A date-only expiry ("2026-10-25") is inclusive: the credit is usable through
// that UTC day and expired from the next one.
export function expiryTime(value) {
  if (typeof value !== 'string') return null;
  if (/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    const parsed = Date.parse(`${value}T23:59:59.999Z`);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return isoTime(value) === null ? null : Date.parse(value);
}

export function availableItem({
  id, kind, label, value, unit, source, observedAt, stale = false, expired = false, detail,
}) {
  const item = {
    id,
    kind,
    label,
    value,
    unit,
    source,
    observedAt,
    availability: 'available',
    stale,
    estimated: false,
    expired,
  };
  if (detail !== undefined) item.detail = detail;
  return item;
}

export function unavailableItem({
  id, kind, label, unit, source, reason, expired = false,
}) {
  return {
    id,
    kind,
    label,
    value: null,
    unit,
    source,
    observedAt: null,
    availability: 'unavailable',
    stale: false,
    estimated: false,
    expired,
    nullReason: reason,
  };
}

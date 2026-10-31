// /v1/usage items from the existing CodexBar usage proxy (docs/laa/USAGE.md).
//
// The proxy at 127.0.0.1:8081/widget is the single source of truth for quotas
// and balances, and the Bridge only re-shapes what that feed already displays
// (same display projection as the Console collector: code-owned ids, labels and
// units, no provider URL, cookie, raw error or billing payload passes through).
//
// Rules taken from USAGE.md §4:
//   * `value` is null whenever there is no reading, never 0.
//   * a provider absent from the feed is `unavailable` with `fetch_failed`.
//   * `fetchedAt` more than 60 s in the future discards the whole response.
//   * `source: verified` is a screen-checked value with no auto refresh: it is
//     never marked stale; its `observedAt` and expiry carry the freshness.
//   * live/local readings go stale after `autoStaleMs` (20 minutes) from the
//     older of the provider `updatedAt` and the feed `fetchedAt`.
//   * a passed `resetsAt` / `expiresOnUtc` sets `expired` and keeps the value.
//
// Cost and token items are deliberately absent: USAGE.md §6 (parent decision 1)
// keeps them on the app's direct dashboard path so no new credential is added.
// `clef` (proxy kind `status`) is the one provider left out: its reading is a
// text status, which none of the four v1 item kinds can carry. It is reported as
// an open item in bridge/README.md instead of being shown as a fake balance.

import { resolveUsageAutoStaleMs, resolveUsageFeedUrl } from '../config.mjs';
import {
  USAGE_SOURCE,
  availableItem,
  expiryTime,
  finiteNumber,
  isoTime,
  round,
  safeText,
  unavailableItem,
} from './items.mjs';

export const USAGE_FEED_VERSION = 1;
const MAX_PROVIDERS = 32;
const MAX_WINDOWS = 32;
const MAX_COMPONENTS = 30;
const FUTURE_TOLERANCE_MS = 60 * 1000;
const DEFAULT_MAX_BYTES = 512 * 1024;

// Fixed order, so the list is stable between polls and between providers that
// appear and disappear. Labels match the Console collector's code-owned names.
export const USAGE_PROVIDERS = Object.freeze([
  { id: 'claude', label: 'Claude', kind: 'quota' },
  { id: 'codex', label: 'Codex', kind: 'quota' },
  { id: 'antigravity', label: 'Antigravity', kind: 'quota' },
  { id: 'jev', label: 'Jev', kind: 'balance' },
  { id: 'google-cloud', label: 'Google Cloud', kind: 'balance' },
  { id: 'venice', label: 'Venice', kind: 'balance' },
  { id: 'claude-api', label: 'Claude API', kind: 'balance' },
  { id: 'fal', label: 'fal', kind: 'balance' },
  { id: 'gemini', label: 'Gemini API', kind: 'balance' },
  { id: 'google-flow', label: 'Google Flow', kind: 'unitCredits' },
  { id: 'liquid', label: 'Liquid AI', kind: 'usage' },
  { id: 'deepseek', label: 'DeepSeek API', kind: 'balance' },
  { id: 'grok-bot', label: 'Grok Bot', kind: 'quota' },
  { id: 'refuseless', label: 'Refuseless', kind: 'balance' },
  { id: 'opencode-go', label: 'OpenCode Go', kind: 'quota' },
  { id: 'magnific', label: 'Magnific', kind: 'unitCredits' },
]);

const SHAPES = Object.freeze({
  quota: { itemKind: 'quota', unit: 'percent', suffix: 'quota' },
  balance: { itemKind: 'balance', unit: 'usd', suffix: 'balance' },
  unitCredits: { itemKind: 'balance', unit: 'credits', suffix: 'credits' },
  usage: { itemKind: 'usage', unit: 'tokens', suffix: 'usage' },
});

export class UsageFeedError extends Error {
  constructor(code) {
    super(`usage feed rejected: ${code}`);
    this.name = 'UsageFeedError';
    this.code = code;
  }
}

function shapeOf(provider) {
  return SHAPES[provider.kind];
}

function itemId(provider) {
  return `provider.${provider.id}.${shapeOf(provider).suffix}`;
}

function baseOf(provider) {
  return {
    id: itemId(provider),
    kind: shapeOf(provider).itemKind,
    label: provider.label,
    unit: shapeOf(provider).unit,
    source: USAGE_SOURCE,
  };
}

export function unavailableUsageItems(reason = 'fetch_failed') {
  return USAGE_PROVIDERS.map((provider) => unavailableItem({ ...baseOf(provider), reason }));
}

export async function readUsageFeed({
  url = resolveUsageFeedUrl(),
  fetcher = fetch,
  timeoutMs = 5000,
  maxBytes = DEFAULT_MAX_BYTES,
} = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetcher(url, {
      redirect: 'error',
      signal: controller.signal,
      headers: { accept: 'application/json' },
    });
    if (!response.ok) throw new UsageFeedError('fetch_failed');
    const length = Number(response.headers?.get?.('content-length') ?? Number.NaN);
    if (Number.isFinite(length) && length > maxBytes) throw new UsageFeedError('fetch_failed');
    const text = await response.text();
    if (Buffer.byteLength(text, 'utf8') > maxBytes) throw new UsageFeedError('fetch_failed');
    let parsed;
    try {
      parsed = JSON.parse(text);
    } catch {
      throw new UsageFeedError('fetch_failed');
    }
    return parsed;
  } catch (error) {
    if (error instanceof UsageFeedError) throw error;
    // Timeouts, refused connections and TLS problems are one display state: the
    // proxy could not be read. The original message is never forwarded.
    throw new UsageFeedError('fetch_failed');
  } finally {
    clearTimeout(timer);
  }
}

function normalizeWindows(row) {
  const raw = [...(Array.isArray(row.windows) ? row.windows : []), ...(Array.isArray(row.extraWindows) ? row.extraWindows : [])];
  const windows = [];
  for (const entry of raw.slice(0, MAX_WINDOWS)) {
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) continue;
    const remaining = finiteNumber(entry.remaining, { max: 100 });
    if (remaining === null) continue;
    const window = {
      label: safeText(entry.label, 64) ?? `Window ${windows.length + 1}`,
      remainingPercent: remaining,
      resetsAt: isoTime(entry.resetsAt),
    };
    const minutes = finiteNumber(entry.windowMinutes, { min: 1 });
    if (minutes !== null) window.windowMinutes = minutes;
    if (!windows.some((old) => old.label === window.label && old.remainingPercent === window.remainingPercent
      && old.resetsAt === window.resetsAt && old.windowMinutes === window.windowMinutes)) windows.push(window);
  }
  return windows;
}

function normalizeComponents(row) {
  if (!Array.isArray(row.components)) return [];
  const components = [];
  for (const entry of row.components.slice(0, MAX_COMPONENTS)) {
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) continue;
    const amount = finiteNumber(entry.amount);
    if (amount === null) continue;
    const component = { kind: safeText(entry.kind, 32) ?? 'other', amount };
    const granted = finiteNumber(entry.grantedAmount);
    if (granted !== null) component.grantedAmount = granted;
    if (typeof entry.expiresOnUtc === 'string' && expiryTime(entry.expiresOnUtc) !== null) {
      component.expiresOnUtc = entry.expiresOnUtc;
    }
    components.push(component);
  }
  return components;
}

// A balance is expired when its own expiry has passed, or when every component
// that still holds something has expired (the `claude-api` shape: some credit
// lapsed, some did not, so the item is not called expired).
function balanceExpired(row, now) {
  const own = expiryTime(row.expiresOnUtc);
  if (own !== null && now > own) return true;
  if (!Array.isArray(row.components)) return false;
  const live = row.components.filter((entry) => entry && typeof entry === 'object'
    && finiteNumber(entry.amount) !== null && entry.amount > 0);
  if (live.length === 0) return false;
  return live.every((entry) => {
    const at = expiryTime(entry.expiresOnUtc);
    return at !== null && now > at;
  });
}

function isStale(row, feedFetchedAt, now, autoStaleMs) {
  // A verified value is a screen check with no auto refresh: age is expected,
  // and `observedAt` plus the expiry already say how old it is.
  if (row.source === 'verified') return false;
  const times = [isoTime(row.updatedAt), feedFetchedAt]
    .filter((value) => value !== null)
    .map((value) => Date.parse(value));
  if (times.length === 0) return false;
  return now - Math.min(...times) > autoStaleMs;
}

function observedAtOf(row, feedFetchedAt) {
  return isoTime(row.updatedAt);
}

function quotaItem(row, provider, context) {
  const windows = normalizeWindows(row);
  if (windows.length === 0) {
    return unavailableItem({ ...baseOf(provider), reason: 'fetch_failed' });
  }
  const binding = windows.reduce((lowest, window) => (
    window.remainingPercent < lowest.remainingPercent ? window : lowest
  ));
  const expired = binding.resetsAt !== null && Date.parse(binding.resetsAt) <= context.now;
  const detail = { windows };
  if (row.source === 'verified') detail.sourceKind = 'verified';
  const extraCredits = finiteNumber(row.credits?.remaining);
  if (extraCredits !== null) detail.credits = { remaining: extraCredits, updatedAt: isoTime(row.credits?.updatedAt) };
  if (row.resetPasses && typeof row.resetPasses.available === 'boolean') {
    detail.resetPasses = { available: row.resetPasses.available, remaining: finiteNumber(row.resetPasses.remaining),
      updatedAt: isoTime(row.resetPasses.updatedAt), expiresAt: isoTime(row.resetPasses.expiresAt) };
  }
  return availableItem({
    ...baseOf(provider),
    value: binding.remainingPercent,
    observedAt: observedAtOf(row, context.fetchedAt),
    stale: isStale(row, context.fetchedAt, context.now, context.autoStaleMs),
    expired,
    detail,
  });
}

function balanceItem(row, provider, context) {
  const currency = row.currency === 'JPY' ? 'JPY' : row.currency === 'USD' ? 'USD' : null;
  const amount = finiteNumber(row.amount);
  const expired = balanceExpired(row, context.now);
  const base = { ...baseOf(provider), unit: currency === 'JPY' ? 'jpy' : 'usd' };
  if (amount === null) {
    return unavailableItem({ ...base, reason: 'fetch_failed', expired });
  }
  const detail = {};
  if (row.source === 'verified') detail.sourceKind = 'verified';
  if (currency !== null) detail.currency = currency;
  for (const key of ['usd', 'diem', 'monthlyRemainingPercent']) {
    const value = finiteNumber(row[key], { max: key === 'monthlyRemainingPercent' ? 100 : Number.MAX_SAFE_INTEGER });
    if (value !== null) detail[key] = value;
  }
  const components = normalizeComponents(row);
  if (components.length > 0) detail.components = components;
  if (typeof row.expiresOnUtc === 'string' && expiryTime(row.expiresOnUtc) !== null) {
    detail.expiresOnUtc = row.expiresOnUtc;
  }
  return availableItem({
    ...base,
    value: amount,
    observedAt: observedAtOf(row, context.fetchedAt),
    stale: isStale(row, context.fetchedAt, context.now, context.autoStaleMs),
    expired,
    detail,
  });
}

function creditsItem(row, provider, context) {
  const remaining = finiteNumber(row.remaining);
  const expiresAt = expiryTime(row.expiresOnUtc);
  const expired = expiresAt !== null && context.now > expiresAt;
  if (remaining === null) {
    return unavailableItem({ ...baseOf(provider), reason: 'fetch_failed', expired });
  }
  const detail = {};
  if (row.source === 'verified') detail.sourceKind = 'verified';
  if (row.unit === 'AI credits' || row.unit === 'Flow credits') detail.creditUnit = row.unit;
  if (typeof row.expiresOnUtc === 'string' && expiryTime(row.expiresOnUtc) !== null) detail.expiresOnUtc = row.expiresOnUtc;
  const renewsAt = isoTime(row.renewsAt);
  if (renewsAt !== null) detail.renewsAt = renewsAt;
  for (const key of ['grantedAmount', 'monthlyGrantedAmount', 'dailyRemaining', 'dailyGrantedAmount', 'fallbackAiCredits']) {
    const value = finiteNumber(row[key]);
    if (value !== null) detail[key] = value;
  }
  return availableItem({
    ...baseOf(provider),
    value: remaining,
    observedAt: observedAtOf(row, context.fetchedAt),
    stale: isStale(row, context.fetchedAt, context.now, context.autoStaleMs),
    expired,
    detail,
  });
}

function recordedUsageItem(row, provider, context) {
  const recorded = row.recordedUsage;
  const input = finiteNumber(recorded?.inputTokens);
  const output = finiteNumber(recorded?.outputTokens);
  if (!recorded || typeof recorded !== 'object' || input === null || output === null) {
    return unavailableItem({ ...baseOf(provider), reason: 'fetch_failed' });
  }
  const startedAt = isoTime(recorded.startedAt);
  const lastRecordedAt = isoTime(recorded.lastRecordedAt);
  const span = startedAt !== null && lastRecordedAt !== null
    ? Date.parse(lastRecordedAt) - Date.parse(startedAt)
    : 0;
  const periodDays = Math.max(1, Math.ceil(span / (24 * 60 * 60 * 1000)));
  return availableItem({
    ...baseOf(provider),
    value: round(input + output, 0),
    observedAt: observedAtOf(row, context.fetchedAt),
    stale: isStale(row, context.fetchedAt, context.now, context.autoStaleMs),
    detail: {
      periodDays,
      recordedCostUsd: finiteNumber(recorded.costUsd),
      recordedRequestCount: finiteNumber(recorded.requestCount),
      lastRecordedAt,
      models: [{
        model: safeText(recorded.model, 64) ?? 'recorded-calls',
        inputTokens: input,
        outputTokens: output,
      }],
    },
  });
}

function itemFromRow(row, provider, context) {
  if (row.available === false) {
    return unavailableItem({
      ...baseOf(provider),
      reason: 'fetch_failed',
      expired: provider.kind === 'balance' || provider.kind === 'unitCredits'
        ? balanceExpired(row, context.now)
        : false,
    });
  }
  switch (provider.kind) {
    case 'quota': return quotaItem(row, provider, context);
    case 'balance': return balanceItem(row, provider, context);
    case 'unitCredits': return creditsItem(row, provider, context);
    case 'usage': return recordedUsageItem(row, provider, context);
    default: return unavailableItem({ ...baseOf(provider), reason: 'unsupported' });
  }
}

function validateFeed(raw, now) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new UsageFeedError('invalid_feed');
  if (raw.version !== USAGE_FEED_VERSION) throw new UsageFeedError('invalid_version');
  if (!Array.isArray(raw.providers) || raw.providers.length > MAX_PROVIDERS) {
    throw new UsageFeedError('invalid_providers');
  }
  const fetchedAt = isoTime(raw.fetchedAt);
  if (fetchedAt === null) throw new UsageFeedError('invalid_fetched_at');
  if (Date.parse(fetchedAt) > now + FUTURE_TOLERANCE_MS) throw new UsageFeedError('fetched_at_in_future');
  return fetchedAt;
}

export function usageItemsFromFeed(raw, { now = Date.now(), autoStaleMs = resolveUsageAutoStaleMs() } = {}) {
  const fetchedAt = validateFeed(raw, now);
  const byId = new Map();
  for (const entry of raw.providers) {
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) throw new UsageFeedError('invalid_provider');
    const provider = USAGE_PROVIDERS.find((candidate) => candidate.id === entry.id);
    if (!provider) continue;
    if (byId.has(provider.id)) throw new UsageFeedError('duplicate_provider');
    byId.set(provider.id, entry);
  }
  const context = { now, fetchedAt, autoStaleMs };
  return USAGE_PROVIDERS.map((provider) => {
    const row = byId.get(provider.id);
    if (!row) return unavailableItem({ ...baseOf(provider), reason: 'fetch_failed' });
    const item = itemFromRow(row, provider, context);
    // Console's projection uses the feed time for every provider and treats a
    // missing source as live; the raw /widget response has no row.fetchedAt.
    const source = row.source ?? 'live';
    if (item.availability === 'available' && ['live', 'local', 'codexbar-cli'].includes(source)) {
      const updated = isoTime(row.updatedAt);
      if (updated !== null && Date.parse(updated) <= now + FUTURE_TOLERANCE_MS) {
        item.detail ??= {};
        item.detail.freshUntil = new Date(Math.min(Date.parse(updated), Date.parse(fetchedAt)) + autoStaleMs).toISOString();
      }
    }
    return item;
  });
}

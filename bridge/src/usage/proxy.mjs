// /v1/usage items from the existing CodexBar usage proxy (docs/laa/USAGE.md).
//
// The proxy at 127.0.0.1:8081/widget is the single source of truth for quotas
// and balances, and the Bridge only re-shapes what that feed already displays
// (same display projection as the Console collector: code-owned ids, labels and
// units, no provider URL, cookie, raw error or billing payload passes through).
//
// A reading must be automatic, successful, and younger than ten minutes.
// Unknown, failed, expired, and manually checked values carry no numeric data.
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
const GOOGLE_AI_PRO = Object.freeze({ id: 'google-ai-pro', name: 'Google AI Pro' });
const MUSE = Object.freeze({ id: 'muse', name: 'Muse' });
const FABLE_ID = 'claude-weekly-scoped-fable';
const WEEKLY_MINUTES = 10080;
// Automatic readings: CodexBar's (no source, `live`, `local`, `codexbar-cli`), the
// Antigravity pool's own `/usage` reading (`agy-usage`) and the Muse resident's
// Usage-screen snapshot (`muse-usage`), both from usage-meters.
const AUTO_SOURCES = Object.freeze(['live', 'local', 'codexbar-cli', 'agy-usage', 'muse-usage']);
// How old an observation may be while its producer still vouches for it in
// freshUntil. Muse's weekly Free allowance moves only when the harness spends
// it and the resident reads it around jobs, so usage-meters keeps a reading for
// 24 hours. The feed itself (fetchedAt, receipt) still expires after 10 minutes.
const OBSERVATION_LIMIT_MS = Object.freeze({ 'muse-usage': 24 * 60 * 60 * 1000 });

function observationLimit(row, autoStaleMs) {
  return row.freshUntil != null && Object.hasOwn(OBSERVATION_LIMIT_MS, row.source ?? '')
    ? Math.max(autoStaleMs, OBSERVATION_LIMIT_MS[row.source])
    : autoStaleMs;
}
const MAX_PROVIDERS = 32;
const MAX_WINDOWS = 32;
const MAX_COMPONENTS = 30;
const DEFAULT_MAX_BYTES = 512 * 1024;

// Fixed order, so the list is stable between polls and between providers that
// appear and disappear. Labels match the Console collector's code-owned names.
// The owner's priority (2026-11-05): the quotas, then the API balances and
// costs, the recorded Liquid usage, and Venice last. Jev, Google Cloud and Google Flow
// are retired: the proxy no longer reads them, and a cached row never brings
// them back. nanoGPT left on 2026-11-11 (the owner cancelled the plan): a row
// the proxy still sends is skipped like any other unknown provider.
// Codex and GPT API left on 2026-11-28 (GPT cancelled, D-42), skipped the same way.
//
// The API provider (Claude API) carries a balance item beside its cost items. It
// publishes no balance, so the item is the billing-page reading the proxy passes
// as `balance`, marked verified; the cost item stays an amount used.
export const USAGE_PROVIDERS = Object.freeze([
  { id: 'opencode-go', label: 'OpenCode', kind: 'quota' },
  { id: 'claude', label: 'Claude', kind: 'quota' },
  // Google AI Pro (2026-11-23): one row per subscription account, in the order the
  // Antigravity pool uses them (laa-agy-pool, Sub2→Sub3→Sub4). The app shows them as one
  // group that opens to the accounts; `active` marks the one the pool would use next.
  ...['sub2', 'sub3', 'sub4'].map((account) => ({ id: `google-ai-pro-${account}`, label: `Google ${account[0].toUpperCase()}${account.slice(1)}`,
    kind: 'quota', group: GOOGLE_AI_PRO.id, groupName: GOOGLE_AI_PRO.name })),
  // Muse (2026-11-26, owner): the three Free accounts LAA's harness switches between for
  // TTS and video, one row each with its weekly Free allowance; `active` is the resident
  // the harness sends to. usage-meters reads the resident's snapshot (muse_usage.py).
  ...['Muse1', 'Muse2', 'Muse3'].map((account) => ({ id: `muse-${account}`, label: account,
    kind: 'quota', group: MUSE.id, groupName: MUSE.name })),
  { id: 'magnific', label: 'Magnific', kind: 'unitCredits' },
  { id: 'claude-api', label: 'Claude API', kind: 'balance' },
  { id: 'claude-api', label: 'Claude API', kind: 'cost', period: 'today' },
  { id: 'claude-api', label: 'Claude API', kind: 'cost', period: 'month' },
  { id: 'liquid', label: 'Liquid AI', kind: 'usage' },
  { id: 'venice', label: 'Venice', kind: 'balance' },
  { id: 'deepseek', label: 'DeepSeek API', kind: 'balance' },
  { id: 'grok-bot', label: 'Grok Bot', kind: 'quota' },
  { id: 'refuseless', label: 'Refuseless', kind: 'balance' },
]);

const SHAPES = Object.freeze({
  quota: { itemKind: 'quota', unit: 'percent', suffix: 'quota' },
  balance: { itemKind: 'balance', unit: 'usd', suffix: 'balance' },
  unitCredits: { itemKind: 'balance', unit: 'credits', suffix: 'credits' },
  usage: { itemKind: 'usage', unit: 'tokens', suffix: 'usage' },
  cost: { itemKind: 'cost', unit: 'usd', suffix: 'cost' },
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
  return `provider.${provider.id}.${shapeOf(provider).suffix}${provider.period ? `-${provider.period}` : ""}`;
}

function baseOf(provider) {
  return {
    id: itemId(provider),
    kind: shapeOf(provider).itemKind,
    label: provider.label,
    unit: shapeOf(provider).unit,
    source: USAGE_SOURCE,
    ...(provider.group ? { group: provider.group, groupName: provider.groupName } : {}),
  };
}

// The grouped rows say which account is in use, read or not; anything but a boolean is left out.
function withActive(item, provider, row) {
  if (provider.group && typeof row?.active === 'boolean') item.active = row.active;
  return item;
}

export function unavailableUsageItems(reason = 'fetch_failed') {
  return USAGE_PROVIDERS.map((provider) => unavailableItem({ ...baseOf(provider), reason }));
}

export async function readUsageFeed({
  url = resolveUsageFeedUrl(),
  fetcher = fetch,
  timeoutMs = 5000,
  maxBytes = DEFAULT_MAX_BYTES,
  signal,
} = {}) {
  const controller = new AbortController();
  const abort = () => controller.abort();
  if (signal?.aborted) controller.abort();
  else signal?.addEventListener('abort', abort, { once: true });
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
    signal?.removeEventListener('abort', abort);
  }
}

function normalizeWindows(row) {
  // Do not discard a bad ordinary window: it may be the limiting quota.
  for (const key of ['windows', 'extraWindows']) {
    if (row[key] !== undefined && (!Array.isArray(row[key]) || row[key].length > MAX_WINDOWS)) return null;
  }
  const raw = [...(Array.isArray(row.windows) ? row.windows : []), ...(Array.isArray(row.extraWindows) ? row.extraWindows : [])];
  const windows = [];
  for (const entry of raw) {
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) return null;
    // Also keep explicitly scoped entries from older feeds out of the ordinary quota.
    if (row.id === 'claude' && (entry.id === FABLE_ID || entry.scoped === true || entry.scope === 'model')) continue;
    const remaining = finiteNumber(entry.remaining, { max: 100 });
    if (remaining === null) return null;
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

function normalizeFableWeekly(entry, now) {
  if (!entry || typeof entry !== 'object' || Array.isArray(entry)
      || entry.id !== FABLE_ID || entry.windowMinutes !== WEEKLY_MINUTES) return null;
  const remainingPercent = finiteNumber(entry.remaining, { max: 100 });
  const resetsAt = isoTime(entry.resetsAt);
  if (remainingPercent === null || resetsAt === null || Date.parse(resetsAt) <= now) return null;
  return { id: FABLE_ID, label: 'Fable', windowMinutes: WEEKLY_MINUTES, remainingPercent, resetsAt };
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

function isStale(row, feedFetchedAt, now, autoStaleMs, receivedAt = now) {
  const observed = isoTime(row.updatedAt);
  if (observed === null || Date.parse(observed) > Math.min(now, receivedAt) + 120_000) return true;
  if (row.source != null && ![...AUTO_SOURCES, 'verified'].includes(row.source)) return true;
  if (row.source === 'verified') return true;
  if (row.freshUntil != null && (isoTime(row.freshUntil) === null || Date.parse(row.freshUntil) <= now)) return true;
  if (feedFetchedAt !== null && now - Date.parse(feedFetchedAt) >= autoStaleMs) return true;
  return now - Date.parse(observed) >= observationLimit(row, autoStaleMs);
}

function observedAtOf(row, feedFetchedAt) {
  return isoTime(row.updatedAt);
}

function quotaItem(row, provider, context) {
  const windows = normalizeWindows(row);
  if (!windows || windows.length === 0) {
    return unavailableItem({ ...baseOf(provider), reason: 'fetch_failed' });
  }
  const binding = windows.reduce((lowest, window) => (
    window.remainingPercent < lowest.remainingPercent ? window : lowest
  ));
  const expired = binding.resetsAt !== null && Date.parse(binding.resetsAt) <= context.now;
  const detail = { windows };
  if (provider.id === 'claude') {
    const fableWeekly = normalizeFableWeekly(row.fableWeekly, context.now);
    if (fableWeekly !== null) detail.fableWeekly = fableWeekly;
  }
  if (row.source === 'verified') detail.sourceKind = 'verified';
  const extraCredits = finiteNumber(row.credits?.remaining);
  const creditsTime = isoTime(row.credits?.updatedAt);
  if (extraCredits !== null && creditsTime !== null && Date.parse(creditsTime) <= Math.min(context.now, context.receivedAt) + 120_000 &&
      context.now - Date.parse(creditsTime) < context.autoStaleMs) {
    detail.credits = { remaining: extraCredits, updatedAt: creditsTime };
  }
  return availableItem({
    ...baseOf(provider),
    value: binding.remainingPercent,
    observedAt: observedAtOf(row, context.fetchedAt),
    stale: isStale(row, context.fetchedAt, context.now, context.autoStaleMs, context.receivedAt),
    expired,
    detail,
  });
}

// A billing page can read below zero: an unpaid balance is still the balance.
function confirmedBalanceItem(balance, provider, now) {
  const amount = finiteNumber(balance.amount, { min: Number.MIN_SAFE_INTEGER });
  const confirmedAt = isoTime(balance.confirmedAt);
  if (amount === null || confirmedAt === null) return unavailableItem({ ...baseOf(provider), unit: 'usd', reason: 'not_auto' });
  const detail = { sourceKind: 'verified', currency: 'USD' };
  // What the balance counts down from (its level after the last top-up), when
  // the proxy has seen one; without it the row draws no scale.
  const granted = finiteNumber(balance.grantedAmount);
  if (granted !== null && granted > 0) detail.grantedAmount = granted;
  // Credit that lapses on a date the billing page names: the day is shown,
  // and past it the balance no longer stands.
  const expiresAt = typeof balance.expiresOnUtc === 'string' ? expiryTime(balance.expiresOnUtc) : null;
  if (expiresAt !== null) detail.expiresOnUtc = balance.expiresOnUtc;
  return availableItem({ ...baseOf(provider), unit: 'usd', value: amount, observedAt: confirmedAt, stale: false,
    expired: expiresAt !== null && now > expiresAt, detail });
}

function balanceItem(row, provider, context) {
  const currency = row.currency === 'JPY' ? 'JPY' : row.currency === 'USD' ? 'USD' : null;
  const amount = finiteNumber(row.amount);
  const expired = balanceExpired(row, context.now);
  const base = { ...baseOf(provider), unit: currency === 'JPY' ? 'jpy' : 'usd' };
  if (amount === null) {
    // A row that carries no balance field at all is a provider that publishes
    // usage only: there is no automatic balance to read, so the item reports
    // `not_auto` rather than a failed read. The cost item for the same provider
    // stays an amount used and is never copied here.
    const reason = row.amount === undefined ? 'not_auto' : 'fetch_failed';
    return unavailableItem({ ...base, reason, expired });
  }
  const detail = {};
  if (row.source === 'verified') detail.sourceKind = 'verified';
  if (currency !== null) detail.currency = currency;
  for (const key of ['usd', 'monthlyRemainingPercent']) {
    const value = finiteNumber(row[key], { max: key === 'monthlyRemainingPercent' ? 100 : Number.MAX_SAFE_INTEGER });
    if (value !== null) detail[key] = value;
  }
  const granted = finiteNumber(row.grantedAmount);
  if (granted !== null && granted > 0) detail.grantedAmount = granted;
  const components = normalizeComponents(row);
  if (components.length > 0) detail.components = components;
  if (typeof row.expiresOnUtc === 'string' && expiryTime(row.expiresOnUtc) !== null) {
    detail.expiresOnUtc = row.expiresOnUtc;
  }
  return availableItem({
    ...base,
    value: amount,
    observedAt: observedAtOf(row, context.fetchedAt),
    stale: isStale(row, context.fetchedAt, context.now, context.autoStaleMs, context.receivedAt),
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
    stale: isStale(row, context.fetchedAt, context.now, context.autoStaleMs, context.receivedAt),
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
    stale: isStale(row, context.fetchedAt, context.now, context.autoStaleMs, context.receivedAt),
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

function costItem(row, provider, context) {
  const amount = finiteNumber(row[provider.period === 'today' ? 'todayAmount' : 'monthAmount']);
  const expectedLag = provider.id === 'claude-api' ? 'typical-5m' : 'undisclosed';
  if (amount === null || row.sourceLag !== expectedLag || row.periodTimezone !== 'UTC' || row.currency !== 'USD') {
    return unavailableItem({ ...baseOf(provider), reason: 'freshness_unknown' });
  }
  return availableItem({ ...baseOf(provider), value: amount,
    observedAt: observedAtOf(row, context.fetchedAt),
    detail: { sourceLag: expectedLag, periodTimezone: 'UTC' } });
}

// Muse's signed-out account (`needs_owner_login`) is a sign-in to make, like any
// expired sign-in; every other unknown reason is a failed read.
function unavailableReason(reason, provider) {
  if (provider.group === MUSE.id && reason === 'needs_owner_login') return 'auth_required';
  return ['not_configured', 'auth_required', 'not_auto', 'freshness_unknown', 'fetch_failed'].includes(reason) ? reason : 'fetch_failed';
}

function itemFromRow(row, provider, context) {
  if (row.available !== true) {
    return unavailableItem({
      ...baseOf(provider),
      reason: unavailableReason(row.reason, provider),
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
    case 'cost': return costItem(row, provider, context);
    default: return unavailableItem({ ...baseOf(provider), reason: 'unsupported' });
  }
}

function validateFeed(raw, now, receivedAt) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new UsageFeedError('invalid_feed');
  if (raw.version !== USAGE_FEED_VERSION) throw new UsageFeedError('invalid_version');
  if (raw.stale === true) throw new UsageFeedError('stale_feed');
  if (!Array.isArray(raw.providers) || raw.providers.length > MAX_PROVIDERS) {
    throw new UsageFeedError('invalid_providers');
  }
  const fetchedAt = isoTime(raw.fetchedAt);
  if (fetchedAt === null) throw new UsageFeedError('invalid_fetched_at');
  if (Date.parse(fetchedAt) > Math.min(now, receivedAt) + 120_000) throw new UsageFeedError('fetched_at_in_future');
  return fetchedAt;
}

export function usageItemsFromFeed(raw, { now = Date.now(), receivedAt = now, observationAnchors = new Map(), autoStaleMs = resolveUsageAutoStaleMs() } = {}) {
  receivedAt = Math.min(receivedAt ?? now, now);
  const fetchedAt = validateFeed(raw, now, receivedAt);
  const byId = new Map();
  for (const entry of raw.providers) {
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) throw new UsageFeedError('invalid_provider');
    const provider = USAGE_PROVIDERS.find((candidate) => candidate.id === entry.id);
    if (!provider) continue;
    if (byId.has(provider.id)) throw new UsageFeedError('duplicate_provider');
    byId.set(provider.id, entry);
  }
  const autoLimit = Math.min(autoStaleMs, 10 * 60 * 1000);
  return USAGE_PROVIDERS.map((provider) => withActive(itemForProvider(provider), provider, byId.get(provider.id)));

  function itemForProvider(provider) {
    const row = byId.get(provider.id);
    if (!row) return unavailableItem({ ...baseOf(provider), reason: 'fetch_failed' });
    if (provider.kind === 'balance' && row.balance) return confirmedBalanceItem(row.balance, provider, now);
    const prior = observationAnchors.get(provider.id);
    const rowReceivedAt = prior?.observedAt === Date.parse(row.updatedAt) ? Math.min(prior.receivedAt, receivedAt) : receivedAt;
    const context = { now, fetchedAt, receivedAt: rowReceivedAt, autoStaleMs: autoLimit };
    if (row.available === true && (isStale(row, fetchedAt, now, context.autoStaleMs, context.receivedAt) ||
        now - context.receivedAt >= context.autoStaleMs)) {
      return unavailableItem({ ...baseOf(provider), reason: row.source === 'verified' ? 'not_auto' : 'fetch_failed' });
    }
    const item = itemFromRow(row, provider, context);
    if (item.availability === 'available' && (item.stale || item.expired ||
        item.detail?.windows?.some((window) => window.resetsAt !== null && Date.parse(window.resetsAt) <= now))) {
      return unavailableItem({ ...baseOf(provider), reason: 'fetch_failed' });
    }
    // usage-meters/usage-proxy.py normalize() intentionally omits source for
    // ordinary CodexBar live rows; inventory/collector/usage.ts also supplies
    // live for them. Manual credit rows explicitly carry source: verified.
    // The raw /widget response has no row.fetchedAt.
    const source = row.source ?? 'live';
    if (item.availability === 'available' && AUTO_SOURCES.includes(source)) {
      const updated = isoTime(row.updatedAt);
      if (updated !== null && Date.parse(updated) <= Math.min(now, context.receivedAt) + 120_000) {
        item.detail ??= {};
        const deadline = Math.min(Date.parse(updated) + observationLimit(row, context.autoStaleMs), Date.parse(fetchedAt) + context.autoStaleMs,
          context.receivedAt + context.autoStaleMs,
          row.freshUntil == null ? Infinity : Date.parse(row.freshUntil));
        item.detail.freshUntil = new Date(deadline).toISOString();
      }
    }
    return item;
  }
}

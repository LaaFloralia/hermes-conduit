#!/usr/bin/env node
// Operator check that /v1/usage and /v1/mac/status read the live sources
// faithfully (ROADMAP 09, docs/laa/USAGE.md §7).
//
// Reads the CodexBar feed and the laa-storage-guard status file directly, then
// rebuilds the expected item values with independent arithmetic and compares
// them with the Bridge's projection. Read-only: no credential, no token, no
// service start, and nothing is printed but counts and field names.
//
//   node bridge/scripts/verify-usage.mjs [--timeout-ms 30000]
//
// Not part of `npm test`: CI has no Mac sources and must not need them.

import { readDiskStatus } from '../src/usage/host.mjs';
import { readUsageFeed, usageItemsFromFeed } from '../src/usage/proxy.mjs';

const failures = [];
const checks = [];

function check(name, ok, detail = '') {
  checks.push({ name, ok, detail });
  if (!ok) failures.push(`${name}${detail === '' ? '' : `: ${detail}`}`);
}

function numberAt(value) {
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

const args = process.argv.slice(2);
const timeoutIndex = args.indexOf('--timeout-ms');
// The proxy can take its full upstream budget when CodexBar is busy; the default
// matches the service (5 s), and an operator can wait longer for a diagnosis.
const timeoutMs = timeoutIndex >= 0 ? Number(args[timeoutIndex + 1]) : 5000;

const feed = await readUsageFeed({ timeoutMs });
const items = usageItemsFromFeed(feed, { now: Date.now() });
const byId = new Map(items.map((item) => [item.id, item]));

check('feed version', feed.version === 1, String(feed.version));
check('providers in feed', Array.isArray(feed.providers) && feed.providers.length > 0, `${feed.providers?.length ?? 0}`);

// One independent recomputation per provider kind: the item value must equal
// what the source says, and a provider the feed omits must stay null.
const expected = new Map();
for (const row of feed.providers) {
  if (!row || typeof row !== 'object') continue;
  // `clef` reports a text status, which no v1 item kind carries (README).
  if (row.id === 'clef') continue;
  if (row.kind === 'quota' && Array.isArray(row.windows)) {
    const remaining = row.windows.map((window) => numberAt(window?.remaining)).filter((value) => value !== null);
    if (remaining.length > 0) expected.set(`provider.${row.id}.quota`, Math.min(...remaining));
  } else if (row.kind === 'balance' && numberAt(row.amount) !== null) {
    expected.set(`provider.${row.id}.balance`, row.amount);
  } else if (row.kind === 'unitCredits' && numberAt(row.remaining) !== null) {
    expected.set(`provider.${row.id}.credits`, row.remaining);
  } else if (row.kind === 'usage' && row.recordedUsage) {
    const input = numberAt(row.recordedUsage.inputTokens);
    const output = numberAt(row.recordedUsage.outputTokens);
    if (input !== null && output !== null) expected.set(`provider.${row.id}.usage`, input + output);
  }
  if (row.available === false) expected.set(
    `provider.${row.id}.${row.kind === 'quota' ? 'quota' : row.kind === 'unitCredits' ? 'credits' : row.kind === 'usage' ? 'usage' : 'balance'}`,
    null,
  );
}

for (const [id, value] of expected) {
  const item = byId.get(id);
  if (!item) {
    check(id, false, 'item is missing');
    continue;
  }
  if (value === null) {
    check(id, item.value === null, `value ${item.value}`);
  } else {
    check(id, item.value === value, `item ${item.value} source ${value}`);
  }
}

// Every known provider is represented, and nothing is invented for the ones the
// feed does not carry.
for (const item of items) {
  check(`${item.id} shape`, item.value === null || typeof item.value === 'number', typeof item.value);
  check(`${item.id} null rule`, item.availability === 'available' ? item.value !== null : item.value === null && typeof item.nullReason === 'string');
}
const missing = items.filter((item) => item.availability === 'unavailable');
check('providers not in the feed are unavailable', missing.every((item) => item.value === null));

// The disk reading is the status file the daily guard wrote, not a new scan.
const disk = await readDiskStatus();
if (disk.availability === 'available') {
  check('disk source', disk.source === 'laa-storage-guard');
  check('disk unit', disk.unit === 'gb');
  check('disk value', typeof disk.value === 'number');
  check('disk total', typeof disk.detail?.totalGb === 'number');
} else {
  check('disk reported, not zeroed', disk.value === null && typeof disk.nullReason === 'string');
}

const summary = {
  feedFetchedAt: feed.fetchedAt,
  providersInFeed: feed.providers.length,
  items: items.length,
  available: items.filter((item) => item.availability === 'available').length,
  unavailable: items.filter((item) => item.availability === 'unavailable').length,
  stale: items.filter((item) => item.stale).length,
  expired: items.filter((item) => item.expired).length,
  disk: disk.availability === 'available'
    ? { freeGb: disk.value, totalGb: disk.detail.totalGb, level: disk.detail.level ?? null, observedAt: disk.observedAt, stale: disk.stale }
    : { availability: disk.availability, nullReason: disk.nullReason },
};

for (const entry of checks) {
  if (!entry.ok) process.stdout.write(`FAIL  ${entry.name} (${entry.detail})\n`);
}
process.stdout.write(`${JSON.stringify({ summary, checks: checks.length, failures }, null, 2)}\n`);
process.exit(failures.length === 0 ? 0 : 1);

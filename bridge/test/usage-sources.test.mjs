// Unit tests for the two usage sources: the CodexBar feed projection and the
// in-process host sampler (ROADMAP 09, docs/laa/USAGE.md §4).
//
// These cover the rules the route tests only touch through one happy path:
// which reading wins when a provider has several windows, how expiry and
// staleness are decided, how a text field from a source is sanitised, and how
// the 10-second sample cache behaves.

import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import {
  createHostSampler,
  readDiskStatus,
  unavailableCpu,
  unavailableMemory,
} from '../src/usage/host.mjs';
import { UsageFeedError, usageItemsFromFeed } from '../src/usage/proxy.mjs';

const NOW = Date.parse('2026-10-29T05:00:00Z');
const FIXTURE_DIR = new URL('../../docs/laa/fixtures/usage/', import.meta.url);

function projection(providers, { now = NOW, autoStaleMs = 20 * 60 * 1000 } = {}) {
  return usageItemsFromFeed(
    { version: 1, fetchedAt: '2026-10-29T04:59:00Z', providers },
    { now, autoStaleMs },
  );
}

function byId(items, id) {
  const item = items.find((candidate) => candidate.id === id);
  assert.ok(item, `${id} is missing`);
  return item;
}

test('the quota value is the window with the least remaining, extras included', () => {
  const items = projection([{
    id: 'opencode-go',
    kind: 'quota',
    available: true,
    updatedAt: '2026-10-29T04:58:00Z',
    source: 'codexbar-cli',
    windows: [
      { label: '5時間', remaining: 84, resetsAt: '2026-10-29T09:04:59Z', windowMinutes: 300 },
      { label: 'Weekly', remaining: 77, resetsAt: '2026-11-01T23:59:59Z', windowMinutes: 10080 },
    ],
    extraWindows: [{ label: 'Monthly', remaining: 41, resetsAt: '2026-11-25T08:42:44Z' }],
  }]);
  const item = byId(items, 'provider.opencode-go.quota');
  assert.equal(item.value, 41);
  assert.equal(item.unit, 'percent');
  assert.equal(item.detail.windows.length, 3);
  assert.equal(item.expired, false);
});

test('a passed reset removes the entire quota value', () => {
  const item = byId(projection([{ id: 'claude', available: true, updatedAt: '2026-10-29T04:58:00Z',
    windows: [{ label: 'Session', remaining: 62, resetsAt: '2026-10-29T04:00:00Z' }] }]), 'provider.claude.quota');
  assert.equal(item.availability, 'unavailable');
  assert.equal(item.value, null);
  assert.equal(item.detail, undefined);
});

test('a provider without windows is unavailable instead of zero', () => {
  const items = projection([{ id: 'claude', kind: 'quota', available: true, updatedAt: '2026-10-29T04:58:00Z' }]);
  const item = byId(items, 'provider.claude.quota');
  assert.equal(item.availability, 'unavailable');
  assert.equal(item.value, null);
  assert.equal(item.nullReason, 'fetch_failed');
});

test('an invalid or excessive quota window cannot hide a potentially binding limit', () => {
  const good = { label: 'Weekly', remaining: 80, resetsAt: null };
  for (const bad of [null, {}, { label: 'Session', remaining: -1 }, { label: 'Session', remaining: 101 }]) {
    const item = byId(projection([{ id: 'claude', available: true, updatedAt: '2026-10-29T04:58:00Z',
      windows: [bad, good] }]), 'provider.claude.quota');
    assert.equal(item.availability, 'unavailable');
    assert.equal(item.value, null);
    assert.equal(item.nullReason, 'fetch_failed');
  }
  const overflow = byId(projection([{ id: 'claude', available: true, updatedAt: '2026-10-29T04:58:00Z',
    windows: Array(33).fill(good) }]), 'provider.claude.quota');
  assert.equal(overflow.availability, 'unavailable');
  const extras = byId(projection([{ id: 'claude', available: true, updatedAt: '2026-10-29T04:58:00Z',
    windows: Array(32).fill(good), extraWindows: [{ label: 'Session', remaining: 0, resetsAt: null }] }]), 'provider.claude.quota');
  assert.equal(extras.value, 0);
});

test('a live zero balance is real; retired providers are ignored', () => {
  const items = projection([
    { id: 'deepseek', source: 'live', available: true, updatedAt: '2026-10-29T04:58:00Z', currency: 'USD', amount: 0 },
    { id: 'fal', source: 'live', available: true, updatedAt: '2026-10-29T04:58:00Z', amount: 42 },
    { id: 'venice', source: 'live', available: true, updatedAt: '2026-10-29T04:58:00Z', currency: 'USD', amount: 43, components: [{kind: 'DIEM', amount: 2}] },
    { id: 'jev', source: 'live', available: true, updatedAt: '2026-10-29T04:58:00Z', currency: 'USD', amount: 45 },
    { id: 'google-cloud', source: 'live', available: true, updatedAt: '2026-10-29T04:58:00Z', amount: 46 },
    { id: 'google-flow', source: 'live', available: true, updatedAt: '2026-10-29T04:58:00Z', remaining: 47 },
    { id: 'gemini', source: 'verified', available: true, updatedAt: '2026-10-29T04:58:00Z', amount: 44 },
  ]);
  assert.equal(byId(items, 'provider.deepseek.balance').value, 0);
  assert.equal(byId(items, 'provider.deepseek.balance').availability, 'available');
  assert.equal(byId(items, 'provider.venice.balance').value, 43);
  assert.equal(byId(items, 'provider.venice.balance').detail.components[0].amount, 2);
  for (const id of ['gemini', 'fal', 'jev', 'google-cloud', 'google-flow']) {
    assert.equal(items.some(item => item.id.startsWith(`provider.${id}.`)), false);
  }
});

test('expired and manually verified balances do not return numeric details', () => {
  const items = projection([
    { id: 'deepseek', source: 'live', available: true, updatedAt: '2026-10-29T04:58:00Z', currency: 'USD', amount: 5,
      components: [{ kind: 'monthly', amount: 5, expiresOnUtc: '2026-10-26' }] },
    { id: 'refuseless', source: 'verified', available: true, updatedAt: '2026-10-29T04:58:00Z', currency: 'USD', amount: 8 },
  ]);
  for (const id of ['provider.deepseek.balance', 'provider.refuseless.balance']) {
    const item = byId(items, id);
    assert.equal(item.value, null);
    assert.equal(item.detail, undefined);
  }
  assert.equal(byId(items, 'provider.refuseless.balance').nullReason, 'not_auto');
});

test('verified and ten-minute-old live readings are unavailable', () => {
  const items = projection([
    { id: 'refuseless', source: 'verified', available: true, updatedAt: '2026-10-29T04:58:00Z', currency: 'USD', amount: 1 },
    { id: 'codex', available: true, updatedAt: '2026-10-29T04:50:00Z', windows: [{ label: 'Weekly', remaining: 48 }] },
  ]);
  for (const id of ['provider.refuseless.balance', 'provider.codex.quota']) {
    const item = byId(items, id);
    assert.equal(item.availability, 'unavailable');
    assert.equal(item.value, null);
    assert.equal(item.detail, undefined);
  }
});

test('unit credits and recorded usage keep their own units and details', () => {
  const items = projection([
    { id: 'magnific', kind: 'unitCredits', source: 'verified', available: true, updatedAt: '2026-10-18T13:55:00Z', remaining: 0, renewsAt: null, monthlyGrantedAmount: 1000 },
    {
      id: 'liquid',
      kind: 'usage',
      source: 'local',
      available: true,
      updatedAt: '2026-10-29T04:59:00Z',
      recordedUsage: {
        scope: 'recorded-calls',
        model: 'd1.1 / d1-ultra',
        startedAt: '2026-10-15T22:58:23Z',
        lastRecordedAt: '2026-10-29T04:59:00Z',
        requestCount: 6473,
        inputTokens: 32007029,
        outputTokens: 0,
        costUsd: 1.31,
      },
    },
  ]);
  const credits = byId(items, 'provider.magnific.credits');
  assert.equal(credits.value, null);
  assert.equal(credits.unit, 'credits');
  assert.equal(credits.nullReason, 'not_auto');
  assert.equal(credits.detail, undefined);
  const liquid = byId(items, 'provider.liquid.usage');
  assert.equal(liquid.value, 32007029);
  assert.equal(liquid.unit, 'tokens');
  assert.equal(liquid.detail.periodDays, 14);
  assert.equal(liquid.detail.recordedCostUsd, 1.31);
  assert.equal(liquid.detail.recordedRequestCount, 6473);
  assert.deepEqual(liquid.detail.models, [{ model: 'd1.1 / d1-ultra', inputTokens: 32007029, outputTokens: 0 }]);
});

test('projection respects provider deadlines and separately ages quota extras', () => {
  const item = byId(projection([{ id: 'claude', source: 'live', available: true,
    updatedAt: '2026-10-29T04:51:00Z', freshUntil: '2026-10-29T05:00:30Z',
    windows: [{ label: 'Session', remaining: 0, resetsAt: '2026-10-29T06:00:00Z' }],
    extraWindows: [{ label: 'Session', remaining: 0, resetsAt: '2026-10-29T06:00:00Z' }],
    credits: { remaining: 0, updatedAt: '2026-10-29T04:52:00Z' },
    resetPasses: { available: true, remaining: 7, updatedAt: '2026-10-29T04:59:00Z' },
  }]), 'provider.claude.quota');
  assert.equal(item.detail.windows.length, 1);
  assert.equal(item.value, 0);
  assert.equal(item.detail.freshUntil, '2026-10-29T05:00:30.000Z');
  assert.equal(item.detail.credits.remaining, 0);
  assert.equal(item.detail.resetPasses, undefined);
  for (const changes of [{ updatedAt: null }, { updatedAt: '2026-10-29T05:02:01Z' },
                         { source: 'unknown' }, { freshUntil: '2026-10-29T05:00:00Z' },
                         { freshUntil: 'bad' }, { available: undefined }]) {
    const invalid = byId(projection([{ id: 'codex', source: 'live', available: true, updatedAt: '2026-10-29T04:59:00Z',
      windows: [{ label: 'Weekly', remaining: 24, resetsAt: null }], ...changes }]), 'provider.codex.quota');
    assert.equal(invalid.availability, 'unavailable');
    assert.equal(invalid.value, null);
    assert.equal(invalid.detail, undefined);
  }
  const oldCredits = byId(projection([{ id: 'codex', source: 'live', available: true, updatedAt: '2026-10-29T04:59:00Z',
    windows: [{ label: 'Weekly', remaining: 24 }], credits: { remaining: 8, updatedAt: '2026-10-29T04:50:00Z' } }]), 'provider.codex.quota');
  assert.equal(oldCredits.value, 24);
  assert.equal(oldCredits.detail.credits, undefined);
});

test('text from the feed is sanitised and never carries a credential or a path', () => {
  const items = projection([{
    id: 'claude',
    kind: 'quota',
    available: true,
    updatedAt: '2026-10-29T04:58:00Z',
    windows: [
      { label: 'Bearer sk-secret', remaining: 50, resetsAt: null },
      { label: '/Users/laa/secret', remaining: 60, resetsAt: null },
      { label: 'Session', remaining: 70, resetsAt: null },
    ],
  }]);
  const labels = byId(items, 'provider.claude.quota').detail.windows.map((window) => window.label);
  assert.deepEqual(labels, ['Window 1', 'Window 2', 'Session']);
});

test('an unknown provider id is ignored and a duplicate is rejected', () => {
  const items = projection([
    { id: 'clef', kind: 'status', available: true, updatedAt: '2026-10-29T04:58:00Z', value: '予備' },
    { id: 'deepseek', kind: 'balance', source: 'verified', available: true, updatedAt: '2026-10-29T04:00:00Z', currency: 'USD', amount: 0 },
  ]);
  assert.equal(items.some((item) => item.id.includes('clef')), false);
  assert.throws(() => projection([
    { id: 'deepseek', kind: 'balance', available: true, updatedAt: '2026-10-29T04:00:00Z', amount: 0 },
    { id: 'deepseek', kind: 'balance', available: true, updatedAt: '2026-10-29T04:00:00Z', amount: 0 },
  ]), UsageFeedError);
});

test('a feed more than 120 seconds in the future, missing time zone, or another version is rejected', () => {
  for (const fetchedAt of ['2026-10-29T05:02:01Z', '2026-10-29T04:59:00']) {
    assert.throws(() => usageItemsFromFeed({ version: 1, fetchedAt, providers: [] }, { now: NOW }), UsageFeedError);
  }
  assert.throws(() => usageItemsFromFeed({ version: 2, fetchedAt: '2026-10-29T04:59:00Z', providers: [] }, { now: NOW }), UsageFeedError);
});

test('future tolerance anchors expiration at receipt, and an older feed always expires', () => {
  const row = { id: 'claude', available: true, updatedAt: '2026-10-29T05:02:00Z',
    windows: [{ label: 'Session', remaining: 42, resetsAt: null }] };
  const feed = { version: 1, fetchedAt: row.updatedAt, providers: [row] };
  const fresh = byId(usageItemsFromFeed(feed, { now: NOW, receivedAt: NOW }), 'provider.claude.quota');
  assert.equal(fresh.value, 42);
  assert.equal(Date.parse(fresh.detail.freshUntil), NOW + 600_000);
  const aged = byId(usageItemsFromFeed(feed, { now: NOW + 600_000, receivedAt: NOW }), 'provider.claude.quota');
  assert.equal(aged.value, null);
  const future = { ...feed, providers: [{ ...row, updatedAt: '2026-10-29T05:02:01Z' }] };
  assert.equal(byId(usageItemsFromFeed(future, { now: NOW }), 'provider.claude.quota').value, null);
  assert.equal(byId(usageItemsFromFeed(future, { now: NOW + 2_000, receivedAt: NOW }), 'provider.claude.quota').value, null);
  const oldFeed = { ...feed, fetchedAt: '2026-10-29T04:50:00Z', providers: [{ ...row, updatedAt: '2026-10-29T05:00:00Z' }] };
  assert.equal(byId(usageItemsFromFeed(oldFeed, { now: NOW }), 'provider.claude.quota').value, null);
});

test('cost readings carry UTC periods and declared lag without inventing a watermark', () => {
  const base = { kind: 'cost', source: 'live', available: true, updatedAt: '2026-10-29T04:59:00Z',
    currency: 'USD', periodTimezone: 'UTC', todayAmount: 0, monthAmount: 1.25 };
  const items = projection([{ ...base, id: 'claude-api', sourceLag: 'typical-5m' },
    { ...base, id: 'openai-api', sourceLag: 'undisclosed' }]);
  for (const id of ['claude-api', 'openai-api']) {
    const today = byId(items, `provider.${id}.cost-today`);
    const month = byId(items, `provider.${id}.cost-month`);
    assert.equal(today.value, 0);
    assert.equal(month.value, 1.25);
    assert.equal(today.detail.periodTimezone, 'UTC');
    assert.equal(today.detail.reflectedThrough, undefined);
  }
  for (const changes of [{ sourceLag: null }, { periodTimezone: 'JST' }, { currency: 'JPY' }]) {
    const item = byId(projection([{ ...base, id: 'claude-api', sourceLag: 'typical-5m', ...changes }]), 'provider.claude-api.cost-today');
    assert.equal(item.value, null);
    assert.equal(item.nullReason, 'freshness_unknown');
  }
});

test('a missing todayAmount keeps the month amount and hides only today', () => {
  const base = { kind: 'cost', source: 'live', available: true, updatedAt: '2026-10-29T04:59:00Z',
    currency: 'USD', periodTimezone: 'UTC', monthAmount: 1.25 };
  const items = projection([{ ...base, id: 'openai-api', sourceLag: 'undisclosed' },
    { ...base, id: 'claude-api', sourceLag: 'typical-5m' }]);
  for (const id of ['openai-api', 'claude-api']) {
    const today = byId(items, `provider.${id}.cost-today`);
    const month = byId(items, `provider.${id}.cost-month`);
    assert.equal(today.value, null);
    assert.equal(today.nullReason, 'freshness_unknown');
    assert.equal(today.detail, undefined);
    assert.equal(month.value, 1.25);
    assert.equal(month.nullReason, undefined);
    assert.equal(month.detail.periodTimezone, 'UTC');
  }
});

test('an empty cost response is an unavailable provider, not a zero', () => {
  const row = { id: 'openai-api', kind: 'cost', source: 'live', available: false,
    updatedAt: null, reason: 'freshness_unknown' };
  const items = projection([row]);
  for (const period of ['today', 'month']) {
    const item = byId(items, `provider.openai-api.cost-${period}`);
    assert.equal(item.value, null);
    assert.equal(item.nullReason, 'freshness_unknown');
    assert.equal(item.detail, undefined);
  }
});

test('an API provider with no balance field reports no balance, never its spend', () => {
  const base = { kind: 'cost', source: 'live', available: true, updatedAt: '2026-10-29T04:59:00Z',
    currency: 'USD', periodTimezone: 'UTC', todayAmount: 0.96, monthAmount: 21.8 };
  const items = projection([{ ...base, id: 'openai-api', sourceLag: 'undisclosed' },
    { ...base, id: 'claude-api', sourceLag: 'typical-5m' }]);
  for (const id of ['openai-api', 'claude-api']) {
    const balance = byId(items, `provider.${id}.balance`);
    assert.equal(balance.kind, 'balance');
    assert.equal(balance.availability, 'unavailable');
    assert.equal(balance.value, null);
    assert.equal(balance.unit, 'usd');
    assert.equal(balance.nullReason, 'not_auto');
    assert.equal(balance.observedAt, null);
    assert.equal(balance.detail, undefined);
    // The spend keeps its own row and its own meaning.
    assert.equal(byId(items, `provider.${id}.cost-today`).value, 0.96);
    assert.equal(byId(items, `provider.${id}.cost-month`).value, 21.8);
  }
});

test('a published API balance is shown beside the spend and not replaced by it', () => {
  const row = { id: 'openai-api', kind: 'cost', source: 'live', available: true,
    updatedAt: '2026-10-29T04:59:00Z', currency: 'USD', amount: 21.8, periodTimezone: 'UTC',
    todayAmount: 0.96, monthAmount: 3.4, sourceLag: 'undisclosed' };
  const balance = byId(projection([row]), 'provider.openai-api.balance');
  assert.equal(balance.availability, 'available');
  assert.equal(balance.value, 21.8);
  assert.equal(balance.unit, 'usd');
  assert.equal(balance.detail.currency, 'USD');
  assert.equal(Date.parse(balance.detail.freshUntil), Date.parse('2026-10-29T05:09:00Z'));
  // Ten minutes on, the same row holds no number.
  const aged = byId(projection([row], { now: NOW + 600_000 }), 'provider.openai-api.balance');
  assert.equal(aged.value, null);
  assert.equal(aged.nullReason, 'fetch_failed');
  assert.equal(aged.detail, undefined);
  // A balance field that is present but unreadable is a failed read, not an
  // automatic source that does not exist.
  const broken = byId(projection([{ ...row, amount: 'n/a' }]), 'provider.openai-api.balance');
  assert.equal(broken.nullReason, 'fetch_failed');
});

test('a manually entered API balance is not the current balance', () => {
  const items = projection([{ id: 'claude-api', kind: 'balance', source: 'verified', available: true,
    updatedAt: '2026-10-29T04:58:00Z', currency: 'USD', amount: 58.51 }]);
  const balance = byId(items, 'provider.claude-api.balance');
  assert.equal(balance.availability, 'unavailable');
  assert.equal(balance.value, null);
  assert.equal(balance.nullReason, 'not_auto');
  assert.equal(balance.detail, undefined);
});

test('the host sampler computes CPU from a tick delta and caches for 10 seconds', async () => {
  let ticks = { user: 100, sys: 0, idle: 100 };
  let calls = 0;
  const cpus = () => {
    calls += 1;
    return [{ times: { user: ticks.user, nice: 0, sys: ticks.sys, idle: ticks.idle, irq: 0 } }];
  };
  let clock = 1_000_000;
  const exec = async () => {
    throw new Error('not used on this platform');
  };
  const sampler = createHostSampler({ now: () => clock, cpus, exec, platform: 'linux' });
  assert.equal(calls, 1, 'the baseline is taken when the Bridge starts');

  ticks = { user: 130, sys: 0, idle: 170 };
  clock += 5000;
  const first = await sampler.read();
  assert.equal(first.cpu.availability, 'available');
  assert.equal(first.cpu.value, 30);
  assert.equal(first.cpu.unit, 'percent');
  assert.equal(first.cpu.detail.windowSeconds, 5);
  assert.equal(first.cpu.detail.userPercent, 30);
  assert.equal(first.cpu.detail.systemPercent, 0);
  assert.equal(first.memory.availability, 'unavailable');
  assert.equal(first.memory.nullReason, 'unsupported');

  const before = calls;
  clock += 4000; // still inside the 10 s cache
  const cached = await sampler.read();
  assert.deepEqual(cached, first);
  assert.equal(calls, before, 'a cached read does not resample');

  ticks = { user: 140, sys: 0, idle: 260 };
  clock += 7000;
  const third = await sampler.read();
  assert.equal(third.cpu.value, 10);
  assert.ok(calls > before);
});

test('the host sampler reports memory from vm_stat page counts and swap usage', async () => {
  const vmStat = [
    'Mach Virtual Memory Statistics: (page size of 16384 bytes)',
    'Pages free:                                     9955.',
    'Pages active:                                 318685.',
    'Pages inactive:                               315096.',
    'Pages speculative:                              2396.',
    'Pages wired down:                             374708.',
  ].join('\n');
  // iostat's first line is the since-boot average; the last one is the interval
  // that counts.
  const iostat = [
    '    KB/t  tps  MB/s     KB/t  tps  MB/s     KB/t  tps  MB/s  us sy id   1m   5m   15m',
    '   37.57  485 17.81    71.43    0  0.00    50.85    1  0.04  17 12 71  579.15 287.48 139.27',
    '   53.20 6789 352.77     0.00    0  0.00    55.30  288 15.56  20 10 70  579.15 287.48 139.27',
  ].join('\n');
  const exec = async (command) => {
    if (command === '/usr/sbin/iostat') return { stdout: iostat };
    if (command === '/usr/bin/vm_stat') return { stdout: vmStat };
    if (command === '/usr/sbin/sysctl') return { stdout: 'total = 12288.00M  used = 1024.00M  free = 11264.00M  (encrypted)' };
    throw new Error(`unexpected command ${command}`);
  };
  const sampler = createHostSampler({
    now: () => 1_000_000,
    cpus: () => [{ times: { user: 1, nice: 0, sys: 1, idle: 8, irq: 0 } }],
    exec,
    platform: 'darwin',
  });
  const { cpu, memory } = await sampler.read();
  assert.equal(cpu.availability, 'available');
  assert.equal(cpu.value, 30);
  assert.deepEqual(cpu.detail, { windowSeconds: 1, userPercent: 20, systemPercent: 10 });
  assert.equal(memory.availability, 'available');
  assert.equal(memory.unit, 'bytes');
  assert.equal(memory.detail.availableBytes, (9955 + 315096 + 2396) * 16384);
  assert.equal(memory.detail.swapUsedBytes, 1024 * 1024 ** 2);
  assert.equal(memory.value, memory.detail.totalBytes - memory.detail.availableBytes);
  assert.match(memory.observedAt, /^1970-01-01T00:16:40Z$/);
});

test('a failing vm_stat or a non-Darwin host is unavailable, never zero', async () => {
  const sampler = createHostSampler({
    now: () => 1_000_000,
    cpus: () => [{ times: { user: 1, nice: 0, sys: 1, idle: 8, irq: 0 } }],
    exec: async () => { throw new Error('vm_stat failed'); },
    platform: 'darwin',
  });
  const { memory } = await sampler.read();
  assert.equal(memory.availability, 'unavailable');
  assert.equal(memory.value, null);
  assert.equal(memory.nullReason, 'fetch_failed');

  const fixture = JSON.parse(await readFile(new URL('mac-status-unavailable.json', FIXTURE_DIR), 'utf8'));
  assert.deepEqual(unavailableMemory('unsupported'), fixture.data.items[1]);
  assert.deepEqual(unavailableCpu('unsupported'), fixture.data.items[0]);
});

test('the storage-guard status file is read as written, and bad files stay unavailable', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'laa-usage-disk-'));
  const write = (name, body) => {
    const file = join(dir, name);
    writeFileSync(file, typeof body === 'string' ? body : JSON.stringify(body));
    return file;
  };

  // The guard writes a +0900 offset; the item carries UTC at second precision.
  const good = write('good.json', {
    checked_at: '2026-10-29T14:32:00+0900',
    free_gb: 166.6,
    total_gb: 460.4,
    level: 'warn',
    findings: ['work 22.6GB（上限20GB）', 'Bearer sk-should-not-appear', '/Users/laa/private'],
  });
  const disk = await readDiskStatus({ file: good, now: () => Date.parse('2026-10-29T05:40:00Z') });
  assert.equal(disk.observedAt, '2026-10-29T05:32:00Z');
  assert.equal(disk.value, 166.6);
  assert.equal(disk.stale, false);
  assert.equal(disk.detail.volume, '/');
  assert.equal(disk.detail.totalGb, 460.4);
  assert.equal(disk.detail.level, 'warn');
  assert.deepEqual(disk.detail.findings, ['work 22.6GB（上限20GB）']);

  const broken = write('broken.json', '{"checked_at":');
  const unreadable = await readDiskStatus({ file: broken, now: () => NOW });
  assert.equal(unreadable.availability, 'unavailable');
  assert.equal(unreadable.nullReason, 'fetch_failed');

  const wrongShape = write('shape.json', { checked_at: 'yesterday', free_gb: 1, total_gb: 2 });
  const shape = await readDiskStatus({ file: wrongShape, now: () => NOW });
  assert.equal(shape.availability, 'unavailable');
  assert.equal(shape.value, null);

  const absent = await readDiskStatus({ file: join(dir, 'nope.json'), now: () => NOW });
  assert.equal(absent.nullReason, 'not_configured');
});


test('an API balance is the billing-page reading, below zero too, whether or not the costs were read', () => {
  const items = usageItemsFromFeed({ version: 1, fetchedAt: '2026-10-29T05:00:00Z', stale: false, providers: [
    { id: 'claude-api', kind: 'cost', available: false, source: 'live', reason: 'fetch_failed',
      balance: { amount: -0.19, confirmedAt: '2026-10-20T14:24:00Z' } },
    { id: 'openai-api', kind: 'cost', available: false, source: 'live', reason: 'fetch_failed', balance: null },
  ] }, { now: Date.parse('2026-10-29T05:00:00Z') });
  const claude = byId(items, 'provider.claude-api.balance');
  assert.equal(claude.availability, 'available');
  assert.equal(claude.value, -0.19);
  assert.equal(claude.observedAt, '2026-10-20T14:24:00Z');
  assert.equal(claude.detail.sourceKind, 'verified');
  assert.equal(byId(items, 'provider.openai-api.balance').availability, 'unavailable');
});

test('Venice USD and Magnific credits keep their units and priority, without Antigravity or nanoGPT', () => {
  const items = projection([
    { id: 'nanogpt', available: true, source: 'live', updatedAt: '2026-10-29T04:58:00Z',
      windows: [{ label: 'Weekly', remaining: 80, windowMinutes: 10080 }] },
    { id: 'magnific', kind: 'unitCredits', available: true, source: 'live',
      updatedAt: '2026-10-29T04:58:00Z', remaining: 2100, unit: 'AI credits' },
    { id: 'venice', kind: 'balance', available: true, source: 'live',
      updatedAt: '2026-10-29T04:58:00Z', amount: 14.5, currency: 'USD',
      components: [{ kind: 'DIEM', amount: 2 }] },
    { id: 'antigravity', available: true, updatedAt: '2026-10-29T04:58:00Z',
      windows: [{ label: 'Weekly', remaining: 90 }] },
  ]);
  assert.deepEqual([...new Set(items.map(item => item.id.split('.')[1]))].slice(0, 8),
    ['codex', 'opencode-go', 'claude', 'magnific', 'openai-api', 'claude-api', 'liquid', 'venice']);
  assert.equal(items.some(item => item.id.startsWith('provider.antigravity.')), false);
  assert.equal(items.some(item => item.id.startsWith('provider.nanogpt.')), false);
  const venice = byId(items, 'provider.venice.balance');
  assert.equal(venice.unit, 'usd');
  assert.equal(venice.value, 14.5);
  assert.equal(venice.detail.components[0].amount, 2);
  const magnific = byId(items, 'provider.magnific.credits');
  assert.equal(magnific.unit, 'credits');
  assert.equal(magnific.value, 2100);
  assert.equal(magnific.detail.creditUnit, 'AI credits');
});

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
      { label: '週間', remaining: 77, resetsAt: '2026-11-01T23:59:59Z', windowMinutes: 10080 },
    ],
    extraWindows: [{ label: '月間', remaining: 41, resetsAt: '2026-11-25T08:42:44Z' }],
  }]);
  const item = byId(items, 'provider.opencode-go.quota');
  assert.equal(item.value, 41);
  assert.equal(item.unit, 'percent');
  assert.equal(item.detail.windows.length, 3);
  assert.equal(item.expired, false);
});

test('a passed resetsAt marks the binding window expired and keeps the value', () => {
  const items = projection([{
    id: 'claude',
    kind: 'quota',
    available: true,
    updatedAt: '2026-10-29T04:58:00Z',
    windows: [
      { label: 'Session', remaining: 62, resetsAt: '2026-10-29T04:00:00Z' },
      { label: 'Weekly', remaining: 90, resetsAt: '2026-11-02T00:00:00Z' },
    ],
  }]);
  const item = byId(items, 'provider.claude.quota');
  assert.equal(item.value, 62);
  assert.equal(item.expired, true);
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

test('a zero balance is a real reading; a missing one is not', () => {
  const items = projection([
    { id: 'fal', kind: 'balance', source: 'verified', available: true, updatedAt: '2026-10-29T04:00:00Z', currency: 'USD', amount: 0 },
    { id: 'gemini', kind: 'balance', source: 'verified', available: true, updatedAt: '2026-10-29T04:00:00Z', currency: 'JPY', amount: 48725.03 },
    { id: 'venice', kind: 'balance', available: false, updatedAt: null },
  ]);
  assert.equal(byId(items, 'provider.fal.balance').value, 0);
  assert.equal(byId(items, 'provider.fal.balance').availability, 'available');
  const gemini = byId(items, 'provider.gemini.balance');
  assert.equal(gemini.unit, 'jpy');
  assert.equal(gemini.value, 48725.03);
  assert.equal(byId(items, 'provider.venice.balance').nullReason, 'fetch_failed');
});

test('Venice USD and DIEM remain distinct when the proxy has no amount field', () => {
  const item = byId(projection([{ id: 'venice', kind: 'balance', available: true,
    updatedAt: '2026-10-29T04:58:00Z', usd: 2.5, diem: 44 }]), 'provider.venice.balance');
  assert.equal(item.availability, 'available');
  assert.equal(item.value, 2.5);
  assert.equal(item.unit, 'usd');
  assert.equal(item.detail.diem, 44);
  const diemOnly = byId(projection([{ id: 'venice', kind: 'balance', available: true,
    updatedAt: '2026-10-29T04:58:00Z', diem: 44 }]), 'provider.venice.balance');
  assert.equal(diemOnly.availability, 'unavailable'); // Do not call DIEM USD.
});

test('a balance is expired when every remaining component has expired', () => {
  const items = projection([
    {
      id: 'claude-api',
      kind: 'balance',
      source: 'verified',
      available: true,
      updatedAt: '2026-10-12T00:20:14Z',
      currency: 'USD',
      amount: 58.51,
      components: [
        { kind: 'monthly', amount: 58.51, grantedAmount: 100, expiresOnUtc: '2026-10-26' },
        { kind: 'purchased', amount: 0 },
      ],
    },
    {
      id: 'jev',
      kind: 'balance',
      source: 'verified',
      available: true,
      updatedAt: '2026-10-23T10:34:25Z',
      currency: 'USD',
      amount: 9.98,
      components: [
        { kind: 'monthly', amount: 4.98, grantedAmount: 5, expiresOnUtc: '2026-11-19' },
        { kind: 'purchased', amount: 5, grantedAmount: 5, expiresOnUtc: '2027-10-11' },
      ],
    },
  ]);
  assert.equal(byId(items, 'provider.claude-api.balance').expired, true);
  assert.equal(byId(items, 'provider.jev.balance').expired, false);
  assert.equal(byId(items, 'provider.jev.balance').detail.currency, 'USD');
  assert.deepEqual(byId(items, 'provider.jev.balance').detail.components[0], {
    kind: 'monthly',
    amount: 4.98,
    grantedAmount: 5,
    expiresOnUtc: '2026-11-19',
  });
});

test('a verified reading is never stale; a live one is after 20 minutes', () => {
  const items = projection([
    { id: 'jev', kind: 'balance', source: 'verified', available: true, updatedAt: '2026-10-23T10:34:25Z', currency: 'USD', amount: 1 },
    { id: 'codex', kind: 'quota', available: true, updatedAt: '2026-10-29T04:58:00Z', windows: [{ label: 'Weekly', remaining: 48, resetsAt: '2026-11-01T00:00:00Z' }] },
  ], { now: NOW + 40 * 60 * 1000 });
  assert.equal(byId(items, 'provider.jev.balance').stale, false);
  assert.equal(byId(items, 'provider.codex.quota').stale, true);
});

test('unit credits and recorded usage keep their own units and details', () => {
  const items = projection([
    { id: 'google-flow', kind: 'unitCredits', source: 'verified', available: true, updatedAt: '2026-10-18T13:55:00Z', remaining: 0, renewsAt: null, monthlyGrantedAmount: 1000 },
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
  const flow = byId(items, 'provider.google-flow.credits');
  assert.equal(flow.value, 0);
  assert.equal(flow.unit, 'credits');
  assert.deepEqual(flow.detail, { monthlyGrantedAmount: 1000, sourceKind: 'verified' });
  const liquid = byId(items, 'provider.liquid.usage');
  assert.equal(liquid.value, 32007029);
  assert.equal(liquid.unit, 'tokens');
  assert.equal(liquid.detail.periodDays, 14);
  assert.equal(liquid.detail.recordedCostUsd, 1.31);
  assert.equal(liquid.detail.recordedRequestCount, 6473);
  assert.deepEqual(liquid.detail.models, [{ model: 'd1.1 / d1-ultra', inputTokens: 32007029, outputTokens: 0 }]);
});

test('projection keeps quota extras and the original freshness without inventing timestamps', () => {
  const [item] = projection([{
    id: 'claude', kind: 'quota', source: 'live', available: true,
    updatedAt: '2026-10-29T04:50:00Z',
    windows: [{ label: 'Session', remaining: 0, resetsAt: '2026-10-29T06:00:00Z' }],
    extraWindows: [{ label: 'Session', remaining: 0, resetsAt: '2026-10-29T06:00:00Z' }],
    credits: { remaining: 0, updatedAt: '2026-10-29T04:49:00Z' },
    resetPasses: { available: false, updatedAt: '2026-10-29T04:49:00Z', expiresAt: '2026-10-29T07:00:00Z' },
  }]);
  assert.equal(item.detail.windows.length, 1);
  assert.equal(item.detail.windows[0].remainingPercent, 0);
  assert.equal(item.detail.freshUntil, '2026-10-29T05:10:00.000Z');
  assert.deepEqual(item.detail.credits, { remaining: 0, updatedAt: '2026-10-29T04:49:00Z' });
  assert.equal(item.detail.resetPasses.available, false);
  assert.equal(item.detail.resetPasses.remaining, null);
  const missing = byId(projection([{ id: 'codex', kind: 'quota', source: 'live', available: true,
    windows: [{ label: 'Weekly', remaining: 24, resetsAt: null }] }]), 'provider.codex.quota');
  assert.equal(missing.observedAt, null);
  assert.equal(missing.stale, true);
  assert.equal(missing.detail.freshUntil, undefined);
  const future = byId(projection([{ id: 'codex', kind: 'quota', source: 'live', available: true,
    updatedAt: '2026-10-29T05:03:00Z', fetchedAt: '2026-10-29T04:59:00Z',
    windows: [{ label: 'Weekly', remaining: 24, resetsAt: null }] }]), 'provider.codex.quota');
  assert.equal(future.detail.freshUntil, undefined);
  assert.equal(future.stale, true);
  const defaultLive = byId(projection([{ id: 'codex', kind: 'quota', available: true,
    updatedAt: '2026-10-29T04:59:00Z',
    windows: [{ label: 'Weekly', remaining: 24, resetsAt: null }] }]), 'provider.codex.quota');
  assert.equal(defaultLive.detail.freshUntil, '2026-10-29T05:19:00.000Z');
  const unknownSource = byId(projection([{ id: 'codex', kind: 'quota', source: 'unknown', available: true,
    updatedAt: '2026-10-29T04:59:00Z',
    windows: [{ label: 'Weekly', remaining: 24, resetsAt: null }] }]), 'provider.codex.quota');
  assert.equal(unknownSource.detail.freshUntil, undefined);
  assert.equal(unknownSource.stale, true);
  const verifiedMissing = byId(projection([{ id: 'fal', source: 'verified', available: true, amount: 2 }]), 'provider.fal.balance');
  assert.equal(verifiedMissing.observedAt, null);
  assert.equal(verifiedMissing.stale, true);
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
    { id: 'fal', kind: 'balance', source: 'verified', available: true, updatedAt: '2026-10-29T04:00:00Z', currency: 'USD', amount: 0 },
  ]);
  assert.equal(items.some((item) => item.id.includes('clef')), false);
  assert.throws(() => projection([
    { id: 'fal', kind: 'balance', available: true, updatedAt: '2026-10-29T04:00:00Z', amount: 0 },
    { id: 'fal', kind: 'balance', available: true, updatedAt: '2026-10-29T04:00:00Z', amount: 0 },
  ]), UsageFeedError);
});

test('a feed dated in the future or with another version is rejected', () => {
  assert.throws(
    () => usageItemsFromFeed({ version: 1, fetchedAt: '2026-10-29T05:02:00Z', providers: [] }, { now: NOW }),
    (error) => error instanceof UsageFeedError && error.code === 'fetched_at_in_future',
  );
  assert.throws(
    () => usageItemsFromFeed({ version: 2, fetchedAt: '2026-10-29T04:59:00Z', providers: [] }, { now: NOW }),
    (error) => error instanceof UsageFeedError && error.code === 'invalid_version',
  );
  // 60 s of clock skew is tolerated.
  const items = usageItemsFromFeed(
    { version: 1, fetchedAt: '2026-10-29T05:00:30Z', providers: [] },
    { now: NOW },
  );
  assert.equal(items.length, 16);
});

test('no cost or token items are produced in v1', () => {
  const items = projection([]);
  assert.equal(items.some((item) => item.kind === 'cost'), false);
  assert.equal(items.some((item) => item.id.startsWith('profile.')), false);
  assert.ok(items.every((item) => item.availability === 'unavailable' && item.value === null));
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

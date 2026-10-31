// /v1/usage and /v1/mac/status over the real HTTP pipeline (ROADMAP 09).
//
// The fixture-driven tests are the acceptance check from USAGE.md §7: the same
// readings the fixtures show must come out of the route with the same fields,
// and every item — fixture or live — must satisfy the item contract (null value
// only with `unavailable` and a `nullReason`, never a zero stand-in).

import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { HOST_ITEM_KINDS, ITEM_KINDS, ITEM_UNITS, NULL_REASONS } from '../src/usage/items.mjs';
import { startBridge } from './helpers.mjs';

const FIXTURE_DIR = new URL('../../docs/laa/fixtures/usage/', import.meta.url);
const NOW = Date.parse('2026-10-29T04:52:00Z');
const usageRead = { scopes: ['usage:read'] };

function fixture(name) {
  return readFile(new URL(name, FIXTURE_DIR), 'utf8').then((text) => JSON.parse(text));
}

function assertItemShape(item, where) {
  const at = `${where} ${item?.id ?? '(no id)'}`;
  assert.ok(item && typeof item === 'object' && !Array.isArray(item), `${at}: item must be an object`);
  assert.ok(typeof item.id === 'string' && item.id.length > 0, `${at}: id`);
  assert.ok([...ITEM_KINDS, ...HOST_ITEM_KINDS].includes(item.kind), `${at}: kind ${item.kind}`);
  assert.ok(typeof item.label === 'string' && item.label.length > 0, `${at}: label`);
  assert.ok(item.value === null || (typeof item.value === 'number' && Number.isFinite(item.value)), `${at}: value`);
  assert.ok(ITEM_UNITS.includes(item.unit), `${at}: unit ${item.unit}`);
  assert.ok(typeof item.source === 'string' && item.source.length > 0, `${at}: source`);
  assert.ok(item.observedAt === null || /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(item.observedAt), `${at}: observedAt`);
  assert.ok(['available', 'unavailable'].includes(item.availability), `${at}: availability`);
  for (const flag of ['stale', 'estimated', 'expired']) {
    assert.equal(typeof item[flag], 'boolean', `${at}: ${flag}`);
  }
  if (item.availability === 'unavailable') {
    assert.equal(item.value, null, `${at}: an unavailable item never carries a value`);
    assert.ok(NULL_REASONS.includes(item.nullReason), `${at}: nullReason ${item.nullReason}`);
    assert.equal(item.observedAt, null, `${at}: an unavailable item has no observation time`);
    assert.equal(item.stale, false, `${at}: an unavailable item is not called stale`);
  } else {
    assert.notEqual(item.value, null, `${at}: an available item has a value`);
    assert.equal(item.nullReason, undefined, `${at}: only unavailable items carry nullReason`);
  }
}

function feed(overrides = {}) {
  return {
    version: 1,
    fetchedAt: '2026-10-29T04:49:24Z',
    providers: [
      {
        id: 'claude',
        name: 'Claude',
        kind: 'quota',
        available: true,
        updatedAt: '2026-10-29T04:49:23Z',
        windows: [
          { label: 'Session', remaining: 62, resetsAt: '2026-10-29T09:00:00Z', windowMinutes: 300 },
          { label: 'Weekly', remaining: 71, resetsAt: '2026-11-02T00:00:00Z' },
        ],
      },
      {
        id: 'codex',
        name: 'Codex',
        kind: 'quota',
        available: true,
        updatedAt: '2026-10-29T04:49:12Z',
        windows: [{ label: 'Weekly', remaining: 48, resetsAt: '2026-11-01T00:00:00Z' }],
      },
      {
        id: 'jev',
        name: 'Jev',
        kind: 'balance',
        source: 'verified',
        available: true,
        updatedAt: '2026-10-23T10:34:25Z',
        currency: 'USD',
        amount: 12.4,
        components: [
          { kind: 'monthly', amount: 10, grantedAmount: 20 },
          { kind: 'purchased', amount: 2.4 },
        ],
      },
      {
        id: 'gemini',
        name: 'Gemini API（旧）',
        kind: 'balance',
        source: 'verified',
        available: true,
        updatedAt: '2026-10-11T09:14:00Z',
        currency: 'USD',
        amount: 0,
        expiresOnUtc: '2026-10-25',
      },
      {
        id: 'google-flow',
        name: 'Google Flow',
        kind: 'unitCredits',
        source: 'verified',
        available: true,
        updatedAt: '2026-10-18T13:55:00Z',
        remaining: 250,
        renewsAt: '2026-11-01T00:00:00Z',
        monthlyGrantedAmount: 1000,
      },
      {
        id: 'liquid',
        name: 'Liquid AI',
        kind: 'usage',
        source: 'local',
        available: true,
        updatedAt: '2026-10-29T04:49:24Z',
        recordedUsage: {
          scope: 'recorded-calls',
          model: 'd1-ultra',
          startedAt: '2026-10-22T04:49:24Z',
          lastRecordedAt: '2026-10-29T04:49:24Z',
          requestCount: 120,
          inputTokens: 140000,
          outputTokens: 44000,
          costUsd: 1.2,
        },
      },
      { id: 'venice', name: 'Venice', available: false, updatedAt: null },
      {
        id: 'claude-api',
        name: 'Claude API',
        kind: 'balance',
        source: 'verified',
        available: false,
        updatedAt: '2026-10-12T00:20:14Z',
        currency: 'USD',
        amount: 58.51,
        components: [
          { kind: 'monthly', amount: 58.51, grantedAmount: 100, expiresOnUtc: '2026-10-26' },
          { kind: 'purchased', amount: 0 },
        ],
      },
    ],
    ...overrides,
  };
}

function fetcherFor(body) {
  return async () => ({
    ok: true,
    headers: { get: () => null },
    text: async () => (typeof body === 'string' ? body : JSON.stringify(body)),
  });
}

function bridgeWithFeed(payload, { now = () => NOW } = {}) {
  return startBridge({ now, usage: { fetcher: fetcherFor(payload), autoStaleMs: 20 * 60 * 1000 } });
}

function writeStatus(document) {
  const dir = mkdtempSync(join(tmpdir(), 'laa-usage-status-'));
  const file = join(dir, 'status.json');
  writeFileSync(file, typeof document === 'string' ? document : JSON.stringify(document));
  return file;
}

test('usage and mac status require a device with usage:read', async (t) => {
  const api = await bridgeWithFeed(feed());
  t.after(() => api.close());

  const anonymous = await api.request('/v1/usage');
  assert.equal(anonymous.status, 401);
  assert.equal(anonymous.body.error.code, 'unauthenticated');

  const narrow = await api.token(['tasks:read']);
  const denied = await api.request('/v1/usage', { token: narrow });
  assert.equal(denied.status, 403);
  assert.equal(denied.body.error.code, 'insufficient_scope');

  const deniedMac = await api.request('/v1/mac/status', { token: narrow });
  assert.equal(deniedMac.status, 403);

  const token = await api.token(['usage:read']);
  const allowed = await api.request('/v1/usage', { token });
  assert.equal(allowed.status, 200);
  assert.deepEqual(Object.keys(allowed.body.data).sort(), ['items', 'nextCursor']);
  assert.equal(allowed.body.data.nextCursor, null);
  assert.match(allowed.body.requestId, /^req_/);
  assert.equal(allowed.headers.get('cache-control'), 'no-store');
});

test('the normal feed matches the fixture readings field by field', async (t) => {
  const api = await bridgeWithFeed(feed());
  t.after(() => api.close());
  const token = await api.token(usageRead.scopes);
  const res = await api.request('/v1/usage', { token });
  assert.equal(res.status, 200);

  const items = res.body.data.items;
  const normal = (await fixture('usage-normal.json')).data.items;
  const byId = new Map(items.map((item) => [item.id, item]));
  for (const expected of normal) {
    if (!expected.id.startsWith('provider.')) continue; // cost/token items are v1-excluded
    const actual = byId.get(expected.id);
    assert.ok(actual, `${expected.id} is missing from /v1/usage`);
    // Labels are code-owned (the collector's names), so only the reading and
    // its metadata are compared with the fixture's example text.
    const { label: actualLabel, ...actualRest } = actual;
    const { label: expectedLabel, ...expectedRest } = expected;
    assert.equal(actualLabel.length > 0, true);
    assert.equal(expectedLabel.length > 0, true);
    assert.deepEqual(Object.keys(actualRest).sort(), Object.keys(expectedRest).sort(), `${expected.id} fields`);
    for (const [key, value] of Object.entries(expectedRest)) {
      if (key === 'detail') {
        for (const [detailKey, detailValue] of Object.entries(value)) {
          assert.deepEqual(actualRest.detail?.[detailKey], detailValue, `${expected.id} detail.${detailKey}`);
        }
        const added = new Set(['sourceKind', 'freshUntil', 'credits', 'resetPasses', 'usd', 'diem',
          'monthlyRemainingPercent', 'expiresOnUtc', 'creditUnit', 'fallbackAiCredits',
          'recordedCostUsd', 'recordedRequestCount', 'lastRecordedAt']);
        for (const detailKey of Object.keys(actualRest.detail)) {
          assert.ok(Object.hasOwn(value, detailKey) || added.has(detailKey), `${expected.id} unexpected detail.${detailKey}`);
        }
      } else assert.deepEqual(actualRest[key], value, `${expected.id} ${key}`);
    }
  }

  // Every known provider is present even when the feed omits it: a missing
  // reading is reported, not dropped (USAGE.md §2).
  for (const id of ['provider.deepseek.balance', 'provider.antigravity.quota', 'provider.refuseless.balance']) {
    assert.equal(byId.get(id).availability, 'unavailable');
    assert.equal(byId.get(id).value, null);
    assert.equal(byId.get(id).nullReason, 'fetch_failed');
  }
  for (const item of items) assertItemShape(item, 'usage');

  // A zero balance is a value, not a missing reading.
  assert.equal(byId.get('provider.gemini.balance').value, 0);
  assert.equal(byId.get('provider.gemini.balance').expired, true);
  // Verified values are screen checks with no auto refresh: old is not stale.
  assert.equal(byId.get('provider.jev.balance').stale, false);
  assert.equal(byId.get('provider.claude-api.balance').availability, 'unavailable');
  assert.equal(byId.get('provider.claude-api.balance').expired, true);
});

test('live readings go stale after 20 minutes; verified ones do not', async (t) => {
  const late = Date.parse('2026-10-29T05:20:00Z'); // 31 min after the feed
  const api = await bridgeWithFeed(feed(), { now: () => late });
  t.after(() => api.close());
  const token = await api.token(usageRead.scopes);
  const res = await api.request('/v1/usage', { token });
  const byId = new Map(res.body.data.items.map((item) => [item.id, item]));

  assert.equal(byId.get('provider.claude.quota').stale, true);
  assert.equal(byId.get('provider.claude.quota').value, 62, 'a stale value is kept for display');
  assert.equal(byId.get('provider.jev.balance').stale, false);
  assert.equal(byId.get('provider.google-flow.credits').stale, false);
});

test('an unreachable proxy is a 200 with unavailable items, never zeros', async (t) => {
  const api = await startBridge({
    now: () => NOW,
    usage: { fetcher: async () => { throw new Error('connect ECONNREFUSED 127.0.0.1:8081'); } },
  });
  t.after(() => api.close());
  const token = await api.token(usageRead.scopes);
  const res = await api.request('/v1/usage', { token });
  assert.equal(res.status, 200);
  assert.ok(res.body.data.items.length >= 16);
  for (const item of res.body.data.items) {
    assert.equal(item.availability, 'unavailable');
    assert.equal(item.value, null);
    assert.equal(item.nullReason, 'fetch_failed');
    assert.equal(item.observedAt, null);
    assertItemShape(item, 'down');
  }
});

test('a future-dated or malformed feed is discarded', async (t) => {
  const future = feed({ fetchedAt: '2026-10-29T06:00:00Z' });
  const api = await bridgeWithFeed(future);
  t.after(() => api.close());
  const token = await api.token(usageRead.scopes);
  const res = await api.request('/v1/usage', { token });
  assert.equal(res.status, 200);
  assert.ok(res.body.data.items.every((item) => item.availability === 'unavailable'));

  const other = await bridgeWithFeed(feed({ version: 2 }));
  t.after(() => other.close());
  const token2 = await other.token(usageRead.scopes);
  const res2 = await other.request('/v1/usage', { token: token2 });
  assert.equal(res2.status, 200);
  assert.ok(res2.body.data.items.every((item) => item.value === null));
});

test('mac status returns CPU, memory and the storage-guard reading', async (t) => {
  const normal = await fixture('mac-status-normal.json');
  const [fixtureCpu, fixtureMemory, fixtureDisk] = normal.data.items;
  const file = writeStatus({
    checked_at: '2026-10-29T05:32:00Z',
    free_gb: 166.6,
    total_gb: 460.4,
    level: 'warn',
    findings: fixtureDisk.detail.findings,
  });
  const api = await startBridge({
    now: () => Date.parse('2026-10-29T05:40:00Z'),
    usage: {
      sampler: { read: async () => ({ cpu: fixtureCpu, memory: fixtureMemory }) },
      storageStatusFile: file,
    },
  });
  t.after(() => api.close());
  const token = await api.token(usageRead.scopes);
  const res = await api.request('/v1/mac/status', { token });
  assert.equal(res.status, 200);
  assert.equal(res.body.data.nextCursor, null);
  assert.deepEqual(res.body.data.items, normal.data.items);
  for (const item of res.body.data.items) assertItemShape(item, 'mac');
});

test('the storage-guard reading is stale after 26 hours and absent without a file', async (t) => {
  const file = writeStatus({
    checked_at: '2026-10-28T05:32:00Z',
    free_gb: 166.6,
    total_gb: 460.4,
    level: 'warn',
    findings: [],
  });
  const sampler = {
    read: async () => ({
      cpu: { id: 'host.cpu', kind: 'host.cpu', label: 'CPU', value: null, unit: 'percent', source: 'bridge-host-sampler', observedAt: null, availability: 'unavailable', stale: false, estimated: false, expired: false, nullReason: 'unsupported' },
      memory: { id: 'host.memory', kind: 'host.memory', label: 'メモリ', value: null, unit: 'bytes', source: 'bridge-host-sampler', observedAt: null, availability: 'unavailable', stale: false, estimated: false, expired: false, nullReason: 'unsupported' },
    }),
  };
  const api = await startBridge({
    now: () => Date.parse('2026-10-29T09:00:00Z'), // 27.5 h after checked_at
    usage: { sampler, storageStatusFile: file },
  });
  t.after(() => api.close());
  const token = await api.token(usageRead.scopes);
  const res = await api.request('/v1/mac/status', { token });
  const disk = res.body.data.items[2];
  assert.equal(disk.value, 166.6, 'a stale reading keeps its value');
  assert.equal(disk.stale, true);
  assert.equal(disk.observedAt, '2026-10-28T05:32:00Z');

  const missing = await startBridge({
    now: () => Date.parse('2026-10-29T09:00:00Z'),
    usage: { sampler, storageStatusFile: join(tmpdir(), 'laa-usage-missing', 'status.json') },
  });
  t.after(() => missing.close());
  const token2 = await missing.token(usageRead.scopes);
  const res2 = await missing.request('/v1/mac/status', { token: token2 });
  assert.equal(res2.status, 200);
  assert.equal(res2.body.data.items[2].availability, 'unavailable');
  assert.equal(res2.body.data.items[2].value, null);
  assert.equal(res2.body.data.items[2].nullReason, 'not_configured');
});

test('every fixture satisfies the item contract', async (t) => {
  for (const name of ['usage-normal.json', 'usage-degraded.json', 'mac-status-normal.json', 'mac-status-unavailable.json']) {
    const body = await fixture(name);
    assert.deepEqual(Object.keys(body).sort(), ['data', 'requestId'], name);
    assert.deepEqual(Object.keys(body.data).sort(), ['items', 'nextCursor'], name);
    for (const item of body.data.items) assertItemShape(item, name);
  }
  // The degraded fixture shows the same rules under failure: Codex and DeepSeek
  // failed, the dashboard needs auth, the stale Claude value is kept.
  const degraded = (await fixture('usage-degraded.json')).data.items;
  assert.equal(degraded.find((item) => item.id === 'provider.claude.quota').stale, true);
});

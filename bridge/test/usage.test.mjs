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
  assert.ok([...ITEM_KINDS, ...HOST_ITEM_KINDS, 'capacity'].includes(item.kind), `${at}: kind ${item.kind}`);
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
        id: 'refuseless',
        name: 'Refuseless',
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
        id: 'magnific',
        name: 'Magnific',
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
  assert.deepEqual(Object.keys(allowed.body.data).sort(), ['fetchedAt', 'items', 'nextCursor']);
  assert.equal(allowed.body.data.nextCursor, null);
  // The receipt time of the served snapshot, not of this request.
  assert.equal(allowed.body.data.fetchedAt, new Date(NOW).toISOString());
  assert.match(allowed.body.requestId, /^req_/);
  assert.equal(allowed.headers.get('cache-control'), 'no-store');
});

test('the HTTP response contains fresh readings only, with reasons for other sources', async (t) => {
  const api = await bridgeWithFeed(feed());
  t.after(() => api.close());
  const token = await api.token(usageRead.scopes);
  const res = await api.request('/v1/usage', { token });
  assert.equal(res.status, 200);
  const items = res.body.data.items;
  const byId = new Map(items.map(item => [item.id, item]));
  assert.equal(byId.get('provider.claude.quota').value, 62);
  assert.equal(byId.get('provider.codex.quota').value, 48);
  assert.equal(byId.get('provider.liquid.usage').value, 184000);
  for (const id of ['provider.refuseless.balance', 'provider.magnific.credits']) {
    assert.equal(byId.get(id).value, null);
    assert.equal(byId.get(id).nullReason, 'not_auto');
    assert.equal(byId.get(id).detail, undefined);
  }
  assert.equal(items.some(item => item.id.includes('gemini')), false);
  for (const id of ['jev', 'google-cloud', 'google-flow']) {
    assert.equal(items.some(item => item.id.startsWith(`provider.${id}.`)), false);
  }
  assert.equal(byId.get('provider.claude-api.cost-today').value, null);
  for (const item of items) assertItemShape(item, 'usage');
});

test('after ten minutes neither live nor manually verified readings retain numbers', async (t) => {
  const late = Date.parse('2026-10-29T05:20:00Z');
  const api = await bridgeWithFeed(feed(), { now: () => late });
  t.after(() => api.close());
  const token = await api.token(usageRead.scopes);
  const res = await api.request('/v1/usage', { token });
  const byId = new Map(res.body.data.items.map(item => [item.id, item]));
  for (const id of ['provider.claude.quota', 'provider.refuseless.balance', 'provider.magnific.credits']) {
    const item = byId.get(id);
    assert.equal(item.availability, 'unavailable');
    assert.equal(item.value, null);
    assert.equal(item.detail, undefined);
  }
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
  assert.ok(res.body.data.items.length >= 13);
  for (const item of res.body.data.items.filter(item => item.kind !== 'capacity')) {
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
  assert.ok(res.body.data.items.filter(item => item.kind !== 'capacity').every((item) => item.availability === 'unavailable'));

  const other = await bridgeWithFeed(feed({ version: 2 }));
  t.after(() => other.close());
  const token2 = await other.token(usageRead.scopes);
  const res2 = await other.request('/v1/usage', { token: token2 });
  assert.equal(res2.status, 200);
  assert.ok(res2.body.data.items.filter(item => item.kind !== 'capacity').every((item) => item.value === null));
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
    const keys = name.startsWith('usage-') ? ['fetchedAt', 'items', 'nextCursor'] : ['items', 'nextCursor'];
    assert.deepEqual(Object.keys(body.data).sort(), keys, name);
    for (const item of body.data.items) assertItemShape(item, name);
  }
  const degraded = (await fixture('usage-degraded.json')).data.items;
  for (const item of degraded) assert.equal(item.value, null);
});

test('a slow proxy read never holds a usage response', async (t) => {
  // The reading source (the CodexBar proxy) can take seconds; the response must not.
  const fetcher = (url, { signal } = {}) => new Promise((resolve, reject) => {
    const timer = setTimeout(() => resolve({ ok: true, headers: { get: () => null }, text: async () => JSON.stringify(feed()) }), 5000);
    signal?.addEventListener('abort', () => {
      clearTimeout(timer);
      reject(Object.assign(new Error('aborted'), { name: 'AbortError' }));
    }, { once: true });
  });
  const api = await startBridge({ now: () => NOW, usage: { fetcher, autoStaleMs: 20 * 60 * 1000 } });
  t.after(() => api.close());
  const token = await api.token(['usage:read']);
  for (const attempt of ['first', 'second']) {
    const started = Date.now();
    const response = await api.request('/v1/usage', { token });
    const elapsed = Date.now() - started;
    assert.equal(response.status, 200);
    assert.ok(elapsed < 50, `the ${attempt} response took ${elapsed} ms`);
    assert.deepEqual(Object.keys(response.body.data).sort(), ['fetchedAt', 'items', 'nextCursor']);
    assert.equal(response.body.data.fetchedAt, null, 'nothing has been read yet');
    assert.ok(response.body.data.items.filter(item => item.kind !== 'capacity').every((item) => item.availability === 'unavailable'));
  }
});


test('usage exposes injected capacity even when the feed fails', async t => {
  const fixtureItem = { id: 'capacity.macbook.memory', kind: 'capacity', label: 'MacBook · Memory', value: 60, unit: 'bytes', source: 'fixture', observedAt: '2026-10-29T04:49:24Z', availability: 'available', stale: false, estimated: false, expired: false, detail: { totalBytes: 100, availableBytes: 40 } };
  const api = await startBridge({ now: () => NOW, usage: { fetcher: async () => { throw Error('offline'); }, capacitySource: { read: () => [fixtureItem], close() {} } } });
  t.after(() => api.close());
  const token = await api.token(usageRead.scopes);
  const result = await api.request('/v1/usage', { token });
  assert.deepEqual(result.body.data.items.find(item => item.id === fixtureItem.id), fixtureItem);
});

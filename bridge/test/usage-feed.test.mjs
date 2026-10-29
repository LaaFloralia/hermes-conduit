// Last-good usage feed (2026-10-29). The proxy takes 19–25 s on `/widget` under
// Mac load, so the Bridge must answer with the last successful payload instead
// of 「未取得」 — carrying that payload's own timestamps, so age is never hidden.
//
// Fixed here: the slow read falls back (with and without a snapshot), one
// refresh in flight at most, the snapshot reload after a restart, and a corrupt
// snapshot file being ignored rather than inventing a reading.

import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import {
  USAGE_SNAPSHOT_SCHEMA,
  createUsageFeedSource,
  writeUsageSnapshot,
} from '../src/usage/feed.mjs';
import { startBridge } from './helpers.mjs';

const NOW = Date.parse('2026-10-29T04:52:00Z');
const OBSERVED = '2026-10-29T04:49:23Z';

function payload(fetchedAt = '2026-10-29T04:49:24Z') {
  return {
    version: 1,
    fetchedAt,
    providers: [
      {
        id: 'claude',
        name: 'Claude',
        kind: 'quota',
        available: true,
        updatedAt: OBSERVED,
        windows: [{ label: 'Session', remaining: 62, resetsAt: '2026-10-29T09:00:00Z' }],
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
      },
    ],
  };
}

function response(body) {
  return { ok: true, headers: { get: () => null }, text: async () => JSON.stringify(body) };
}

function fastFetcher(body = payload()) {
  return async () => response(body);
}

function slowFetcher(ms, body = payload()) {
  return () => new Promise((resolve) => setTimeout(() => resolve(response(body)), ms));
}

function workingFile() {
  return join(mkdtempSync(join(tmpdir(), 'laa-usage-feed-')), 'usage-feed.json');
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

test('a slow read returns the last-good payload with its original observedAt', async () => {
  const file = workingFile();
  const seeded = createUsageFeedSource({ file, fetcher: fastFetcher(), timeoutMs: 100 });
  const first = await seeded.read();
  assert.equal(first.lastGood, false);
  assert.equal(first.feed.fetchedAt, '2026-10-29T04:49:24Z');

  // Same file, restarted source, upstream now slower than the cap.
  const slow = createUsageFeedSource({ file, fetcher: slowFetcher(200), timeoutMs: 20, refreshTimeoutMs: 1000 });
  const started = Date.now();
  const fallback = await slow.read();
  assert.ok(Date.now() - started < 150, 'the request must not wait for the slow read');
  assert.equal(fallback.lastGood, true);
  assert.equal(fallback.feed.fetchedAt, '2026-10-29T04:49:24Z', 'old data keeps its own timestamp');
  assert.equal(fallback.feed.providers[0].updatedAt, OBSERVED);
});

test('without a snapshot a slow read is unavailable, and the next request gets the value', async () => {
  const file = workingFile();
  const source = createUsageFeedSource({ file, fetcher: slowFetcher(120), timeoutMs: 20, refreshTimeoutMs: 1000 });
  const empty = await source.read();
  assert.deepEqual(empty, { feed: null, lastGood: false });
  assert.equal(source.inflight, true, 'the slow read keeps running in the background');

  await sleep(150);
  const next = await source.read();
  assert.ok(next.feed, 'the background read filled the snapshot');
  assert.equal(next.feed.providers[0].id, 'claude');
  const stored = JSON.parse(readFileSync(file, 'utf8'));
  assert.equal(stored.schema, USAGE_SNAPSHOT_SCHEMA);
  assert.equal(stored.feed.fetchedAt, '2026-10-29T04:49:24Z');
});

test('concurrent requests share one in-flight refresh', async () => {
  const file = workingFile();
  let calls = 0;
  const counting = () => {
    calls += 1;
    return new Promise((resolve) => setTimeout(() => resolve(response(payload())), 80));
  };
  const source = createUsageFeedSource({ file, fetcher: counting, timeoutMs: 15, refreshTimeoutMs: 1000 });
  const [a, b, c] = await Promise.all([source.read(), source.read(), source.read()]);
  assert.equal(calls, 1, 'three requests, one upstream read');
  for (const result of [a, b, c]) assert.equal(result.feed, null, 'nothing cached yet');

  await sleep(120); // let the shared refresh land in the snapshot
  const cachedAtStart = source.snapshot();
  assert.ok(cachedAtStart);
  const [d, e] = await Promise.all([source.read(), source.read()]);
  assert.equal(calls, 2, 'the second poll starts exactly one more read');
  assert.equal(d.feed.fetchedAt, cachedAtStart.fetchedAt);
  assert.equal(e.feed.fetchedAt, cachedAtStart.fetchedAt);
  assert.equal(d.lastGood, true);
});

test('a restart reloads the snapshot from disk', async () => {
  const file = workingFile();
  writeUsageSnapshot(file, payload());
  const source = createUsageFeedSource({
    file,
    fetcher: async () => { throw new Error('connect ECONNREFUSED 127.0.0.1:8081'); },
    timeoutMs: 50,
  });
  const { feed, lastGood } = await source.read();
  assert.equal(lastGood, true);
  assert.equal(feed.fetchedAt, '2026-10-29T04:49:24Z');
  assert.equal(feed.providers.length, 2);
});

test('a corrupt or foreign snapshot file is ignored, then replaced by a good read', async () => {
  for (const corrupt of ['not json at all', '{"schema":1,"feed":{"version":2,"fetchedAt":"2026-10-29T04:49:24Z","providers":[]}}', '[]']) {
    const file = workingFile();
    writeFileSync(file, corrupt);
    const offline = createUsageFeedSource({
      file,
      fetcher: async () => { throw new Error('ECONNREFUSED'); },
      timeoutMs: 50,
    });
    assert.deepEqual(await offline.read(), { feed: null, lastGood: false }, corrupt);

    const online = createUsageFeedSource({ file, fetcher: fastFetcher(), timeoutMs: 100 });
    const { feed } = await online.read();
    assert.equal(feed.fetchedAt, '2026-10-29T04:49:24Z');
    assert.equal(JSON.parse(readFileSync(file, 'utf8')).schema, USAGE_SNAPSHOT_SCHEMA);
  }
});

function assertUsageReady(res) {
  assert.equal(res.status, 200);
  assert.equal(res.body.data.nextCursor, null);
  return new Map(res.body.data.items.map((item) => [item.id, item]));
}

test('over HTTP a slow proxy answers with the snapshot; its age still decides stale', async (t) => {
  const file = workingFile();
  writeUsageSnapshot(file, payload());

  const bridge = await startBridge({
    now: () => NOW,
    usage: { fetcher: slowFetcher(500), feedTimeoutMs: 20, refreshTimeoutMs: 1000, feedStateFile: file },
  });
  t.after(() => bridge.close());
  const token = await bridge.token(['usage:read']);

  const started = Date.now();
  const res = await bridge.request('/v1/usage', { token });
  assert.ok(Date.now() - started < 400, 'the app is not held by the slow read');
  const items = assertUsageReady(res);
  const claude = items.get('provider.claude.quota');
  assert.equal(claude.value, 62, 'the last reading is shown, not 未取得');
  assert.equal(claude.observedAt, OBSERVED, 'the original observation time is kept');
  assert.equal(claude.stale, false, 'nine minutes old is not stale');
  assert.equal(items.get('provider.jev.balance').value, 12.4);

  // 31 minutes later the same payload is stale, and it is still not relabelled.
  const lateFile = workingFile();
  writeUsageSnapshot(lateFile, payload());
  const late = await startBridge({
    now: () => Date.parse('2026-10-29T05:20:00Z'),
    usage: { fetcher: slowFetcher(500), feedTimeoutMs: 20, refreshTimeoutMs: 1000, feedStateFile: lateFile },
  });
  t.after(() => late.close());
  const lateToken = await late.token(['usage:read']);
  const lateItems = assertUsageReady(await late.request('/v1/usage', { token: lateToken }));
  assert.equal(lateItems.get('provider.claude.quota').stale, true);
  assert.equal(lateItems.get('provider.claude.quota').value, 62);
  assert.equal(lateItems.get('provider.claude.quota').observedAt, OBSERVED);
  assert.equal(lateItems.get('provider.jev.balance').stale, false, 'verified stays a screen check');
});

test('over HTTP a slow proxy without a snapshot stays unavailable', async (t) => {
  const bridge = await startBridge({
    now: () => NOW,
    usage: {
      fetcher: slowFetcher(500),
      feedTimeoutMs: 20,
      refreshTimeoutMs: 1000,
      feedStateFile: workingFile(),
    },
  });
  t.after(() => bridge.close());
  const token = await bridge.token(['usage:read']);
  const items = assertUsageReady(await bridge.request('/v1/usage', { token }));
  for (const item of items.values()) {
    assert.equal(item.availability, 'unavailable');
    assert.equal(item.value, null);
  }
});

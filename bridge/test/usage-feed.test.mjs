import assert from 'node:assert/strict';
import { mkdtempSync, readdirSync, rmSync } from 'node:fs';
import { execFile } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import test from 'node:test';
import { createUsageFeedSource } from '../src/usage/feed.mjs';
import { usageItemsFromFeed } from '../src/usage/proxy.mjs';

const observed = '2026-10-29T04:49:23Z';
// Codex is first in the projection's fixed provider order, so [0] is this row.
const feed = { version: 1, fetchedAt: observed, providers: [{ id: 'codex', available: true,
  updatedAt: observed, windows: [{ label: 'Weekly', remaining: 62, resetsAt: null }] }] };
const response = (body = feed) => ({ ok: true, headers: { get: () => null }, text: async () => JSON.stringify(body) });

test('initial read never waits for a background fetch', async (t) => {
  let resolveFetch;
  const pending = new Promise(resolve => { resolveFetch = resolve; });
  const source = createUsageFeedSource({ fetcher: () => pending });
  t.after(source.close);
  assert.deepEqual(await source.read(), { feed: null, receivedAt: null, observationAnchors: new Map() });
  assert.equal(source.inflight, true);
  resolveFetch(response());
  assert.deepEqual(await source.refresh(), feed);
  assert.deepEqual((await source.read()).feed, feed);
});

test('a failed refresh clears memory', async (t) => {
  let calls = 0;
  const source = createUsageFeedSource({ fetcher: async () => {
    if (++calls === 1) return response();
    throw new Error('offline');
  } });
  t.after(source.close);
  await source.refresh();
  assert.deepEqual((await source.read()).feed, feed);
  assert.equal(await source.refresh(), null);
  assert.equal((await source.read()).feed, null);
});

test('refresh does not create a snapshot under an isolated home', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'laa-usage-feed-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const script = `import { createUsageFeedSource } from './src/usage/feed.mjs';
    const body = ${JSON.stringify(feed)};
    const source = createUsageFeedSource({ fetcher: async () => ({
      ok: true, headers: { get: () => null }, text: async () => JSON.stringify(body) }) });
    await source.refresh(); source.close();`;
  await promisify(execFile)(process.execPath, ['--input-type=module', '-e', script], {
    cwd: new URL('..', import.meta.url), env: { ...process.env, HOME: dir, XDG_STATE_HOME: dir },
  });
  assert.deepEqual(readdirSync(dir), []);
});

test('concurrent refreshes share one request and reads keep the actual timestamp', async (t) => {
  let calls = 0;
  let resolveFetch;
  const pending = new Promise(resolve => { resolveFetch = resolve; });
  const source = createUsageFeedSource({ fetcher: () => { calls++; return pending; } });
  t.after(source.close);
  const a = source.refresh();
  const b = source.refresh();
  assert.strictEqual(a, b);
  assert.equal(calls, 1);
  resolveFetch(response());
  await a;
  const cached = (await source.read()).feed;
  assert.equal(cached.providers[0].updatedAt, observed);
  const at = Date.parse(observed);
  assert.equal(usageItemsFromFeed(cached, { now: at + 599_000 })[0].value, 62);
  const expired = usageItemsFromFeed(cached, { now: at + 600_000 })[0];
  assert.equal(expired.availability, 'unavailable');
  assert.equal(expired.value, null);
  assert.equal(expired.detail, undefined);
});

test('repeated observations cannot extend a future-clock allowance', async (t) => {
  const start = Date.parse('2026-10-29T05:00:00Z');
  let now = start;
  let updatedAt = new Date(start + 120_000).toISOString();
  const source = createUsageFeedSource({ now: () => now, fetcher: async () => response({
    version: 1, fetchedAt: new Date(now).toISOString(), providers: [{ id: 'codex', available: true,
      updatedAt, windows: [{ label: 'Weekly', remaining: 42, resetsAt: null }] }],
  }) });
  t.after(source.close);
  const project = async () => {
    const sample = await source.read();
    return usageItemsFromFeed(sample.feed, { now, receivedAt: sample.receivedAt,
      observationAnchors: sample.observationAnchors })[0];
  };
  await source.refresh();
  const first = await project();
  assert.equal(Date.parse(first.detail.freshUntil), start + 600_000);
  now += 120_000;
  updatedAt = updatedAt.replace('.000Z', '+00:00');
  await source.refresh();
  assert.equal((await project()).detail.freshUntil, first.detail.freshUntil);
  now = start + 600_000;
  await source.refresh();
  assert.equal((await project()).value, null);
  updatedAt = new Date(now).toISOString();
  await source.refresh();
  assert.equal((await project()).value, 42);
});

test('timeout invalidates the cache without retaining a previous sample', async (t) => {
  let calls = 0;
  const source = createUsageFeedSource({ refreshTimeoutMs: 15,
    fetcher: async (_url, { signal }) => {
      if (++calls === 1) return response();
      return new Promise((_resolve, reject) => signal.addEventListener('abort', () => reject(new Error('timeout'))));
    } });
  t.after(source.close);
  await source.refresh();
  assert.deepEqual((await source.read()).feed, feed);
  await source.refresh();
  assert.equal((await source.read()).feed, null);
});

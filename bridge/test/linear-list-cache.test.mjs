import test from 'node:test';
import assert from 'node:assert/strict';
import { createLinearListCache, invalidateLinearLists } from '../src/tasks/list-cache.mjs';

test('list cache coalesces cold reads, isolates snapshots and serves stale without waiting', async () => {
  let time = 0, calls = 0, resolve;
  const cache = createLinearListCache({ now: () => time });
  const load = async () => { calls++; return { items: [{ title: 'first' }] }; };
  const pages = await Promise.all(Array.from({ length: 20 }, () => cache('open', load)));
  assert.equal(calls, 1);
  pages[0].items[0].title = 'changed locally';
  assert.equal((await cache('open', load)).items[0].title, 'first');
  time = 45_001;
  const slow = () => { calls++; return new Promise(r => { resolve = r; }); };
  assert.equal((await cache('open', slow)).items[0].title, 'first');
  assert.equal((await cache('open', slow)).items[0].title, 'first');
  assert.equal(calls, 2);
  resolve({ items: [{ title: 'second' }] });
  await new Promise(setImmediate);
  assert.equal((await cache('open', load)).items[0].title, 'second');
});

test('write invalidation fences in-flight refreshes and both archive variants; failed cold reads are retryable', async () => {
  const cache = createLinearListCache();
  let release;
  const old = cache('open', () => new Promise(r => { release = r; }));
  await new Promise(setImmediate);
  await cache('archive', async () => 'old archived');
  invalidateLinearLists();
  assert.equal(await cache('open', async () => 'new'), 'new');
  assert.equal(await cache('archive', async () => 'new archived'), 'new archived');
  release('old'); assert.equal(await old, 'new');
  assert.equal(await cache('open', async () => 'should not load'), 'new');
  await assert.rejects(cache('failure', async () => { throw new Error('offline'); }));
  assert.equal(await cache('failure', async () => 'recovered'), 'recovered');
});

test('failed stale refresh preserves the last complete snapshot', async () => {
  let now = 0;
  const cache = createLinearListCache({ now: () => now });
  await cache('open', async () => 'complete');
  now = 46_000;
  assert.equal(await cache('open', async () => { throw new Error('offline'); }), 'complete');
  await new Promise(setImmediate);
  assert.equal(await cache('open', async () => 'new'), 'complete');
});

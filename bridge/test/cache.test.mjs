// The read cache behind the slow read-only routes (BRIDGE §9): a request never
// waits for a source that has already answered once, one refresh runs at a time,
// and only a source that has never answered can fail the request.
import assert from 'node:assert/strict';
import test from 'node:test';
import { createLastGood, createReadCache } from '../src/cache.mjs';

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const stamp = (ms) => new Date(ms).toISOString();

function counter(values) {
  const calls = [];
  const read = async () => { calls.push(Date.now()); return values[Math.min(calls.length - 1, values.length - 1)]; };
  return { read, calls };
}

test('a value inside the freshness window is served without reading again', async () => {
  const { read, calls } = counter(['a', 'b']);
  const cache = createReadCache({ read, freshMs: 60000 });
  assert.deepEqual((await cache.get()).value, 'a');
  assert.deepEqual((await cache.get()).value, 'a');
  assert.equal(calls.length, 1);
});

test('an expired value is served immediately while exactly one refresh runs', async () => {
  let calls = 0;
  let release;
  const cache = createReadCache({
    freshMs: 20,
    read: async () => { calls += 1; if (calls === 1) return 'first'; await new Promise((resolve) => { release = resolve; }); return 'second'; },
  });
  const first = await cache.get();
  assert.equal(first.value, 'first');
  await delay(30);
  const started = Date.now();
  const stale = await cache.get();
  assert.ok(Date.now() - started < 50, 'an expired value must not wait for the refresh');
  assert.equal(stale.value, 'first');
  assert.equal(stale.stale, true);
  assert.equal(stale.fetchedAt, first.fetchedAt);
  assert.equal(calls, 2);
  // Concurrent requests while that refresh runs do not start another one.
  const more = await Promise.all([cache.get(), cache.get(), cache.get()]);
  assert.ok(more.every((entry) => entry.value === 'first' && entry.stale === true));
  assert.equal(calls, 2);
  release();
  await delay(10);
  assert.equal(cache.peek().value, 'second');
});

test('concurrent requests for a value that was never read share one read', async () => {
  let calls = 0;
  const cache = createReadCache({ read: async () => { calls += 1; await delay(50); return 'value'; } });
  const entries = await Promise.all([cache.get(), cache.get(), cache.get(), cache.get()]);
  assert.ok(entries.every((entry) => entry.value === 'value' && entry.stale === false));
  assert.equal(calls, 1);
});

test('a failed refresh keeps the previous value, and a first failure is an error', async () => {
  let calls = 0;
  const cache = createReadCache({
    freshMs: 10, waitMs: 500,
    read: async () => { calls += 1; if (calls > 1) throw Object.assign(new Error('source down'), { status: 503 }); return 'good'; },
  });
  const first = await cache.get();
  await delay(20);
  const kept = await cache.get();
  assert.equal(kept.value, 'good');
  assert.equal(kept.stale, true);
  assert.equal(kept.fetchedAt, first.fetchedAt);
  assert.equal(kept.error?.status, 503);
  await assert.rejects(createReadCache({ read: async () => { throw Object.assign(new Error('down'), { status: 503 }); } }).get(), { status: 503 });
});

test('a source that answers badly stays an error even with a cached value', async () => {
  let calls = 0;
  const cache = createReadCache({
    freshMs: 10, waitMs: 500,
    read: async () => {
      calls += 1;
      if (calls > 1) throw Object.assign(new Error('bad response'), { status: 502 });
      return 'good';
    },
  });
  await cache.get();
  await delay(20);
  await assert.rejects(cache.get(), { status: 502 });
});

test('a read that takes longer than the wait budget is served from the cache afterwards', async () => {
  let calls = 0;
  const cache = createReadCache({ waitMs: 20, read: async () => { calls += 1; await delay(60); return `v${calls}`; } });
  assert.equal((await cache.get()).value, 'v1');       // the first answer waits for the read
  const started = Date.now();
  const second = await cache.get();                    // the source is known to be slow
  assert.ok(Date.now() - started < 50);
  assert.equal(second.value, 'v1');
  assert.equal(second.stale, true);
});

test('the last good value covers a source that cannot be read at all', () => {
  const cache = createLastGood();
  cache.accept({ data: 'catalog', etag: '"tag"' });
  const cached = cache.fallback(Object.assign(new Error('down'), { status: 503, code: 'studio_not_connected' }));
  assert.equal(cached.value.etag, '"tag"');
  assert.equal(cached.stale, true);
  assert.equal(typeof cached.fetchedAt, 'number');
  assert.throws(() => createLastGood().fallback(Object.assign(new Error('down'), { status: 503 })), { status: 503 });
  assert.throws(() => cache.fallback(Object.assign(new Error('bad'), { status: 502 })), { status: 502 });
});

test('the served value carries the time it was read, not the time it was requested', async () => {
  let clock = 1000;
  const cache = createReadCache({ now: () => clock, freshMs: 60000, read: async () => 'value' });
  const first = await cache.get();
  clock += 30000;
  const second = await cache.get();
  assert.equal(first.fetchedAt, 1000);
  assert.equal(second.fetchedAt, first.fetchedAt);
  assert.equal(stamp(second.fetchedAt), '1970-01-01T00:00:01.000Z');
});

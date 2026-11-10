import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createStore } from '../src/store.mjs';
import { createStudioQueue } from '../src/studio/queue.mjs';

test('Studio delivers a persisted request after restart and expires requests after 24 hours', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'laa-studio-queue-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const day = 24 * 60 * 60 * 1000;
  let time = 10;
  const now = () => time;
  const setup = (backend) => {
    const store = createStore({ dir, now });
    let close;
    const queue = createStudioQueue({
      store, now, backend, intervalMs: 30_000,
      registerCleanup: (callback) => { close = callback; },
    });
    t.after(close);
    return { store, queue, close };
  };
  const before = setup({ createRequest: () => assert.fail('only queue during the first process') });
  const expired = { id: '00000000-0000-4000-8000-000000000001', prompt: 'expired' };
  const request = { id: '00000000-0000-4000-8000-000000000002', prompt: 'still queued' };
  before.queue.enqueue(expired, 'phone');
  time += 100;
  before.queue.enqueue(request, 'phone');
  before.close();
  time += day - 50;
  let deliver;
  const delivered = new Promise((resolve) => { deliver = resolve; });
  const calls = [];
  const after = setup({
    createRequest: async (value) => { calls.push(value); deliver(); },
  });
  await delivered;
  await Promise.resolve();
  assert.deepEqual(calls, [request]);
  assert.equal(after.queue.get(expired.id, 'phone')?.status, 'expired');
  assert.equal(after.queue.get(request.id, 'phone'), undefined);
  assert.equal(after.store.read().studioQueue[request.id], undefined);
});

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { startBridge } from './helpers.mjs';

test('routine endpoint requires read access and projects only public fields', async (t) => {
  const bridge = await startBridge({ routines: { read: async () => ({ data: [{ id: 'job:a', name: 'Daily', schedule: 'daily', privateValue: 'hidden', reading: { nextRunAt: '2026-11-01T03:00:00Z', lastRunAt: null, result: 'ok', secret: 'hidden' } }] }) } });
  t.after(() => bridge.close());
  assert.equal((await bridge.request('/v1/routines')).status, 401);
  const token = await bridge.token();
  const response = await bridge.request('/v1/routines', { token });
  assert.equal(response.status, 200);
  assert.deepEqual(response.body.data.items, [{ id: 'job:a', name: 'Daily', schedule: 'daily', nextRunAt: '2026-11-01T03:00:00Z', lastRunAt: null, result: 'ok' }]);
});

test('unavailable routine source returns an error rather than an empty list', async (t) => {
  const bridge = await startBridge({ routines: { read: async () => { throw new Error('private error'); } } });
  t.after(() => bridge.close());
  const response = await bridge.request('/v1/routines', { token: await bridge.token() });
  assert.equal(response.status, 503);
  assert.equal(JSON.stringify(response.body).includes('private error'), false);
});

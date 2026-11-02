import { test } from 'node:test';
import assert from 'node:assert/strict';
import { projectRoutines, routineDestination, routineState } from '../src/routes/routines.mjs';
import { startBridge } from './helpers.mjs';

test('routine endpoint requires read access and projects only public fields', async (t) => {
  const bridge = await startBridge({ routines: { read: async () => ({ data: [{ id: 'job:a', name: 'Daily', schedule: 'daily', privateValue: 'hidden', reading: { nextRunAt: '2026-11-01T03:00:00Z', lastRunAt: null, result: 'ok', secret: 'hidden' } }] }) } });
  t.after(() => bridge.close());
  assert.equal((await bridge.request('/v1/routines')).status, 401);
  const token = await bridge.token();
  const response = await bridge.request('/v1/routines', { token });
  assert.equal(response.status, 200);
  assert.deepEqual(response.body.data.items, [{ id: 'job:a', name: 'Daily', schedule: 'daily', nextRunAt: '2026-11-01T03:00:00Z', lastRunAt: null, result: 'ok', destination: null, state: 'unknown', businessStatus: null, notificationStatus: null }]);
});

test('unavailable routine source returns an error rather than an empty list', async (t) => {
  const bridge = await startBridge({ routines: { read: async () => { throw new Error('private error'); } } });
  t.after(() => bridge.close());
  const response = await bridge.request('/v1/routines', { token: await bridge.token() });
  assert.equal(response.status, 503);
  assert.equal(JSON.stringify(response.body).includes('private error'), false);
});


test('routine states use current scheduler and business observations with explicit precedence', () => {
  assert.equal(routineState({ expected: 'stopped' }, { running: true, enabled: false, schedulerResult: 'error' }), 'running');
  assert.equal(routineState({ expected: 'stopped' }, { enabled: true, schedulerResult: 'error' }), 'paused');
  assert.equal(routineState({}, { enabled: false }), 'paused');
  assert.equal(routineState({}, { enabled: true, schedulerResult: 'error' }), 'error');
  assert.equal(routineState({}, { enabled: true, businessStatus: 'partial' }), 'error');
  assert.equal(routineState({}, { enabled: true, businessStatus: 'failed' }), 'error');
  assert.equal(routineState({}, { enabled: true, result: 'timeout', schedulerResult: 'success', businessStatus: 'success' }), 'scheduled');
  assert.equal(routineState({}, {}), 'unknown');
});

test('destinations only use explicitly configured chat roles and preserve unknown receivers', () => {
  assert.equal(routineDestination({ notificationMode: 'chat', receiverRole: 'COS', ownerRole: 'Ciel' }), 'Merlinの定期実行チャット');
  assert.equal(routineDestination({ notificationMode: 'chat', ownerRole: 'ciel', deliver: 'local' }), 'Cielの定期実行チャット');
  assert.equal(routineDestination({ notificationMode: 'email', ownerRole: 'ciel' }), null);
  assert.equal(routineDestination({ notificationMode: 'chat', receiverRole: 'unknown', ownerRole: 'ciel' }), null);
  assert.equal(routineDestination({ notificationMode: 'chat', ownerRole: 'constructor' }), null);
});

test('history stays visible separately from the current state and is recomputed each read', () => {
  const job = { id: 'job:mail', name: 'Mail', notificationMode: 'chat', ownerRole: 'ciel', reading: {
    enabled: true, schedulerResult: 'error', businessStatus: 'failed', notificationStatus: 'pending', result: 'timeout', lastRunAt: '2026-11-02T00:00:00Z' } };
  assert.equal(projectRoutines({ data: [job] })[0].state, 'error');
  job.reading.schedulerResult = 'success'; job.reading.businessStatus = 'success';
  const row = projectRoutines({ data: [job] })[0];
  assert.equal(row.state, 'scheduled');
  assert.equal(row.result, 'timeout');
  assert.equal(row.notificationStatus, 'pending');
  assert.equal(row.lastRunAt, '2026-11-02T00:00:00Z');
});

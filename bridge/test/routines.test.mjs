import { test } from 'node:test';
import assert from 'node:assert/strict';
import { consoleEnv, projectRoutines, routineKind, routineDestination, routineState } from '../src/routes/routines.mjs';
import { startBridge } from './helpers.mjs';

test('routine endpoint requires read access and projects only public fields', async (t) => {
  const bridge = await startBridge({ routines: { read: async () => ({ data: [{ id: 'job:a', name: 'Daily', schedule: 'daily', privateValue: 'hidden', reading: { nextRunAt: '2026-11-01T03:00:00Z', lastRunAt: null, result: 'ok', secret: 'hidden' } }] }) } });
  t.after(() => bridge.close());
  assert.equal((await bridge.request('/v1/routines')).status, 401);
  const token = await bridge.token();
  const response = await bridge.request('/v1/routines', { token });
  assert.equal(response.status, 200);
  assert.deepEqual(response.body.data.items, [{ id: 'job:a', name: 'Daily', schedule: 'daily', nextRunAt: '2026-11-01T03:00:00Z', lastRunAt: null, result: 'ok', triggerKind: 'unknown', destination: null, state: 'unknown', businessStatus: null, notificationStatus: null, ...Object.fromEntries(['runId', 'reasonCode', 'observationStatus', 'scheduledAt', 'expectedRunAt', 'startedAt', 'finishedAt', 'notificationAcceptedAt', 'notificationSentAt', 'notificationReceivedAt'].map((key) => [key, null])), ref: 'R1' }]);
});

test('unavailable routine source returns an error rather than an empty list', async (t) => {
  const bridge = await startBridge({ routines: { read: async () => { throw new Error('private error'); } } });
  t.after(() => bridge.close());
  const response = await bridge.request('/v1/routines', { token: await bridge.token() });
  assert.equal(response.status, 503);
  assert.equal(JSON.stringify(response.body).includes('private error'), false);
});

test('one unusable row is skipped and a wholly unusable document is still an error', async (t) => {
  const mixed = await startBridge({ routines: { read: async () => ({ data: [
    { id: 'job:a', name: 'Daily', reading: { enabled: true } },
    { id: 7, name: null },
  ] }) } });
  t.after(() => mixed.close());
  const page = await mixed.request('/v1/routines', { token: await mixed.token() });
  assert.equal(page.status, 200);
  assert.deepEqual(page.body.data.items.map((row) => row.id), ['job:a']);
  assert.equal(page.body.data.skipped, 1);

  const replaced = await startBridge({ routines: { read: async () => ({ data: [{ nope: true }] }) } });
  t.after(() => replaced.close());
  const broken = await replaced.request('/v1/routines', { token: await replaced.token() });
  assert.equal(broken.status, 503, 'a changed Console shape is never shown as "no routines"');
});

test('a failed cold read retries on its own instead of waiting for the next app request', async (t) => {
  let calls = 0;
  const bridge = await startBridge({ routines: { firstWaitMs: 100, retryMs: 50, read: async () => {
    calls += 1;
    if (calls === 1) throw new Error('console busy');
    return { data: [{ id: 'job:a', name: 'Daily', reading: { enabled: true } }] };
  } } });
  t.after(() => bridge.close());
  const deadline = Date.now() + 5000;
  while (calls < 2 && Date.now() < deadline) await delay(20);
  assert.ok(calls >= 2, 'the cold cache retried without an HTTP request');
  const page = await bridge.request('/v1/routines', { token: await bridge.token() });
  assert.equal(page.status, 200);
  assert.equal(page.body.data.items[0].id, 'job:a');
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
  assert.equal(routineDestination({ notificationMode: 'chat', receiverRole: 'COS', ownerRole: 'Ciel' }), 'Merlinのチャット');
  assert.equal(routineDestination({ notificationMode: 'chat', ownerRole: 'ciel', deliver: 'local' }), 'Cielのチャット');
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

test('console reader puts the Bridge runtime first on the launchd PATH', () => {
  const env = consoleEnv({ PATH: '/usr/bin:/bin', HOME: '/Users/laa' }, '/opt/laa/node/bin/node');
  assert.equal(env.PATH, '/opt/laa/node/bin:/usr/bin:/bin');
  assert.equal(env.HOME, '/Users/laa');
  assert.equal(consoleEnv({}, '/opt/laa/node/bin/node').PATH, '/opt/laa/node/bin');
});

test('routine classification uses structured triggers, never schedule wording', () => {
  for (const kind of ['scheduled', 'service', 'manual', 'unknown']) {
    assert.equal(routineKind({ triggerKind: kind, schedule: 'KeepAlive', reading: { source: 'launchd' } }), kind);
  }
  assert.equal(routineKind({ schedule: '毎日 07:00', reading: { source: 'launchd' } }), 'unknown');
  assert.equal(routineKind({ schedule: '常駐', reading: { source: 'hermes' } }), 'scheduled');
  assert.equal(routineKind({ triggerKind: 'invalid' }), 'unknown');
});

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function waitForStatus(bridge, token, status, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  let last;
  while (Date.now() < deadline) {
    last = await bridge.request('/v1/routines', { token });
    if (last.status === status) return last;
    await delay(50);
  }
  return last;
}

test('a cold request waits for the first console read and a bounded wait still leaves it running', async (t) => {
  let calls = 0;
  const bridge = await startBridge({ routines: { firstWaitMs: 150, read: async () => {
    calls += 1;
    await delay(600); // the production hang was 86 s; the shape of the failure is the same
    return { data: [{ id: 'job:a', name: 'Daily', reading: { enabled: true } }] };
  } } });
  t.after(() => bridge.close());
  const token = await bridge.token();

  const cold = Date.now();
  const first = await bridge.request('/v1/routines', { token });
  const waited = Date.now() - cold;
  assert.equal(first.status, 503);                       // nothing has ever been read yet
  assert.ok(waited >= 140 && waited < 1200, `a cold request waited ${waited} ms`);

  const filled = await waitForStatus(bridge, token, 200);
  assert.equal(filled.body.data.items[0].id, 'job:a');
  assert.equal(typeof filled.body.data.fetchedAt, 'string');

  const warm = Date.now();
  const second = await bridge.request('/v1/routines', { token });
  assert.equal(second.status, 200);
  assert.ok(Date.now() - warm < 50, `a repeated request took ${Date.now() - warm} ms`);
  assert.equal(second.body.data.fetchedAt, filled.body.data.fetchedAt);
  assert.equal(calls, 1);
});

test('a first read that lands inside the wait answers with data, not an error', async (t) => {
  let calls = 0;
  const bridge = await startBridge({ routines: { firstWaitMs: 2000, read: async () => {
    calls += 1;
    await delay(250);
    return { data: [{ id: 'job:a', name: 'Daily', reading: { enabled: true } }] };
  } } });
  t.after(() => bridge.close());
  const token = await bridge.token();
  const page = await bridge.request('/v1/routines', { token });
  assert.equal(page.status, 200, 'the app asked once and got the routines instead of "could not load"');
  assert.equal(page.body.data.items[0].id, 'job:a');
  assert.equal(calls, 1);
});

test('an expired routine value is served at once and one console read refreshes it', async (t) => {
  let calls = 0;
  let clock = 1_000_000;
  const bridge = await startBridge({ routines: { freshMs: 60000, now: () => clock, read: async () => {
    calls += 1;
    if (calls > 1) await delay(300);
    return { data: [{ id: 'job:a', name: 'Daily', reading: { enabled: true } }] };
  } } });
  t.after(() => bridge.close());
  const token = await bridge.token();
  const first = await waitForStatus(bridge, token, 200);
  assert.equal(first.body.data.fetchedAt, new Date(clock).toISOString());
  clock += 60001;

  const started = Date.now();
  const stale = await bridge.request('/v1/routines', { token });
  const elapsed = Date.now() - started;
  assert.equal(stale.status, 200);
  // The stale answer must not wait for the 300 ms refresh behind it. The bound
  // stays below that so the contract is still proved, but tolerates a busy
  // developer Mac (a 74 ms answer under load 200 failed a 50 ms bound).
  assert.ok(elapsed < 250, `an expired value took ${elapsed} ms`);
  assert.equal(stale.body.data.fetchedAt, first.body.data.fetchedAt);

  const concurrent = await Promise.all(Array.from({ length: 4 }, () => bridge.request('/v1/routines', { token })));
  assert.ok(concurrent.every((response) => response.status === 200));
  assert.ok(concurrent.every((response) => response.body.data.fetchedAt === first.body.data.fetchedAt));
  assert.equal(calls, 2, 'one refresh runs for all requests');
});

test('a failed console read keeps the previous observations instead of a 503', async (t) => {
  let calls = 0;
  let clock = 2_000_000;
  const bridge = await startBridge({ routines: { freshMs: 60000, now: () => clock, read: async () => {
    calls += 1;
    if (calls > 1) throw new Error('console failed');
    return { data: [{ id: 'job:a', name: 'Daily', reading: { enabled: true } }] };
  } } });
  t.after(() => bridge.close());
  const token = await bridge.token();
  const first = await waitForStatus(bridge, token, 200);
  clock += 60001;
  const kept = await bridge.request('/v1/routines', { token });
  assert.equal(kept.status, 200);
  assert.deepEqual(kept.body.data.items, first.body.data.items);
  assert.equal(kept.body.data.fetchedAt, first.body.data.fetchedAt);
  await delay(100);
  assert.equal(calls, 2);
});


test('execution evidence crosses Console to LAA without private output', () => {
  for (const [reasonCode, businessStatus, notificationStatus] of [
    ['observed', 'completed', 'accepted'], ['result_needs_attention', 'failed', 'accepted'],
    ['observed', 'completed', 'not_received'], ['schedule_overdue', 'unknown', 'unknown'],
    ['read_unavailable', 'unknown', 'unknown'],
  ]) {
    const reading = { enabled: true, runId: 'execution-12345678', reasonCode, businessStatus, notificationStatus,
      scheduledAt: '2026-11-08T00:00:00Z', startedAt: '2026-11-08T00:00:01Z', finishedAt: '2026-11-08T00:01:00Z',
      notificationSentAt: null, notificationReceivedAt: null, privateOutput: 'PRIVATE-MAIL' };
    const row = projectRoutines({ data: [{ id: 'job:test', name: 'fixture', triggerKind: 'scheduled', reading }] })[0];
    assert.equal(row.runId, reading.runId);
    assert.equal(row.reasonCode, reasonCode);
    assert.equal(row.businessStatus, businessStatus);
    assert.equal(row.notificationStatus, notificationStatus);
    assert.equal(row.startedAt, reading.startedAt);
    assert.equal(row.notificationReceivedAt, null);
    assert.equal(JSON.stringify(row).includes('PRIVATE-MAIL'), false);
    if (['schedule_overdue', 'read_unavailable'].includes(reasonCode)) assert.equal(row.state, 'error');
  }
});

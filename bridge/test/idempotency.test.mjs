import assert from 'node:assert/strict';
import test from 'node:test';
import { requestFingerprint } from '../src/idempotency.mjs';
import { startBridge } from './helpers.mjs';

async function enrolledDevice(api) {
  const paired = await api.pair();
  const enrolled = await api.enroll(paired.code);
  return { deviceId: enrolled.body.data.deviceId, token: enrolled.body.data.token };
}

test('a state-changing request without Idempotency-Key is 400', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const { token } = await enrolledDevice(api);
  const res = await api.request('/v1/_test/echo', { method: 'POST', token, body: { a: 1 } });
  assert.equal(res.status, 400);
  assert.equal(res.body.error.code, 'idempotency_key_required');

  const invalid = await api.request('/v1/_test/echo', {
    method: 'POST',
    token,
    key: 'has spaces and slashes//',
    body: { a: 1 },
  });
  assert.equal(invalid.status, 400);
  assert.equal(invalid.body.error.code, 'idempotency_key_invalid');
});

test('the same key and body replays the stored response', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const { token } = await enrolledDevice(api);

  const first = await api.request('/v1/_test/echo', { method: 'POST', token, key: 'pair-1', body: { a: 1 } });
  assert.equal(first.status, 201);
  assert.equal(first.headers.get('idempotency-replayed'), null);

  const replay = await api.request('/v1/_test/echo', { method: 'POST', token, key: 'pair-1', body: { a: 1 } });
  assert.equal(replay.status, 201);
  assert.equal(replay.headers.get('idempotency-replayed'), 'true');
  assert.equal(replay.body.data.mutationId, first.body.data.mutationId, 'the same effect, not a second one');
  assert.notEqual(replay.body.requestId, first.body.requestId, 'each HTTP request keeps its own trace id');

  const other = await api.request('/v1/_test/echo', { method: 'POST', token, key: 'pair-2', body: { a: 1 } });
  assert.notEqual(other.body.data.mutationId, first.body.data.mutationId, 'a new key executes again');
});

test('the same key with a different body is 409 and does not execute', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const { token } = await enrolledDevice(api);

  await api.request('/v1/_test/echo', { method: 'POST', token, key: 'k', body: { a: 1 } });
  const conflict = await api.request('/v1/_test/echo', { method: 'POST', token, key: 'k', body: { a: 2 } });
  assert.equal(conflict.status, 409);
  assert.equal(conflict.body.error.code, 'idempotency_key_conflict');

  const ledger = Object.values(api.store.read().idempotency);
  assert.equal(ledger.length, 1, 'the conflict added no ledger row');
});

test('the ledger is per device: another device may reuse the same key', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const one = await enrolledDevice(api);
  const two = await enrolledDevice(api);

  const a = await api.request('/v1/_test/echo', { method: 'POST', token: one.token, key: 'shared', body: { a: 1 } });
  const b = await api.request('/v1/_test/echo', { method: 'POST', token: two.token, key: 'shared', body: { a: 9 } });
  assert.equal(a.status, 201);
  assert.equal(b.status, 201);
  assert.notEqual(a.body.data.mutationId, b.body.data.mutationId);
});

test('replays and tokens survive a restart', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const { token } = await enrolledDevice(api);

  const first = await api.request('/v1/_test/echo', { method: 'POST', token, key: 'durable', body: { a: 1 } });
  assert.equal(first.status, 201);

  await api.restart();

  assert.equal((await api.request('/v1/me', { token })).status, 200, 'device state survived');
  const replay = await api.request('/v1/_test/echo', { method: 'POST', token, key: 'durable', body: { a: 1 } });
  assert.equal(replay.status, 201);
  assert.equal(replay.headers.get('idempotency-replayed'), 'true');
  assert.equal(replay.body.data.mutationId, first.body.data.mutationId, 'the ledger survived');
});

test('entries older than seven days are pruned and execute again', async (t) => {
  let clock = Date.now();
  const api = await startBridge({ now: () => clock });
  t.after(() => api.close());
  const { token } = await enrolledDevice(api);

  const first = await api.request('/v1/_test/echo', { method: 'POST', token, key: 'week', body: { a: 1 } });
  clock += 6 * 24 * 60 * 60 * 1000;
  const sameWeek = await api.request('/v1/_test/echo', { method: 'POST', token, key: 'week', body: { a: 1 } });
  assert.equal(sameWeek.body.data.mutationId, first.body.data.mutationId, 'still inside retention');

  clock += 2 * 24 * 60 * 60 * 1000;
  const afterRetention = await api.request('/v1/_test/echo', { method: 'POST', token, key: 'week', body: { a: 1 } });
  assert.notEqual(afterRetention.body.data.mutationId, first.body.data.mutationId, 'expired row allows a new execution');
  assert.equal(afterRetention.headers.get('idempotency-replayed'), null);
});

test('an abandoned in-flight row is not retried automatically', async (t) => {
  let clock = Date.now();
  const api = await startBridge({ now: () => clock });
  t.after(() => api.close());
  const { deviceId, token } = await enrolledDevice(api);

  const body = { a: 1 };
  const fingerprint = requestFingerprint('POST', '/v1/_test/echo', Buffer.from(JSON.stringify(body)));

  // Simulate a crash after reserving the row but before completing it.
  api.store.mutate((state) => {
    state.idempotency[`${deviceId}|crashed`] = {
      deviceId,
      key: 'crashed',
      method: 'POST',
      path: '/v1/_test/echo',
      fingerprint,
      status: 'in_progress',
      httpStatus: null,
      response: null,
      createdAt: clock,
      completedAt: null,
    };
  });

  const inFlight = await api.request('/v1/_test/echo', { method: 'POST', token, key: 'crashed', body });
  assert.equal(inFlight.status, 409);
  assert.equal(inFlight.body.error.code, 'idempotency_key_in_flight');
  assert.equal(inFlight.body.error.retryable, true);

  clock += 61 * 1000;
  const unresolved = await api.request('/v1/_test/echo', { method: 'POST', token, key: 'crashed', body });
  assert.equal(unresolved.status, 409);
  assert.equal(unresolved.body.error.code, 'idempotency_outcome_unknown');
  assert.equal(unresolved.body.error.retryable, false);
});

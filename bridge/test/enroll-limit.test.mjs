// BUS-567 F1/F2: the pairing limiter refuses even a correct code once the
// failure window is full, and each device carries a coarse last-use time.
import assert from 'node:assert/strict';
import test from 'node:test';
import { startBridge } from './helpers.mjs';

test('ten failed pairings in a minute refuse the right code too; a minute later it enrolls', async (t) => {
  let clock = Date.parse('2026-11-28T08:00:00Z');
  const api = await startBridge({ now: () => clock });
  t.after(() => api.close());
  const paired = await api.pair();
  const statuses = [];
  for (let i = 0; i < 9; i++) statuses.push((await api.enroll('ZZZZ-ZZZZ')).status);
  // A malformed code counts as a failure as well.
  statuses.push((await api.enroll('x')).status);
  assert.deepEqual(statuses.slice(0, 9), Array(9).fill(401));
  assert.equal(statuses[9], 429);
  const blocked = await api.enroll(paired.code);
  assert.equal(blocked.status, 429);
  assert.equal(blocked.body.error.code, 'rate_limited');
  assert.equal(Object.keys(api.store.read().devices).length, 0, 'no device is created while limited');
  clock += 61_000;
  assert.equal((await api.enroll(paired.code)).status, 201);
});

test('a device records its last use once, not on every request within the hour', async (t) => {
  let clock = Date.parse('2026-11-28T08:00:00Z');
  const api = await startBridge({ now: () => clock });
  t.after(() => api.close());
  const enrolled = await api.enroll((await api.pair()).code);
  const id = enrolled.body.data.deviceId, token = enrolled.body.data.token;
  const lastUsed = async () => { await new Promise((resolve) => setImmediate(resolve)); return api.store.read().devices[id].lastUsedAt; };
  assert.equal(api.store.read().devices[id].lastUsedAt, undefined);
  const me = await api.request('/v1/me', { token });
  assert.equal(me.status, 200);
  assert.equal('lastUsedAt' in me.body.data, false, 'not returned to clients');
  assert.equal(await lastUsed(), '2026-11-28T08:00:00.000Z');
  clock += 30 * 60_000;
  await api.request('/v1/me', { token });
  assert.equal(await lastUsed(), '2026-11-28T08:00:00.000Z');
  clock += 31 * 60_000;
  await api.request('/v1/me', { token });
  assert.equal(await lastUsed(), '2026-11-28T09:01:00.000Z');
});

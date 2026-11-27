import assert from 'node:assert/strict';
import { symlinkSync, unlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { startBridge } from './helpers.mjs';

const checked = Date.parse('2026-11-26T10:30:00Z');
const deadline = Date.parse('2026-11-26T10:35:00Z');
const secret = 'test-private-text';
const fixture = (status = 'ok') => ({
  schema: 'laa.supervisor-status.v1',
  checkedAt: '2026-11-26T10:30:00+00:00',
  nextCheckBy: '2026-11-26T10:35:00Z',
  status,
  tickDurationMs: 2840,
  inspectP95Ms: 620.5,
  vmPressureLevel: 1,
  counts: { runningAll: 6, stalled: 0, readyPending: -1, needsJudgement: secret, extra: secret },
  sla: { breaches: [secret] },
  cronLintWarnings: [{ jobId: secret }],
  actionsThisTick: [secret],
  reason: secret,
  lastJudgementModel: secret,
});

async function rig(t, now = () => checked) {
  const api = await startBridge({ now, supervisorFile: (dir) => join(dir, 'supervisor-status.json') });
  t.after(() => api.close());
  return { api, path: join(api.dir, 'supervisor-status.json') };
}

test('status requires an authorized device and keeps public health unchanged', async (t) => {
  const { api, path } = await rig(t);
  writeFileSync(path, JSON.stringify(fixture()));
  const narrow = await api.token(['sessions:read']);
  assert.equal((await api.request('/v1/status')).status, 401);
  assert.equal((await api.request('/v1/status', { token: narrow })).status, 403);
  const health = await api.request('/v1/health');
  assert.equal(health.status, 200);
  assert.deepEqual(Object.keys(health.body.data).sort(), ['uptimeSeconds', 'version']);
});

test('status projects safe metrics, reports a writer stall, and becomes stale only after the deadline', async (t) => {
  let now = deadline;
  const { api, path } = await rig(t, () => now);
  const token = await api.token();
  writeFileSync(path, JSON.stringify(fixture()));
  const res = await api.request('/v1/status', { token });
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('cache-control'), 'no-store');
  assert.deepEqual(res.body.data.supervisor, {
    status: 'ok', checkedAt: '2026-11-26T10:30:00.000Z', nextCheckBy: '2026-11-26T10:35:00.000Z',
    tickDurationMs: 2840, inspectP95Ms: 620.5, vmPressureLevel: 1,
    counts: { runningAll: 6, stalled: 0 }, slaBreachCount: 1, cronLintWarningCount: 1,
  });
  assert.equal(JSON.stringify(res.body).includes(secret), false);
  writeFileSync(path, JSON.stringify(fixture('stalled')));
  assert.equal((await api.request('/v1/status', { token })).body.data.supervisor.status, 'stalled');
  now++;
  assert.equal((await api.request('/v1/status', { token })).body.data.supervisor.status, 'stale');
});

test('status rejects incomplete, invalid and reversed supervisor timestamps without failing the endpoint', async (t) => {
  const { api, path } = await rig(t);
  const token = await api.token();
  const { checkedAt, nextCheckBy, ...raw } = fixture();
  for (const timing of [{}, { checkedAt }, { nextCheckBy },
    { checkedAt, nextCheckBy: 'not-a-timestamp' },
    { checkedAt: '2026-02-30T10:30:00Z', nextCheckBy },
    { checkedAt, nextCheckBy: '2026-11-26T24:00:00Z' },
    { checkedAt, nextCheckBy: '2026-11-26T11:00:00+01:00' },
    { checkedAt: '2026-11-26T10:35:00.0009Z', nextCheckBy: '2026-11-26T11:35:00.0001+01:00' }]) {
    writeFileSync(path, JSON.stringify({ ...raw, ...timing }));
    const res = await api.request('/v1/status', { token });
    assert.equal(res.status, 200);
    assert.deepEqual(res.body.data.supervisor, { status: 'missing' }, JSON.stringify(timing));
  }
});

test('status bounds supervisor precision and checks the normalized UTC year', async (t) => {
  const { api, path } = await rig(t);
  const token = await api.token();
  const statusFor = async (timing) => {
    writeFileSync(path, JSON.stringify({ ...fixture(), ...timing }));
    const res = await api.request('/v1/status', { token });
    assert.equal(res.status, 200);
    return res.body.data.supervisor.status;
  };
  const invalid = {
    'overprecision in checkedAt': { checkedAt: '2026-11-26T10:30:00.1234567890Z' },
    'long fraction in nextCheckBy': { nextCheckBy: `2026-11-26T10:35:00.${'0'.repeat(16_384)}1Z` },
    'UTC underflow': { checkedAt: '0001-01-01T00:00:00+01:00' },
    'UTC overflow': { nextCheckBy: '9999-12-31T23:59:59-01:00' },
    'unrepresentable local year': { checkedAt: '0000-12-31T23:59:59-01:00' },
  };
  for (const [name, timing] of Object.entries(invalid)) assert.equal(await statusFor(timing), 'missing', name);
  assert.equal(await statusFor({ checkedAt: '2026-11-26T10:35:00.1234Z',
    nextCheckBy: '2026-11-26T11:35:00.123400000+01:00' }), 'ok');
  assert.equal(await statusFor({ checkedAt: '0001-01-01T00:00:00Z',
    nextCheckBy: '9999-12-31T23:59:59Z' }), 'ok');
});

test('missing, malformed, oversized or symlinked status is not reported as healthy', async (t) => {
  const { api, path } = await rig(t);
  const token = await api.token();
  const assertMissing = async () => {
    const res = await api.request('/v1/status', { token });
    assert.equal(res.status, 200);
    assert.deepEqual(res.body.data.supervisor, { status: 'missing' });
  };
  await assertMissing();
  for (const content of ['{', JSON.stringify(fixture('future')), JSON.stringify({ ...fixture(), nextCheckBy: secret }),
    ' '.repeat(256 * 1024 + 1)]) {
    writeFileSync(path, content);
    await assertMissing();
  }
  unlinkSync(path);
  const target = join(api.dir, 'other.json');
  writeFileSync(target, JSON.stringify(fixture()));
  symlinkSync(target, path);
  await assertMissing();
});

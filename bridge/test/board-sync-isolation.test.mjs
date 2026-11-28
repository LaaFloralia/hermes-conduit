import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { DEFAULT_SCOPES, IDEMPOTENCY_RETENTION_MS } from '../src/config.mjs';
import { createDecisionService } from '../src/decisions/service.mjs';
import { createDecisionStore } from '../src/decisions/store.mjs';
import { BridgeError } from '../src/errors.mjs';
import { createBridge, errorForLog } from '../src/http.mjs';
import { laneClient } from '../src/lane/client.mjs';
import { createOwnerNotifier } from '../src/notify/index.mjs';
import { DEFAULT_KINDS } from '../src/notify/preferences.mjs';
import { issuePairing } from '../src/pairing.mjs';
import { StateFileError } from '../src/routes/state-file.mjs';
import { createStore } from '../src/store.mjs';
import { clearInheritedAdapters, startBridge } from './helpers.mjs';

const epoch = Date.parse('2026-11-24T22:56:31.626Z');
const source = { paseoAgentId: '019af000-0000-8000-8000-000000000001', sessionId: 'ses_0123456789abcdef', name: 'Lab Work' };
const fixtureRows = [303, 352].map((length, i) => ({
  id: `dec_000000000000000${i + 1}`, ref: null, title: '判断の試験', summary: '文'.repeat(length),
  options: [{ label: 'あ'.repeat(10), detail: '文'.repeat(62), recommended: true },
    { label: 'い'.repeat(7), detail: '文'.repeat(27), recommended: false },
    { label: 'う'.repeat(5), detail: '文'.repeat(35), recommended: false }],
  allowOther: true, impact: `【必ず社長：本人認証】${'文'.repeat(64)}`, deadline: null, source, requestId: `fixture-${i}`,
  createdAt: new Date(epoch + i * 600_000).toISOString(), answer: null, delivery: null,
}));
const routes = ['/v1/sessions', '/v1/decisions'];
const writeRows = (dir, records) => writeFileSync(join(dir, 'decisions.json'), JSON.stringify({
  schema: 1, records: records.map((r) => ({ ...r, status: 'open', updatedAt: r.createdAt })), operations: {}, notifications: {},
}));

for (const [index, record] of fixtureRows.entries()) {
  test(`board ${index + 1}: failing lane notifier cannot break either HTTP list or retry on polls`, async (t) => {
    clearInheritedAdapters(t);
    const root = mkdtempSync(join(tmpdir(), 'laa-lane-'));
    const env = { LAA_LANE_ID: 'decision-sync-test', LAA_LANE_ROOT: root, LAA_BRIDGE_PORT: '0', HOME: join(root, 'home'),
      TMPDIR: join(root, 'tmp'), LAA_BRIDGE_STATE_DIR: join(root, 'state'), LAA_BRIDGE_BRAIN_ROOT: join(root, 'brain') };
    const previous = Object.fromEntries(Object.keys(env).map((key) => [key, process.env[key]]));
    for (const dir of [env.HOME, env.TMPDIR, env.LAA_BRIDGE_STATE_DIR, env.LAA_BRIDGE_BRAIN_ROOT]) mkdirSync(dir);
    Object.assign(process.env, env);
    let bridge;
    t.after(async () => {
      try { await bridge?.close(); } finally {
        for (const [key, value] of Object.entries(previous)) {
          if (value === undefined) delete process.env[key];
          else process.env[key] = value;
        }
        rmSync(root, { recursive: true, force: true });
      }
    });
    let time = Date.parse(record.createdAt);
    const now = () => time;
    const store = createStore({ dir: env.LAA_BRIDGE_STATE_DIR, idempotencyRetentionMs: IDEMPOTENCY_RETENTION_MS, now });
    const logs = [];
    bridge = createBridge({ store, now, log: (entry) => logs.push(entry), testEndpoints: false });
    const { port } = await bridge.listen({ host: '127.0.0.1', port: 0 });
    const request = laneClient(`http://127.0.0.1:${port}`, env.LAA_LANE_ID);
    const paired = issuePairing(store, { name: 'Lab', scopes: DEFAULT_SCOPES, ttlMs: 60_000, now: now() });
    const enrolled = await request('/v1/devices/enroll', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ code: paired.code, name: 'Lab' }) });
    assert.equal(enrolled.status, 201);
    const { data: { token } } = await enrolled.json();
    const get = async (path) => {
      const result = await request(path, { headers: { authorization: `Bearer ${token}` } });
      return { status: result.status, body: await result.json() };
    };
    assert.deepEqual((await Promise.all(routes.map(get))).map((r) => r.status), [200, 200]);
    const sink = join(root, 'sink', 'notify.jsonl');
    mkdirSync(sink, { recursive: true }); // Fail the existing synthetic notifier adapter, never real egress.
    writeRows(store.dir, [record]);
    const initial = await Promise.all(routes.map(get));
    assert.deepEqual(initial.map((r) => [r.status, r.body.error?.code ?? null]), [[200, null], [200, null]]);
    assert.deepEqual(initial[1].body.data.items.map((r) => r.id), [record.id]);
    assert.equal((await get('/v1/projects')).status, 200);
    assert.equal(logs.filter((entry) => entry.event === 'decision_notification_retry').length, 1);
    assert.equal(createDecisionStore({ dir: store.dir, now }).notificationDone(record.id, 'new'), false);
    rmSync(sink, { recursive: true });
    time += 4_999;
    assert.equal((await get('/v1/decisions')).status, 200);
    assert.throws(() => readFileSync(sink), { code: 'ENOENT' });
    time += 1;
    assert.equal((await get('/v1/sessions')).status, 200);
    assert.equal(JSON.parse(readFileSync(sink)).kind, 'decision.new');
    assert.equal(createDecisionStore({ dir: store.dir, now }).notificationDone(record.id, 'new'), true);
    assert.equal((await get('/v1/decisions')).status, 200);
    assert.equal(readFileSync(sink, 'utf8').trim().split('\n').length, 1);
  });
}

function localService(t, options = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'decision-sync-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  let time = epoch;
  const now = () => time;
  const store = createDecisionStore({ dir, now });
  writeRows(dir, fixtureRows);
  const service = createDecisionService({ store, now, ...options });
  return { dir, store, service, advance: (ms) => { time += ms; } };
}

test('both payloads fit unabridged; an outbox-state failure has the redacted log shape and does not block other notices', async (t) => {
  const attempts = [0, 0], events = [], errors = [];
  let unavailable = true;
  const f = localService(t, { notify: async (notice) => {
    const i = fixtureRows.findIndex((r) => r.id === notice.meta.id);
    attempts[i]++;
    try { return await (i === 0 && unavailable ? broken : healthy)(notice); }
    catch (error) { errors.push(errorForLog(error)); throw error; }
  } });
  const deliver = async (event) => { events.push(event); return { delivered: true }; };
  const badFile = join(f.dir, 'bad-notify.json');
  writeFileSync(badFile, '{broken');
  const broken = createOwnerNotifier({ file: badFile, deliver });
  const healthy = createOwnerNotifier({ file: join(f.dir, 'healthy-notify.json'), deliver });
  await f.service.sync();
  assert.deepEqual(attempts, [1, 1]);
  assert.deepEqual(errors, [{ error: 'Error' }]);
  await f.service.sync();
  assert.deepEqual(attempts, [1, 1]);
  f.advance(5_000);
  await f.service.sync();
  assert.deepEqual(attempts, [2, 1]);
  unavailable = false;
  f.advance(9_999);
  await f.service.sync();
  assert.deepEqual(attempts, [2, 1]);
  f.advance(1);
  await f.service.sync();
  assert.deepEqual(attempts, [3, 1]);
  for (const r of fixtureRows) {
    assert.equal(f.store.notificationDone(r.id, 'new'), true);
    const event = events.find((n) => n.session_id.includes(r.id));
    const meta = JSON.parse(Buffer.from(event.session_id.split('#')[1], 'base64url'));
    assert(Buffer.byteLength(event.session_id) <= 512);
    assert.deepEqual(meta.o, r.options.map((o) => o.label));
  }
});

test('a durable outbox handoff owns delivery retry; an unqueued refusal is retried by board sync', async (t) => {
  let f, attempts = 0, sends = 0;
  const deliver = async () => ({ delivered: ++sends > 1 });
  f = localService(t, { notify: async (e) => {
    if (e.meta.id === fixtureRows[1].id) return { delivered: ++attempts > 1 };
    return notify(e);
  } });
  const notify = createOwnerNotifier({ file: join(f.dir, 'outbox.json'), deliver });
  await f.service.sync();
  await f.service.sync();
  assert.deepEqual([sends, attempts], [1, 1]);
  assert.equal(f.store.notificationDone(fixtureRows[0].id, 'new'), true);
  assert.equal(f.store.notificationDone(fixtureRows[1].id, 'new'), false);
  f.advance(5_000);
  await f.service.sync();
  assert.deepEqual([sends, attempts], [1, 2]);
  await notify.flush();
  assert.deepEqual([sends, attempts], [2, 2]);
});

test('schema-less notification preferences allow a decision to reach the durable outbox', async (t) => {
  const logs = [], events = [], errors = [];
  const bridge = await startBridge({ now: () => epoch, log: (entry) => logs.push(entry), decisions: { notify: async (event) => {
    try { return await notify(event); }
    catch (e) { errors.push({ name: e.name, code: e.code }); throw e; }
  } } });
  t.after(bridge.close);
  const token = await bridge.token();
  const preferenceFile = join(bridge.stateDir, 'notification-preferences.json');
  const original = JSON.stringify({ kinds: { ...DEFAULT_KINDS, decision: 'quiet' }, updatedAt: new Date(epoch).toISOString() });
  writeFileSync(preferenceFile, original);
  const file = join(bridge.stateDir, 'owner-notifications.json');
  writeFileSync(file, JSON.stringify({ schema: 1, delivered: {}, pending: {} }));
  const notify = createOwnerNotifier({ file, now: () => epoch, deliver: async (event) => {
    events.push(event);
    return { delivered: events.length > 1 };
  } });
  const [record] = fixtureRows;
  writeRows(bridge.stateDir, [record]);
  const [sessions, decisions] = await Promise.all(routes.map((path) => bridge.request(path, { token })));
  assert.equal(sessions.status, 200);
  assert.equal(decisions.status, 200);
  assert.equal(decisions.body.data.items.length, 1);
  assert.deepEqual(errors, []);
  assert.equal(events.length, 1);
  assert.equal(logs.filter((e) => e.event === 'decision_notification_retry').length, 0);
  assert.equal(createDecisionStore({ dir: bridge.stateDir, now: () => epoch }).notificationDone(record.id, 'new'), true);
  const pending = () => Object.values(JSON.parse(readFileSync(file, 'utf8')).pending);
  assert.equal(pending().length, 1);
  assert.equal(pending()[0].kind, 'decision.new');
  assert.equal(JSON.parse(Buffer.from(events[0].session_id.split('#')[1], 'base64url')).lv, 'p');
  await notify.flush();
  assert.equal(events.length, 2);
  assert.equal(events[1].event_id, events[0].event_id);
  assert.equal(pending().length, 0);
  assert.equal((await bridge.request('/v1/decisions', { token })).status, 200);
  assert.equal(events.length, 2);
  assert.equal(readFileSync(preferenceFile, 'utf8'), original);
});

test('a decision maintenance error cannot break either HTTP list', async (t) => {
  let refAttempts = 0;
  const logs = [];
  const bridge = await startBridge({ now: () => epoch, log: (entry) => logs.push(entry), decisions: {
    observeRefs: () => { refAttempts++; throw new StateFileError('state_corrupt', 'fixture path'); }, notify: null,
  } });
  t.after(bridge.close);
  const token = await bridge.token();
  writeRows(bridge.stateDir, fixtureRows);
  for (let i = 0; i < 2; i++) {
    const [sessions, decisions] = await Promise.all(routes.map((path) => bridge.request(path, { token })));
    assert.equal(sessions.status, 200);
    assert.equal(decisions.status, 200);
    assert.equal(decisions.body.data.items.length, 2);
  }
  assert.equal(refAttempts, 1);
  assert.deepEqual(logs.filter((entry) => entry.event === 'decision_sync_retry'), [{ level: 'error', event: 'decision_sync_retry' }]);
});

test('unexpected lookup rejections do not close an open decision', async (t) => {
  const f = localService(t, { notify: null, daemon: { status: async () => { throw null; } } });
  assert.equal((await f.service.list()).items.length, 2);
  assert.equal(f.store.all().filter((r) => r.status === 'open').length, 2);
});

test('an uncorroborated 404 keeps the decision open; the same lookup plus confirmed deletion retires it', async (t) => {
  let deleted = false;
  const f = localService(t, { notify: null, daemon: { status: async () => { throw new BridgeError(404, 'not_found', 'temporary miss'); } },
    sessionStore: { all: () => fixtureRows.slice(0, 1).map((r) => ({ id: r.source.sessionId, delegate: { sessionId: r.source.paseoAgentId },
      daemonDeletedAt: deleted ? new Date(epoch).toISOString() : null })) } });
  assert.equal((await f.service.list()).items.length, 2);
  deleted = true;
  assert.equal((await f.service.list()).items.length, 0);
  assert(f.store.all().every((r) => r.status === 'withdrawn'));
});

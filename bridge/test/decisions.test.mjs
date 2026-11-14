import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtempSync, rmSync, readFileSync, writeFileSync, statSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn, spawnSync } from 'node:child_process';
import { createDecisionStore } from '../src/decisions/store.mjs';
import { createDecisionService } from '../src/decisions/service.mjs';
import { createSessionStore } from '../src/sessions/store.mjs';
import { createSessionService } from '../src/sessions/service.mjs';
import { daemonAdapter, daemonSessionID } from '../src/sessions/daemon.mjs';
import { BridgeError } from '../src/errors.mjs';
import { startBridge } from './helpers.mjs';
import { createRefService } from '../src/refs/service.mjs';

const cli = fileURLToPath(new URL('../bin/laa-bridge', import.meta.url));
const request = (extra = {}) => ({ title: '公開日を決める', summary: '公開準備が完了しました。日付を選んでください。',
  options: [{ label: '明日', detail: null, recommended: false }, { label: '来週', detail: '確認時間を確保', recommended: true }],
  requestId: 'decision-1', source: { paseoAgentId: 'agent-1', name: 'HP｜公開' }, ...extra });
function fixture(t, options = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'laa-decisions-test-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  let time = Date.parse('2026-11-08T00:00:00Z');
  const now = () => time;
  const store = createDecisionStore({ dir, now });
  const notifications = [], sent = [];
  let afterSend = false;
  const daemon = { status: async () => ({ daemonStatus: afterSend ? 'running' : 'idle', activeTurn: afterSend, pending: [], updatedAt: new Date(time - 1000).toISOString() }),
    send: async (id, message) => { sent.push({ id, ...message }); afterSend = true; } };
  const service = createDecisionService({ store, now, daemon, notify: async (e) => { notifications.push(e); return { delivered: true }; }, ...options });
  return { dir, store, service, notifications, sent, daemon, now, advance: (ms) => { time += ms; } };
}
const code = (expected) => (e) => e.code === expected;

test('store: shared add identity, recommended first, controls removed, no extra fields, 0600', (t) => {
  const f = fixture(t);
  const a = f.service.add(request({ title: '公開\n日\0を決める', secret: 'must not persist' })).decision;
  assert.match(a.id, /^dec_[0-9a-f]{16}$/);
  assert.equal(a.title, '公開日を決める');
  assert.equal(a.ref, null);
  assert.equal(a.source.sessionId, daemonSessionID('agent-1'));
  assert.deepEqual(a.options.map((o) => o.label), ['来週', '明日']);
  assert.equal(f.service.add(request({ title: '別の題名' })).decision.id, a.id);
  assert.notEqual(f.service.add(request({ source: { paseoAgentId: 'agent-2' } })).decision.id, a.id);
  assert.equal(statSync(f.store.file).mode & 0o777, 0o600);
  assert(!readFileSync(f.store.file, 'utf8').includes('must not persist'));
  const second = createDecisionStore({ dir: f.dir, now: f.now });
  assert.equal(second.get(a.id).title, a.title);
  assert(!('requestId' in f.service.get(a.id)));
});

test('store: field limits, invalid options/deadlines and free answers are rejected', (t) => {
  const f = fixture(t);
  for (const extra of [ { title: 'x'.repeat(61) }, { summary: 'x'.repeat(601) }, { options: [] },
    { options: [{ label: 'x'.repeat(81) }, { label: 'y' }] }, { options: [{ label: 'x', detail: 'a'.repeat(201) }, { label: 'y' }] },
    { options: [{ label: 'x', recommended: true }, { label: 'y', recommended: true }] }, { allowOther: 'yes' },
    { deadline: 'tomorrow' }, { deadline: '2026-02-30T00:00:00Z' }, { impact: 'x'.repeat(201) }, { requestId: '\n' }, { source: { name: 'x'.repeat(201) } } ]) {
    assert.throws(() => f.service.add(request(extra)), code('decision_invalid'));
  }
  const r = f.service.add(request({ allowOther: false })).decision;
  assert.throws(() => f.store.reserve(r.id, 'phone', { requestId: 'free', optionIndex: null, note: '自由回答' }), code('decision_invalid'));
  for (const optionIndex of [-1, 2, '0', 0.5]) assert.throws(() => f.store.reserve(r.id, 'phone', { requestId: 'bad', optionIndex }), code('decision_invalid'));
  assert.throws(() => f.store.reserve(r.id, 'phone', { requestId: 'bad', optionIndex: 0, note: 'x'.repeat(601) }), code('decision_invalid'));
});

test('store: corrupt JSON and invalid schema refuse writes without resetting', (t) => {
  const f = fixture(t);
  f.service.add(request());
  const invalidRecord = JSON.parse(readFileSync(f.store.file, 'utf8'));
  invalidRecord.records[0].options[0].label = '';
  for (const raw of ['{bad', '{"schema":9}', '{"schema":1,"records":{},"operations":{},"notifications":{}}', JSON.stringify(invalidRecord)]) {
    writeFileSync(f.store.file, raw);
    assert.throws(() => f.store.all(), code('decisions_store_unavailable'));
    assert.throws(() => f.service.add(request()), code('decisions_store_unavailable'));
    assert.equal(readFileSync(f.store.file, 'utf8'), raw);
  }
});

test('answer: fixed Japanese text, stable message id, readback, device replay, closed conflicts', async (t) => {
  const f = fixture(t);
  const r = f.service.add(request()).decision;
  const body = { requestId: 'answer-1', optionIndex: 0, note: 'お願いします' };
  const a = await f.service.answer({ id: r.id, deviceId: 'phone', body });
  assert.equal(a.decision.delivery.state, 'delivered');
  assert.equal(a.decision.answer.deviceId, 'phone');
  assert.deepEqual(f.sent, [{ id: 'agent-1', messageId: `${r.id}:answer:1`, text: `【判断ボードの回答】${r.id}「公開日を決める」\n選択: 来週\n補足: お願いします\n（社長が判断ボードで選びました。この判断で作業を続けてください。）` }]);
  assert.deepEqual(await f.service.answer({ id: r.id, deviceId: 'phone', body }), a);
  assert.equal(f.sent.length, 1);
  await assert.rejects(f.service.answer({ id: r.id, deviceId: 'phone', body: { ...body, optionIndex: 1 } }), code('decision_request_conflict'));
  await assert.rejects(f.service.answer({ id: r.id, deviceId: 'other', body }), code('decision_closed'));
  assert.deepEqual((await f.service.list()).items, []);
});

test('answer: no agent stores free answer for CLI without daemon or notification', async (t) => {
  const f = fixture(t, { daemon: null });
  const r = f.service.add(request({ source: {} })).decision;
  assert.equal(r.source.sessionId, null);
  const a = await f.service.answer({ id: r.id, deviceId: 'phone', body: { requestId: 'free', optionIndex: null, note: '再来週' } });
  assert.equal(a.decision.delivery.state, 'stored');
  assert.equal(a.decision.answer.label, '再来週');
  assert.equal(f.sent.length, 0);
  assert.equal(f.store.get(r.id).answer.label, '再来週');
});

// A conversation that no longer exists cannot take the answer: it leaves the
// board without a 届いていません notice, and 届け直す is refused (owner, 2026-11-14).
for (const failure of ['not_found', 'agent_archived']) {
  test(`delivery: ${failure} retires the answer instead of asking for a resend`, async (t) => {
    const f = fixture(t);
    f.daemon.status = async () => {
      if (failure === 'agent_archived') return { archivedAt: '2026-11-08' };
      throw new BridgeError(404, failure, 'do not leak details');
    };
    const r = f.service.add(request()).decision;
    const a = await f.service.answer({ id: r.id, deviceId: 'phone', body: { requestId: 'answer', optionIndex: 0 } });
    assert.equal(a.decision.status, 'answered');
    assert.equal(a.decision.delivery.state, 'gone');
    assert.equal(a.decision.delivery.error, failure);
    assert.equal((await f.service.list()).items.length, 0);
    await f.service.sync();
    assert.equal(f.notifications.filter((e) => e.kind === 'decision.failed').length, 0);
    await assert.rejects(f.service.answer({ id: r.id, deviceId: 'phone', body: { requestId: 'retry' }, retry: true }), code('decision_closed'));
    assert.equal(f.sent.length, 0);
  });
}

for (const failure of ['pending_decision_requires_reply', 'paseo_unavailable', 'delivery_unconfirmed']) {
  test(`delivery: ${failure} stays answered, visible, notifies once and retry uses next attempt`, async (t) => {
    const f = fixture(t);
    const normal = f.daemon.status;
    f.daemon.status = async () => {
      if (failure === 'pending_decision_requires_reply') return { pending: [{}] };
      if (failure === 'delivery_unconfirmed') return { daemonStatus: 'idle', updatedAt: '2026-11-07T00:00:00Z' };
      throw new BridgeError(503, failure, 'do not leak details');
    };
    const r = f.service.add(request()).decision;
    const a = await f.service.answer({ id: r.id, deviceId: 'phone', body: { requestId: 'answer', optionIndex: 0 } });
    assert.equal(a.decision.status, 'answered');
    assert.equal(a.decision.delivery.state, 'failed');
    assert.equal(a.decision.delivery.error, failure);
    assert.equal((await f.service.list()).items[0].id, r.id);
    await f.service.sync();
    assert.equal(f.notifications.filter((e) => e.kind === 'decision.failed').length, 1);
    f.daemon.status = normal;
    const retried = await f.service.answer({ id: r.id, deviceId: 'phone', body: { requestId: 'retry' }, retry: true });
    assert.equal(retried.decision.delivery.state, 'delivered');
    assert.equal(retried.decision.delivery.messageId, `${r.id}:answer:2`);
    assert.equal(retried.decision.delivery.attempts, 2);
    await f.service.answer({ id: r.id, deviceId: 'phone', body: { requestId: 'retry' }, retry: true });
    assert.equal(f.sent.filter((m) => m.messageId.endsWith(':2')).length, 1);
    await assert.rejects(f.service.answer({ id: r.id, deviceId: 'phone', body: { requestId: 'retry-again' }, retry: true }), code('decision_closed'));
  });
}

test('delivery: updatedAt advancement confirms an already completed turn; unknown errors are redacted', async (t) => {
  const f = fixture(t);
  let calls = 0;
  f.daemon.status = async () => ({ updatedAt: new Date(f.now() + (++calls > 1 ? 1000 : -1000)).toISOString(), daemonStatus: 'idle' });
  const r = f.service.add(request()).decision;
  assert.equal((await f.service.answer({ id: r.id, deviceId: 'phone', body: { requestId: 'a', optionIndex: 1 } })).decision.delivery.state, 'delivered');
  const other = f.service.add(request({ requestId: 'two' })).decision;
  f.daemon.send = async () => { throw new Error('private-path-and-secret'); };
  const failed = await f.service.answer({ id: other.id, deviceId: 'phone', body: { requestId: 'b', optionIndex: 0 } });
  assert.equal(failed.decision.delivery.error, 'paseo_unavailable');
  assert(!readFileSync(f.store.file, 'utf8').includes('private-path-and-secret'));
});

test('concurrent answers cannot send twice; interrupted pending delivery becomes retryable', async (t) => {
  const f = fixture(t);
  const r = f.service.add(request()).decision;
  let release;
  f.daemon.send = async () => { await new Promise((resolve) => { release = resolve; }); };
  const a = f.service.answer({ id: r.id, deviceId: 'phone', body: { requestId: 'a', optionIndex: 0 } });
  await new Promise((resolve) => setImmediate(resolve));
  await assert.rejects(f.service.answer({ id: r.id, deviceId: 'phone2', body: { requestId: 'b', optionIndex: 1 } }), code('decision_closed'));
  assert.equal((await f.service.answer({ id: r.id, deviceId: 'phone', body: { requestId: 'a', optionIndex: 0 } })).decision.delivery.state, 'pending');
  release(); await a;
  const other = f.service.add(request({ requestId: 'two' })).decision;
  f.store.reserve(other.id, 'phone', { requestId: 'crash', optionIndex: 0 });
  f.advance(61_000); await f.service.sync();
  assert.equal(f.store.get(other.id).delivery.error, 'delivery_unconfirmed');
});

test('list: failures first, deadlines then newest, native questions merged, archived and deleted excluded, dynamic refs', async (t) => {
  const sessionStore = { all: () => [
    { id: 'ses_1111111111111111', name: 'Native question', phase: 'awaiting_decision', pending: { kinds: ['question'] }, createdAt: '2026-11-06T00:00:00Z' },
    { id: 'ses_2222222222222222', phase: 'awaiting_decision', archivedAt: '2026-11-08' },
    { id: 'ses_3333333333333333', phase: 'awaiting_decision', daemonArchivedAt: '2026-11-08' },
    { id: 'ses_4444444444444444', phase: 'awaiting_decision', daemonDeletedAt: '2026-11-08' },
  ] };
  const sessions = { syncDaemon: async () => {}, decision: async () => ({ requests: [{ questions: [{ question: '選んでください' }] }] }) };
  const f = fixture(t, { sessionStore, sessions, refs: (kind) => kind === 'session' ? 'S3' : 'J1' });
  const later = f.service.add(request({ requestId: 'later', deadline: '2026-11-10T00:00:00Z' })).decision;
  const early = f.service.add(request({ requestId: 'early', deadline: '2026-11-09T00:00:00Z' })).decision;
  f.advance(1000);
  const newest = f.service.add(request({ requestId: 'newest' })).decision;
  const failed = f.service.add(request({ requestId: 'failed', deadline: '2026-11-20T00:00:00Z' })).decision;
  const reserved = f.store.reserve(failed.id, 'phone', { requestId: 'answer', optionIndex: 0 }).decision;
  f.store.settle(failed.id, reserved.delivery.messageId, 'failed', 'paseo_unavailable');
  const items = (await f.service.list()).items;
  assert.deepEqual(items.map((r) => r.id ?? r.sessionId), [failed.id, early.id, later.id, newest.id, 'ses_1111111111111111']);
  assert.equal(items[0].ref, 'J1'); assert.equal(items[0].sourceRef, 'S3');
  assert.equal(f.store.get(failed.id).ref, null);
  assert.equal(items.at(-1).summary, '選んでください'); assert.deepEqual(items.at(-1).kinds, ['question']);
});

test('notifications: CLI file is detected, new is deduplicated across restart, finished suppressed only while open', async (t) => {
  const f = fixture(t);
  const sessionStore = createSessionStore({ file: join(f.dir, 'sessions.json'), now: f.now });
  let status = 'running';
  const daemon = { list: async () => [{ id: 'agent-1', title: 'HP', status, createdAt: new Date(f.now()).toISOString(), updatedAt: new Date(f.now()).toISOString() }], workspacePins: async () => [] };
  const notifications = [];
  const sessions = createSessionService({ sessionStore, daemon, adapter: {}, decisions: f.service, notify: async (n) => { notifications.push(n); }, now: f.now });
  await sessions.syncDaemon();
  const otherStore = createDecisionStore({ dir: f.dir, now: f.now });
  const r = otherStore.add(request()).decision;
  status = 'idle'; f.advance(1000); await sessions.syncDaemon();
  assert.equal(notifications.length, 0);
  assert.equal(f.notifications.length, 1);
  assert.equal(f.notifications[0].kind, 'decision.new');
  assert.equal(f.notifications[0].body, '推奨: 来週');
  assert.equal(f.notifications[0].deepLink, `laa://work/decisions/${r.id}`);
  await createDecisionService({ store: otherStore, notify: async () => { assert.fail('duplicate after restart'); } }).sync();
  f.service.withdraw(r.id, '自分で解決');
  status = 'running'; f.advance(1000); await sessions.syncDaemon();
  status = 'idle'; f.advance(1000); await sessions.syncDaemon();
  assert.equal(notifications[0].kind, 'session.finished');
});

test('history: retain closed 30 days; prune closed records, operations, notifications; retain open', async (t) => {
  const f = fixture(t);
  const open = f.service.add(request()).decision;
  const withdrawn = f.service.add(request({ requestId: 'withdraw' })).decision;
  f.service.withdraw(withdrawn.id, '解決');
  assert.equal(f.service.withdraw(withdrawn.id, '再試行').status, 'withdrawn');
  const answered = f.service.add(request({ requestId: 'answer', source: {} })).decision;
  await f.service.answer({ id: answered.id, deviceId: 'phone', body: { requestId: 'a', optionIndex: 1 } });
  assert.throws(() => f.service.withdraw(answered.id, '変更'), code('decision_closed'));
  f.advance(29 * 86400_000); assert.equal(f.store.all().length, 3);
  f.advance(2 * 86400_000); await f.service.sync();
  assert.deepEqual(f.store.all().map((r) => r.id), [open.id]);
  assert.deepEqual(JSON.parse(readFileSync(f.store.file, 'utf8')).operations, {});
  assert.notEqual(f.service.add(request({ requestId: 'withdraw' })).decision.id, withdrawn.id);
});

test('HTTP: authenticated read, reply scope, idempotency and closed detail history', async (t) => {
  const f = fixture(t);
  const r = f.service.add(request()).decision;
  const h = await startBridge({ decisions: { service: f.service } });
  t.after(() => h.close());
  const reader = await h.token(['sessions:read']);
  const writer = await h.token(['sessions:read', 'sessions:write']);
  assert.equal((await h.request('/v1/decisions')).status, 401);
  assert.equal((await h.request('/v1/decisions', { token: reader })).body.data.items[0].id, r.id);
  assert.equal((await h.request(`/v1/decisions/${r.id}`, { token: reader })).body.data.id, r.id);
  const path = `/v1/decisions/${r.id}/answer`;
  const body = { optionIndex: 0, requestId: 'http' };
  assert.equal((await h.request(path, { method: 'POST', token: reader, key: 'read-only', body })).status, 403);
  assert.equal((await h.request(path, { method: 'POST', token: writer, body })).status, 400);
  assert.equal((await h.request(path, { method: 'POST', token: writer, key: 'one', body: '{bad' })).status, 400);
  const a = await h.request(path, { method: 'POST', token: writer, key: 'two', body });
  assert.equal(a.status, 200); assert.equal(a.body.data.decision.delivery.state, 'delivered');
  assert.equal((await h.request(path, { method: 'POST', token: writer, key: 'two', body })).status, 200);
  assert.equal((await h.request(path, { method: 'POST', token: writer, key: 'three', body })).status, 200);
  assert.equal(f.sent.length, 1);
  assert.equal((await h.request(path, { method: 'POST', token: writer, key: 'four', body: { ...body, requestId: 'second' } })).status, 409);
  assert.equal((await h.request(`/v1/decisions/${r.id}`, { token: reader })).body.data.status, 'answered');
});

test('HTTP integration: CLI file + native questions, existing reply tickets, failed delivery retry through shared daemon', async (t) => {
  const agents = [
    { id: 'board-agent', title: '公開の会話', status: 'idle', createdAt: '2026-11-08T00:00:00Z', updatedAt: '2026-11-08T00:00:00Z' },
    { id: 'native-agent', title: '質問の会話', status: 'idle', createdAt: '2026-11-08T00:00:00Z', updatedAt: '2026-11-08T00:00:00Z', pendingPermissions: [{ id: 'question-1', kind: 'question', name: 'request_user_input_async', input: { questions: [{ title: 'どちらにしますか', options: ['A', 'B'] }] } }] },
  ];
  const sent = [], replied = [], notifications = [];
  let fail = true;
  const daemon = daemonAdapter({ connect: async () => ({
    fetchAgents: async () => ({ entries: agents.map((agent) => ({ agent })), pageInfo: {} }),
    fetchWorkspaces: async () => ({ entries: [] }),
    fetchAgent: async ({ agentId }) => ({ agent: agents.find((a) => a.id === agentId) }),
    sendMessage: async (id, message, options) => { if (fail) throw new Error('unavailable'); sent.push({ id, message, options }); Object.assign(agents[0], { status: 'running', activeTurn: { id: 'new-turn' } }); },
    respondToPermissionAndWait: async (id, requestId, response) => { replied.push({ id, requestId, response }); agents[1].pendingPermissions = []; },
    close: async () => {},
  }) });
  const h = await startBridge({ sessions: { daemon, notify: async () => {} }, decisions: { notify: async (e) => { notifications.push(e); return { delivered: true }; } },
    refs: (stateDir) => createRefService({ file: join(stateDir, 'refs.json') }) });
  t.after(() => h.close());
  const token = await h.token();
  await h.request('/v1/sessions', { token });
  await h.refs.observeSource('session');
  const added = runCli(h.stateDir, ['add', '--title', '公開日', '--summary', '公開日を選んでください', '--option', '明日', '--option', '来週', '--agent', 'board-agent', '--request-id', 'http-cli', '--json']);
  assert.equal(added.status, 0, added.stderr);
  const r = JSON.parse(added.stdout).decision;
  assert.equal(r.source.name, '公開の会話');
  const board = await h.request('/v1/decisions', { token });
  assert.equal(board.status, 200); assert.equal(board.body.data.items.length, 2);
  assert.equal(board.body.data.items.find((i) => i.kind === 'session').summary, 'どちらにしますか');
  assert.equal(notifications.filter((n) => n.kind === 'decision.new').length, 1);
  // The decision holds J1 from the first sync, and the notice carries it.
  const boardItem = board.body.data.items.find((i) => i.kind === 'board');
  assert.equal(boardItem.ref, 'J1'); assert.match(boardItem.sourceRef, /^S\d+$/);
  assert.equal(notifications.find((n) => n.kind === 'decision.new').title, '判断 J1: 公開日');
  assert.equal(h.refs.resolve('j1').holder.kind, 'decision');
  const native = daemonSessionID('native-agent');
  const ticket = (await h.request(`/v1/sessions/${native}/decision`, { token })).body.data;
  const reply = await h.request(`/v1/sessions/${native}/reply`, { method: 'POST', token, key: 'native-answer', body: { requestHash: ticket.requestHash, expiresAt: ticket.expiresAt, requestId: 'question-1', decision: 'answer', answers: { '0': 'B' } } });
  assert.equal(reply.status, 200); assert.equal(replied[0].response.updatedInput.answers['Question 1'], 'B');
  const answer = await h.request(`/v1/decisions/${r.id}/answer`, { method: 'POST', token, key: 'board-answer', body: { requestId: 'answer', optionIndex: 1 } });
  assert.equal(answer.status, 200); assert.equal(answer.body.data.decision.delivery.state, 'failed');
  fail = false;
  const retry = await h.request(`/v1/decisions/${r.id}/retry`, { method: 'POST', token, key: 'board-retry', body: { requestId: 'retry' } });
  assert.equal(retry.status, 200); assert.equal(retry.body.data.decision.delivery.state, 'delivered');
  assert.equal(sent[0].options.activeTurnBehavior, 'steer'); assert.equal(sent[0].options.messageId, `${r.id}:answer:2`);
  assert(!sent[0].message.includes('補足:'));
  assert.equal((await h.request('/v1/decisions', { token })).body.data.items.length, 0);
  // Delivered: the board no longer holds it, so J1 is released.
  await h.refs.observeSource('decision');
  assert.equal(h.refs.refFor('decision', r.id), null); assert.equal(h.refs.resolve('J1').status, 'released');
  assert.equal(JSON.parse(runCli(h.stateDir, ['status', r.id, '--json']).stdout).decision.delivery.state, 'delivered');
});

test('daemon: delivery snapshot keeps activeTurn and archive state without changing native question view', async () => {
  const agent = { id: 'agent', title: 'Title', status: 'idle', activeTurn: { id: 'turn' }, archivedAt: '2026-11-07', pendingPermissions: [{ id: 'q', kind: 'question', name: 'request_user_input_async', input: { questions: [{ title: '質問', options: ['はい', 'いいえ'] }] } }] };
  const adapter = daemonAdapter({ connect: async () => ({ fetchAgent: async () => ({ agent }), fetchWorkspaces: async () => ({ entries: [] }), close: async () => {} }) });
  const status = await adapter.status('agent');
  assert.equal(status.activeTurn, true); assert.equal(status.archivedAt, '2026-11-07'); assert.equal(status.phase, 'awaiting_decision');
  const d = await adapter.decision('agent');
  assert.deepEqual(d.requests[0].questions, [{ question: '質問', options: ['はい', 'いいえ'] }]);
});

function runCli(dir, args) {
  return spawnSync(cli, ['decide', ...args], { env: { ...process.env, PASEO_AGENT_ID: '', LAA_BRIDGE_STATE_DIR: dir }, encoding: 'utf8' });
}
test('real CLI: add/status/list/withdraw, replay, usage/not-found/conflict/input/store exit codes', (t) => {
  const f = fixture(t);
  const args = ['add', '--title', '判断', '--summary', '説明', '--option', '案A::詳細', '--option', '案B', '--recommended', '2', '--no-other', '--request-id', 'cli', '--json'];
  const added = runCli(f.dir, args); assert.equal(added.status, 0, added.stderr);
  const r = JSON.parse(added.stdout).decision;
  assert.equal(r.options[0].label, '案B'); assert.equal(r.allowOther, false);
  assert.equal(JSON.parse(runCli(f.dir, args).stdout).decision.id, r.id);
  assert.equal(JSON.parse(runCli(f.dir, ['status', r.id, '--json']).stdout).decision.status, 'open');
  assert.equal(JSON.parse(runCli(f.dir, ['list', '--json']).stdout).items.length, 1);
  // Listing from CLI must leave the server's notification untouched.
  assert.equal(f.store.notificationDone(r.id, 'new'), false);
  assert.equal(runCli(f.dir, ['withdraw', r.id, '--reason', '解決', '--json']).status, 0);
  assert.equal(JSON.parse(runCli(f.dir, ['list', '--json']).stdout).items.length, 0);
  assert.equal(runCli(f.dir, ['status', 'dec_0000000000000000', '--json']).status, 3);
  assert.equal(runCli(f.dir, ['add']).status, 2);
  assert.equal(runCli(f.dir, ['add', '--title']).status, 2);
  assert.equal(runCli(f.dir, ['list', '--unknown', 'x']).status, 2);
  assert.equal(runCli(f.dir, args.map((v) => v === '判断' ? 'x'.repeat(61) : v)).status, 5);
  const answered = f.service.add(request({ source: {}, requestId: 'stored' })).decision;
  f.store.reserve(answered.id, 'phone', { requestId: 'stored-answer', optionIndex: 0 });
  assert.equal(runCli(f.dir, ['withdraw', answered.id, '--reason', '解決']).status, 4);
  writeFileSync(f.store.file, '{bad');
  assert.equal(runCli(f.dir, ['list', '--json']).status, 6);
});

test('real CLI: shows the J number the server assigned and accepts it for status, without writing refs.json', (t) => {
  const f = fixture(t);
  const added = runCli(f.dir, ['add', '--title', '番号', '--summary', '説明', '--option', 'A', '--option', 'B', '--request-id', 'cli-ref', '--json']);
  assert.equal(added.status, 0, added.stderr);
  const id = JSON.parse(added.stdout).decision.id;
  assert.equal(JSON.parse(added.stdout).decision.ref, null);
  assert.equal(existsSync(join(f.dir, 'refs.json')), false, 'the CLI never creates the registry');
  // The server numbers it (here: the same registry the server uses).
  createRefService({ file: join(f.dir, 'refs.json') }).observe('decision', [{ key: id, title: '番号', createdAt: new Date().toISOString(), external: {} }]);
  const status = runCli(f.dir, ['status', 'j1', '--json']);
  assert.equal(status.status, 0, status.stderr);
  assert.equal(JSON.parse(status.stdout).decision.id, id);
  assert.equal(JSON.parse(status.stdout).decision.ref, 'J1');
  assert.equal(JSON.parse(runCli(f.dir, ['list', '--json']).stdout).items[0].ref, 'J1');
});

test('real concurrent CLI writers keep one record for one idempotency key', async (t) => {
  const f = fixture(t);
  const args = ['decide', 'add', '--title', '判断', '--summary', '説明', '--option', 'A', '--option', 'B', '--request-id', 'race', '--json'];
  const run = () => new Promise((resolve, reject) => {
    const child = spawn(cli, args, { env: { ...process.env, PASEO_AGENT_ID: '', LAA_BRIDGE_STATE_DIR: f.dir }, stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '', err = ''; child.stdout.on('data', (b) => { out += b; }); child.stderr.on('data', (b) => { err += b; });
    child.on('error', reject); child.on('close', (status) => { if (status !== 0) reject(new Error(err)); else resolve(JSON.parse(out).decision.id); });
  });
  const ids = await Promise.all([run(), run(), run(), run()]);
  assert.equal(new Set(ids).size, 1); assert.equal(f.store.all().length, 1);
});

// A conversation in the middle of a turn refuses a second foreground prompt.
function busyFixture(t, options = {}) {
  const f = fixture(t, options);
  const state = { busy: true, archived: false, down: false, raceOnce: false };
  f.daemon.status = async () => {
    if (state.down) throw new BridgeError(503, 'paseo_unavailable', 'down');
    return { daemonStatus: state.busy ? 'running' : 'idle', activeTurn: state.busy, pending: [], archivedAt: state.archived ? '2026-11-08T00:00:00Z' : null,
      updatedAt: new Date(f.now() - 1000).toISOString() };
  };
  f.daemon.send = async (id, message) => {
    if (state.busy || state.raceOnce) { state.raceOnce = false; throw new BridgeError(409, 'session_busy', 'busy'); }
    f.sent.push({ id, ...message }); state.busy = true;
  };
  return { ...f, state };
}
const failedNotices = (f) => f.notifications.filter((e) => e.kind === 'decision.failed');

test('waiting: an answer to a busy conversation waits, stays on the board without a failure notice, then is delivered once the turn ends', async (t) => {
  const f = busyFixture(t);
  const r = f.service.add(request()).decision;
  const a = await f.service.answer({ id: r.id, deviceId: 'phone', body: { requestId: 'answer', optionIndex: 0 } });
  assert.equal(a.decision.delivery.state, 'pending');
  assert.equal(a.decision.delivery.waiting, true);
  assert.equal(a.decision.delivery.error, null);
  // Past the 60 s interruption rule and several checks: still waiting, never failed.
  for (let i = 0; i < 20; i += 1) { f.advance(15_000); await f.service.deliverWaiting(); }
  const listed = (await f.service.list()).items.find((i) => i.id === r.id);
  assert.equal(listed.delivery.state, 'pending'); assert.equal(listed.delivery.waiting, true);
  assert.equal(failedNotices(f).length, 0); assert.equal(f.sent.length, 0);
  // The owner cannot pile retries onto a waiting answer.
  await assert.rejects(f.service.answer({ id: r.id, deviceId: 'phone', body: { requestId: 'retry' }, retry: true }), code('decision_closed'));
  f.state.busy = false;
  f.advance(15_000); await f.service.deliverWaiting();
  const done = f.store.get(r.id);
  assert.equal(done.delivery.state, 'delivered');
  assert.equal(done.delivery.messageId, `${r.id}:answer:1`);
  assert(!('waiting' in done.delivery) && !('waitingSince' in done.delivery) && !('holds' in done.delivery));
  assert.deepEqual(f.sent.map((m) => m.messageId), [`${r.id}:answer:1`]);
  assert.equal((await f.service.list()).items.length, 0);
  assert.equal(failedNotices(f).length, 0);
});

test('waiting: one send per answer across concurrent passes, a lost race and later passes', async (t) => {
  const f = busyFixture(t);
  const r = f.service.add(request()).decision;
  await f.service.answer({ id: r.id, deviceId: 'phone', body: { requestId: 'answer', optionIndex: 0 } });
  // The turn ended, but another prompt wins the race: the answer goes back to waiting.
  f.state.busy = false; f.state.raceOnce = true;
  f.advance(15_000); await f.service.deliverWaiting();
  assert.equal(f.store.get(r.id).delivery.waiting, true); assert.equal(f.store.get(r.id).delivery.holds, 2);
  assert.equal(f.sent.length, 0);
  f.advance(15_000);
  await Promise.all([f.service.deliverWaiting(), f.service.deliverWaiting(), f.service.deliverWaiting()]);
  assert.equal(f.store.get(r.id).delivery.state, 'delivered');
  // A second service on the same file (the CLI, or the next Bridge) finds nothing left to send.
  const other = createDecisionService({ store: createDecisionStore({ dir: f.dir, now: f.now }), now: f.now, daemon: f.daemon, notify: null });
  f.state.busy = false; f.advance(60_000);
  await other.deliverWaiting(); await f.service.deliverWaiting();
  assert.equal(f.sent.length, 1);
  // A send claimed by a Bridge that then stopped is never repeated: it becomes a visible failure.
  const second = f.service.add(request({ requestId: 'two' })).decision;
  f.state.busy = true;
  await f.service.answer({ id: second.id, deviceId: 'phone', body: { requestId: 'answer-2', optionIndex: 0 } });
  const held = f.store.get(second.id);
  assert(f.store.release(second.id, held.delivery.messageId)); // claimed, then the Bridge died mid-send
  assert.equal(f.store.release(second.id, held.delivery.messageId), null);
  f.state.busy = false; f.advance(61_000);
  await other.deliverWaiting(); await other.sync();
  assert.equal(f.store.get(second.id).delivery.state, 'failed');
  assert.equal(f.store.get(second.id).delivery.error, 'delivery_unconfirmed');
  assert.equal(f.sent.length, 1);
});

test('waiting: an archived or deleted conversation leaves the board quietly; a stopped Paseo and an expired wait fail visibly, once', async (t) => {
  for (const [failure, arrange] of [
    ['agent_archived', (f) => { f.state.archived = true; }],
    ['not_found', (f) => { f.daemon.status = async () => { throw new BridgeError(404, 'not_found', 'gone'); }; }],
  ]) {
    const f = busyFixture(t);
    const r = f.service.add(request()).decision;
    await f.service.answer({ id: r.id, deviceId: 'phone', body: { requestId: 'answer', optionIndex: 0 } });
    arrange(f);
    f.advance(15_000); await f.service.deliverWaiting(); await f.service.deliverWaiting();
    assert.equal((await f.service.list()).items.find((i) => i.id === r.id), undefined);
    const gone = f.store.get(r.id);
    assert.equal(gone.delivery.state, 'gone'); assert.equal(gone.delivery.error, failure);
    assert(!('waiting' in gone.delivery));
    assert.equal(failedNotices(f).length, 0);
    assert.equal(f.sent.length, 0);
  }
  // Paseo restarting is tolerated for five minutes; stopped for longer is a failure.
  const f = busyFixture(t);
  const r = f.service.add(request()).decision;
  await f.service.answer({ id: r.id, deviceId: 'phone', body: { requestId: 'answer', optionIndex: 0 } });
  f.state.down = true;
  f.advance(15_000); await f.service.deliverWaiting();
  f.advance(120_000); await f.service.deliverWaiting();
  assert.equal(f.store.get(r.id).delivery.waiting, true);
  f.state.down = false; f.advance(15_000); await f.service.deliverWaiting();
  f.state.down = true;
  for (let i = 0; i < 6; i += 1) { f.advance(60_000); await f.service.deliverWaiting(); }
  assert.equal(f.store.get(r.id).delivery.error, 'paseo_unavailable');
  assert.equal(failedNotices(f).length, 1);
  // A day of a busy conversation ends the wait; that failure is not picked up again.
  const g = busyFixture(t);
  const d = g.service.add(request()).decision;
  await g.service.answer({ id: d.id, deviceId: 'phone', body: { requestId: 'answer', optionIndex: 0 } });
  g.advance(86_400_000 + 1); await g.service.deliverWaiting(); await g.service.deliverWaiting();
  assert.equal(g.store.get(d.id).delivery.error, 'delivery_wait_expired');
  assert.equal(failedNotices(g).length, 1);
  g.state.busy = false;
  const retried = await g.service.answer({ id: d.id, deviceId: 'phone', body: { requestId: 'retry' }, retry: true });
  assert.equal(retried.decision.delivery.state, 'delivered'); assert.equal(retried.decision.delivery.attempts, 2);
});

test('waiting: survives a Bridge restart, and an answer an earlier Bridge filed as failed(session_busy) is picked up', async (t) => {
  const f = busyFixture(t);
  const r = f.service.add(request()).decision;
  await f.service.answer({ id: r.id, deviceId: 'phone', body: { requestId: 'answer', optionIndex: 0 } });
  // Written by the Bridge before this change.
  const old = f.service.add(request({ requestId: 'old', source: { paseoAgentId: 'agent-2' } })).decision;
  const reserved = f.store.reserve(old.id, 'phone', { requestId: 'old-answer', optionIndex: 1 }).decision;
  f.store.settle(old.id, reserved.delivery.messageId, 'failed', 'session_busy');
  const other = f.service.add(request({ requestId: 'other', source: { paseoAgentId: 'agent-3' } })).decision;
  const kept = f.store.reserve(other.id, 'phone', { requestId: 'other-answer', optionIndex: 1 }).decision;
  f.store.settle(other.id, kept.delivery.messageId, 'failed', 'agent_archived');
  // The stored shape stays readable by the store's own validation.
  const raw = JSON.parse(readFileSync(f.store.file, 'utf8')).records.find((x) => x.id === r.id).delivery;
  assert.deepEqual(Object.keys(raw).sort(), ['attempts', 'deliveredAt', 'error', 'holds', 'messageId', 'state', 'waiting', 'waitingSince']);
  assert.equal(raw.state, 'pending'); assert.equal(raw.error, null);
  // Restart: a new store and service over the same file.
  f.advance(3_600_000);
  const store = createDecisionStore({ dir: f.dir, now: f.now });
  const notices = [];
  const service = createDecisionService({ store, now: f.now, daemon: f.daemon, notify: async (e) => { notices.push(e); return { delivered: true }; } });
  await service.sync();
  assert.equal(store.get(r.id).delivery.waiting, true);
  await service.deliverWaiting(); // startup pass: still busy
  assert.equal(store.get(old.id).delivery.state, 'pending'); assert.equal(store.get(old.id).delivery.waiting, true);
  assert.equal(store.get(old.id).delivery.messageId, `${old.id}:answer:1`);
  assert.equal(store.get(other.id).delivery.error, 'agent_archived');
  assert.equal(f.sent.length, 0);
  f.state.busy = false;
  f.advance(60_000); await service.deliverWaiting();
  f.state.busy = false;
  f.advance(60_000); await service.deliverWaiting();
  assert.deepEqual(f.sent.map((m) => `${m.id} ${m.messageId}`).sort(), [`agent-1 ${r.id}:answer:1`, `agent-2 ${old.id}:answer:1`].sort());
  assert.equal(store.get(r.id).delivery.state, 'delivered'); assert.equal(store.get(old.id).delivery.state, 'delivered');
  assert.equal(notices.filter((e) => e.kind === 'decision.failed' && e.dedupeKey.startsWith(r.id)).length, 0);
});

test('gone: an asker that is archived, deleted or past its deadline leaves the board, and its answer is never resent', async (t) => {
  const agents = { 'agent-1': { archivedAt: null }, 'agent-2': { archivedAt: '2026-11-08T00:00:00Z' } };
  const daemon = {
    status: async (id) => {
      if (id === 'agent-down') throw new BridgeError(503, 'paseo_unavailable', 'down');
      if (!agents[id]) throw new BridgeError(404, 'not_found', 'Paseo agent not found');
      return { daemonStatus: 'idle', activeTurn: false, pending: [], updatedAt: new Date(0).toISOString(), ...agents[id] };
    },
    send: async () => { throw new BridgeError(404, 'not_found', 'Paseo agent not found'); },
  };
  const f = fixture(t, { daemon });
  const kept = f.service.add(request({ requestId: 'kept' })).decision;
  const archived = f.service.add(request({ requestId: 'archived', source: { paseoAgentId: 'agent-2' } })).decision;
  const deleted = f.service.add(request({ requestId: 'deleted', source: { paseoAgentId: 'agent-9' } })).decision;
  const unreachable = f.service.add(request({ requestId: 'unreachable', source: { paseoAgentId: 'agent-down' } })).decision;
  const expired = f.service.add(request({ requestId: 'expired', deadline: '2026-11-08T12:00:00Z' })).decision;
  // Answered while its conversation was already gone: the delivery failed with not_found.
  const lost = f.service.add(request({ requestId: 'lost', source: { paseoAgentId: 'agent-7' } })).decision;
  const answered = await f.service.answer({ id: lost.id, deviceId: 'phone', body: { requestId: 'a1', optionIndex: 0 } });
  // Retired at once: not 届いていません, not 届け直す.
  assert.equal(answered.decision.delivery.state, 'gone');
  assert.equal(answered.decision.delivery.error, 'not_found');
  f.advance(86_400_000);
  const ids = (await f.service.list()).items.map((r) => r.id);
  // Paseo being unreachable is not proof the conversation is gone.
  assert.deepEqual(ids.sort(), [kept.id, unreachable.id].sort());
  assert.equal(f.store.get(archived.id).status, 'withdrawn');
  assert.equal(f.store.get(deleted.id).status, 'withdrawn');
  assert.equal(f.store.get(expired.id).status, 'withdrawn');
  const gone = f.store.get(lost.id);
  assert.equal(gone.status, 'answered');
  assert.equal(gone.delivery.state, 'gone');
  assert.equal(gone.delivery.error, 'not_found');
  assert.equal(gone.answer.label, '来週');
  // The board's 届け直す has nothing to send to: the retry is refused, nothing is sent.
  await assert.rejects(f.service.answer({ id: lost.id, deviceId: 'phone', body: { requestId: 'r1' }, retry: true }), code('decision_closed'));
  // The record still reads back (detail, history) and survives a reload.
  assert.equal(createDecisionStore({ dir: f.dir, now: f.now }).get(lost.id).delivery.state, 'gone');
});

test('add: a short Paseo id resolves to the one full id it names', (t) => {
  const sessionStore = { all: () => [
    { id: 'ses_aaaaaaaaaaaaaaaa', delegate: { sessionId: 'c0e83149-0f40-4f25-b29b-64f3bcf126d6' } },
    { id: 'ses_bbbbbbbbbbbbbbbb', delegate: { sessionId: 'd1111111-0000-4000-8000-000000000001' } },
    { id: 'ses_cccccccccccccccc', delegate: { sessionId: 'd1111111-0000-4000-8000-000000000002' } },
  ] };
  const f = fixture(t, { sessionStore });
  assert.equal(f.service.add(request({ requestId: 's1', source: { paseoAgentId: 'c0e83149' } })).decision.source.paseoAgentId, 'c0e83149-0f40-4f25-b29b-64f3bcf126d6');
  // Ambiguous or unknown prefixes are kept as given.
  assert.equal(f.service.add(request({ requestId: 's2', source: { paseoAgentId: 'd1111111' } })).decision.source.paseoAgentId, 'd1111111');
  assert.equal(f.service.add(request({ requestId: 's3', source: { paseoAgentId: 'e2222222' } })).decision.source.paseoAgentId, 'e2222222');
});

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

for (const failure of ['not_found', 'agent_archived', 'pending_decision_requires_reply', 'paseo_unavailable', 'delivery_unconfirmed']) {
  test(`delivery: ${failure} stays answered, visible, notifies once and retry uses next attempt`, async (t) => {
    const f = fixture(t);
    const normal = f.daemon.status;
    f.daemon.status = async () => {
      if (failure === 'agent_archived') return { archivedAt: '2026-11-08' };
      if (failure === 'pending_decision_requires_reply') return { pending: [{}] };
      if (failure === 'delivery_unconfirmed') return { daemonStatus: 'idle', updatedAt: '2026-11-07T00:00:00Z' };
      throw new BridgeError(failure === 'not_found' ? 404 : 503, failure, 'do not leak details');
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

test('list: failures first, deadlines then newest, native questions merged, archived excluded, dynamic refs', async (t) => {
  const sessionStore = { all: () => [
    { id: 'ses_1111111111111111', name: 'Native question', phase: 'awaiting_decision', pending: { kinds: ['question'] }, createdAt: '2026-11-06T00:00:00Z' },
    { id: 'ses_2222222222222222', phase: 'awaiting_decision', archivedAt: '2026-11-08' },
    { id: 'ses_3333333333333333', phase: 'awaiting_decision', daemonArchivedAt: '2026-11-08' },
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

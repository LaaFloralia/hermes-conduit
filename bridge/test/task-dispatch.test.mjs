import assert from 'node:assert/strict';
import test from 'node:test';
import { createHash } from 'node:crypto';
import { EventEmitter } from 'node:events';
import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { BridgeError } from '../src/errors.mjs';
import { createTaskRunStore, createTaskDispatchService, taskCleanup, taskAssignee, TASK_STAFF } from '../src/tasks/dispatch.mjs';
import { createSessionStore } from '../src/sessions/store.mjs';
import { createSessionService } from '../src/sessions/service.mjs';
import { createDecisionStore } from '../src/decisions/store.mjs';
import { createRefService } from '../src/refs/service.mjs';

const ID = '00000000-0000-4000-8000-000000000001';
const OTHER = '00000000-0000-4000-8000-000000000002';
const CHILD = 'ses_1234567890abcdef';
const options = { profiles: [{ id: 'opus-high', label: 'Opus 5.5', effort: 'high' }, { id: 'sol-high', label: 'GPT Sol', effort: 'high' }] };
const staff = { kind: 'staff', staff: 'monet', name: 'Monet' };
const sha = (v) => createHash('sha256').update(v).digest('hex');

function fixture(t) {
  const dir = mkdtempSync(join(tmpdir(), 'laa-task-dispatch-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  let clock = Date.parse('2026-11-09T10:00:00Z'), profiles = options, failure = null;
  const now = () => clock, stamp = () => new Date(clock).toISOString();
  const store = createTaskRunStore({ dir, now }), sessionStore = createSessionStore({ file: join(dir, 'sessions.json'), now });
  const decisionStore = createDecisionStore({ dir, now });
  const refs = createRefService({ file: join(dir, 'refs.json'), now });
  const tasksById = new Map([[ID, { id: ID, identifier: 'BUS-401', title: '資料を直す', description: '本文を読んで更新する', priority: 2, dueDate: '2026-11-10', status: 'todo', updatedAt: stamp(), archivedAt: null }]]);
  const events = [], comments = new Map(), agents = new Map(), creates = [], bodies = [];
  const f = { dir, now, stamp, store, sessionStore, decisionStore, refs, tasksById, events, comments, creates, bodies,
    failures: 0, unknownOutcomes: 0, cleanupCount: 0,
    advance(ms) { clock += ms; }, profiles(v) { profiles = v; }, failAt(v) { failure = v; } };
  const fail = (stage) => { events.push(stage); if (failure === stage) { failure = null; throw new BridgeError(503, `${stage}_unavailable`, 'not echoed', { retryable: true }); } };
  const tasks = {
    async readOwnerTask(id) { fail('read'); return structuredClone(tasksById.get(id) ?? null); },
    async prepareCompletion() { fail('config'); },
    async commentOwnerTask(id, comment) {
      const stage = comment.body.startsWith('[laa-bridge] 完了') ? 'comment' : 'pickup_comment';
      fail(stage);
      if (comments.has(comment.id)) assert.deepEqual(comments.get(comment.id), { issueId: id, ...comment });
      comments.set(comment.id, { issueId: id, ...comment });
    },
    async completeOwnerTask(id) { fail('done'); const task = tasksById.get(id); assert.ok(task); task.status = 'done'; task.updatedAt = stamp(); },
  };
  const adapter = {
    async create(input) {
      creates.push(structuredClone(input));
      if (f.failures-- > 0) throw new BridgeError(503, 'delegation_unavailable', 'lin_api_SECRET', { retryable: true });
      const prior = agents.get(input.requestId);
      if (prior) assert.deepEqual(input, prior.input);
      else agents.set(input.requestId, { input, sessionId: 'agent-root' });
      if (f.unknownOutcomes-- > 0) throw new BridgeError(409, 'creation_outcome_unknown', 'unknown', { retryable: true });
      return { sessionId: 'agent-root', requested: { profile: input.profile, provider: 'claude', model: 'opus', effort: 'high' } };
    },
    async status() { return { phase: 'awaiting_review', daemonStatus: 'idle', pending: [] }; },
  };
  const underlying = createSessionService({ sessionStore, adapter, notify: null, now, homeCwd: '/Users/laa', findWorkspace: () => null });
  const sessions = { ...underlying,
    createSession(input) { bodies.push(structuredClone(input.body)); return underlying.createSession(input); },
    async updateSession(input) { fail(input.body.archived ? 'archive' : 'unpin'); return underlying.updateSession(input); },
  };
  const realWithdraw = decisionStore.withdraw;
  decisionStore.withdraw = (id, reason) => { assert.equal(reason, 'タスク完了'); fail('withdraw'); return realWithdraw(id, reason); };
  const realRelease = refs.release;
  refs.release = (kind, id) => { if (kind === 'task') fail('release'); return realRelease(kind, id); };
  const service = createTaskDispatchService({ store, tasks, sessions, sessionStore, decisionStore, refs,
    sessionOptions: () => profiles, now, cleanup() { f.cleanupCount += 1; fail('cleanup'); }, log() {} });
  return Object.assign(f, { tasks, service, sessions, agents,
    record(assignee = staff) { refs.assign('task', ID, tasksById.get(ID).title, { linear: 'BUS-401' }); return service.accept({ task: tasksById.get(ID), deviceId: 'device-test', assignee, profile: assignee.kind === 'owner' ? null : 'opus-high' }); },
    complete(overrides = {}) { return service.complete({ id: ID, deviceId: 'device-test', key: 'complete-1', expected: '2026-11-09T10:00:00.000Z', ...overrides }); },
    child() { const root = store.get(ID).sessionId; sessionStore.create({ record: { id: CHILD, parentId: root, delegate: { sessionId: 'agent-child' }, name: '子｜確認', phase: 'awaiting_review', favorite: false, archivedAt: null, createdAt: stamp(), updatedAt: stamp() } }); return CHILD; },
    decision(source = {}) { return decisionStore.add({ title: '選択', summary: '必要な判断', options: [{ label: '進む' }, { label: '保留' }], requestId: `decision-${decisionStore.all().length}`, source }).decision; },
  });
}

test('owner create records once; the execution file is 0600, bounded and pruned after 30 days', (t) => {
  const f = fixture(t), first = f.record({ kind: 'owner' });
  assert.equal(first.phase, 'owner'); assert.equal(first.creator, 'owner'); assert.equal(first.sessionId, null);
  assert.deepEqual(f.record({ kind: 'owner' }), first); assert.equal(f.store.all().length, 1);
  assert.equal(statSync(f.store.file).mode & 0o777, 0o600);
  assert.equal(f.service.view(ID).state, null);
  assert.throws(() => f.record(), { code: 'task_assignment_conflict' });
  f.store.update(ID, (r) => { r.phase = 'completed'; r.completedAt = f.stamp(); });
  f.advance(30 * 86400_000 - 1); assert.equal(f.store.all().length, 1);
  f.advance(1); f.store.prune(); assert.equal(f.store.all().length, 0);
});

test('malformed JSON and invalid execution records fail closed without replacing the file', (t) => {
  const f = fixture(t); f.record();
  for (const broken of ['{', '{"schema":1,"records":[]}', JSON.stringify({ ...JSON.parse(readFileSync(f.store.file)), records: [{ ...f.store.get(ID), creator: 'agent' }] })]) {
    writeFileSync(f.store.file, broken);
    assert.throws(() => f.store.all(), { status: 503, code: 'task_runs_store_unavailable' });
    assert.throws(() => f.store.record({}), { code: 'task_runs_store_unavailable' });
    assert.equal(readFileSync(f.store.file, 'utf8'), broken);
  }
});

test('only listed employees and selectable profiles are accepted', () => {
  assert.deepEqual(taskAssignee({}, options), { assignee: { kind: 'owner' }, profile: null });
  for (const [id, who] of Object.entries(TASK_STAFF)) assert.deepEqual(taskAssignee({ assignee: { kind: 'staff', staff: id }, profile: 'opus-high' }, options).assignee, { kind: 'staff', staff: id, name: who.name });
  for (const body of [{ assignee: null }, { assignee: { kind: 'staff', staff: 'unknown' }, profile: 'opus-high' }, { assignee: { kind: 'staff', staff: 'monet' } },
    { assignee: { kind: 'staff', staff: 'monet' }, profile: 'alias' }, { profile: null }, { assignee: { kind: 'owner', staff: 'monet' } }]) {
    assert.throws(() => taskAssignee(body, options), { status: 400 });
  }
});

test('pickup creates a HOME bypass session with the fixed request and full instructions, without pinning it', async (t) => {
  const f = fixture(t); f.record({ kind: 'staff', staff: 'cfo', name: 'Morgan' });
  assert.equal(f.service.view(ID).state, 'queued'); await f.service.pickup(ID);
  const r = f.store.get(ID), body = f.bodies[0], actual = f.creates[0];
  assert.equal(r.phase, 'started'); assert.equal(r.attempts, 1); assert.equal(r.sessionId, f.sessions.sessionIdFor(`task-${ID}`));
  assert.equal(body.requestId, `task-${ID}`); assert.equal(body.name, '資料を直す'); assert.equal(body.workspaceId, 'home');
  assert.equal(actual.cwd, '/Users/laa'); assert.equal(actual.mode, 'bypass'); assert.equal(actual.profile, 'opus-high');
  assert.match(body.prompt, /\/roles\/Monet\/SOUL.md/); assert.match(body.prompt, /Morgan（CFO）/); assert.match(body.prompt, /\/roles\/CFO\/SOUL.md/);
  assert.match(body.prompt, /本文を読んで更新する/); assert.match(body.prompt, /2026-11-10/); assert.match(body.purpose, /T1（BUS-401）/);
  assert.match(body.completion, new RegExp(`tasks report ${ID}`)); assert.match(body.scope, /判断ボード/); assert.match(body.scope, /アーカイブしない/);
  assert.equal(f.sessionStore.get(r.sessionId).favorite, false);
  assert.match([...f.comments.values()][0].body, /^\[laa-bridge\] Monetが取得（S1・Morgan・Opus 5.5 · High）$/);
  assert.equal(f.service.view(ID).sessionRef, 'S1'); assert.equal(f.service.view(ID).profileLabel, 'Opus 5.5 · High');
  await f.service.pickup(ID); assert.equal(f.creates.length, 1); assert.equal(f.comments.size, 1);
});

test('owner and unrecorded tasks never launch a session, including during recovery ticks', async (t) => {
  const f = fixture(t); f.record({ kind: 'owner' }); await f.service.tick();
  assert.equal(f.creates.length, 0); assert.equal(f.service.view(OTHER), null);
});

test('pickup retry uses 1m, 5m, 15m, 60m and then 60m backoff without a retry cap', async (t) => {
  const f = fixture(t); f.record(); f.failures = 5;
  for (const wait of [60_000, 300_000, 900_000, 3600_000, 3600_000]) {
    await f.service.tick(); const r = f.store.get(ID);
    assert.equal(r.phase, 'queued'); assert.equal(Date.parse(r.nextAttemptAt) - f.now(), wait);
    assert.equal(r.lastError, 'delegation_unavailable'); assert.ok(!JSON.stringify(r).includes('SECRET'));
    const count = f.creates.length; await f.service.tick(); assert.equal(f.creates.length, count); f.advance(wait);
  }
  await f.service.tick(); assert.equal(f.store.get(ID).phase, 'started'); assert.equal(f.store.get(ID).attempts, 6);
  assert.equal(new Set(f.bodies.map((r) => r.requestId)).size, 1);
});

test('an unknown create outcome reconciles to one agent with identical frozen content after an issue edit', async (t) => {
  const f = fixture(t); f.record(); f.unknownOutcomes = 1;
  await f.service.pickup(ID); assert.equal(f.store.get(ID).phase, 'queued'); assert.equal(f.agents.size, 1);
  f.tasksById.get(ID).title = '別の題名'; f.tasksById.get(ID).description = '別の説明';
  f.advance(60_000); await f.service.tick();
  assert.equal(f.store.get(ID).phase, 'started'); assert.equal(f.agents.size, 1); assert.deepEqual(f.bodies[0], f.bodies[1]);
});

test('the brief is frozen at creation, so an issue edit before the pickup never reaches the session', async (t) => {
  const f = fixture(t); f.record();
  f.tasksById.get(ID).title = '別の指示'; f.tasksById.get(ID).description = 'ほかの作業もする';
  await f.service.pickup(ID);
  assert.match(f.bodies[0].prompt, /本文を読んで更新する/); assert.match(f.bodies[0].purpose, /資料を直す/);
  assert.doesNotMatch(JSON.stringify(f.bodies[0]), /別の指示|ほかの作業/);
});

test('a staff record without a frozen brief never launches a session', async (t) => {
  const f = fixture(t);
  f.store.record({ task: f.tasksById.get(ID), deviceId: 'device-test', assignee: staff, profile: 'opus-high' });
  await f.service.pickup(ID);
  assert.equal(f.creates.length, 0); assert.equal(f.store.get(ID).phase, 'failed'); assert.equal(f.store.get(ID).lastError, 'task_brief_missing');
});

test('a removed profile or closed task is a permanent pickup failure', async (t) => {
  const f = fixture(t); f.record(); f.profiles({ profiles: [] }); await f.service.tick();
  assert.equal(f.store.get(ID).phase, 'failed'); assert.equal(f.store.get(ID).lastError, 'task_profile_unknown'); assert.equal(f.service.view(ID).state, 'failed');
  f.advance(86400_000); await f.service.tick(); assert.equal(f.creates.length, 0);
});

test('the pickup comment retries after a report, without launching another session', async (t) => {
  const f = fixture(t); f.record(); f.failAt('pickup_comment'); await f.service.pickup(ID);
  assert.equal(f.store.get(ID).phase, 'started'); await f.service.report(ID, '作成と確認済み', 'agent-root');
  f.advance(60_000); await f.service.tick(); assert.equal(f.comments.size, 1); assert.equal(f.creates.length, 1); assert.equal(f.store.get(ID).report.summary, '作成と確認済み');
});

test('a saved session is linked after the execution-record write fails, even if its profile was removed', async (t) => {
  const f = fixture(t); f.record(); const update = f.store.update; let failLink = true;
  f.store.update = (id, fn) => update(id, (r) => {
    const previous = r.sessionId; fn(r);
    if (failLink && previous === null && r.sessionId !== null) { failLink = false; throw new BridgeError(503, 'task_runs_store_unavailable', 'temporary'); }
  });
  await f.service.pickup(ID); assert.equal(f.store.get(ID).sessionId, null); assert.equal(f.sessionStore.all().length, 1);
  f.profiles({ profiles: [] }); f.advance(60_000); await f.service.tick();
  assert.equal(f.store.get(ID).phase, 'started'); assert.equal(f.creates.length, 1); assert.equal(f.comments.size, 1);
});

test('state derives from queued, running, child decisions, native questions, report and stopped sessions', async (t) => {
  const f = fixture(t); f.record(); assert.equal(f.service.view(ID).state, 'queued');
  await f.service.pickup(ID); const root = f.store.get(ID).sessionId;
  assert.equal(f.service.view(ID).state, 'running');
  f.child(); const d = f.decision({ paseoAgentId: 'agent-child' }); f.refs.assign('decision', d.id, d.title);
  assert.equal(f.service.view(ID).state, 'awaiting_decision'); assert.equal(f.service.view(ID).decisionRef, 'J1');
  f.decisionStore.withdraw(d.id, 'タスク完了'); f.sessionStore.update(CHILD, (r) => { r.phase = 'awaiting_decision'; });
  assert.equal(f.service.view(ID).state, 'awaiting_decision'); assert.equal(f.service.view(ID).decisionRef, null);
  f.sessionStore.update(CHILD, (r) => { r.phase = 'awaiting_review'; });
  f.sessionStore.update(root, (r) => { r.phase = 'error'; }); assert.equal(f.service.view(ID).state, 'stopped');
  await f.service.report(ID, '修正と検証済み', 'agent-root'); assert.equal(f.service.view(ID).state, 'done');
});

test('report accepts UUID, T number and identifier from the root and descendants, and rejects unrelated agents', async (t) => {
  const f = fixture(t); f.record(); await f.service.pickup(ID); f.child();
  for (const [given, agent] of [[ID.toUpperCase(), 'agent-root'], ['Ｔ １', 'agent-child'], ['BUS-401', 'agent-root']]) assert.equal((await f.service.report(given, '完了した', agent)).report.summary, '完了した');
  await assert.rejects(f.service.report(ID, '偽の報告', 'other-agent'), { status: 403, code: 'task_report_forbidden' });
  for (const missing of [null, undefined, '']) await assert.rejects(f.service.report(ID, '名乗らない報告', missing), { status: 403, code: 'task_report_forbidden' });
  await assert.rejects(f.service.report(ID, 'あ'.repeat(601)), { status: 400 }); await assert.rejects(f.service.report(ID, '  '), { status: 400 });
  await assert.rejects(f.service.report(OTHER, 'ない'), { status: 404 });
});

test('a new descendant not yet imported is authorized only by the daemon parent labels', async (t) => {
  const f = fixture(t); f.record(); await f.service.pickup(ID);
  const service = createTaskDispatchService({ store: f.store, sessionStore: f.sessionStore, daemon: { async list() { return [{ id: 'fresh-child', labels: { 'paseo.parent-agent-id': 'middle' } }, { id: 'middle', labels: { 'paseo.parent-agent-id': 'agent-root' } }]; } } });
  await service.report(ID, '子の報告', 'fresh-child');
  await assert.rejects(service.report(ID, '別の会話', 'other'), { status: 403 });
});

test('complete withdraws child decisions, archives the tree, comments, sets Done and releases references before one cleanup', async (t) => {
  const f = fixture(t); f.record(); await f.service.pickup(ID); const root = f.store.get(ID).sessionId; f.child();
  f.refs.assign('session', CHILD, '子'); const a = f.decision({ sessionId: root }), b = f.decision({ paseoAgentId: 'agent-child' });
  const unrelated = f.decision({ paseoAgentId: 'other' }); f.refs.assign('decision', a.id, a.title); f.refs.assign('decision', b.id, b.title);
  f.sessionStore.update(root, (r) => { r.favorite = true; }); await f.service.report(ID, '修正済み。検証成功。残件なし。', 'agent-root');
  f.events.length = 0; const result = await f.complete();
  assert.deepEqual(result.data, { id: ID, completed: true, sessionArchived: true, archive: 'queued' });
  assert.equal(f.decisionStore.get(a.id).status, 'withdrawn'); assert.equal(f.decisionStore.get(b.id).status, 'withdrawn'); assert.equal(f.decisionStore.get(unrelated.id).status, 'open');
  assert.ok(f.sessionStore.get(root).archivedAt); assert.ok(f.sessionStore.get(CHILD).archivedAt); assert.equal(f.sessionStore.get(root).favorite, false);
  assert.equal(f.refs.refFor('session', root), null); assert.equal(f.refs.refFor('session', CHILD), null); assert.equal(f.refs.refFor('task', ID), null); assert.equal(f.refs.refFor('decision', a.id), null);
  assert.match([...f.comments.values()].find((c) => c.body.startsWith('[laa-bridge] 完了')).body, /S1・資料を直す・Monet・Opus 5.5 · High.*\n修正済み/s);
  assert.equal(f.tasksById.get(ID).status, 'done'); assert.equal(f.store.get(ID).phase, 'completed'); assert.equal(f.cleanupCount, 1);
  assert.ok(f.events.indexOf('withdraw') < f.events.indexOf('archive')); assert.ok(f.events.indexOf('archive') < f.events.indexOf('comment')); assert.ok(f.events.indexOf('comment') < f.events.indexOf('done')); assert.ok(f.events.indexOf('done') < f.events.indexOf('release')); assert.ok(f.events.indexOf('release') < f.events.indexOf('cleanup'));
  f.tasksById.clear(); const replay = await f.complete(); assert.equal(replay.replayed, true); assert.equal(f.cleanupCount, 1);
});

for (const stage of ['withdraw', 'archive', 'comment', 'done', 'release']) test(`completion resumes after ${stage} fails, including a store reopen`, async (t) => {
  const f = fixture(t); f.record(); await f.service.pickup(ID); f.child(); f.decision({ paseoAgentId: 'agent-child' });
  f.failAt(stage); await assert.rejects(f.complete(), { status: 503 });
  const reloaded = createTaskRunStore({ dir: f.dir, now: f.now }); assert.ok(reloaded.completion(ID));
  const result = await f.complete(); assert.equal(result.data.completed, true); assert.equal(f.cleanupCount, 1); assert.equal(f.comments.size, 2);
  assert.equal(f.tasksById.get(ID).status, 'done');
});

test('a failed cleanup leaves Done and is not retried by a replay', async (t) => {
  const f = fixture(t); f.record({ kind: 'owner' }); f.failAt('cleanup');
  assert.equal((await f.complete()).data.sessionArchived, false); assert.equal(f.tasksById.get(ID).status, 'done');
  await f.complete(); assert.equal(f.cleanupCount, 1);
});

test('cleanup stays reserved if the final response cannot be committed, so a retry never spawns it twice', async (t) => {
  const f = fixture(t); f.record({ kind: 'owner' }); const advance = f.store.advance; let failFinal = true;
  f.store.advance = (id, stage, patch) => { if (failFinal && stage === 7) { failFinal = false; throw new BridgeError(503, 'task_runs_store_unavailable', 'temporary'); } return advance(id, stage, patch); };
  await assert.rejects(f.complete(), { status: 503 }); assert.equal(f.cleanupCount, 1); assert.equal(f.tasksById.get(ID).status, 'done');
  await f.complete(); assert.equal(f.cleanupCount, 1);
});

for (const legacy of [false, true]) test(`an owner task ${legacy ? 'without' : 'with'} a run record completes without a session`, async (t) => {
  const f = fixture(t); if (!legacy) f.record({ kind: 'owner' });
  const result = await f.complete(); assert.equal(result.data.sessionArchived, false); assert.equal(f.creates.length, 0);
  assert.match([...f.comments.values()][0].body, /完了（社長）\n報告なし/); assert.equal(f.tasksById.get(ID).status, 'done');
  assert.equal(f.store.get(ID)?.phase ?? null, legacy ? null : 'completed');
});

test('a running child refuses completion without any persisted or external change', async (t) => {
  const f = fixture(t); f.record(); await f.service.pickup(ID); f.child(); const d = f.decision({ paseoAgentId: 'agent-child' });
  f.sessionStore.update(CHILD, (r) => { r.phase = 'running'; });
  const before = readFileSync(f.store.file, 'utf8'), comments = f.comments.size; f.events.length = 0;
  await assert.rejects(f.complete(), { status: 409, code: 'session_running' });
  assert.equal(readFileSync(f.store.file, 'utf8'), before); assert.equal(f.decisionStore.get(d.id).status, 'open');
  assert.equal(f.comments.size, comments); assert.equal(f.cleanupCount, 0); assert.deepEqual(f.events, ['read']);
});

test('stale and conflicting completion requests cannot overwrite a reserved operation', async (t) => {
  const f = fixture(t); f.record({ kind: 'owner' });
  await assert.rejects(f.complete({ expected: 'old' }), { status: 412 }); assert.equal(f.store.completion(ID), null);
  f.failAt('comment'); await assert.rejects(f.complete(), { status: 503 });
  await assert.rejects(f.complete({ expected: 'other' }), { code: 'idempotency_key_conflict' });
  await assert.rejects(f.complete({ id: OTHER }), { code: 'idempotency_key_conflict' });
  await f.complete();
});

test('cleanup uses only the fixed done-only command and logs aggregate output plus the exit code', () => {
  const logs = [], child = new EventEmitter(); child.stdout = new EventEmitter(); child.stderr = new EventEmitter(); child.unref = () => {};
  taskCleanup({ log: (v) => logs.push(v), spawnImpl(bin, args, opts) {
    assert.equal(bin, '/Users/laa/.local/bin/laa-agent'); assert.deepEqual(args, ['cleanup', '--done-only']); assert.deepEqual(opts.stdio, ['ignore', 'pipe', 'pipe']); return child;
  } });
  child.stdout.emit('data', 'SECRET title / body\nsaved: 2\ndeleted: 2\n'); child.stderr.emit('data', 'lin_api_SECRET'); child.emit('close', 7);
  assert.deepEqual(logs, [{ event: 'task_cleanup', level: 'error', exitCode: 7, summary: 'saved: 2; deleted: 2' }]);
});

test('cleanup summarizes the existing JSON notes without exposing issue identifiers, titles or errors', () => {
  const logs = [], child = new EventEmitter(); child.stdout = new EventEmitter(); child.stderr = new EventEmitter(); child.unref = () => {};
  taskCleanup({ log: (r) => logs.push(r), spawnImpl: () => child });
  child.stdout.emit('data', JSON.stringify({ notes: ['PRIVATE-ID: logged', 'PRIVATE-ID: deleted', 'PRIVATE-OTHER: changed, kept'] })); child.emit('close', 0);
  assert.equal(logs[0].summary, 'saved: 1; deleted: 1; kept: 1'); assert.ok(!JSON.stringify(logs).includes('PRIVATE'));
});

test('tasks report CLI persists into the same file and validates required flags', async (t) => {
  const f = fixture(t); f.record(); await f.service.pickup(ID);
  const cli = fileURLToPath(new URL('../src/cli.mjs', import.meta.url));
  const call = (given, summary, agent = 'agent-root') => spawnSync(process.execPath, [cli, 'tasks', 'report', given, '--summary', summary, '--json'], { env: { ...process.env, LAA_BRIDGE_STATE_DIR: f.dir, PASEO_AGENT_ID: agent }, encoding: 'utf8', timeout: 15_000 });
  const ok = call('T1', '検証済み'); assert.equal(ok.status, 0, ok.stderr); assert.equal(JSON.parse(ok.stdout).report.summary, '検証済み'); assert.equal(f.store.get(ID).report.summary, '検証済み');
  const noSummary = spawnSync(process.execPath, [cli, 'tasks', 'report', ID, '--json'], { env: { ...process.env, LAA_BRIDGE_STATE_DIR: f.dir }, encoding: 'utf8' });
  assert.equal(noSummary.status, 2); assert.equal(f.store.get(ID).report.summary, '検証済み');
  const anonymous = call('T1', '名乗らない報告', '');
  assert.notEqual(anonymous.status, 0); assert.equal(f.store.get(ID).report.summary, '検証済み');
});

import assert from 'node:assert/strict';
import { readFileSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import test from 'node:test';
import { startBridge } from './helpers.mjs';
import { createPersonalLinearSource } from '../src/tasks/personal.mjs';
import { createTaskOperationLedger } from '../src/tasks/operation-ledger.mjs';

const VIEWER = { id: 'fixture-owner', name: 'Owner' };
function sourceFixture() {
  const calls = [];
  const adapter = {
    calls,
    viewer: VIEWER,
    current: { id: 'linear:BUS-1', linearId: 'issue-uuid', sourceId: 'BUS-1', title: 'remote', description: 'remote text', updatedAt: '2026-11-01T00:00:00Z' },
    async session() { calls.push('viewer'); return { viewer: this.viewer }; },
    async getTaskInSession(_session, id) { calls.push(`read:${id}`); return this.current ? { task: this.current } : null; },
    async createIssue(_session, input) { calls.push({ create: input }); return { id: input.id, identifier: 'BUS-123' }; },
    async updateIssue(_session, id, input) { calls.push({ update: { id, input } }); return { id: 'issue-uuid', identifier: 'BUS-1' }; },
  };
  return adapter;
}
function mutations(source) { return source.calls.filter((call) => typeof call === 'object'); }

async function setup(t, options = {}) {
  const personal = options.personal ?? sourceFixture();
  const api = await startBridge({ tasks: { personal }, ...(options.now ? { now: options.now } : {}) });
  t.after(() => api.close());
  const token = await api.token(['tasks:read', 'tasks:write']);
  return { personal, api, token };
}
function create(api, token, key, body = { teamId: 'team', title: 'private fixture title', description: 'private fixture body' }) {
  return api.request('/v1/personal-tasks', { method: 'POST', token, key, body });
}
function update(api, token, key, body, version) {
  return api.request('/v1/personal-tasks/linear%3ABUS-1', { method: 'PATCH', token, key, body,
    headers: version ? { 'if-match': version } : {} });
}

test('writes require task scope, key and validated fields', async (t) => {
  const { personal, api, token } = await setup(t);
  const readOnly = await api.token(['tasks:read']);
  assert.equal((await create(api, readOnly, 'a')).status, 403);
  assert.equal((await create(api, token, undefined)).body.error.code, 'idempotency_key_required');
  assert.equal((await create(api, token, 'a', { teamId: 'team', title: 'x', delegateId: 'worker' })).status, 400);
  assert.equal((await create(api, token, 'a', { teamId: 'team', title: 'x', dueDate: '2026-02-31' })).status, 400);
  assert.equal(mutations(personal).length, 0);
});

test('creation has a client-independent UUID, replays once, persists no content, and survives restart', async (t) => {
  const { personal, api, token } = await setup(t);
  const first = await create(api, token, 'create-1');
  assert.equal(first.status, 201);
  const op = first.body.data.operation;
  assert.equal(op.status, 'succeeded');
  assert.match(op.targetId, /^[0-9a-f-]{36}$/);
  assert.equal(op.resultId, op.targetId);
  assert.equal(mutations(personal)[0].create.id, op.targetId);
  await api.restart();
  const replay = await create(api, token, 'create-1');
  assert.equal(replay.status, 200);
  assert.equal(replay.body.data.operation.operationId, op.operationId);
  assert.equal(mutations(personal).length, 1);
  const changed = await create(api, token, 'create-1', { teamId: 'team', title: 'different' });
  assert.equal(changed.body.error.code, 'idempotency_key_conflict');
  const record = readFileSync(join(api.stateDir, 'task-operations.json'), 'utf8');
  assert.doesNotMatch(record, /private fixture title|private fixture body/);
  assert.doesNotMatch(readFileSync(join(api.stateDir, 'state.json'), 'utf8'), /private fixture title|private fixture body/);
  assert.equal(api.store.read().taskOperationsInitialized, true);
});

test('attribute updates are last-writer-wins and do not launch any worker', async (t) => {
  const { personal, api, token } = await setup(t);
  const saved = await update(api, token, 'attr', { stateId: 'state', assigneeId: 'someone', priority: 2 }, 'stale');
  assert.equal(saved.status, 200);
  assert.equal(personal.calls.filter((call) => typeof call === 'string' && call.startsWith('read:')).length, 0);
  assert.deepEqual(mutations(personal)[0].update.input, { stateId: 'state', assigneeId: 'someone', priority: 2 });
  assert.equal(mutations(personal).length, 1);
  const changedVersion = await update(api, token, 'attr', { stateId: 'state', assigneeId: 'someone', priority: 2 }, 'other');
  assert.equal(changedVersion.body.error.code, 'idempotency_key_conflict');
});

test('description requires If-Match and returns the current text on conflict without writing', async (t) => {
  const { personal, api, token } = await setup(t);
  assert.equal((await update(api, token, 'no-match', { description: 'local' })).status, 428);
  const conflict = await update(api, token, 'conflict', { description: 'local' }, 'stale');
  assert.equal(conflict.status, 412);
  assert.equal(conflict.body.error.details.current.description, 'remote text');
  assert.equal(mutations(personal).length, 0);
  const repeat = await update(api, token, 'conflict', { description: 'local' }, 'stale');
  assert.equal(repeat.status, 412);
  const chosen = await update(api, token, 'chosen', { description: 'local' }, personal.current.updatedAt);
  assert.equal(chosen.status, 200);
  assert.equal(mutations(personal).length, 1);
});

test('parallel identical submissions cannot both reach Linear', async (t) => {
  const personal = sourceFixture();
  let entered;
  let complete;
  const enteredPromise = new Promise((resolve) => { entered = resolve; });
  const blocker = new Promise((resolve) => { complete = resolve; });
  personal.createIssue = async (_session, input) => { personal.calls.push({ create: input }); entered(); await blocker; return { id: input.id, identifier: 'BUS-123' }; };
  const { api, token } = await setup(t, { personal });
  const first = create(api, token, 'parallel');
  await enteredPromise;
  const second = await create(api, token, 'parallel');
  assert.equal(second.body.error.code, 'idempotency_key_in_flight');
  complete();
  assert.equal((await first).status, 201);
  assert.equal(mutations(personal).length, 1);
});

test('unknown outcomes are retained beyond seven days and require explicit reconciliation', async (t) => {
  let clock = Date.parse('2026-11-01T00:00:00Z');
  const personal = sourceFixture();
  personal.createIssue = async (_session, input) => { personal.calls.push({ create: input }); throw new Error('private upstream output'); };
  const { api, token } = await setup(t, { personal, now: () => clock });
  const sent = await create(api, token, 'lost');
  assert.equal(sent.body.error.code, 'idempotency_outcome_unknown');
  const lookup = await api.request('/v1/task-operations/by-key', { token, key: 'lost' });
  const operationId = lookup.body.data.operation.operationId;
  assert.equal(lookup.body.data.operation.status, 'outcome_unknown');
  clock += 8 * 24 * 60 * 60 * 1000;
  await api.restart();
  assert.equal((await create(api, token, 'lost')).body.error.code, 'idempotency_outcome_unknown');
  const unresolved = await api.request('/v1/task-operations', { token });
  assert.equal(unresolved.body.data.items[0].operationId, operationId);
  const path = `/v1/task-operations/${operationId}/resolve`;
  assert.equal((await api.request(path, { token, key: 'resolve-1', method: 'POST', body: { resolution: 'applied' } })).status, 400);
  const confirmed = await api.request(path, { token, key: 'resolve-1', method: 'POST', body: { confirmed: true, resolution: 'applied' } });
  assert.equal(confirmed.body.data.operation.status, 'resolved');
  const repeated = await api.request(path, { token, key: 'resolve-1', method: 'POST', body: { confirmed: true, resolution: 'applied' } });
  assert.equal(repeated.status, 200);
  const changed = await api.request(path, { token, key: 'resolve-1', method: 'POST', body: { confirmed: true, resolution: 'not_applied' } });
  assert.equal(changed.body.error.code, 'idempotency_key_conflict');
  assert.equal((await create(api, token, 'lost')).body.error.code, 'idempotency_outcome_unknown');
  assert.equal(mutations(personal).length, 1);
});

test('an old successful key is refused after seven days and points at its minimal record', async (t) => {
  let clock = Date.parse('2026-11-01T00:00:00Z');
  const { personal, api, token } = await setup(t, { now: () => clock });
  assert.equal((await create(api, token, 'old')).status, 201);
  clock += 8 * 24 * 60 * 60 * 1000;
  const repeat = await create(api, token, 'old');
  assert.equal(repeat.body.error.code, 'idempotency_outcome_unknown');
  assert.equal(repeat.body.error.details.operation.replayExpired, true);
  assert.equal(mutations(personal).length, 1);
});

test('a missing ledger fails closed before another Linear write', async (t) => {
  const { personal, api, token } = await setup(t);
  assert.equal((await create(api, token, 'first')).status, 201);
  rmSync(join(api.stateDir, 'task-operations.json'));
  const response = await create(api, token, 'second');
  assert.equal(response.status, 503);
  assert.equal(response.body.error.code, 'task_ledger_unavailable');
  assert.equal(mutations(personal).length, 1);
});

test('operation records are bound to both device and viewer', async (t) => {
  const { personal, api, token } = await setup(t);
  assert.equal((await create(api, token, 'bound')).status, 201);
  const anotherDevice = await api.token(['tasks:write']);
  assert.equal((await api.request('/v1/task-operations/by-key', { token: anotherDevice, key: 'bound' })).status, 404);
  personal.viewer = { id: 'different-owner', name: 'Different' };
  assert.equal((await api.request('/v1/task-operations/by-key', { token, key: 'bound' })).status, 404);
  assert.equal((await create(api, token, 'bound')).body.error.code, 'idempotency_key_conflict');
  assert.equal(mutations(personal).length, 1);
});

test('a real personal adapter checks the expected viewer before each mutation', async (t) => {
  let viewer = VIEWER;
  const calls = [];
  const personal = createPersonalLinearSource({ expectedViewerId: VIEWER.id, readToken: async () => 'lin_api_fixture',
    fetchImpl: async (_url, options) => {
      const request = JSON.parse(options.body);
      calls.push(request);
      if (request.query.includes('LAAPersonalViewer')) return new Response(JSON.stringify({ data: { viewer } }));
      if (request.query.includes('LAAPersonalIssueCreate')) return new Response(JSON.stringify({ data: {
        issueCreate: { success: true, issue: { id: request.variables.input.id, identifier: 'BUS-123', updatedAt: '2026-11-01T00:00:00Z' } },
      } }));
      throw new Error('unexpected request');
    },
  });
  const { api, token } = await setup(t, { personal });
  assert.equal((await create(api, token, 'real-adapter')).status, 201);
  assert.equal(calls.filter(({ query }) => query.includes('LAAPersonalIssueCreate')).length, 1);
  viewer = { id: 'another-owner', name: 'Other' };
  const refused = await create(api, token, 'mismatch');
  assert.equal(refused.status, 403);
  assert.equal(refused.body.error.code, 'linear_viewer_mismatch');
  assert.equal(calls.filter(({ query }) => query.includes('LAAPersonalIssueCreate')).length, 1);
  assert.doesNotMatch(readFileSync(join(api.stateDir, 'task-operations.json'), 'utf8'), /lin_api_fixture/);
});

test('ambiguous GraphQL error after mutation is not retried', async (t) => {
  let writes = 0;
  const personal = createPersonalLinearSource({ expectedViewerId: VIEWER.id, readToken: async () => 'lin_api_fixture',
    fetchImpl: async (_url, options) => {
      const request = JSON.parse(options.body);
      if (request.query.includes('LAAPersonalViewer')) return new Response(JSON.stringify({ data: { viewer: VIEWER } }));
      writes++;
      return new Response(JSON.stringify({ data: null, errors: [{ message: 'private upstream data' }] }));
    },
  });
  const { api, token } = await setup(t, { personal });
  assert.equal((await create(api, token, 'ambiguous')).body.error.code, 'idempotency_outcome_unknown');
  assert.equal((await create(api, token, 'ambiguous')).body.error.code, 'idempotency_outcome_unknown');
  assert.equal(writes, 1);
});

test('a live writer cannot be resolved as crashed solely because time passed', async (t) => {
  let clock = Date.parse('2026-11-01T00:00:00Z');
  const { api } = await setup(t, { now: () => clock });
  const ledger = createTaskOperationLedger({ store: api.store, now: () => clock });
  const args = { deviceId: 'device-fixture', viewerId: VIEWER.id, key: 'inflight', method: 'POST',
    path: '/v1/personal-tasks', rawBody: Buffer.from('{}'), kind: 'create', targetId: 'target' };
  const reserved = ledger.reserve(args);
  clock += 120_000;
  const identity = { deviceId: args.deviceId, viewerId: args.viewerId, operationId: reserved.entry.operationId };
  assert.equal(ledger.get(identity).status, 'in_progress');
  assert.throws(() => ledger.resolve({ ...identity, resolution: 'not_applied', key: 'confirm', fingerprint: 'fixture' }),
    { code: 'operation_not_unresolved' });
  // Replace the fixture writer PID with a process which has exited, as a
  // restart after a crash would leave it. This never reads a real task.
  const exited = spawnSync(process.execPath, ['-e', 'process.exit(0)']);
  assert.equal(exited.status, 0);
  const record = JSON.parse(readFileSync(ledger.file, 'utf8'));
  Object.values(record.entries)[0].processId = exited.pid;
  writeFileSync(ledger.file, JSON.stringify(record));
  assert.equal(ledger.get(identity).status, 'outcome_unknown');
  assert.equal(ledger.resolve({ ...identity, resolution: 'not_applied', key: 'confirm', fingerprint: 'fixture' }).status, 'resolved');
  assert.equal(ledger.reserve({ ...args, key: 'confirm' }).action, 'conflict');
});

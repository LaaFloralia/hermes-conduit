import assert from 'node:assert/strict';
import { readFileSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { startBridge } from './helpers.mjs';
import { createPersonalLinearSource } from '../src/tasks/personal.mjs';
import { createTaskOperationLedger } from '../src/tasks/operation-ledger.mjs';
import { TaskSourceError } from '../src/tasks/errors.mjs';

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
  return api.request('/v1/personal-tasks', { method: 'POST', token, key, body: { expectedViewerId: VIEWER.id, ...body } });
}
function update(api, token, key, body, version) {
  return api.request('/v1/personal-tasks/linear%3ABUS-1', { method: 'PATCH', token, key, body: { expectedViewerId: VIEWER.id, ...body },
    headers: version ? { 'if-match': version } : {} });
}

test('writes require task scope, key and validated fields', async (t) => {
  const { personal, api, token } = await setup(t);
  const readOnly = await api.token(['tasks:read']);
  assert.equal((await create(api, readOnly, 'a')).status, 403);
  assert.equal((await create(api, token, undefined)).body.error.code, 'idempotency_key_required');
  assert.equal((await create(api, token, 'a', { teamId: 'team', title: 'x', delegateId: 'worker' })).status, 400);
  assert.equal((await create(api, token, 'a', { teamId: 'team', title: 'x', expectedViewerId: null })).body.error.code, 'expected_viewer_required');
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
  assert.equal(personal.calls.filter((call) => typeof call === 'string' && call.startsWith('read:')).length, 1);
  assert.deepEqual(mutations(personal)[0].update.input, { stateId: 'state', assigneeId: 'someone', priority: 2 });
  assert.equal(mutations(personal).length, 1);
  const changedVersion = await update(api, token, 'attr', { stateId: 'state', assigneeId: 'someone', priority: 2 }, 'other');
  assert.equal(changedVersion.body.error.code, 'idempotency_key_conflict');
});

test('estimate writes use the public Linear input integer type', async (t) => {
  const { personal, api, token } = await setup(t);
  assert.equal((await update(api, token, 'whole', { estimate: 3 })).status, 200);
  assert.equal(mutations(personal)[0].update.input.estimate, 3);
  assert.equal((await update(api, token, 'fraction', { estimate: 0.5 })).status, 400);
  assert.equal((await update(api, token, 'invalid-estimate', { estimate: -0.5 })).status, 400);
});

test('description requires If-Match and returns the current text on conflict without writing', async (t) => {
  const { personal, api, token } = await setup(t);
  assert.equal((await update(api, token, 'no-match', { description: 'local' })).status, 428);
  const conflict = await update(api, token, 'conflict', { description: 'local' }, 'stale');
  assert.equal(conflict.status, 412);
  assert.equal(conflict.body.error.details.current.description, 'remote text');
  assert.equal(mutations(personal).length, 0);
  const record = await api.request('/v1/task-operations/by-key', { token, key: 'conflict' });
  assert.equal(record.body.data.operation.rejection, 'version_mismatch');
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
  const abandon = await api.request('/v1/task-operations/abandon-unsent', { token, method: 'POST', key: 'parallel',
    body: { expectedViewerId: VIEWER.id } });
  assert.equal(abandon.body.data.operation.status, 'in_progress');
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
  assert.equal((await create(api, token, 'lost')).body.error.code, 'operation_resolved');
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
  const anotherDevice = await api.token(['tasks:read', 'tasks:write']);
  assert.equal((await api.request('/v1/task-operations/by-key', { token: anotherDevice, key: 'bound' })).status, 404);
  personal.viewer = { id: 'different-owner', name: 'Different' };
  assert.equal((await api.request('/v1/task-operations/by-key', { token, key: 'bound' })).status, 404);
  assert.equal((await create(api, token, 'bound')).body.error.code, 'linear_viewer_changed');
  assert.equal((await create(api, token, 'new-for-wrong-viewer')).body.error.code, 'linear_viewer_changed');
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

test('definite Linear input rejections are recorded without leaking input or creating unknowns', async (t) => {
  const responses = [
    { data: { issueCreate: null }, errors: [{ message: 'private upstream secret', path: ['issueCreate'], extensions: { userError: true, code: 'INPUT_ERROR' } }] },
    { data: null, errors: [{ message: 'private upstream secret', extensions: { userError: true, code: 'INPUT_ERROR' } }] },
    { data: { issueCreate: { success: false, issue: null } } },
    { httpStatus: 400, data: null, errors: [{ path: ['issueCreate'], extensions: { userError: true, code: 'INPUT_ERROR' } }] },
  ];
  let writes = 0;
  const personal = createPersonalLinearSource({ expectedViewerId: VIEWER.id, readToken: async () => 'lin_api_fixture',
    fetchImpl: async (_url, options) => {
      const request = JSON.parse(options.body);
      if (request.query.includes('LAAPersonalViewer')) return new Response(JSON.stringify({ data: { viewer: VIEWER } }));
      const value = responses[writes++];
      return new Response(JSON.stringify(value), { status: value.httpStatus ?? 200 });
    } });
  const { api, token } = await setup(t, { personal });
  for (let i = 0; i < responses.length; i++) {
    const key = `definite-${i}`;
    const refused = await create(api, token, key);
    assert.equal(refused.status, 400); assert.equal(refused.body.error.code, 'linear_rejected');
    assert.doesNotMatch(JSON.stringify(refused.body), /private upstream secret|private fixture|lin_api_/);
    const op = (await api.request('/v1/task-operations/by-key', { token, key })).body.data.operation;
    assert.equal(op.status, 'rejected'); assert.equal(op.rejection, 'linear_rejected');
    assert.equal((await create(api, token, key)).body.error.code, 'task_operation_rejected');
  }
  assert.equal(writes, responses.length);
  assert.deepEqual((await api.request('/v1/task-operations', { token })).body.data.items, []);
  assert.doesNotMatch(readFileSync(join(api.stateDir, 'task-operations.json'), 'utf8'), /private upstream secret|private fixture|lin_api_/);
});

test('partial or nested mutation errors and transport failure remain unknown and never replay', async (t) => {
  const responses = [
    { data: { issueCreate: { success: true, issue: { id: 'x', identifier: 'BUS-1' } } }, errors: [{ path: ['issueCreate'], extensions: { userError: true, code: 'INPUT_ERROR' } }] },
    { data: { issueCreate: null }, errors: [{ path: ['issueCreate', 'issue', 'id'], extensions: { userError: true, code: 'INPUT_ERROR' } }] },
    { data: { issueCreate: { success: false, issue: { id: 'x' } } } },
    'network',
    'http500',
    'http400',
  ];
  let writes = 0;
  const personal = createPersonalLinearSource({ expectedViewerId: VIEWER.id, readToken: async () => 'lin_api_fixture',
    fetchImpl: async (_url, options) => {
      const request = JSON.parse(options.body);
      if (request.query.includes('LAAPersonalViewer')) return new Response(JSON.stringify({ data: { viewer: VIEWER } }));
      const result = responses[writes++];
      if (result === 'network') throw new Error('private network failure');
      if (result === 'http500') return new Response('private server failure', { status: 500 });
      if (result === 'http400') return new Response('opaque upstream refusal', { status: 400 });
      return new Response(JSON.stringify(result));
    } });
  const { api, token } = await setup(t, { personal });
  for (let i = 0; i < responses.length; i++) {
    const key = `uncertain-${i}`;
    assert.equal((await create(api, token, key)).body.error.code, 'idempotency_outcome_unknown');
    assert.equal((await create(api, token, key)).body.error.code, 'idempotency_outcome_unknown');
  }
  assert.equal(writes, responses.length);
});

test('team move resolves immutable issue identity before updating and accepts the changed identifier', async (t) => {
  const personal = sourceFixture();
  personal.updateIssue = async (_session, id, input) => {
    personal.calls.push({ update: { id, input } });
    return { id: 'issue-uuid', identifier: 'ENG-42' };
  };
  const { api, token } = await setup(t, { personal });
  const response = await update(api, token, 'move-team', { teamId: 'ENG' });
  assert.equal(response.status, 200);
  assert.equal(response.body.data.operation.identifier, 'ENG-42');
  assert.equal(mutations(personal)[0].update.id, 'issue-uuid');
  assert.equal((await update(api, token, 'move-team', { teamId: 'ENG' })).status, 200);
  assert.equal(mutations(personal).length, 1);
  personal.updateIssue = async () => ({ id: 'different-uuid', identifier: 'BUS-1' });
  assert.equal((await update(api, token, 'wrong-target', { priority: 1 })).body.error.code, 'idempotency_outcome_unknown');
});

test('only an issue-field INPUT_ERROR without an issue maps to not found', async (t) => {
  let mode = 'missing'; let writes = 0;
  const personal = createPersonalLinearSource({ expectedViewerId: VIEWER.id, readToken: async () => 'lin_api_fixture',
    fetchImpl: async (_url, options) => {
      const request = JSON.parse(options.body);
      if (request.query.includes('LAAPersonalViewer')) return new Response(JSON.stringify({ data: { viewer: VIEWER } }));
      if (request.query.includes('LAAPersonalIssue(')) {
        const path = mode === 'missing' ? ['issue'] : ['differentField'];
        return new Response(JSON.stringify({ data: { issue: null }, errors: [{ path, extensions: { userError: true, code: 'INPUT_ERROR' } }] }));
      }
      writes++; throw new Error('must not write');
    } });
  const { api, token } = await setup(t, { personal });
  const detail = await api.request('/v1/personal-tasks/BUS-999', { token });
  assert.equal(detail.status, 404); assert.equal(detail.body.error.code, 'task_not_found');
  assert.equal((await update(api, token, 'deleted-edit', { description: 'x' }, 'v1')).status, 404);
  assert.equal(writes, 0);
  mode = 'other';
  assert.equal((await api.request('/v1/personal-tasks/BUS-999', { token })).status, 503);
});

test('preflight timeout can safely retry the same immutable request after restart', async (t) => {
  const personal = sourceFixture(); let reads = 0;
  const read = personal.getTaskInSession;
  personal.getTaskInSession = async function (...args) {
    if (++reads === 1) throw new TaskSourceError('linear_unavailable', 'fixture unavailable', { status: 503, retryable: true });
    return read.apply(this, args);
  };
  const { api, token } = await setup(t, { personal });
  const version = personal.current.updatedAt;
  const first = await update(api, token, 'retry-preflight', { description: 'local' }, version);
  assert.equal(first.status, 503); assert.equal(first.body.error.retryable, true);
  const entry = (await api.request('/v1/task-operations/by-key', { token, key: 'retry-preflight' })).body.data.operation;
  assert.equal(entry.status, 'preflight_retryable');
  assert.equal((await update(api, token, 'retry-preflight', { description: 'different' }, version)).body.error.code, 'idempotency_key_conflict');
  await api.restart();
  const retried = await update(api, token, 'retry-preflight', { description: 'local' }, version);
  assert.equal(retried.status, 200); assert.equal(retried.body.data.operation.operationId, entry.operationId);
  assert.equal((await update(api, token, 'retry-preflight', { description: 'local' }, version)).status, 200);
  assert.equal(mutations(personal).length, 1);
});

test('not-applied reconciliation cannot be replayed using the old key', async (t) => {
  const personal = sourceFixture();
  personal.createIssue = async (_session, input) => { personal.calls.push({ create: input }); throw new Error('lost'); };
  const { api, token } = await setup(t, { personal });
  await create(api, token, 'resolved-not-applied');
  const operationId = (await api.request('/v1/task-operations/by-key', { token, key: 'resolved-not-applied' })).body.data.operation.operationId;
  await api.request(`/v1/task-operations/${operationId}/resolve`, { token, method: 'POST', key: 'confirm-not-applied',
    body: { confirmed: true, resolution: 'not_applied' } });
  const replay = await create(api, token, 'resolved-not-applied');
  assert.equal(replay.body.error.code, 'operation_resolved');
  assert.equal(replay.body.error.details.operation.resolution, 'not_applied');
  assert.equal(mutations(personal).length, 1);
});

test('operation lookups use read scope and remain device bound; resolve requires write', async (t) => {
  const { api, token } = await setup(t);
  await create(api, token, 'read-scope');
  api.store.mutate((state) => { Object.values(state.devices)[0].scopes = ['tasks:read']; });
  const lookup = await api.request('/v1/task-operations/by-key', { token, key: 'read-scope' });
  assert.equal(lookup.status, 200);
  assert.equal((await api.request('/v1/task-operations', { token })).status, 200);
  const id = lookup.body.data.operation.operationId;
  assert.equal((await api.request(`/v1/task-operations/${id}`, { token })).status, 200);
  assert.equal((await api.request(`/v1/task-operations/${id}/resolve`, { token, method: 'POST', key: 'read-only-resolve',
    body: { confirmed: true, resolution: 'applied' } })).status, 403);
});

test('quoted strong If-Match versions compare correctly while weak versions do not', async (t) => {
  const { personal, api, token } = await setup(t);
  assert.equal((await update(api, token, 'quoted', { description: 'mine' }, `"${personal.current.updatedAt}"`)).status, 200);
  assert.equal((await update(api, token, 'weak', { description: 'mine' }, `W/"${personal.current.updatedAt}"`)).status, 412);
  assert.equal(mutations(personal).length, 1);
});

test('an expired preflight is atomically closed as rejected and cannot race a retry', async (t) => {
  let clock = Date.parse('2026-11-01T00:00:00Z');
  const personal = sourceFixture();
  personal.getTaskInSession = async () => { throw new TaskSourceError('linear_unavailable', 'fixture', { retryable: true }); };
  const { api, token } = await setup(t, { personal, now: () => clock });
  assert.equal((await update(api, token, 'expired-preflight', { description: 'x' }, 'v1')).status, 503);
  clock += 8 * 24 * 60 * 60 * 1000;
  const entry = (await api.request('/v1/task-operations/by-key', { token, key: 'expired-preflight' })).body.data.operation;
  assert.equal(entry.status, 'rejected'); assert.equal(entry.rejection, 'preflight_retry_expired');
  assert.equal((await update(api, token, 'expired-preflight', { description: 'x' }, 'v1')).body.error.code, 'task_operation_rejected');
  assert.equal(mutations(personal).length, 0);
});

test('concurrent retries of a preflight failure still perform one write', async (t) => {
  const personal = sourceFixture(); let reads = 0, entered, resume;
  const blocked = new Promise((resolve) => { resume = resolve; });
  const enteredPromise = new Promise((resolve) => { entered = resolve; });
  const normalRead = personal.getTaskInSession;
  personal.getTaskInSession = async function (...args) {
    if (++reads === 1) throw new TaskSourceError('linear_unavailable', 'fixture', { retryable: true });
    if (reads === 2) { entered(); await blocked; }
    return normalRead.apply(this, args);
  };
  const { api, token } = await setup(t, { personal });
  const version = personal.current.updatedAt;
  assert.equal((await update(api, token, 'parallel-preflight', { description: 'x' }, version)).status, 503);
  const first = update(api, token, 'parallel-preflight', { description: 'x' }, version);
  await enteredPromise;
  assert.equal((await update(api, token, 'parallel-preflight', { description: 'x' }, version)).body.error.code, 'idempotency_key_in_flight');
  resume(); assert.equal((await first).status, 200); assert.equal(mutations(personal).length, 1);
});

test('abandoning an unsent key safely defeats a delayed original request', async (t) => {
  const personal = sourceFixture(); let calls = 0, entered, resume;
  const waiting = new Promise((resolve) => { resume = resolve; });
  const started = new Promise((resolve) => { entered = resolve; });
  personal.session = async function () {
    if (++calls === 1) { entered(); await waiting; }
    return { viewer: this.viewer };
  };
  const { api, token } = await setup(t, { personal });
  const original = create(api, token, 'late-request');
  await started;
  const abandon = () => api.request('/v1/task-operations/abandon-unsent', { token, method: 'POST', key: 'late-request',
    body: { expectedViewerId: VIEWER.id } });
  const result = await abandon();
  assert.equal(result.body.data.operation.status, 'rejected');
  assert.equal(result.body.data.operation.rejection, 'abandoned_before_reservation');
  resume();
  assert.equal((await original).body.error.code, 'idempotency_key_conflict');
  assert.equal((await abandon()).body.data.operation.operationId, result.body.data.operation.operationId);
  assert.equal(mutations(personal).length, 0);
});

test('abandon closes only a definitely unsent preflight and never an unknown write', async (t) => {
  const personal = sourceFixture();
  personal.getTaskInSession = async () => { throw new TaskSourceError('linear_unavailable', 'fixture', { retryable: true }); };
  personal.createIssue = async (_session, input) => { personal.calls.push({ create: input }); throw new Error('lost'); };
  const { api, token } = await setup(t, { personal });
  await update(api, token, 'preflight-cancel', { description: 'x' }, 'v1');
  await create(api, token, 'unknown-cancel');
  // Read-only scope can close its own unsent record but cannot write Linear.
  api.store.mutate((state) => { Object.values(state.devices)[0].scopes = ['tasks:read']; });
  const abandon = (key, expectedViewerId = VIEWER.id) => api.request('/v1/task-operations/abandon-unsent', {
    token, method: 'POST', key, body: { expectedViewerId } });
  assert.equal((await abandon('preflight-cancel')).body.data.operation.rejection, 'preflight_abandoned');
  assert.equal((await abandon('unknown-cancel')).body.data.operation.status, 'outcome_unknown');
  assert.equal((await abandon('wrong-viewer', 'other-owner')).body.error.code, 'linear_viewer_changed');
  assert.equal((await create(api, token, 'still-read-only')).status, 403);
  assert.equal(mutations(personal).length, 1);
});

test('ledger capacity refuses a new write while retaining existing records', async (t) => {
  const { api } = await setup(t);
  const ledger = createTaskOperationLedger({ store: api.store });
  const args = { deviceId: 'fixture-device', viewerId: VIEWER.id, key: 'existing', method: 'POST',
    path: '/fixture', rawBody: Buffer.from('{}'), kind: 'create', targetId: 'target' };
  ledger.reserve(args);
  const doc = JSON.parse(readFileSync(ledger.file, 'utf8'));
  const template = Object.values(doc.entries)[0];
  for (let i = 1; i < 20_000; i++) doc.entries[`synthetic-${i}`] = { ...template, operationId: `fixture-${i}` };
  writeFileSync(ledger.file, JSON.stringify(doc));
  assert.throws(() => ledger.reserve({ ...args, key: 'over-capacity' }), { code: 'task_ledger_full' });
  assert.equal(ledger.byKey({ deviceId: args.deviceId, viewerId: args.viewerId, key: args.key }).status, 'in_progress');
});

test('another paired device cannot inspect or resolve the original device’s unknown operation', async (t) => {
  const personal = sourceFixture();
  personal.createIssue = async () => { throw new Error('lost'); };
  const { api, token } = await setup(t, { personal });
  await create(api, token, 'old-device-key');
  const operationId = (await api.request('/v1/task-operations/by-key', { token, key: 'old-device-key' })).body.data.operation.operationId;
  const newDevice = await api.token(['tasks:read', 'tasks:write']);
  assert.equal((await api.request('/v1/task-operations/by-key', { token: newDevice, key: 'old-device-key' })).status, 404);
  const attempt = await api.request(`/v1/task-operations/${operationId}/resolve`, { token: newDevice, method: 'POST', key: 'new-confirm',
    body: { confirmed: true, resolution: 'not_applied' } });
  assert.equal(attempt.status, 404);
  assert.equal((await api.request('/v1/task-operations/by-key', { token, key: 'old-device-key' })).body.data.operation.status, 'outcome_unknown');
});

test('ledger reserve and finish each replace and synchronously flush the whole JSON record', () => {
  const child = spawnSync(process.execPath, [fileURLToPath(new URL('./fixtures/ledger-io-sample.mjs', import.meta.url))], { encoding: 'utf8' });
  assert.equal(child.status, 0, child.stderr);
  const counts = JSON.parse(child.stdout);
  assert.ok(counts.reads >= 4, `observed ${counts.reads} ledger reads`);
  assert.equal(counts.replacements, 2);
  assert.ok(counts.fsyncs >= 4, `observed ${counts.fsyncs} synchronous flushes`);
});

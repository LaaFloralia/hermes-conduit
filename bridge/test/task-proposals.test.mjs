import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { tasksCommand } from '../src/cli-tasks.mjs';
import { BridgeError } from '../src/errors.mjs';
import { linearOwnerTaskRoutes } from '../src/routes/linear-owner-tasks.mjs';
import { createSessionStore } from '../src/sessions/store.mjs';
import { createTaskDispatchService, createTaskRunStore } from '../src/tasks/dispatch.mjs';
import { createLinearProposalSource, createTaskProposalStore, syncLinearTaskProposals } from '../src/tasks/proposals.mjs';

const BASE = Date.parse('2026-11-24T00:00:00Z');
const time = (minutes) => new Date(BASE + minutes * 60_000).toISOString();
const uuid = (n) => `abcdef78-1234-4123-8123-${String(n).padStart(12, '0')}`;
const task = (n, minutes = n) => ({ id: uuid(n), identifier: `BUS-${n}`, createdAt: time(minutes),
  title: 'Private title', description: 'Private description', status: 'todo', updatedAt: time(minutes) });
const OWNER = { kind: 'owner' };
const STAFF = { kind: 'staff', staff: 'monet', name: 'Monet' };
const PROFILE = { id: 'profile', label: 'Model', effort: 'high' };
const CLI = fileURLToPath(new URL('../src/cli.mjs', import.meta.url));

function fixture(t) {
  const dir = mkdtempSync(join(tmpdir(), 'task-proposals-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const runStore = createTaskRunStore({ dir, now: () => BASE });
  const proposals = createTaskProposalStore({ dir, now: () => BASE });
  return { dir, runStore, proposals };
}

async function command(dir, argv, flags, io = {}) {
  let stdout = '', stderr = '';
  const code = await tasksCommand(argv, { ...flags, json: true }, {
    ...io, stateDir: dir, write: (chunk) => { stdout += chunk; }, writeErr: (chunk) => { stderr += chunk; },
  });
  return { code, data: JSON.parse(stdout), stderr };
}

test('owner registration is durable, case-insensitive, body-free and changes the digest once', (t) => {
  const { dir, proposals } = fixture(t);
  const empty = proposals.pending();
  const first = task(1);
  const variant = { ...first, id: first.id.toUpperCase(), updatedAt: time(2), createdAt: time(2), title: 'Edited' };
  proposals.recordOwnerTask(first);
  proposals.recordOwnerTask(variant);
  const reopened = createTaskProposalStore({ dir });
  const result = reopened.pending();
  assert.equal(result.totalSeen, 1);
  assert.equal(result.newestCreatedAt, time(1));
  assert.notEqual(result.digest, empty.digest);
  assert.deepEqual(result.pending, [{
    id: first.id, identifier: first.identifier, createdAt: time(1), state: 'pending', commentId: null,
  }]);
  assert.equal(statSync(proposals.file).mode & 0o777, 0o600);
  assert.doesNotMatch(readFileSync(proposals.file, 'utf8'), /Private|Edited/);
});

test('terminal markers are immutable and idempotent across retries', (t) => {
  const { proposals } = fixture(t);
  for (const n of [1, 2]) proposals.recordOwnerTask(task(n));
  const { digest } = proposals.pending();
  const proposed = proposals.mark(uuid(1), 'proposed', 'comment-a');
  assert.deepEqual(proposals.mark(uuid(1), 'proposed', 'comment-a'), proposed);
  assert.throws(() => proposals.mark(uuid(1), 'proposed', 'comment-b'), { status: 409 });
  assert.throws(() => proposals.mark(uuid(1), 'dismissed'), { status: 409 });
  assert.throws(() => proposals.mark(uuid(2), 'dismissed', 'invalid-comment'), { status: 400 });
  assert.throws(() => proposals.mark(uuid(3), 'proposed'), { status: 404 });
  proposals.mark(uuid(2), 'dismissed');
  proposals.recordOwnerTask(task(2, 9));
  assert.deepEqual(proposals.pending(), { pending: [], totalSeen: 2, newestCreatedAt: time(2), digest });
});

test('first sync seeds a baseline, subsequent overlapping scans deduplicate and ignore historical tasks', async (t) => {
  const { dir, proposals } = fixture(t);
  const scan = (target, minutes) => syncLinearTaskProposals({
    proposals: target, now: () => Date.parse(time(minutes)), staffIds: () => [],
    candidates: async ({ since, through }) => {
      assert.equal(since, minutes === 10 ? null : time(10));
      assert.equal(through, time(minutes));
      return minutes === 10 ? [task(1), task(2)] : [task(2), task(3, 12), task(3, 12)];
    },
  });
  proposals.recordOwnerTask(task(4));
  await scan(proposals, 10);
  assert.deepEqual(proposals.pending().pending.map((r) => r.identifier), ['BUS-4']);
  const reopened = createTaskProposalStore({ dir });
  await scan(reopened, 20);
  assert.deepEqual(reopened.pending().pending.map((r) => r.identifier), ['BUS-4', 'BUS-3']);
  const { digest } = reopened.pending();
  await scan(reopened, 25);
  assert.equal(reopened.pending().digest, digest);
});

test('failed scans keep the checkpoint and recovery reads the unchanged window', async (t) => {
  const { proposals } = fixture(t);
  const sync = (minutes, candidates) => syncLinearTaskProposals({
    proposals, candidates, staffIds: () => [], now: () => Date.parse(time(minutes)),
  });
  await sync(1, async () => []);
  const old = proposals.scan();
  await assert.rejects(sync(10, async () => { throw new Error('unavailable'); }), /unavailable/);
  assert.deepEqual(proposals.scan(), old);
  await sync(20, async ({ since }) => {
    assert.equal(since, time(1));
    return [task(3)];
  });
  assert.equal(proposals.pending().totalSeen, 1);
});

test('older concurrent scan completions cannot roll back the checkpoint', async (t) => {
  const { proposals } = fixture(t);
  const staffIds = () => [];
  proposals.reconcile({ expected: null, through: time(1), items: [], staffIds });
  const expected = proposals.scan();
  proposals.reconcile({ expected, through: time(10), items: [task(2)], staffIds });
  proposals.reconcile({ expected, through: time(5), items: [], staffIds });
  assert.deepEqual(proposals.scan(), { baseline: time(1), through: time(10) });
  assert.equal(proposals.pending().totalSeen, 1);
});

test('staff dispatch suppresses prior or later observations without changing the prior digest', (t) => {
  const { proposals, runStore } = fixture(t);
  const dispatch = createTaskDispatchService({ store: runStore, proposals, sessionOptions: () => ({ profiles: [PROFILE] }) });
  proposals.recordOwnerTask(task(1));
  const { digest } = proposals.pending();
  for (const n of [1, 2]) dispatch.accept({ task: task(n), deviceId: 'device', assignee: STAFF, profile: PROFILE.id });
  proposals.recordOwnerTask(task(2));
  assert.deepEqual(proposals.pending(), { pending: [], totalSeen: 1, newestCreatedAt: time(1), digest });
  assert.equal(runStore.get(uuid(2)).phase, 'queued');
});

test('a legacy explicit staff run is suppressed on sync and cannot be marked proposed', async (t) => {
  const { dir, proposals, runStore } = fixture(t);
  proposals.recordOwnerTask(task(1));
  runStore.record({ task: task(1), deviceId: 'device', assignee: STAFF, profile: PROFILE.id });
  const pending = await command(dir, ['proposals'], { pending: true });
  assert.deepEqual(pending.data.pending, []);
  const mark = await command(dir, ['proposals', 'mark'], { id: uuid(1), state: 'proposed' });
  assert.equal(mark.code, 4);
  const sync = await command(dir, ['proposals'], { pending: true, 'sync-linear': true }, { proposalSource: async () => [] });
  assert.deepEqual(sync.data.pending, []);
  assert.equal(sync.data.totalSeen, 1);
});

test('owner HTTP creation records once and never schedules, comments or starts Work', async (t) => {
  const { proposals } = fixture(t);
  const created = task(1);
  const source = {
    createOwnerTask: async () => created,
    commentOwnerTask: () => assert.fail('unexpected Linear comment'),
  };
  const dispatch = {
    proposals, store: { all: () => [], get: () => null }, view: () => null, accept: () => {},
    validateAssignment: () => ({ assignee: OWNER, profile: null }),
    schedule: () => assert.fail('unexpected Work scheduling'),
  };
  const route = linearOwnerTaskRoutes({ source, dispatch }).find((r) => r.method === 'POST' && r.path === '/v1/linear-owner-tasks');
  const request = { rawBody: Buffer.from(JSON.stringify({ id: created.id, title: created.title })), device: { id: 'device' } };
  assert.equal((await route.handler(request)).status, 201);
  await route.handler(request);
  assert.equal(proposals.pending().totalSeen, 1);
});

test('staff HTTP creation reserves suppression across the external write and delegates only the explicit run', async (t) => {
  const { proposals, runStore } = fixture(t);
  proposals.reconcile({ expected: null, through: time(0), items: [], staffIds: () => [] });
  const created = task(1);
  const source = {
    async createOwnerTask() {
      proposals.reconcile({ expected: proposals.scan(), through: time(2), items: [created], staffIds: () => [] });
      assert.equal(proposals.pending().totalSeen, 0);
      return created;
    },
  };
  const dispatch = createTaskDispatchService({ store: runStore, proposals, sessionOptions: () => ({ profiles: [PROFILE] }) });
  const scheduled = [];
  dispatch.schedule = (id) => scheduled.push(id);
  const route = linearOwnerTaskRoutes({ source, dispatch }).find((r) => r.method === 'POST' && r.path === '/v1/linear-owner-tasks');
  const request = { rawBody: Buffer.from(JSON.stringify({ id: created.id, title: created.title,
    assignee: { kind: 'staff', staff: 'monet' }, profile: PROFILE.id })),
  device: { id: 'device', scopes: ['sessions:write'] } };
  assert.equal((await route.handler(request)).status, 201);
  assert.deepEqual(scheduled, [created.id]);
  assert.equal(proposals.pending().totalSeen, 0);
});

test('a verified pre-write failure releases only its staged staff attempt', async (t) => {
  const { proposals, runStore } = fixture(t);
  const created = task(1);
  const dispatch = createTaskDispatchService({ store: runStore, proposals, sessionOptions: () => ({ profiles: [PROFILE] }) });
  const source = { async createOwnerTask() { throw new BridgeError(503, 'unavailable', 'no write', { writeStarted: false }); } };
  const route = linearOwnerTaskRoutes({ source, dispatch }).find((r) => r.method === 'POST' && r.path === '/v1/linear-owner-tasks');
  const request = { rawBody: Buffer.from(JSON.stringify({ id: created.id, title: created.title,
    assignee: { kind: 'staff', staff: 'monet' }, profile: PROFILE.id })),
  device: { id: 'device', scopes: ['sessions:write'] } };
  await assert.rejects(route.handler(request), { code: 'unavailable', writeStarted: false });
  proposals.recordOwnerTask(created);
  assert.equal(proposals.pending().pending.length, 1);
});

test('the candidate source verifies owner and team, applies its frozen interval and follows cursors', async () => {
  const issue = (n, extra = {}) => ({ ...task(n), creator: { id: 'owner' }, assignee: { id: 'owner' },
    team: { id: 'team' }, state: { type: 'unstarted' }, ...extra });
  const calls = [];
  const candidates = createLinearProposalSource({ ownerUserId: 'owner', readToken: async () => 'fake-token',
    async fetchImpl(_url, request) {
      const body = JSON.parse(request.body);
      calls.push(body);
      assert.match(body.query, /^query /);
      assert.equal(request.headers.authorization, 'Bearer fake-token');
      if (body.query.startsWith('query BridgeOwnerViewer')) {
        return Response.json({ data: { viewer: { id: 'owner' }, teams: { nodes: [{ id: 'team', key: 'BUS', name: 'LAA',
          states: { nodes: [{ id: 'todo', name: 'Todo', type: 'unstarted' }] } }] } } });
      }
      const first = body.variables.after === null;
      assert.deepEqual(body.variables.filter.createdAt, { gte: time(1), lte: time(9) });
      const nodes = first ? [
        issue(2), issue(3, { creator: null }), issue(4, { assignee: { id: 'staff' } }), issue(5, { team: { id: 'other' } }),
        issue(6, { archivedAt: time(6) }), issue(7, { delegate: { id: 'staff' } }),
      ] : [issue(8), issue(9, { state: { type: 'completed' } }), issue(10)];
      return Response.json({ data: { viewer: { id: 'owner',
        createdIssues: { nodes, pageInfo: { hasNextPage: first, endCursor: first ? 'next' : null } } } } });
    },
  });
  assert.deepEqual(await candidates({ since: time(1), through: time(9) }), [2, 8].map((n) => ({
    id: uuid(n), identifier: `BUS-${n}`, createdAt: time(n),
  })));
  assert.deepEqual(calls.slice(1).map(({ variables }) => variables.after), [null, 'next']);
});

test('a paging cycle errors without presenting a partial candidate list', async () => {
  const candidates = createLinearProposalSource({ ownerUserId: 'owner', readToken: async () => 'fake-token',
    async fetchImpl(_url, request) {
      if (JSON.parse(request.body).query.startsWith('query BridgeOwnerViewer')) {
        return Response.json({ data: { viewer: { id: 'owner' }, teams: { nodes: [{ id: 'team', key: 'BUS', name: 'LAA',
          states: { nodes: [{ id: 'todo', name: 'Todo', type: 'unstarted' }] } }] } } });
      }
      return Response.json({ data: { viewer: { id: 'owner', createdIssues: { nodes: [],
        pageInfo: { hasNextPage: true, endCursor: 'same' } } } } });
    },
  });
  await assert.rejects(candidates({ since: time(1), through: time(9) }), { code: 'linear_pagination_incomplete' });
});

test('Linear CLI lists live-source metadata with dispatch state and sanitizes source failures', async (t) => {
  const { dir, runStore } = fixture(t);
  runStore.record({ task: task(1), deviceId: 'device', assignee: STAFF, profile: PROFILE.id });
  const linearSource = { async listOwnerTasks(query) {
    assert.deepEqual(query, { archived: false });
    return { items: [task(1), task(2)] };
  } };
  const result = await command(dir, ['list'], { source: 'linear', limit: '1' }, { linearSource });
  assert.deepEqual(result.data, { ok: true, total: 2, items: [{
    id: uuid(1), identifier: 'BUS-1', title: 'Private title', status: 'todo',
    dueDate: null, updatedAt: time(1), assignee: STAFF, run: { state: 'queued' },
  }] });
  const failure = await command(dir, ['list'], { source: 'linear' }, { linearSource: {
    async listOwnerTasks() { throw new Error('private credential'); },
  } });
  assert.equal(failure.code, 7);
  assert.equal(failure.data.error.code, 'linear_unavailable');
  assert.doesNotMatch(JSON.stringify(failure), /private credential/);
});

test('proposal CLI lists, marks and preserves the high-water digest without any Linear operation', async (t) => {
  const { dir, proposals } = fixture(t);
  proposals.recordOwnerTask(task(1));
  const options = { proposalSource: () => assert.fail('unexpected Linear read') };
  const list = await command(dir, ['proposals'], { pending: true }, options);
  assert.equal(list.code, 0);
  assert.equal(list.data.pending.length, 1);
  const marked = await command(dir, ['proposals', 'mark'], { id: uuid(1), state: 'proposed', 'comment-id': 'id-1' }, options);
  assert.equal(marked.data.proposal.commentId, 'id-1');
  const result = await command(dir, ['proposals'], { pending: true }, options);
  assert.equal(result.data.digest, list.data.digest);
  assert.deepEqual(result.data.pending, []);
});

test('corrupt proposal state is surfaced without overwriting history', async (t) => {
  const { dir, proposals } = fixture(t);
  writeFileSync(proposals.file, '{}');
  const result = await command(dir, ['proposals'], { pending: true });
  assert.equal(result.code, 6);
  assert.equal(result.data.error.code, 'task_proposals_store_unavailable');
  assert.equal(readFileSync(proposals.file, 'utf8'), '{}');
});

test('the executable records a terminal marker without contacting Linear', (t) => {
  const { dir, proposals } = fixture(t);
  proposals.recordOwnerTask(task(1));
  const { digest } = proposals.pending();
  const result = spawnSync(process.execPath, [CLI, 'tasks', 'proposals', 'mark',
    '--id', uuid(1), '--state', 'dismissed', '--json'], {
    encoding: 'utf8', env: { ...process.env, LAA_BRIDGE_STATE_DIR: dir, LAA_BRIDGE_LINEAR_TOKEN_HELPER: '/nonexistent' },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).proposal.state, 'dismissed');
  assert.equal(proposals.pending().digest, digest);
});

test('the executable exports archived project membership without writing session state', (t) => {
  const { dir } = fixture(t);
  const sessions = createSessionStore({ file: join(dir, 'sessions.json') });
  const record = (n, opts = {}) => ({ id: `ses_${String(n).padStart(16, '0')}`, delegate: { sessionId: uuid(n) },
    projectId: 'prj_123456789abc', updatedAt: time(n), ...opts });
  sessions.create({ record: record(1, { archivedAt: time(2) }) });
  sessions.create({ record: record(2, { delegate: { sessionId: uuid(1) }, projectId: 'prj_aaaaaaaaaaaa', archivedAt: time(3) }) });
  sessions.create({ record: record(3, { projectId: null }) });
  sessions.create({ record: record(4, { delegate: null }) });
  const before = readFileSync(sessions.file, 'utf8');
  const output = spawnSync(process.execPath, [CLI, 'projects', 'sessions', '--json'], {
    encoding: 'utf8', env: { ...process.env, LAA_BRIDGE_STATE_DIR: dir },
  });
  assert.equal(output.status, 0, output.stderr);
  assert.deepEqual(JSON.parse(output.stdout), { ok: true, data: { items: [
    { agentId: uuid(1), sessionId: record(2).id, projectId: 'prj_aaaaaaaaaaaa' },
    { agentId: uuid(3), sessionId: record(3).id, projectId: null },
  ] } });
  assert.equal(readFileSync(sessions.file, 'utf8'), before);
});

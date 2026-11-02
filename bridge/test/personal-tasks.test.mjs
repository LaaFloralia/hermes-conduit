import assert from 'node:assert/strict';
import test from 'node:test';
import { createPersonalLinearSource } from '../src/tasks/personal.mjs';
import { startBridge } from './helpers.mjs';

const KEY = 'lin_api_fixture_only';
const VIEWER = { id: 'owner-fixture', name: 'Fixture Owner' };
const page = (nodes, after = null) => ({ nodes, pageInfo: { hasNextPage: after !== null, endCursor: after } });
const issue = (n) => ({
  id: `uuid-${n}`, identifier: `BUS-${n}`, title: `Fixture ${n}`, url: `https://linear.app/fixture/BUS-${n}`,
  updatedAt: '2026-11-01T00:00:00.000Z', priority: 1, estimate: null, dueDate: null,
  state: { id: 'state', name: 'Todo', type: 'unstarted' }, team: { id: 'team', key: 'BUS', name: 'Fixture' },
  assignee: { ...VIEWER, app: false }, delegate: null, project: null, projectMilestone: null, cycle: null, parent: null,
  labels: page([]),
});
function fixture(handler, { viewer = VIEWER, expectedViewerId = VIEWER.id } = {}) {
  const calls = [];
  const fetchImpl = async (_url, options) => {
    const request = JSON.parse(options.body);
    calls.push({ ...request, authorization: options.headers.authorization });
    if (request.query.includes('LAAPersonalViewer')) return new Response(JSON.stringify({ data: { viewer } }), { status: 200 });
    return handler(request);
  };
  return { calls, source: createPersonalLinearSource({ expectedViewerId, readToken: async () => KEY, fetchImpl }) };
}
function success(data) { return new Response(JSON.stringify({ data }), { status: 200 }); }

test('personal access is disabled without an explicit expected viewer and never uses the agent token', async () => {
  let reads = 0;
  const source = createPersonalLinearSource({ expectedViewerId: '', tokenHelper: '', readToken: async () => { reads++; return KEY; } });
  await assert.rejects(source.listTasks(), { code: 'linear_personal_not_configured' });
  assert.equal(reads, 0);
  const unconfigured = createPersonalLinearSource({ expectedViewerId: VIEWER.id, tokenHelper: '' });
  await assert.rejects(unconfigured.listTasks(), { code: 'linear_personal_not_configured' });
});

test('viewer mismatch prevents the business query, and errors never expose upstream output', async () => {
  const fake = fixture(() => { throw new Error('must not query'); }, { viewer: { id: 'different', name: 'Other' } });
  await assert.rejects(fake.source.listTasks(), { code: 'linear_viewer_mismatch', status: 403 });
  assert.equal(fake.calls.length, 1);
  const partial = fixture(() => success({ issues: page([issue(1)]) }));
  const throwing = createPersonalLinearSource({ expectedViewerId: VIEWER.id, readToken: async () => KEY,
    fetchImpl: async (_url, options) => JSON.parse(options.body).query.includes('LAAPersonalViewer')
      ? success({ viewer: VIEWER }) : new Response(JSON.stringify({ data: {}, errors: [{ message: KEY }] }), { status: 200 }) });
  await assert.rejects(throwing.listTasks(), (error) => error.code === 'linear_graphql_error' && !error.message.includes(KEY));
  assert.equal((await partial.source.listTasks()).items.length, 1);
});

test('server-side cursor can reach beyond 500 issues and is bound to the filter and viewer', async () => {
  const fake = fixture(({ variables }) => {
    const start = Number(variables.after ?? 0);
    const count = Math.min(variables.first, 525 - start);
    return success({ issues: page(Array.from({ length: count }, (_, i) => issue(start + i + 1)), start + count < 525 ? String(start + count) : null) });
  });
  const ids = new Set();
  let cursor;
  let pages = 0;
  do {
    const result = await fake.source.listTasks({ view: 'mine', limit: 50, cursor });
    result.items.forEach((item) => ids.add(item.id));
    assert.equal(result.paginationConsistency, 'live');
    cursor = result.nextCursor;
    pages++;
  } while (cursor);
  assert.equal(ids.size, 525);
  assert.equal(pages, 11);
  const first = await fake.source.listTasks({ view: 'mine', limit: 50 });
  await assert.rejects(fake.source.listTasks({ view: 'all', cursor: first.nextCursor }), { code: 'cursor_invalid' });
  assert.deepEqual(fake.calls.find((call) => call.query.includes('LAAPersonalIssues')).variables.filter, { assignee: { id: { eq: VIEWER.id } } });
  assert.ok(fake.calls.every((call) => call.authorization === KEY));
});

test('search and saved views use Linear filtering, not an approximation', async () => {
  const fake = fixture(({ query, variables }) => {
    if (query.includes('LAAPersonalSearch')) {
      assert.equal(variables.term, 'word');
      assert.deepEqual(variables.filter, { state: { type: { eq: 'started' } }, project: { id: { eq: 'project' } } });
      return success({ searchIssues: page([issue(1)]) });
    }
    assert.equal(variables.id, 'view-id');
    return success({ customView: { id: 'view-id', name: 'Fixture', modelName: 'Issue', issues: page([issue(2)]) } });
  });
  assert.equal((await fake.source.listTasks({ view: 'active', project: 'project', search: 'word' })).items[0].sourceId, 'BUS-1');
  assert.equal((await fake.source.listTasks({ customView: 'view-id' })).items[0].sourceId, 'BUS-2');
  await assert.rejects(fake.source.listTasks({ customView: 'view-id', view: 'mine' }), { code: 'filter_invalid' });
});

test('detail preserves long description and distinguishes people, apps and partial labels', async () => {
  const fake = fixture(() => success({ issue: { ...issue(1), description: '文'.repeat(6000),
    assignee: { id: 'another-human', name: 'Other', app: false },
    delegate: { id: 'app', name: 'App', app: true }, labels: page([{ id: 'l1', name: 'label', color: '#123456' }], 'next') } }));
  const found = await fake.source.getTask('linear:BUS-1');
  assert.equal(found.task.description.length, 6000);
  assert.equal(found.task.owner.kind, 'person');
  assert.equal(found.task.executor.kind, 'agent');
  assert.equal(found.task.labelsComplete, false);
  assert.equal(found.viewerId, VIEWER.id);
});

test('inbox read preserves unread status and pagination, without marking anything read', async () => {
  const notification = { id: 'n1', type: 'issue', createdAt: '2026-11-01T00:00:00Z', updatedAt: '2026-11-01T00:00:00Z',
    readAt: null, archivedAt: null, user: { id: VIEWER.id }, issue: { id: 'i1', identifier: 'BUS-1', title: 'Fixture' } };
  const fake = fixture(() => success({ notifications: page([notification], 'next') }));
  const first = await fake.source.listCollection('inbox');
  assert.equal(first.items[0].readAt, null);
  assert.ok(first.nextCursor);
  assert.ok(fake.calls.every(({ query }) => /^query /.test(query)));
});

test('metadata reports incomplete choices rather than claiming all were returned', async () => {
  const fake = fixture(() => success({
    teams: page([{ id: 'team', key: 'BUS', name: 'Fixture' }]), users: page([], 'more'), workflowStates: page([]),
    issueLabels: page([]), projects: page([]), projectMilestones: page([]), cycles: page([]), issuePriorityValues: [],
  }));
  const meta = await fake.source.metadata();
  assert.equal(meta.users.complete, false);
  assert.equal(meta.teams.complete, true);
  assert.equal(meta.viewer.id, VIEWER.id);
});

test('personal endpoints are scope-protected and cannot fall back to legacy agent data', async (t) => {
  const personal = {
    async listTasks(options) { return { items: [{ id: 'personal' }], nextCursor: null, view: options.view }; },
    async getTask(id) { return id === 'BUS-1' ? { task: { id: 'BUS-1' } } : null; },
    async listCollection(name) { return { items: [{ id: name }], nextCursor: null }; },
    async metadata() { return { viewer: VIEWER }; },
  };
  const api = await startBridge({ tasks: { personal } });
  t.after(() => api.close());
  assert.equal((await api.request('/v1/personal-tasks')).status, 401);
  const noScope = await api.token(['sessions:read']);
  assert.equal((await api.request('/v1/personal-tasks', { token: noScope })).status, 403);
  const token = await api.token(['tasks:read']);
  const list = await api.request('/v1/personal-tasks?view=mine', { token });
  assert.equal(list.status, 200);
  assert.equal(list.body.data.view, 'mine');
  assert.equal((await api.request('/v1/personal-tasks/BUS-1', { token })).status, 200);
  assert.equal((await api.request('/v1/personal-tasks/absent', { token })).status, 404);
  assert.equal((await api.request('/v1/task-inbox', { token })).body.data.items[0].id, 'inbox');
  assert.equal((await api.request('/v1/task-metadata', { token })).body.data.viewer.id, VIEWER.id);
});

test('agent account uses the configured owner for My Tasks and never substitutes the agent inbox', async () => {
  const calls = [];
  const source = createPersonalLinearSource({ agentAccount: true, ownerUserId: 'owner-person',
    readToken: async () => 'fixture-agent-oauth', fetchImpl: async (_url, options) => {
      const request = JSON.parse(options.body); calls.push({ ...request, authorization: options.headers.authorization });
      if (request.query.includes('LAAPersonalViewer')) return success({ viewer: { id: 'agent-person', name: 'LAA Agent' } });
      return success({ issues: page([]) });
    } });
  const result = await source.listTasks({ view: 'mine' });
  assert.equal(result.viewerId, 'agent-person');
  assert.equal(calls[1].variables.filter.assignee.id.eq, 'owner-person');
  assert.equal(calls[0].authorization, 'Bearer fixture-agent-oauth');
  const before = calls.length;
  await assert.rejects(source.listCollection('inbox'), { code: 'linear_owner_inbox_unavailable', status: 403 });
  await assert.rejects(source.getNotification('notice'), { code: 'linear_owner_inbox_unavailable', status: 403 });
  assert.equal(calls.length, before);
});

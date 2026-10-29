import assert from 'node:assert/strict';
import test from 'node:test';
import { DEFAULT_SCOPES } from '../src/config.mjs';
import { taskRoutes } from '../src/routes/tasks.mjs';
import { TaskSourceError } from '../src/tasks/errors.mjs';
import { startBridge } from './helpers.mjs';

const OWNER = { kind: 'owner', name: '社長', id: 'user_owner' };
const AGENT = { kind: 'agent', name: 'LAA', id: 'user_agent' };
const UNASSIGNED = { kind: 'unassigned', name: null, id: null };
const PROJECTS = [
  { id: 'proj_hermes', name: 'Hermes Conduit' },
  { id: 'proj_hq', name: 'HQ運用' },
];
const STATES = [
  { name: 'Todo', type: 'unstarted', category: 'open' },
  { name: 'In Progress', type: 'started', category: 'open' },
  { name: 'Done', type: 'completed', category: 'done' },
];

function fixtureTask(index, overrides = {}) {
  const n = index + 1;
  const ownerKind = n % 5 === 0 ? UNASSIGNED : (n % 3 === 0 ? AGENT : OWNER);
  const delegated = n === 2;
  const state = STATES[n % STATES.length];
  const updatedAt = new Date(Date.UTC(2026, 9, 25, 12, 0, 0) - index * 60_000).toISOString();
  return {
    id: `linear:BUS-${100 + n}`,
    source: 'linear',
    sourceId: `BUS-${100 + n}`,
    title: `Task ${n}`,
    owner: ownerKind,
    executor: ownerKind.kind === 'agent' || delegated ? { ...AGENT } : null,
    status: state,
    dependencies: { blockedBy: n % 7 === 0 ? ['BUS-1'] : [], blocks: [], complete: true },
    result: state.category === 'done'
      ? { state: 'completed', summary: null, commentId: null, reportedAt: updatedAt }
      : { state: 'none', summary: null, commentId: null, reportedAt: null },
    project: PROJECTS[n % PROJECTS.length],
    labels: n % 4 === 0 ? ['agent'] : [],
    url: `https://linear.app/laa/issue/BUS-${100 + n}`,
    updatedAt,
    version: updatedAt,
    ...overrides,
  };
}

const ITEMS = Array.from({ length: 25 }, (_, index) => fixtureTask(index));

function fakeLinear(items = ITEMS, { truncated = false, failWith = null } = {}) {
  const calls = [];
  return {
    id: 'linear',
    calls,
    describe: () => ({ source: 'linear', state: 'available', observedAt: '2026-10-25T12:00:00.000Z' }),
    async listTasks() {
      calls.push('list');
      if (failWith) throw failWith;
      return { items, truncated };
    },
    async getTask(sourceId) {
      calls.push(`get:${sourceId}`);
      if (failWith) throw failWith;
      const item = items.find((candidate) => candidate.sourceId === sourceId);
      if (!item) return null;
      return {
        task: { ...item, description: `description of ${sourceId}` },
        comments: [{
          id: 'comment_1',
          author: { id: 'user_agent', name: 'LAA' },
          createdAt: item.updatedAt,
          updatedAt: item.updatedAt,
          body: `[laa-agent] 完了: ${sourceId} を確認した`,
          truncated: false,
          agentReport: true,
        }],
        links: [{ id: 'att_1', title: 'report.md', url: `https://example.invalid/${sourceId}`, createdAt: item.updatedAt }],
      };
    },
  };
}

function fakeKanban(items = [], { state = 'available' } = {}) {
  const calls = [];
  return {
    id: 'kanban',
    calls,
    describe: () => (state === 'available'
      ? { source: 'kanban', state: 'available', observedAt: '2026-10-25T12:00:00.000Z' }
      : {
        source: 'kanban',
        state: 'unavailable',
        reason: 'kanban_wrapper_not_authorized',
        detail: 'the Hermes dashboard Kanban API needs an authenticated Mac-side wrapper that does not exist yet',
        observedAt: '2026-10-25T12:00:00.000Z',
      }),
    async listTasks() {
      calls.push('list');
      return { items };
    },
    async getTask(sourceId) {
      calls.push(`get:${sourceId}`);
      const item = items.find((candidate) => candidate.sourceId === sourceId);
      return item ? { task: item, comments: [], links: [] } : null;
    },
  };
}

function kanbanTask(id, overrides = {}) {
  return {
    id: `kanban:${id}`,
    source: 'kanban',
    sourceId: id,
    title: `Kanban ${id}`,
    owner: { kind: 'agent', name: 'ciel', id: null },
    executor: { kind: 'agent', name: 'ciel', id: null },
    status: { name: 'todo', type: 'todo', category: 'open' },
    dependencies: { blockedBy: [], blocks: [], complete: true },
    result: { state: 'none', summary: null, commentId: null, reportedAt: null },
    project: null,
    labels: [],
    url: null,
    updatedAt: '2026-10-25T11:00:00.000Z',
    version: id,
    linearRefs: [],
    ...overrides,
  };
}

async function authenticate(api, scopes = DEFAULT_SCOPES) {
  const paired = await api.pair({ scopes });
  const enrolled = await api.enroll(paired.code);
  assert.equal(enrolled.status, 201);
  return enrolled.body.data.token;
}

test('task endpoints require a token and the tasks:read scope', async (t) => {
  const api = await startBridge({ tasks: { linear: fakeLinear(), kanban: fakeKanban() } });
  t.after(() => api.close());

  const anonymous = await api.request('/v1/tasks');
  assert.equal(anonymous.status, 401);
  assert.equal(anonymous.body.error.code, 'unauthenticated');

  const sessionsOnly = await authenticate(api, ['sessions:read']);
  const forbidden = await api.request('/v1/tasks', { token: sessionsOnly });
  assert.equal(forbidden.status, 403);
  assert.equal(forbidden.body.error.code, 'insufficient_scope');
  assert.match(forbidden.body.error.message, /tasks:read/);

  const detailForbidden = await api.request('/v1/tasks/BUS-101', { token: sessionsOnly });
  assert.equal(detailForbidden.status, 403);
});

test('listing maps owner, executor, status, dependencies, result and sourceId for 25 items', async (t) => {
  const linear = fakeLinear();
  const api = await startBridge({
    tasks: { linear, kanban: fakeKanban([], { state: 'unavailable' }) },
  });
  t.after(() => api.close());
  const token = await authenticate(api);

  const res = await api.request('/v1/tasks', { token });
  assert.equal(res.status, 200);
  assert.equal(res.body.data.total, 25);
  assert.equal(res.body.data.items.length, 25);
  assert.equal(res.body.data.nextCursor, null);
  assert.deepEqual(linear.calls, ['list']);

  const expectedKeys = [
    'dependencies', 'executor', 'id', 'labels', 'owner', 'project', 'result',
    'source', 'sourceId', 'status', 'title', 'updatedAt', 'url', 'version',
  ];
  for (const item of res.body.data.items) {
    assert.deepEqual(Object.keys(item).sort(), expectedKeys);
    const fixture = ITEMS.find((candidate) => candidate.sourceId === item.sourceId);
    assert.equal(item.title, fixture.title);
    assert.deepEqual(item.owner, fixture.owner);
    assert.deepEqual(item.executor, fixture.executor);
    assert.deepEqual(item.status, fixture.status);
    assert.deepEqual(item.dependencies, fixture.dependencies);
    assert.deepEqual(item.result, fixture.result);
    assert.equal(item.updatedAt, fixture.updatedAt);
  }

  // The separation itself: an agent-assigned task names the agent as executor
  // while an owner task has none, and a delegated owner task keeps both.
  const agentTask = res.body.data.items.find((item) => item.owner.kind === 'agent');
  assert.equal(agentTask.executor.kind, 'agent');
  const ownerTask = res.body.data.items.find((item) => item.owner.kind === 'owner' && item.executor === null);
  assert.equal(ownerTask.owner.name, '社長');
  const delegated = res.body.data.items.find((item) => item.sourceId === 'BUS-102');
  assert.equal(delegated.owner.kind, 'owner');
  assert.equal(delegated.executor.kind, 'agent');

  const unassigned = res.body.data.items.filter((item) => item.owner.kind === 'unassigned');
  assert.ok(unassigned.length > 0);

  const linearState = res.body.data.sources.find((state) => state.source === 'linear');
  assert.equal(linearState.state, 'available');
  const kanbanState = res.body.data.sources.find((state) => state.source === 'kanban');
  assert.equal(kanbanState.state, 'unavailable');
  assert.equal(kanbanState.reason, 'kanban_wrapper_not_authorized');
});

test('filters narrow by owner, status, project and source', async (t) => {
  const kanban = fakeKanban([kanbanTask('kb-1')]);
  const api = await startBridge({ tasks: { linear: fakeLinear(), kanban } });
  t.after(() => api.close());
  const token = await authenticate(api);

  const owners = await api.request('/v1/tasks?owner=owner', { token });
  assert.equal(owners.status, 200);
  assert.ok(owners.body.data.items.length > 0);
  assert.ok(owners.body.data.items.every((item) => item.owner.kind === 'owner'));

  const agents = await api.request('/v1/tasks?owner=agent', { token });
  assert.ok(agents.body.data.items.every((item) => item.owner.kind === 'agent'));
  assert.ok(agents.body.data.items.length > 0);

  const todo = await api.request('/v1/tasks?status=todo', { token });
  assert.ok(todo.body.data.items.length > 0);
  assert.ok(todo.body.data.items.every((item) => item.status.name.toLowerCase() === 'todo'));

  const started = await api.request('/v1/tasks?status=started', { token });
  assert.ok(started.body.data.items.every((item) => item.status.type === 'started'));

  const project = await api.request('/v1/tasks?project=hq%E9%81%8B%E7%94%A8', { token });
  assert.ok(project.body.data.items.length > 0);
  assert.ok(project.body.data.items.every((item) => item.project.name === 'HQ運用'));

  const onlyKanban = await api.request('/v1/tasks?source=kanban', { token });
  assert.equal(onlyKanban.body.data.total, 1);
  assert.equal(onlyKanban.body.data.items[0].source, 'kanban');

  const invalidOwner = await api.request('/v1/tasks?owner=ceo', { token });
  assert.equal(invalidOwner.status, 400);
  assert.equal(invalidOwner.body.error.code, 'filter_invalid');
  const invalidSource = await api.request('/v1/tasks?source=drive', { token });
  assert.equal(invalidSource.status, 400);
});

test('pagination walks every item once and refuses a cursor from another filter set', async (t) => {
  const api = await startBridge({ tasks: { linear: fakeLinear(), kanban: fakeKanban() } });
  t.after(() => api.close());
  const token = await authenticate(api);

  const seen = [];
  let cursor = null;
  for (let page = 0; page < 5; page += 1) {
    const query = `/v1/tasks?limit=10${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ''}`;
    const res = await api.request(query, { token });
    assert.equal(res.status, 200);
    assert.ok(res.body.data.items.length <= 10);
    seen.push(...res.body.data.items.map((item) => item.id));
    cursor = res.body.data.nextCursor;
    if (!cursor) break;
  }
  assert.equal(seen.length, 25);
  assert.equal(new Set(seen).size, 25);

  const first = await api.request('/v1/tasks?limit=10', { token });
  const cursorFromAll = first.body.data.nextCursor;
  const mismatched = await api.request(`/v1/tasks?limit=10&owner=agent&cursor=${encodeURIComponent(cursorFromAll)}`, { token });
  assert.equal(mismatched.status, 400);
  assert.equal(mismatched.body.error.code, 'cursor_filter_mismatch');

  const malformed = await api.request('/v1/tasks?cursor=not-a-cursor', { token });
  assert.equal(malformed.status, 400);
  assert.equal(malformed.body.error.code, 'cursor_invalid');

  const badLimit = await api.request('/v1/tasks?limit=0', { token });
  assert.equal(badLimit.status, 400);
});

test('a cursor older than 24 hours asks the client to list again', async (t) => {
  let clockMs = Date.parse('2026-10-25T12:00:00.000Z');
  const api = await startBridge({
    now: () => clockMs,
    tasks: { linear: fakeLinear(), kanban: fakeKanban() },
  });
  t.after(() => api.close());
  const token = await authenticate(api);

  const first = await api.request('/v1/tasks?limit=10', { token });
  assert.ok(first.body.data.nextCursor);
  clockMs += 24 * 60 * 60 * 1000 + 1000;
  const expired = await api.request(
    `/v1/tasks?limit=10&cursor=${encodeURIComponent(first.body.data.nextCursor)}`,
    { token },
  );
  assert.equal(expired.status, 410);
  assert.equal(expired.body.error.code, 'cursor_expired');
});

test('detail returns the task with comments and links, and 404 outside the range', async (t) => {
  const linear = fakeLinear();
  const api = await startBridge({ tasks: { linear, kanban: fakeKanban() } });
  t.after(() => api.close());
  const token = await authenticate(api);

  for (const path of ['/v1/tasks/linear:BUS-101', '/v1/tasks/BUS-101']) {
    const res = await api.request(path, { token });
    assert.equal(res.status, 200);
    assert.equal(res.body.data.task.sourceId, 'BUS-101');
    assert.equal(res.body.data.task.description, 'description of BUS-101');
    assert.equal(res.body.data.comments[0].agentReport, true);
    assert.equal(res.body.data.links[0].title, 'report.md');
  }
  assert.deepEqual(linear.calls, ['get:BUS-101', 'get:BUS-101']);

  const unknown = await api.request('/v1/tasks/BUS-9999', { token });
  assert.equal(unknown.status, 404);
  assert.equal(unknown.body.error.code, 'task_not_found');

  const malformed = await api.request('/v1/tasks/not%20an%20id', { token });
  assert.equal(malformed.status, 404);
  const traversal = await api.request('/v1/tasks/%2e%2e%2fstate.json', { token });
  assert.equal(traversal.status, 404);
});

test('Kanban is a separate source and a Kanban copy of a Linear task is suppressed', async (t) => {
  const kanban = fakeKanban([
    kanbanTask('kb-1', { linearRefs: ['BUS-101'] }),
    kanbanTask('kb-2', { linearRefs: [] }),
  ]);
  const api = await startBridge({ tasks: { linear: fakeLinear(), kanban } });
  t.after(() => api.close());
  const token = await authenticate(api);

  const res = await api.request('/v1/tasks?source=all', { token });
  assert.equal(res.status, 200);
  assert.equal(res.body.data.total, 26); // 25 Linear + 1 real Kanban item
  assert.equal(res.body.data.suppressedDuplicates.kanban, 1);
  const kanbanItems = res.body.data.items.filter((item) => item.source === 'kanban');
  assert.equal(kanbanItems.length, 1);
  assert.equal(kanbanItems[0].sourceId, 'kb-2');
  assert.equal(kanbanItems[0].linearSourceId, null);

  const detail = await api.request('/v1/tasks/kanban:kb-2', { token });
  assert.equal(detail.status, 200);
  assert.equal(detail.body.data.task.source, 'kanban');

  const unavailable = await startBridge({
    tasks: { linear: fakeLinear(), kanban: fakeKanban([], { state: 'unavailable' }) },
  });
  t.after(() => unavailable.close());
  const otherToken = await authenticate(unavailable);
  const kanbanDetail = await unavailable.request('/v1/tasks/kanban:kb-2', { token: otherToken });
  assert.equal(kanbanDetail.status, 503);
  assert.equal(kanbanDetail.body.error.code, 'kanban_unavailable');
  assert.equal(kanbanDetail.body.error.retryable, false);
});

test('a Linear failure is a 503 dependency error, not an empty list', async (t) => {
  const failure = new TaskSourceError(
    'linear_credential_unavailable',
    'the Linear credential helper did not return a token',
  );
  const api = await startBridge({
    tasks: { linear: fakeLinear(ITEMS, { failWith: failure }), kanban: fakeKanban() },
  });
  t.after(() => api.close());
  const token = await authenticate(api);

  const res = await api.request('/v1/tasks', { token });
  assert.equal(res.status, 503);
  assert.equal(res.body.error.code, 'linear_credential_unavailable');
  assert.equal(res.body.error.retryable, false);
  assert.equal(res.body.error.message, 'the Linear credential helper did not return a token');

  const detail = await api.request('/v1/tasks/BUS-101', { token });
  assert.equal(detail.status, 503);
});

test('the task surface is read-only: GET only, no mutating source methods', () => {
  const linear = fakeLinear();
  const kanban = fakeKanban();
  const routes = taskRoutes({ linear, kanban });
  assert.equal(routes.length, 2);
  for (const route of routes) {
    assert.equal(route.method, 'GET');
    assert.equal(route.scope, 'tasks:read');
    assert.equal(route.idempotent, undefined);
    assert.equal(typeof route.handler, 'function');
  }
  const mutating = /dispatch|assign|start|create|update|write|delete|mutation|run|comment|reassign/i;
  for (const source of [linear, kanban]) {
    for (const key of Object.keys(source)) {
      assert.doesNotMatch(key, mutating, `${source.id ?? 'source'} must not expose ${key}`);
    }
  }
});

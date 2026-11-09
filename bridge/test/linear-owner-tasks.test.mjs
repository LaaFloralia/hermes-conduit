// /v1/linear-owner-tasks: the owner's own Linear tasks, readable and writable.
//
// The fake below is a tiny Linear: it answers only the eight fixed documents
// the source is allowed to send, and records every call so a test can prove
// that a retry did not write twice and that nothing else was sent.

import assert from 'node:assert/strict';
import test from 'node:test';
import { writeFileSync } from 'node:fs';
import { TaskSourceError } from '../src/tasks/errors.mjs';
import { createLinearOwnerTaskSource } from '../src/tasks/linear-owner.mjs';
import { linearOwnerTaskRoutes } from '../src/routes/linear-owner-tasks.mjs';
import { createTaskRunStore, createTaskDispatchService } from '../src/tasks/dispatch.mjs';
import { createSessionStore } from '../src/sessions/store.mjs';
import { startBridge } from './helpers.mjs';

const OWNER = 'd1f71177-5355-4f4f-b42c-7894c0870112';
const AGENT = 'agent-user-id';
const TEAM = { id: 'team-bus-id', key: 'BUS', name: 'LAA' };
const STATES = [
  { id: 'state-todo', name: 'Todo', type: 'unstarted' },
  { id: 'state-doing', name: 'In Progress', type: 'started' },
  { id: 'state-done', name: 'Done', type: 'completed' },
  { id: 'state-canceled', name: 'Canceled', type: 'canceled' },
];
const DOCUMENT_NAMES = new Set([
  'BridgeOwnerViewer',
  'BridgeOwnerTasks',
  'BridgeOwnerArchivedTasks',
  'BridgeOwnerTask',
  'BridgeOwnerTaskCreate',
  'BridgeOwnerTaskUpdate',
  'BridgeOwnerTaskArchive',
  'BridgeOwnerTaskRestore',
  'BridgeOwnerTaskComment',
  'BridgeOwnerTaskCommentCreate',
]);

function uuid(n) {
  return `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
}

function issue(overrides = {}) {
  return {
    id: uuid(1),
    identifier: 'BUS-201',
    title: 'Workタブのタスク',
    description: '説明',
    dueDate: null,
    priority: 2,
    url: 'https://linear.app/laa/issue/BUS-201',
    updatedAt: '2026-11-02T00:00:00.000Z',
    archivedAt: null,
    trashed: false,
    completedAt: null,
    canceledAt: null,
    state: { name: 'Todo', type: 'unstarted' },
    assignee: { id: OWNER, name: 'LAA' },
    delegate: null,
    team: { id: TEAM.id, key: TEAM.key, name: TEAM.name },
    ...overrides,
  };
}

function fakeLinear({
  viewer = { id: OWNER, name: 'LAA' },
  teams = [TEAM],
  states = STATES,
  issues = [],
  pageSize = 100,
  failOn = null,
  archiveOutcome = 'success',
  archiveEffect = true,
  archiveMarks = null,
  malformedIssueRead = null,
} = {}) {
  const store = new Map(issues.map((item) => [item.id, { ...item }]));
  const calls = [];
  const comments = new Map();
  let clock = Date.parse('2026-11-02T00:00:00.000Z');

  function stamp() {
    clock += 60_000;
    return new Date(clock).toISOString();
  }

  function stateById(id) {
    const state = states.find((item) => item.id === id);
    return state ? { name: state.name, type: state.type } : { name: 'Todo', type: 'unstarted' };
  }

  function visible() {
    // What Linear itself would return for team+assignee filters.
    return [...store.values()]
      .filter((item) => item.team?.key === TEAM.key)
      .filter((item) => item.assignee?.id === OWNER)
      .sort((a, b) => (a.id < b.id ? -1 : 1));
  }

  const fetchImpl = async (url, init) => {
    const { query, variables } = JSON.parse(init.body);
    const name = /(?:query|mutation)\s+([A-Za-z_]+)/.exec(query)?.[1];
    calls.push({ name, variables, headers: init.headers, query });
    if (!DOCUMENT_NAMES.has(name)) {
      return { ok: false, status: 400, json: async () => ({ errors: [{ message: 'unknown document' }] }) };
    }
    if (failOn === name) {
      return { ok: false, status: 500, json: async () => ({ errors: [{ message: 'upstream exploded with lin_api_secret' }] }) };
    }
    const reply = (data) => ({ ok: true, status: 200, json: async () => ({ data }) });

    if (name === 'BridgeOwnerViewer') return reply({ viewer, teams: { nodes: teams.map(t => ({ ...t, states: { nodes: states } })) } });

    if (name === 'BridgeOwnerTasks' || name === 'BridgeOwnerArchivedTasks') {
      const offset = variables.after === null ? 0 : Number(variables.after);
      const all = visible().filter(item => !item.delegate).filter(item => name === 'BridgeOwnerArchivedTasks'
        ? Boolean(item.archivedAt) : !item.archivedAt && !['completed', 'canceled'].includes(item.state?.type));
      const page = all.slice(offset, offset + pageSize);
      const hasNextPage = offset + pageSize < all.length;
      return reply({
        issues: {
          nodes: page,
          pageInfo: { hasNextPage, endCursor: hasNextPage ? String(offset + pageSize) : null },
        },
      });
    }

    if (name === 'BridgeOwnerTask') {
      if (malformedIssueRead === 'missing') return reply({});
      if (malformedIssueRead === 'string') return reply({ issue: 'not-an-issue' });
      const found = store.get(variables.id);
      if (!found) {
        return {
          ok: true,
          status: 200,
          json: async () => ({
            data: null,
            errors: [{ message: 'Entity not found: Issue', path: ['issue'], extensions: { code: 'INPUT_ERROR', userError: true } }],
          }),
        };
      }
      return reply({ issue: found });
    }

    if (name === 'BridgeOwnerTaskCreate') {
      const input = variables.input;
      if (store.has(input.id)) {
        return { ok: true, status: 200, json: async () => ({ data: null, errors: [{ message: 'duplicate id' }] }) };
      }
      const created = issue({
        id: input.id,
        identifier: 'BUS-999',
        title: input.title,
        description: input.description ?? '',
        dueDate: input.dueDate ?? null,
        priority: input.priority,
        updatedAt: stamp(),
        state: stateById(input.stateId),
        assignee: input.assigneeId ? { id: input.assigneeId, name: 'LAA' } : null,
        team: { id: TEAM.id, key: TEAM.key, name: TEAM.name },
      });
      store.set(created.id, created);
      return reply({ issueCreate: { success: true, issue: created } });
    }

    if (name === 'BridgeOwnerTaskComment') return reply({ comment: comments.get(variables.id) ?? null });
    if (name === 'BridgeOwnerTaskCommentCreate') {
      const input = variables.input;
      if (comments.has(input.id)) return { ok: true, status: 200, json: async () => ({ errors: [{ message: 'duplicate id' }] }) };
      comments.set(input.id, { ...input });
      return reply({ commentCreate: { success: true, comment: comments.get(input.id) } });
    }

    if (name === 'BridgeOwnerTaskUpdate') {
      const found = store.get(variables.id);
      if (!found) return { ok: true, status: 200, json: async () => ({ data: null, errors: [{ message: 'not found' }] }) };
      const input = variables.input;
      const next = { ...found, updatedAt: stamp() };
      if (Object.hasOwn(input, 'title')) next.title = input.title;
      if (Object.hasOwn(input, 'description')) next.description = input.description ?? '';
      if (Object.hasOwn(input, 'dueDate')) next.dueDate = input.dueDate;
      if (Object.hasOwn(input, 'priority')) next.priority = input.priority;
      if (Object.hasOwn(input, 'stateId')) next.state = stateById(input.stateId);
      if (Object.hasOwn(input, 'assigneeId')) {
        next.assignee = input.assigneeId ? { id: input.assigneeId, name: 'LAA' } : null;
      }
      store.set(next.id, next);
      return reply({ issueUpdate: { success: true, issue: next } });
    }

    if (name === 'BridgeOwnerTaskArchive' || name === 'BridgeOwnerTaskRestore') {
      const archived = name === 'BridgeOwnerTaskArchive';
      const found = store.get(variables.id);
      if (archiveEffect && found) store.set(found.id, { ...found, archivedAt: archived ? stamp() : null, updatedAt: stamp(), ...archiveMarks });
      if (archiveOutcome === 'graphql-error') return { ok: true, status: 200, json: async () => ({ errors: [{ message: 'rejected' }] }) };
      if (archiveOutcome === 'missing') return reply({});
      return reply({ [archived ? 'issueArchive' : 'issueUnarchive']: { success: archiveOutcome === 'success' } });
    }

    return { ok: false, status: 500, json: async () => ({ errors: [{ message: 'unhandled' }] }) };
  };

  fetchImpl.calls = calls;
  fetchImpl.issues = store;
  fetchImpl.comments = comments;
  fetchImpl.mutations = () => calls.filter((call) => call.name.startsWith('BridgeOwnerTask') && call.name !== 'BridgeOwnerTasks' && call.name !== 'BridgeOwnerTask');
  return fetchImpl;
}

function sourceFor(fetchImpl, overrides = {}) {
  return createLinearOwnerTaskSource({
    teamKey: 'BUS',
    teamName: 'LAA',
    ownerUserId: OWNER,
    fetchImpl,
    readToken: async () => 'test-token',
    ...overrides,
  });
}

async function bridgeWith(fetchImpl, options = {}) {
  const source = options.source ?? sourceFor(fetchImpl, options.sourceOptions ?? {});
  const bridge = await startBridge({ linearOwnerTasks: { source, ...options.linearOwnerTasks }, sessions: options.sessions, now: options.now });
  const token = await bridge.token();
  const readOnly = await bridge.token(['sessions:read', 'tasks:read']);
  const writeOnly = await bridge.token(['sessions:read', 'tasks:write']);
  return { bridge, token, readOnly, writeOnly };
}

test('the list is only the owner\'s open tasks, across every page', async () => {
  const fetchImpl = fakeLinear({
    pageSize: 2,
    issues: [
      issue({ id: uuid(1), identifier: 'BUS-201' }),
      issue({ id: uuid(2), identifier: 'BUS-202', assignee: { id: AGENT, name: 'LAA' } }),
      issue({ id: uuid(3), identifier: 'BUS-203', delegate: { id: AGENT, name: 'LAA' } }),
      issue({ id: uuid(4), identifier: 'BUS-204', state: { name: 'Done', type: 'completed' }, completedAt: '2026-11-01T00:00:00.000Z' }),
      issue({ id: uuid(5), identifier: 'BUS-205', state: { name: 'Canceled', type: 'canceled' } }),
      issue({ id: uuid(6), identifier: 'BUS-206', archivedAt: '2026-11-01T00:00:00.000Z' }),
      issue({ id: uuid(7), identifier: 'BUS-207', priority: 0, dueDate: '2026-11-05', state: { name: 'In Progress', type: 'started' } }),
      issue({ id: uuid(8), identifier: 'BUS-208' }),
    ],
  });
  const { bridge, token } = await bridgeWith(fetchImpl);
  try {
    const response = await bridge.request('/v1/linear-owner-tasks', { token });
    assert.equal(response.status, 200);
    assert.equal(response.body.data.nextCursor, null);
    assert.deepEqual(response.body.data.items.map((item) => item.identifier), ['BUS-201', 'BUS-207', 'BUS-208']);

    const [first] = response.body.data.items;
    assert.deepEqual(first, {
      id: uuid(1),
      identifier: 'BUS-201',
      title: 'Workタブのタスク',
      description: '説明',
      priority: 2,
      status: 'todo',
      stateName: 'Todo',
      updatedAt: '2026-11-02T00:00:00.000Z',
      archivedAt: null,
      url: 'https://linear.app/laa/issue/BUS-201',
      ref: 'T1',
      run: null,
    });
    assert.equal(response.body.data.items[1].status, 'doing');
    assert.equal(response.body.data.items[1].dueDate, '2026-11-05');
    assert.equal(response.body.data.items[1].priority, 0);

    // Two pages were read, and every read carried the fixed filter.
    const lists = fetchImpl.calls.filter((call) => call.name === 'BridgeOwnerTasks');
    assert.equal(lists.length, 2);
    for (const call of lists) {
      assert.deepEqual(call.variables, { team: 'BUS', owner: OWNER, after: call.variables.after });
      assert.match(call.query, /assignee: \{ id: \{ eq: \$owner \} \}/);
    }
    assert.deepEqual(lists.map((call) => call.variables.after), [null, '2']);
  } finally {
    await bridge.close();
  }
});

test('a row the filter should not have returned is still excluded', async () => {
  const config = async () => ({
    ok: true,
    status: 200,
    json: async () => ({ data: { viewer: { id: OWNER }, teams: { nodes: [{ ...TEAM, states: { nodes: STATES } }] } } }),
  });
  const rows = [
    issue({ id: uuid(1) }),
    // The same team and assignee, but an agent holds it.
    issue({ id: uuid(2), delegate: { id: AGENT, name: 'LAA' } }),
    // A different team that slipped through the filter.
    issue({ id: uuid(3), team: { id: 'other', key: 'OPS', name: 'Other' } }),
    // Someone else's task.
    issue({ id: uuid(4), assignee: { id: AGENT, name: 'LAA' } }),
    // Unassigned and still open.
    issue({ id: uuid(5), assignee: null }),
  ];
  const fetchImpl = async (url, init) => {
    const { query } = JSON.parse(init.body);
    if (/BridgeOwnerTasks/.test(query)) {
      return { ok: true, status: 200, json: async () => ({ data: { issues: { nodes: rows, pageInfo: { hasNextPage: false, endCursor: null } } } }) };
    }
    return config();
  };
  const { bridge, token } = await bridgeWith(null, { source: sourceFor(fetchImpl) });
  try {
    const response = await bridge.request('/v1/linear-owner-tasks', { token });
    assert.equal(response.status, 200);
    assert.deepEqual(response.body.data.items.map((item) => item.id), [uuid(1)]);
  } finally {
    await bridge.close();
  }
});

test('page information must be a boolean and cursors must not repeat', async () => {
  const settings = async () => ({
    ok: true,
    status: 200,
    json: async () => ({ data: { viewer: { id: OWNER }, teams: { nodes: [{ ...TEAM, states: { nodes: STATES } }] } } }),
  });
  const page = (pageInfo) => async (url, init) => {
    const { query } = JSON.parse(init.body);
    if (/BridgeOwnerTasks/.test(query)) {
      return { ok: true, status: 200, json: async () => ({ data: { issues: { nodes: [issue()], pageInfo } } }) };
    }
    return settings();
  };

  for (const pageInfo of [
    { hasNextPage: 'false', endCursor: null },
    { hasNextPage: 0, endCursor: null },
    { hasNextPage: null, endCursor: 'x' },
  ]) {
    const { bridge, token } = await bridgeWith(null, { source: sourceFor(page(pageInfo)) });
    try {
      const response = await bridge.request('/v1/linear-owner-tasks', { token });
      assert.equal(response.status, 503, JSON.stringify(pageInfo));
      assert.equal(response.body.error.code, 'linear_response_invalid');
    } finally {
      await bridge.close();
    }
  }

  // A -> B -> A would otherwise loop and look complete.
  let round = 0;
  const cycle = async (url, init) => {
    const { query } = JSON.parse(init.body);
    if (/BridgeOwnerTasks/.test(query)) {
      round += 1;
      const endCursor = round === 1 ? 'A' : round === 2 ? 'B' : 'A';
      return { ok: true, status: 200, json: async () => ({ data: { issues: { nodes: [issue()], pageInfo: { hasNextPage: true, endCursor } } } }) };
    }
    return settings();
  };
  const { bridge, token } = await bridgeWith(null, { source: sourceFor(cycle) });
  try {
    const response = await bridge.request('/v1/linear-owner-tasks', { token });
    assert.equal(response.status, 503);
    assert.equal(response.body.error.code, 'linear_pagination_stalled');
    assert.equal(round, 3);
  } finally {
    await bridge.close();
  }
});

test('a page that cannot be read is a 503, never a short list', async () => {
  // hasNextPage without a cursor
  const stalled = fakeLinear({ pageSize: 1, issues: [issue({ id: uuid(1) }), issue({ id: uuid(2) })] });
  const stallingSource = sourceFor(async (url, init) => {
    const { query } = JSON.parse(init.body);
    if (/BridgeOwnerTasks/.test(query)) {
      return {
        ok: true,
        status: 200,
        json: async () => ({ data: { issues: { nodes: [issue({ id: uuid(1) })], pageInfo: { hasNextPage: true, endCursor: 'same' } } } }),
      };
    }
    return stalled(url, init);
  });
  {
    const { bridge, token } = await bridgeWith(null, { source: stallingSource });
    try {
      const response = await bridge.request('/v1/linear-owner-tasks', { token });
      assert.equal(response.status, 503);
      assert.equal(response.body.error.code, 'linear_pagination_stalled');
      assert.equal(response.body.data, undefined);
    } finally {
      await bridge.close();
    }
  }

  // A page without pageInfo
  const noPageInfo = sourceFor(async (url, init) => {
    const { query } = JSON.parse(init.body);
    if (/BridgeOwnerTasks/.test(query)) {
      return { ok: true, status: 200, json: async () => ({ data: { issues: { nodes: [issue()] } } }) };
    }
    return { ok: true, status: 200, json: async () => ({ data: { viewer: { id: OWNER }, teams: { nodes: [{ ...TEAM, states: { nodes: STATES } }] } } }) };
  });
  {
    const { bridge, token } = await bridgeWith(null, { source: noPageInfo });
    try {
      const response = await bridge.request('/v1/linear-owner-tasks', { token });
      assert.equal(response.status, 503);
      assert.equal(response.body.error.code, 'linear_response_invalid');
    } finally {
      await bridge.close();
    }
  }

  // More pages than the Bridge reads
  const endless = sourceFor(async (url, init) => {
    const { query, variables } = JSON.parse(init.body);
    if (/BridgeOwnerTasks/.test(query)) {
      return {
        ok: true,
        status: 200,
        json: async () => ({
          data: {
            issues: {
              nodes: [issue()],
              pageInfo: { hasNextPage: true, endCursor: `${Number(variables.after ?? 0) + 1}` },
            },
          },
        }),
      };
    }
    return { ok: true, status: 200, json: async () => ({ data: { viewer: { id: OWNER }, teams: { nodes: [{ ...TEAM, states: { nodes: STATES } }] } } }) };
  });
  {
    const { bridge, token } = await bridgeWith(null, { source: endless });
    try {
      const response = await bridge.request('/v1/linear-owner-tasks', { token });
      assert.equal(response.status, 503);
      assert.equal(response.body.error.code, 'linear_pagination_incomplete');
    } finally {
      await bridge.close();
    }
  }
});

test('incomplete settings or a non-owner credential is a 503, not an empty list', async () => {
  const cases = [
    { name: 'no team', fetchImpl: fakeLinear({ teams: [] }), code: 'linear_owner_config_incomplete' },
    { name: 'renamed team', fetchImpl: fakeLinear({ teams: [{ ...TEAM, name: 'Other' }] }), code: 'linear_owner_config_incomplete' },
    { name: 'no Todo state', fetchImpl: fakeLinear({ states: STATES.filter((state) => state.name !== 'Todo') }), code: 'linear_owner_config_incomplete' },
    { name: 'agent credential', fetchImpl: fakeLinear({ viewer: { id: AGENT, name: 'LAA' } }), code: 'linear_owner_identity_mismatch' },
  ];
  for (const item of cases) {
    const { bridge, token } = await bridgeWith(item.fetchImpl);
    try {
      const response = await bridge.request('/v1/linear-owner-tasks', { token });
      assert.equal(response.status, 503, item.name);
      assert.equal(response.body.error.code, item.code, item.name);
      assert.equal(response.body.data, undefined, item.name);
    } finally {
      await bridge.close();
    }
  }

  // A missing credential helper is the same 503, without its output.
  const { bridge, token } = await bridgeWith(null, {
    source: createLinearOwnerTaskSource({
      teamKey: 'BUS',
      ownerUserId: OWNER,
      fetchImpl: async () => {
        throw new Error('must not be called');
      },
      readToken: async () => {
        throw new TaskSourceError('linear_credential_unavailable', 'the Linear credential helper did not return a token');
      },
    }),
  });
  try {
    const response = await bridge.request('/v1/linear-owner-tasks', { token });
    assert.equal(response.status, 503);
    assert.equal(response.body.error.code, 'linear_credential_unavailable');
  } finally {
    await bridge.close();
  }
});

test('detail reads one task and hides everyone else\'s', async () => {
  const fetchImpl = fakeLinear({
    issues: [
      issue({ id: uuid(1) }),
      issue({ id: uuid(2), assignee: { id: AGENT, name: 'LAA' } }),
      issue({ id: uuid(3), delegate: { id: AGENT, name: 'LAA' } }),
      // What this endpoint leaves behind after a completion.
      issue({
        id: uuid(4),
        state: { name: 'Done', type: 'completed' },
        assignee: null,
        completedAt: '2026-11-01T00:00:00.000Z',
      }),
      issue({ id: uuid(5), assignee: null }),
    ],
  });
  const { bridge, token } = await bridgeWith(fetchImpl);
  try {
    const mine = await bridge.request(`/v1/linear-owner-tasks/${uuid(1)}`, { token });
    assert.equal(mine.status, 200);
    assert.equal(mine.body.data.identifier, 'BUS-201');
    assert.equal(mine.body.data.status, 'todo');

    for (const id of [uuid(2), uuid(3), uuid(5), uuid(9), 'not-a-uuid']) {
      const other = await bridge.request(`/v1/linear-owner-tasks/${id}`, { token });
      assert.equal(other.status, 404, id);
      assert.equal(other.body.error.code, 'linear_owner_task_not_found');
    }

    const completed = await bridge.request(`/v1/linear-owner-tasks/${uuid(4)}`, { token });
    assert.equal(completed.status, 404);
  } finally {
    await bridge.close();
  }
});

test('create uses the client UUID, the owner, Todo and priority 0', async () => {
  const fetchImpl = fakeLinear();
  const { bridge, token } = await bridgeWith(fetchImpl);
  try {
    const body = { id: uuid(11), title: '  資料を作る  ', description: '詳細', dueDate: '2026-11-10' };
    const created = await bridge.request('/v1/linear-owner-tasks', {
      method: 'POST',
      token,
      key: 'draft-1',
      body,
    });
    assert.equal(created.status, 201);
    assert.equal(created.body.data.id, uuid(11));
    assert.equal(created.body.data.title, '資料を作る');
    assert.equal(created.body.data.description, '詳細');
    assert.equal(created.body.data.dueDate, '2026-11-10');
    assert.equal(created.body.data.priority, 0);
    assert.equal(created.body.data.status, 'todo');
    assert.equal(created.body.data.stateName, 'Todo');
    assert.match(created.body.data.updatedAt, /^\d{4}-\d{2}-\d{2}T/);

    const creates = fetchImpl.calls.filter((call) => call.name === 'BridgeOwnerTaskCreate');
    assert.equal(creates.length, 1);
    assert.deepEqual(creates[0].variables.input, {
      id: uuid(11),
      teamId: TEAM.id,
      title: '資料を作る',
      description: '詳細',
      dueDate: '2026-11-10',
      stateId: 'state-todo',
      assigneeId: OWNER,
      priority: 0,
    });

    // The same key and body replays the stored task instead of creating again.
    const replay = await bridge.request('/v1/linear-owner-tasks', {
      method: 'POST',
      token,
      key: 'draft-1',
      body,
    });
    assert.equal(replay.status, 201);
    assert.equal(replay.headers.get('idempotency-replayed'), 'true');
    assert.deepEqual(replay.body.data, created.body.data);
    assert.equal(fetchImpl.calls.filter((call) => call.name === 'BridgeOwnerTaskCreate').length, 1);

    // The same key with a different body is a conflict, not a second task.
    const conflict = await bridge.request('/v1/linear-owner-tasks', {
      method: 'POST',
      token,
      key: 'draft-1',
      body: { ...body, title: '別の題名' },
    });
    assert.equal(conflict.status, 409);
    assert.equal(conflict.body.error.code, 'idempotency_key_conflict');

    // A new key with the same UUID (a lost response, a new draft) does not
    // create a second issue: Linear refuses the duplicate and the existing
    // issue is the answer.
    const retried = await bridge.request('/v1/linear-owner-tasks', {
      method: 'POST',
      token,
      key: 'draft-2',
      body,
    });
    assert.equal(retried.status, 201);
    assert.equal(retried.body.data.id, uuid(11));
    assert.equal(fetchImpl.issues.size, 1);

    // The same UUID with different content is not the same request: nothing is
    // written and the caller is told the id is taken.
    for (const changed of [
      { ...body, title: '別の題名' },
      { ...body, description: '別の説明' },
      { ...body, dueDate: '2026-11-11' },
      { ...body, priority: 3 },
    ]) {
      const mismatch = await bridge.request('/v1/linear-owner-tasks', {
        method: 'POST',
        token,
        key: `draft-${Math.random()}`,
        body: changed,
      });
      assert.equal(mismatch.status, 409, JSON.stringify(changed));
      assert.equal(mismatch.body.error.code, 'linear_owner_task_conflict');
    }
    assert.equal(fetchImpl.issues.size, 1);
    assert.equal(fetchImpl.issues.get(uuid(11)).title, '資料を作る');

    // A conflict wrote nothing, so its key is free: the same key and body
    // answer the same conflict instead of "still executing".
    const again = await bridge.request('/v1/linear-owner-tasks', {
      method: 'POST',
      token,
      key: 'draft-3',
      body: { ...body, title: '別の題名' },
    });
    assert.equal(again.status, 409);
    const repeat = await bridge.request('/v1/linear-owner-tasks', {
      method: 'POST',
      token,
      key: 'draft-3',
      body: { ...body, title: '別の題名' },
    });
    assert.equal(repeat.status, 409);
    assert.equal(repeat.body.error.code, 'linear_owner_task_conflict');
  } finally {
    await bridge.close();
  }
});

test('create rejects anything outside the allowed fields and sizes', async () => {
  const fetchImpl = fakeLinear();
  const { bridge, token } = await bridgeWith(fetchImpl);
  const good = { id: uuid(21), title: '題名' };
  const bad = [
    [{ ...good, teamId: TEAM.id }, 'payload_field_unknown'],
    [{ ...good, assigneeId: OWNER }, 'payload_field_unknown'],
    [{ ...good, stateId: 'state-done' }, 'payload_field_unknown'],
    [{ title: '題名' }, 'payload_invalid'],
    [{ ...good, id: 'abc' }, 'payload_invalid'],
    [{ ...good, id: uuid(22).toUpperCase() }, null],
    [{ ...good, title: '   ' }, 'payload_invalid'],
    [{ ...good, title: 'x'.repeat(201) }, 'payload_invalid'],
    [{ ...good, description: 12 }, 'payload_invalid'],
    [{ ...good, description: 'x'.repeat(20_001) }, 'payload_invalid'],
    [{ ...good, dueDate: '2026/11/10' }, 'payload_invalid'],
    [{ ...good, dueDate: '2026-02-30' }, 'payload_invalid'],
    [{ ...good, priority: 5 }, 'payload_invalid'],
    [{ ...good, priority: '1' }, 'payload_invalid'],
  ];
  try {
    for (const [body, code] of bad) {
      const response = await bridge.request('/v1/linear-owner-tasks', { method: 'POST', token, key: `k-${Math.random()}`, body });
      if (code === null) {
        assert.equal(response.status, 201, JSON.stringify(body));
      } else {
        assert.equal(response.status, 400, JSON.stringify(body));
        assert.equal(response.body.error.code, code, JSON.stringify(body));
      }
    }
    assert.equal(fetchImpl.calls.filter((call) => call.name === 'BridgeOwnerTaskCreate').length, 1);

    const missingKey = await bridge.request('/v1/linear-owner-tasks', { method: 'POST', token, body: good });
    assert.equal(missingKey.status, 400);
    assert.equal(missingKey.body.error.code, 'idempotency_key_required');

    const readOnly = await bridge.token(['tasks:read']);
    const denied = await bridge.request('/v1/linear-owner-tasks', { method: 'POST', token: readOnly, key: 'k', body: good });
    assert.equal(denied.status, 403);
    assert.equal(denied.body.error.code, 'insufficient_scope');
  } finally {
    await bridge.close();
  }
});

test('a validation failure releases its key so the corrected retry can run', async () => {
  const fetchImpl = fakeLinear();
  const { bridge, token } = await bridgeWith(fetchImpl);
  try {
    const first = await bridge.request('/v1/linear-owner-tasks', {
      method: 'POST',
      token,
      key: 'draft-9',
      body: { id: uuid(31), title: '' },
    });
    assert.equal(first.status, 400);

    const corrected = await bridge.request('/v1/linear-owner-tasks', {
      method: 'POST',
      token,
      key: 'draft-9',
      body: { id: uuid(31), title: '直した題名' },
    });
    assert.equal(corrected.status, 201);
    assert.equal(corrected.body.data.title, '直した題名');
  } finally {
    await bridge.close();
  }
});

test('a settings 503 before the mutation releases its key for the same retry', async () => {
  const base = fakeLinear();
  let failures = 1;
  const flaky = async (url, init) => {
    const { query } = JSON.parse(init.body);
    if (/BridgeOwnerViewer/.test(query) && failures > 0) {
      failures -= 1;
      return { ok: false, status: 500, json: async () => ({ errors: [{ message: 'down with lin_api_secret' }] }) };
    }
    return base(url, init);
  };
  const { bridge, token } = await bridgeWith(null, { source: sourceFor(flaky) });
  try {
    const body = { id: uuid(32), title: '設定失敗のあと' };
    const first = await bridge.request('/v1/linear-owner-tasks', { method: 'POST', token, key: 'settings-1', body });
    assert.equal(first.status, 503);
    assert.equal(first.body.error.code, 'linear_unavailable');
    assert.equal(base.calls.filter((call) => call.name === 'BridgeOwnerTaskCreate').length, 0);

    // The failure was 503 but happened while resolving settings, before any
    // mutation; the same key must be usable.
    const retried = await bridge.request('/v1/linear-owner-tasks', { method: 'POST', token, key: 'settings-1', body });
    assert.equal(retried.status, 201);
    assert.equal(retried.body.data.title, '設定失敗のあと');
    assert.equal(base.calls.filter((call) => call.name === 'BridgeOwnerTaskCreate').length, 1);
  } finally {
    await bridge.close();
  }
});

test('a plain credential-helper error before the mutation keeps its marker through the route', async () => {
  const base = fakeLinear();
  let failures = 1;
  const source = sourceFor(base, {
    readToken: async () => {
      if (failures > 0) {
        failures -= 1;
        throw new Error('helper exploded with a secret');
      }
      return 'test-token';
    },
  });
  const { bridge, token } = await bridgeWith(null, { source });
  try {
    const body = { id: uuid(33), title: '資格情報の再試行' };
    const first = await bridge.request('/v1/linear-owner-tasks', { method: 'POST', token, key: 'credential-1', body });
    assert.equal(first.status, 503);
    assert.doesNotMatch(JSON.stringify(first.body), /helper exploded|secret/);

    const retried = await bridge.request('/v1/linear-owner-tasks', { method: 'POST', token, key: 'credential-1', body });
    assert.equal(retried.status, 201);
    assert.equal(retried.body.data.title, '資格情報の再試行');
    assert.equal(base.calls.filter((call) => call.name === 'BridgeOwnerTaskCreate').length, 1);
  } finally {
    await bridge.close();
  }
});

test('a 503 after the mutation keeps the key unresolved and never repeats the write', async () => {
  let clock = Date.parse('2026-11-02T00:00:00.000Z');
  const base = fakeLinear({ failOn: 'BridgeOwnerTaskCreate' });
  const { bridge, token } = await bridgeWith(null, { source: sourceFor(base), now: () => clock });
  try {
    const body = { id: uuid(34), title: '書込み後の503' };
    const first = await bridge.request('/v1/linear-owner-tasks', { method: 'POST', token, key: 'after-503', body });
    assert.equal(first.status, 503);
    assert.equal(base.calls.filter((call) => call.name === 'BridgeOwnerTaskCreate').length, 1);

    const during = await bridge.request('/v1/linear-owner-tasks', { method: 'POST', token, key: 'after-503', body });
    assert.equal(during.status, 409);
    assert.equal(during.body.error.code, 'idempotency_key_in_flight');

    clock += 61_000;
    const later = await bridge.request('/v1/linear-owner-tasks', { method: 'POST', token, key: 'after-503', body });
    assert.equal(later.status, 409);
    assert.equal(later.body.error.code, 'idempotency_outcome_unknown');
    assert.equal(base.calls.filter((call) => call.name === 'BridgeOwnerTaskCreate').length, 1);
  } finally {
    await bridge.close();
  }
});

test('a 400 or 404 after the mutation is not released either', async () => {
  for (const status of [400, 404]) {
    let clock = Date.parse('2026-11-02T00:00:00.000Z');
    let calls = 0;
    const source = {
      async createOwnerTask() {
        calls += 1;
        throw new TaskSourceError('linear_write_rejected', `write failed with ${status}`, { status, writeStarted: true });
      },
    };
    const { bridge, token } = await bridgeWith(null, { source, now: () => clock });
    try {
      const body = { id: uuid(35), title: `書込み後の${status}` };
      const key = `after-${status}`;
      const first = await bridge.request('/v1/linear-owner-tasks', { method: 'POST', token, key, body });
      assert.equal(first.status, status);
      clock += 61_000;
      const later = await bridge.request('/v1/linear-owner-tasks', { method: 'POST', token, key, body });
      assert.equal(later.status, 409);
      assert.equal(later.body.error.code, 'idempotency_outcome_unknown');
      assert.equal(calls, 1);
    } finally {
      await bridge.close();
    }
  }
});

test('patch requires If-Match, refuses a stale one, and only touches the owner\'s task', async () => {
  const fetchImpl = fakeLinear({
    issues: [
      issue({ id: uuid(41), updatedAt: '2026-11-02T00:00:00.000Z' }),
      issue({ id: uuid(42), assignee: { id: AGENT, name: 'LAA' } }),
    ],
  });
  const { bridge, token } = await bridgeWith(fetchImpl);
  const url = `/v1/linear-owner-tasks/${uuid(41)}`;
  try {
    const missing = await bridge.request(url, { method: 'PATCH', token, key: 'p0', body: { title: '新' } });
    assert.equal(missing.status, 428);
    assert.equal(missing.body.error.code, 'precondition_required');

    const invalid = await bridge.request(url, {
      method: 'PATCH',
      token,
      key: 'p0b',
      headers: { 'if-match': '*' },
      body: { title: '新' },
    });
    assert.equal(invalid.status, 400);
    assert.equal(invalid.body.error.code, 'precondition_invalid');

    const stale = await bridge.request(url, {
      method: 'PATCH',
      token,
      key: 'p1',
      headers: { 'if-match': '"2026-01-01T00:00:00.000Z"' },
      body: { title: '新' },
    });
    assert.equal(stale.status, 412);
    assert.equal(stale.body.error.code, 'precondition_failed');
    assert.deepEqual(stale.body.error.details, { updatedAt: '2026-11-02T00:00:00.000Z' });

    // The stale attempt wrote nothing, so its key is free for the retry.
    const updated = await bridge.request(url, {
      method: 'PATCH',
      token,
      key: 'p1',
      headers: { 'if-match': '2026-11-02T00:00:00.000Z' },
      body: { title: '新しい題名', priority: 1, dueDate: null },
    });
    assert.equal(updated.status, 200);
    assert.equal(updated.body.data.title, '新しい題名');
    assert.equal(updated.body.data.priority, 1);
    assert.equal(updated.body.data.dueDate, undefined);
    const update = fetchImpl.calls.filter((call) => call.name === 'BridgeOwnerTaskUpdate');
    assert.equal(update.length, 1);
    assert.deepEqual(update[0].variables, {
      id: uuid(41),
      input: { title: '新しい題名', priority: 1, dueDate: null },
    });

    const replay = await bridge.request(url, {
      method: 'PATCH',
      token,
      key: 'p1',
      headers: { 'if-match': '2026-11-02T00:00:00.000Z' },
      body: { title: '新しい題名', priority: 1, dueDate: null },
    });
    assert.equal(replay.status, 200);
    assert.equal(replay.headers.get('idempotency-replayed'), 'true');
    assert.equal(fetchImpl.calls.filter((call) => call.name === 'BridgeOwnerTaskUpdate').length, 1);

    const others = await bridge.request(`/v1/linear-owner-tasks/${uuid(42)}`, {
      method: 'PATCH',
      token,
      key: 'p2',
      headers: { 'if-match': '2026-11-02T00:00:00.000Z' },
      body: { title: '乗っ取り' },
    });
    assert.equal(others.status, 404);
    assert.equal(fetchImpl.calls.filter((call) => call.name === 'BridgeOwnerTaskUpdate').length, 1);
  } finally {
    await bridge.close();
  }
});

test('archive and restore retain the owner and workflow state, exclude trash, and replay once', async () => {
  const fake = fakeLinear({ pageSize: 1, issues: [issue({ id: uuid(61) }), issue({ id: uuid(62), trashed: true, archivedAt: '2026-11-01T00:00:00Z' }),
    issue({ id: uuid(63), assignee: { id: AGENT }, archivedAt: '2026-11-01T00:00:00Z' })] });
  const { bridge, token, writeOnly, readOnly } = await bridgeWith(fake);
  try {
    const url = `/v1/linear-owner-tasks/${uuid(61)}`;
    const archiveURL = `${url}/archive`;
    const headers = { 'if-match': '2026-11-02T00:00:00.000Z' };
    assert.equal((await bridge.request(archiveURL, { method: 'POST', token, key: 'no-version' })).status, 428);
    assert.equal((await bridge.request(archiveURL, { method: 'POST', token, key: 'stale', headers: { 'if-match': 'old' } })).status, 412);
    assert.equal((await bridge.request(archiveURL, { method: 'POST', token: writeOnly, key: 'write-only', headers })).status, 403);
    assert.equal((await bridge.request(archiveURL, { method: 'POST', token: readOnly, key: 'read-only', headers })).status, 403);
    const archived = await bridge.request(archiveURL, { method: 'POST', token, key: 'archive-1', headers });
    assert.equal(archived.status, 200);
    assert.deepEqual(archived.body.data, { id: uuid(61), archived: true });
    assert.equal(fake.issues.get(uuid(61)).assignee.id, OWNER);
    assert.equal(fake.issues.get(uuid(61)).state.type, 'unstarted');
    const replay = await bridge.request(archiveURL, { method: 'POST', token, key: 'archive-1', headers });
    assert.equal(replay.headers.get('idempotency-replayed'), 'true');
    assert.equal(fake.calls.filter(c => c.name === 'BridgeOwnerTaskArchive').length, 1);
    assert.deepEqual((await bridge.request('/v1/linear-owner-tasks', { token })).body.data.items, []);
    const list = await bridge.request('/v1/linear-owner-tasks?archived=only', { token });
    assert.deepEqual(list.body.data.items.map(t => t.id), [uuid(61)]);
    assert.ok(fake.calls.filter(c => c.name === 'BridgeOwnerTasks').every(c => !c.query.includes('includeArchived')));
    assert.ok(fake.calls.some(c => c.name === 'BridgeOwnerArchivedTasks' && c.query.includes('archivedAt: { null: false }')));
    assert.equal((await bridge.request(url, { method: 'PATCH', token, key: 'edit-archived', headers: { 'if-match': list.body.data.items[0].updatedAt }, body: { title: 'bad' } })).status, 409);
    const restoreHeaders = { 'if-match': list.body.data.items[0].updatedAt };
    const restored = await bridge.request(`${url}/restore`, { method: 'POST', token, key: 'restore-1', headers: restoreHeaders });
    assert.equal(restored.status, 200);
    assert.deepEqual(restored.body.data, { id: uuid(61), archived: false });
    assert.equal((await bridge.request(`${url}/restore`, { method: 'POST', token, key: 'restore-1', headers: restoreHeaders })).headers.get('idempotency-replayed'), 'true');
    assert.equal(fake.calls.filter(c => c.name === 'BridgeOwnerTaskRestore').length, 1);
    assert.equal((await bridge.request('/v1/linear-owner-tasks', { token })).body.data.items[0].id, uuid(61));
    assert.deepEqual((await bridge.request('/v1/linear-owner-tasks?archived=only', { token })).body.data.items, []);
    assert.equal((await bridge.request(`/v1/linear-owner-tasks/${uuid(63)}/restore`, { method: 'POST', token, key: 'other', headers })).status, 404);
    assert.equal((await bridge.request(`/v1/linear-owner-tasks/${uuid(62)}/restore`, { method: 'POST', token, key: 'trash', headers })).status, 404);
    assert.equal((await bridge.request(url, { method: 'DELETE', token, key: 'old-delete', headers })).status, 405);
    assert.equal((await bridge.request('/v1/linear-owner-tasks?archived=bad', { token })).status, 400);
  } finally { await bridge.close(); }
});

test('failed archive never confuses a missing or trashed issue with an archived issue', async () => {
  for (const options of [
    { archiveOutcome: 'success-false', archiveEffect: false },
    { archiveOutcome: 'missing', archiveEffect: false },
    { archiveOutcome: 'success-false', archiveMarks: { trashed: true } },
  ]) {
    const fake = fakeLinear({ issues: [issue()], ...options });
    const { bridge, token } = await bridgeWith(fake);
    try {
      const url = `/v1/linear-owner-tasks/${uuid(1)}/archive`;
      const args = { method: 'POST', token, key: 'uncertain', headers: { 'if-match': '2026-11-02T00:00:00.000Z' } };
      assert.equal((await bridge.request(url, args)).status, 503);
      assert.equal((await bridge.request(url, args)).status, 409);
      assert.equal(fake.calls.filter(c => c.name === 'BridgeOwnerTaskArchive').length, 1);
    } finally { await bridge.close(); }
  }
});

test('an ambiguous archive or restore is reconciled only by an owned non-trashed issue state', async () => {
  const fake = fakeLinear({ issues: [issue()], archiveOutcome: 'missing' });
  const { bridge, token } = await bridgeWith(fake);
  try {
    const path = `/v1/linear-owner-tasks/${uuid(1)}`;
    assert.equal((await bridge.request(`${path}/archive`, { method: 'POST', token, key: 'a', headers: { 'if-match': '2026-11-02T00:00:00.000Z' } })).status, 200);
    const current = (await bridge.request(path, { token })).body.data;
    assert.ok(current.archivedAt);
    assert.equal((await bridge.request(`${path}/restore`, { method: 'POST', token, key: 'r', headers: { 'if-match': current.updatedAt } })).status, 200);
  } finally { await bridge.close(); }
});

test('an upstream failure is a sanitised 503 and never sends an arbitrary document', async () => {
  const fetchImpl = fakeLinear({ failOn: 'BridgeOwnerTasks' });
  const { bridge, token } = await bridgeWith(fetchImpl);
  try {
    const response = await bridge.request('/v1/linear-owner-tasks', { token });
    assert.equal(response.status, 503);
    assert.equal(response.body.error.code, 'linear_unavailable');
    assert.doesNotMatch(JSON.stringify(response.body), /lin_api_secret|upstream exploded/);

    for (const call of fetchImpl.calls) {
      assert.ok(DOCUMENT_NAMES.has(call.name), call.name);
      assert.equal(call.headers.authorization, 'Bearer test-token');
    }
  } finally {
    await bridge.close();
  }
});

test('the source sends only its own fixed documents', async () => {
  const fetchImpl = fakeLinear({ issues: [issue({ id: uuid(71) })] });
  const source = sourceFor(fetchImpl);
  await source.listOwnerTasks();
  await source.readOwnerTask(uuid(71));
  await source.createOwnerTask({ id: uuid(72), title: 't', priority: 0 });
  await source.patchOwnerTask(uuid(72), { title: 'u' });
  await source.archiveOwnerTask(uuid(72));
  await source.restoreOwnerTask(uuid(72));

  const names = fetchImpl.calls.map((call) => call.name);
  assert.deepEqual(names, [
    'BridgeOwnerViewer',
    'BridgeOwnerTasks',
    'BridgeOwnerTask',
    'BridgeOwnerTaskCreate',
    'BridgeOwnerTaskUpdate',
    'BridgeOwnerTaskArchive',
  'BridgeOwnerTaskRestore',
  ]);
  for (const call of fetchImpl.calls) {
    assert.match(call.query, /^(query|mutation) BridgeOwner/);
  }
});

test('create, update, archive and restore invalidate warm owner and archive snapshots', async () => {
  const fake = fakeLinear({ issues: [issue()] });
  const source = sourceFor(fake);
  const lists = () => fake.calls.filter(c => ['BridgeOwnerTasks', 'BridgeOwnerArchivedTasks'].includes(c.name)).length;
  const warm = async () => { await source.listOwnerTasks(); await source.listOwnerTasks({ archived: true }); };
  await warm(); assert.equal(lists(), 2);
  await warm(); assert.equal(lists(), 2);
  for (const mutate of [
    () => source.createOwnerTask({ id: uuid(99), title: 'new', priority: 0 }),
    () => source.patchOwnerTask(uuid(99), { title: 'updated' }),
    () => source.archiveOwnerTask(uuid(99)),
    () => source.restoreOwnerTask(uuid(99)),
  ]) {
    const before = lists(); await mutate(); await warm(); assert.equal(lists(), before + 2);
  }
});

test('the routes are registered with the Work tab\'s scopes', () => {
  const routes = linearOwnerTaskRoutes({ source: { } });
  assert.deepEqual(
    routes.map((route) => [route.method, route.path, route.scope, Boolean(route.idempotent)]),
    [
      ['GET', '/v1/linear-owner-tasks', 'tasks:read', false],
      ['POST', '/v1/linear-owner-tasks', 'tasks:write', true],
      ['GET', '/v1/linear-owner-tasks/{id}', 'tasks:read', false],
      ['PATCH', '/v1/linear-owner-tasks/{id}', 'tasks:write', true],
      ['POST', '/v1/linear-owner-tasks/{id}/archive', 'tasks:write', true],
      ['POST', '/v1/linear-owner-tasks/{id}/restore', 'tasks:write', true],
      ['POST', '/v1/linear-owner-tasks/{id}/complete', 'tasks:write', false],
    ],
  );
});

test('the owner creation records its paired device and never starts a session', async (t) => {
  const fake = fakeLinear(); const { bridge, token } = await bridgeWith(fake); t.after(() => bridge.close());
  const created = await bridge.request('/v1/linear-owner-tasks', { method: 'POST', token, key: 'owner-create', body: { id: uuid(80), title: '社長の仕事' } });
  assert.equal(created.status, 201); assert.deepEqual(created.body.data.run.assignee, { kind: 'owner' }); assert.equal(created.body.data.run.state, null);
  const store = createTaskRunStore({ dir: bridge.stateDir }); assert.equal(store.all().length, 1); assert.equal(store.get(uuid(80)).creator, 'owner'); assert.match(store.get(uuid(80)).deviceId, /^dev_/);
  const replay = await bridge.request('/v1/linear-owner-tasks', { method: 'POST', token, key: 'owner-create', body: { id: uuid(80), title: '社長の仕事' } });
  assert.equal(replay.status, 201); assert.equal(store.all().length, 1); assert.equal(fake.calls.filter((c) => c.name === 'BridgeOwnerTaskCreate').length, 1);
});

function taskSessionFixture() {
  const calls = [];
  return { calls, options: () => ({ profiles: [{ id: 'opus-high', label: 'Opus 5.5', effort: 'high' }] }),
    adapter: { async create(input) { calls.push(input); return { sessionId: 'task-agent', requested: { profile: input.profile, provider: 'claude', model: 'opus', effort: 'high' } }; },
      async status() { return { phase: 'awaiting_review', daemonStatus: 'idle', pending: [] }; } } };
}

async function waitFor(testFn) {
  for (let i = 0; i < 200; i++) { if (testFn()) return; await new Promise((r) => setTimeout(r, 5)); }
  assert.fail('the fake task pickup did not finish');
}

test('a paired staff create keeps Linear assigned to the owner and exposes its session in list and detail', async (t) => {
  const fake = fakeLinear(), sessions = taskSessionFixture();
  const { bridge, token } = await bridgeWith(fake, { sessions }); t.after(() => bridge.close());
  const body = { id: uuid(81), title: 'AIの仕事', description: '確認して仕上げる', assignee: { kind: 'staff', staff: 'cto' }, profile: 'opus-high' };
  const created = await bridge.request('/v1/linear-owner-tasks', { method: 'POST', token, key: 'staff-create', body });
  assert.equal(created.status, 201); assert.ok(['queued', 'running'].includes(created.body.data.run.state));
  await waitFor(() => fake.comments.size === 1);
  const detail = await bridge.request(`/v1/linear-owner-tasks/${uuid(81)}`, { token });
  assert.equal(detail.body.data.run.state, 'running'); assert.deepEqual(detail.body.data.run.assignee, { kind: 'staff', staff: 'cto', name: 'Ada' }); assert.equal(detail.body.data.run.sessionRef, 'S1');
  const list = await bridge.request('/v1/linear-owner-tasks', { token }); assert.deepEqual(list.body.data.items[0].run, detail.body.data.run);
  assert.equal(fake.calls.find((c) => c.name === 'BridgeOwnerTaskCreate').variables.input.assigneeId, OWNER);
  assert.equal(sessions.calls[0].cwd, '/Users/laa'); assert.equal(sessions.calls[0].mode, 'bypass'); assert.match(sessions.calls[0].task.prompt, /Ada（CTO）/);
  const replay = await bridge.request('/v1/linear-owner-tasks', { method: 'POST', token, key: 'staff-create', body }); assert.equal(replay.status, 201); assert.equal(sessions.calls.length, 1);
  const changed = await bridge.request('/v1/linear-owner-tasks', { method: 'POST', token, key: 'other-assignment', body: { ...body, assignee: { kind: 'staff', staff: 'monet' } } });
  assert.equal(changed.status, 409); assert.equal(changed.body.error.code, 'task_assignment_conflict');
});

test('a device without sessions:write cannot start or archive a task session', async (t) => {
  const fake = fakeLinear(), sessions = taskSessionFixture();
  const { bridge, token } = await bridgeWith(fake, { sessions, linearOwnerTasks: { cleanup: () => {} } }); t.after(() => bridge.close());
  const tasksOnly = await bridge.token(['tasks:read', 'tasks:write']);
  const staffBody = { id: uuid(85), title: 'AIの仕事', assignee: { kind: 'staff', staff: 'monet' }, profile: 'opus-high' };
  const denied = await bridge.request('/v1/linear-owner-tasks', { method: 'POST', token: tasksOnly, key: 'tasks-only-staff', body: staffBody });
  assert.equal(denied.status, 403); assert.equal(denied.body.error.code, 'insufficient_scope');
  assert.equal(fake.calls.filter((c) => c.name === 'BridgeOwnerTaskCreate').length, 0); assert.equal(sessions.calls.length, 0);
  const owner = await bridge.request('/v1/linear-owner-tasks', { method: 'POST', token: tasksOnly, key: 'tasks-only-owner', body: { id: uuid(86), title: '社長の仕事' } });
  assert.equal(owner.status, 201);
  await bridge.request('/v1/linear-owner-tasks', { method: 'POST', token, key: 'full-staff', body: staffBody });
  await waitFor(() => fake.comments.size === 1);
  const headers = { 'if-match': fake.issues.get(uuid(85)).updatedAt };
  const archive = await bridge.request(`/v1/linear-owner-tasks/${uuid(85)}/complete`, { method: 'POST', token: tasksOnly, key: 'tasks-only-complete', headers });
  assert.equal(archive.status, 403); assert.equal(archive.body.error.code, 'insufficient_scope'); assert.notEqual(fake.issues.get(uuid(85)).state.type, 'completed');
  const ownerDone = await bridge.request(`/v1/linear-owner-tasks/${uuid(86)}/complete`, { method: 'POST', token: tasksOnly, key: 'tasks-only-owner-complete', headers: { 'if-match': fake.issues.get(uuid(86)).updatedAt } });
  assert.equal(ownerDone.status, 200);
});

test('staff, profile and execution-store validation stop before the Linear create', async (t) => {
  const fake = fakeLinear(), sessions = taskSessionFixture(); const { bridge, token } = await bridgeWith(fake, { sessions }); t.after(() => bridge.close());
  for (const [i, extra] of [{ assignee: { kind: 'staff', staff: 'cfo' } }, { assignee: { kind: 'staff', staff: 'cfo' }, profile: 'alias' },
    { assignee: { kind: 'staff', staff: 'bad' }, profile: 'opus-high' }, { assignee: { kind: 'owner' }, profile: null }].entries()) {
    const result = await bridge.request('/v1/linear-owner-tasks', { method: 'POST', token, key: `invalid-${i}`, body: { id: uuid(82), title: '題名', ...extra } }); assert.equal(result.status, 400);
  }
  writeFileSync(`${bridge.stateDir}/task-runs.json`, '{');
  const corrupt = await bridge.request('/v1/linear-owner-tasks', { method: 'POST', token, key: 'corrupt-run', body: { id: uuid(82), title: '題名' } });
  assert.equal(corrupt.status, 503); assert.equal(corrupt.body.error.code, 'task_runs_store_unavailable'); assert.equal(fake.calls.filter((c) => c.name === 'BridgeOwnerTaskCreate').length, 0);
});

test('complete requires write plus read, If-Match and Idempotency-Key and can complete legacy owner tasks', async (t) => {
  const fake = fakeLinear({ issues: [issue({ id: uuid(83) })] }); let cleanups = 0;
  const { bridge, token, readOnly, writeOnly } = await bridgeWith(fake, { linearOwnerTasks: { cleanup: () => { cleanups++; } } }); t.after(() => bridge.close());
  const path = `/v1/linear-owner-tasks/${uuid(83)}/complete`, headers = { 'if-match': issue().updatedAt };
  for (const denied of [readOnly, writeOnly]) assert.equal((await bridge.request(path, { method: 'POST', token: denied, key: 'scope', headers })).status, 403);
  assert.equal((await bridge.request(path, { method: 'POST', token, key: 'missing-match' })).status, 428);
  assert.equal((await bridge.request(path, { method: 'POST', token, headers })).body.error.code, 'idempotency_key_required');
  assert.equal((await bridge.request(path, { method: 'POST', token, key: 'stale', headers: { 'if-match': 'old' } })).status, 412);
  const result = await bridge.request(path, { method: 'POST', token, key: 'complete-legacy', headers });
  assert.equal(result.status, 200); assert.deepEqual(result.body.data, { id: uuid(83), completed: true, sessionArchived: false, archive: 'queued' });
  assert.equal(fake.issues.get(uuid(83)).state.type, 'completed'); assert.equal(cleanups, 1);
  assert.match([...fake.comments.values()][0].body, /\[laa-bridge\] 完了（社長）\n報告なし/);
  assert.deepEqual((await bridge.request('/v1/linear-owner-tasks', { token })).body.data.items, []);
  fake.issues.delete(uuid(83));
  const replay = await bridge.request(path, { method: 'POST', token, key: 'complete-legacy', headers });
  assert.equal(replay.status, 200); assert.equal(replay.headers.get('idempotency-replayed'), 'true'); assert.equal(cleanups, 1);
});

test('the staff complete API archives its session and preserves the report in a Linear comment', async (t) => {
  const fake = fakeLinear(), sessions = taskSessionFixture(); let cleanups = 0;
  const { bridge, token } = await bridgeWith(fake, { sessions, linearOwnerTasks: { cleanup: () => { cleanups++; } } }); t.after(() => bridge.close());
  await bridge.request('/v1/linear-owner-tasks', { method: 'POST', token, key: 'staff-complete-create', body: { id: uuid(84), title: 'AIの仕事', assignee: { kind: 'staff', staff: 'monet' }, profile: 'opus-high' } });
  await waitFor(() => fake.comments.size === 1);
  const report = createTaskDispatchService({ store: createTaskRunStore({ dir: bridge.stateDir }), sessionStore: createSessionStore({ file: `${bridge.stateDir}/sessions.json` }) });
  await report.report(uuid(84), '完成。試験成功。残件なし。', 'task-agent');
  const task = (await bridge.request(`/v1/linear-owner-tasks/${uuid(84)}`, { token })).body.data;
  assert.equal(task.run.state, 'done');
  const result = await bridge.request(`/v1/linear-owner-tasks/${uuid(84)}/complete`, { method: 'POST', token, key: 'staff-complete', headers: { 'if-match': task.updatedAt } });
  assert.equal(result.status, 200); assert.equal(result.body.data.sessionArchived, true); assert.equal(cleanups, 1);
  assert.ok(createSessionStore({ file: `${bridge.stateDir}/sessions.json` }).get(task.run.sessionId).archivedAt);
  assert.match([...fake.comments.values()].find((c) => c.body.startsWith('[laa-bridge] 完了')).body, /S1・AIの仕事・Monet・Opus 5.5 · High.*\n完成。試験成功。残件なし。/s);
});

test('comment UUID reconciliation prevents a second comment after a lost response', async () => {
  const fake = fakeLinear({ issues: [issue()] }); let lose = true;
  const wrapped = async (url, init) => { const result = await fake(url, init); if (init.body.includes('mutation BridgeOwnerTaskCommentCreate') && lose) { lose = false; throw new Error('secret echo'); } return result; };
  const source = sourceFor(wrapped); const comment = { id: uuid(90), body: '[laa-bridge] 完了（社長）\n報告なし' };
  await source.commentOwnerTask(uuid(1), comment); await source.commentOwnerTask(uuid(1), comment);
  assert.equal(fake.comments.size, 1); assert.equal(fake.calls.filter((c) => c.name === 'BridgeOwnerTaskCommentCreate').length, 1);
  await assert.rejects(source.commentOwnerTask(uuid(1), { ...comment, body: 'changed' }), { code: 'linear_comment_conflict' });
});

test('comment and completion writes re-read owner scope and refuse delegated, foreign, trashed and missing issues', async () => {
  for (const marks of [{ assignee: { id: AGENT } }, { delegate: { id: AGENT } }, { trashed: true }, { team: { key: 'OTHER' } }, null]) {
    const fake = fakeLinear({ issues: marks ? [issue(marks)] : [] }), source = sourceFor(fake);
    await assert.rejects(source.commentOwnerTask(uuid(1), { id: uuid(91), body: 'fixed' }), { code: 'linear_owner_task_not_found' });
    await assert.rejects(source.completeOwnerTask(uuid(1)), { code: 'linear_owner_task_not_found' });
    assert.equal(fake.mutations().filter((c) => c.name !== 'BridgeOwnerTaskComment').length, 0);
  }
});

test('completion resolves the completed-type state and reconciles an uncertain Done response', async () => {
  const fake = fakeLinear({ issues: [issue()], states: STATES.map((s) => s.type === 'completed' ? { ...s, name: 'Finished' } : s) }); let lose = true;
  const wrapped = async (url, init) => { const result = await fake(url, init); if (init.body.includes('mutation BridgeOwnerTaskUpdate') && lose) { lose = false; throw new Error('lost'); } return result; };
  const source = sourceFor(wrapped); await source.completeOwnerTask(uuid(1)); await source.completeOwnerTask(uuid(1));
  assert.equal(fake.issues.get(uuid(1)).state.type, 'completed'); assert.equal(fake.calls.filter((c) => c.name === 'BridgeOwnerTaskUpdate').length, 1);
  const absent = sourceFor(fakeLinear({ states: STATES.filter((s) => s.type !== 'completed') }));
  await assert.rejects(absent.prepareCompletion(), { code: 'linear_owner_config_incomplete', writeStarted: false });
});

test('the complete API resumes a persisted stage after an upstream failure and a Bridge restart', async (t) => {
  const fake = fakeLinear({ issues: [issue({ id: uuid(85) })] }); let failUpdate = true, cleanups = 0;
  const wrapped = async (url, init) => {
    if (init.body.includes('mutation BridgeOwnerTaskUpdate') && failUpdate) {
      failUpdate = false; return { ok: false, status: 503, json: async () => ({}) };
    }
    return fake(url, init);
  };
  const { bridge, token } = await bridgeWith(fake, { source: sourceFor(wrapped), linearOwnerTasks: { cleanup: () => { cleanups++; } } }); t.after(() => bridge.close());
  const path = `/v1/linear-owner-tasks/${uuid(85)}/complete`, request = { method: 'POST', token, key: 'resume-complete', headers: { 'if-match': issue().updatedAt } };
  assert.equal((await bridge.request(path, request)).status, 503); assert.equal(fake.comments.size, 1); assert.equal(cleanups, 0);
  assert.equal(createTaskRunStore({ dir: bridge.stateDir }).completion(uuid(85)).stage, 3);
  await bridge.restart();
  assert.equal((await bridge.request(path, request)).status, 200); assert.equal(fake.comments.size, 1); assert.equal(cleanups, 1); assert.equal(fake.issues.get(uuid(85)).state.type, 'completed');
});

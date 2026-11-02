// /v1/linear-owner-tasks: the owner's own Linear tasks, readable and writable.
//
// The fake below is a tiny Linear: it answers only the eight fixed documents
// the source is allowed to send, and records every call so a test can prove
// that a retry did not write twice and that nothing else was sent.

import assert from 'node:assert/strict';
import test from 'node:test';
import { TaskSourceError } from '../src/tasks/errors.mjs';
import { createLinearOwnerTaskSource } from '../src/tasks/linear-owner.mjs';
import { linearOwnerTaskRoutes } from '../src/routes/linear-owner-tasks.mjs';
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
  'BridgeOwnerTeam',
  'BridgeOwnerStates',
  'BridgeOwnerTasks',
  'BridgeOwnerTask',
  'BridgeOwnerTaskCreate',
  'BridgeOwnerTaskUpdate',
  'BridgeOwnerTaskDelete',
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
  deleteKeepsIssue = false,
  deleteOutcome = null,
  deleteRemovesIssue = false,
  deleteMarks = null,
  malformedIssueRead = null,
} = {}) {
  const store = new Map(issues.map((item) => [item.id, { ...item }]));
  const calls = [];
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

    if (name === 'BridgeOwnerViewer') return reply({ viewer });
    if (name === 'BridgeOwnerTeam') return reply({ teams: { nodes: teams } });
    if (name === 'BridgeOwnerStates') return reply({ team: { states: { nodes: states } } });

    if (name === 'BridgeOwnerTasks') {
      const offset = variables.after === null ? 0 : Number(variables.after);
      const all = visible();
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

    if (name === 'BridgeOwnerTaskDelete') {
      if (deleteOutcome === 'graphql-error') {
        return {
          ok: true,
          status: 200,
          json: async () => ({
            data: null,
            errors: [{ message: 'delete rejected', path: ['issueDelete'], extensions: { code: 'INPUT_ERROR', userError: true } }],
          }),
        };
      }
      if (deleteOutcome === 'missing') return reply({});
      const success = deleteOutcome !== 'success-false';
      if (success && !deleteKeepsIssue) store.delete(variables.id);
      if (!success && deleteRemovesIssue) store.delete(variables.id);
      if (deleteKeepsIssue && deleteMarks) {
        const found = store.get(variables.id);
        if (found) store.set(found.id, { ...found, ...deleteMarks });
      }
      return reply({ issueDelete: { success } });
    }

    return { ok: false, status: 500, json: async () => ({ errors: [{ message: 'unhandled' }] }) };
  };

  fetchImpl.calls = calls;
  fetchImpl.issues = store;
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
  const bridge = await startBridge({ linearOwnerTasks: { source }, now: options.now });
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
      url: 'https://linear.app/laa/issue/BUS-201',
    });
    assert.equal(response.body.data.items[1].status, 'doing');
    assert.equal(response.body.data.items[1].dueDate, '2026-11-05');
    assert.equal(response.body.data.items[1].priority, 0);

    // Two pages were read, and every read carried the fixed filter.
    const lists = fetchImpl.calls.filter((call) => call.name === 'BridgeOwnerTasks');
    assert.equal(lists.length, 4);
    for (const call of lists) {
      assert.deepEqual(call.variables, { team: 'BUS', owner: OWNER, after: call.variables.after });
      assert.match(call.query, /assignee: \{ id: \{ eq: \$owner \} \}/);
    }
    assert.deepEqual(lists.map((call) => call.variables.after), [null, '2', '4', '6']);
  } finally {
    await bridge.close();
  }
});

test('a row the filter should not have returned is still excluded', async () => {
  const config = async () => ({
    ok: true,
    status: 200,
    json: async () => ({ data: { viewer: { id: OWNER }, teams: { nodes: [TEAM] }, team: { states: { nodes: STATES } } } }),
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
    json: async () => ({ data: { viewer: { id: OWNER }, teams: { nodes: [TEAM] }, team: { states: { nodes: STATES } } } }),
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
    return { ok: true, status: 200, json: async () => ({ data: { viewer: { id: OWNER }, teams: { nodes: [TEAM] }, team: { states: { nodes: STATES } } } }) };
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
    return { ok: true, status: 200, json: async () => ({ data: { viewer: { id: OWNER }, teams: { nodes: [TEAM] }, team: { states: { nodes: STATES } } } }) };
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
    { name: 'no completed state', fetchImpl: fakeLinear({ states: STATES.filter((state) => state.type !== 'completed') }), code: 'linear_owner_config_incomplete' },
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
    assert.equal(completed.status, 200);
    assert.equal(completed.body.data.status, 'done');
    assert.equal(completed.body.data.stateName, 'Done');
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

test('completing a task moves it to Done and unassigns it, and stays readable', async () => {
  const fetchImpl = fakeLinear({ issues: [issue({ id: uuid(51) })] });
  const { bridge, token } = await bridgeWith(fetchImpl);
  const url = `/v1/linear-owner-tasks/${uuid(51)}`;
  try {
    const done = await bridge.request(url, {
      method: 'PATCH',
      token,
      key: 'c1',
      headers: { 'if-match': '2026-11-02T00:00:00.000Z' },
      body: { completed: true },
    });
    assert.equal(done.status, 200);
    assert.equal(done.body.data.status, 'done');
    assert.equal(done.body.data.stateName, 'Done');
    const update = fetchImpl.calls.find((call) => call.name === 'BridgeOwnerTaskUpdate');
    assert.deepEqual(update.variables.input, { stateId: 'state-done', assigneeId: null });

    // Reconciling a completion: the id is the capability, so a second device
    // that kept the draft can still read the finished task.
    const read = await bridge.request(url, { token });
    assert.equal(read.status, 200);
    assert.equal(read.body.data.status, 'done');

    // A fresh key (the app was relaunched) can also repeat the completion.
    const again = await bridge.request(url, {
      method: 'PATCH',
      token,
      key: 'c2',
      headers: { 'if-match': done.body.data.updatedAt },
      body: { completed: true },
    });
    assert.equal(again.status, 200);
    assert.equal(again.body.data.status, 'done');

    // The finished task is gone from the list.
    const list = await bridge.request('/v1/linear-owner-tasks', { token });
    assert.deepEqual(list.body.data.items, []);

    for (const [body, code] of [
      [{ completed: false }, 'payload_invalid'],
      [{ completed: true, title: '同時' }, 'payload_invalid'],
      [{ completed: 'yes' }, 'payload_invalid'],
      [{}, 'payload_invalid'],
      [{ status: 'done' }, 'payload_field_unknown'],
      [{ assigneeId: null }, 'payload_field_unknown'],
    ]) {
      const response = await bridge.request(url, {
        method: 'PATCH',
        token,
        key: `x-${Math.random()}`,
        headers: { 'if-match': done.body.data.updatedAt },
        body,
      });
      assert.equal(response.status, 400, JSON.stringify(body));
      assert.equal(response.body.error.code, code, JSON.stringify(body));
    }

    const writeOnly = await bridge.token(['tasks:write']);
    const denied = await bridge.request(url, {
      method: 'PATCH',
      token: writeOnly,
      key: 'w1',
      headers: { 'if-match': done.body.data.updatedAt },
      body: { title: 'x' },
    });
    assert.equal(denied.status, 403);
  } finally {
    await bridge.close();
  }
});

test('delete removes the owner\'s issue only, once, and reports an unconfirmed delete', async () => {
  const fetchImpl = fakeLinear({
    issues: [
      issue({ id: uuid(61) }),
      issue({ id: uuid(62), assignee: { id: AGENT, name: 'LAA' } }),
    ],
  });
  const { bridge, token } = await bridgeWith(fetchImpl);
  try {
    const url = `/v1/linear-owner-tasks/${uuid(61)}`;
    const noMatch = await bridge.request(url, { method: 'DELETE', token, key: 'd0' });
    assert.equal(noMatch.status, 428);
    assert.equal(noMatch.body.error.code, 'precondition_required');

    const stale = await bridge.request(url, {
      method: 'DELETE',
      token,
      key: 'd0b',
      headers: { 'if-match': '2026-01-01T00:00:00.000Z' },
    });
    assert.equal(stale.status, 412);
    assert.equal(stale.body.error.code, 'precondition_failed');
    assert.equal(fetchImpl.calls.filter((call) => call.name === 'BridgeOwnerTaskDelete').length, 0);

    const deleted = await bridge.request(url, {
      method: 'DELETE',
      token,
      key: 'd1',
      headers: { 'if-match': '2026-11-02T00:00:00.000Z' },
    });
    assert.equal(deleted.status, 200);
    assert.deepEqual(deleted.body.data, { id: uuid(61), deleted: true, alreadyDeleted: false });
    assert.equal(fetchImpl.issues.has(uuid(61)), false);

    const replay = await bridge.request(url, {
      method: 'DELETE',
      token,
      key: 'd1',
      headers: { 'if-match': '2026-11-02T00:00:00.000Z' },
    });
    assert.equal(replay.status, 200);
    assert.equal(replay.headers.get('idempotency-replayed'), 'true');
    assert.equal(fetchImpl.calls.filter((call) => call.name === 'BridgeOwnerTaskDelete').length, 1);

    const others = await bridge.request(`/v1/linear-owner-tasks/${uuid(62)}`, {
      method: 'DELETE',
      token,
      key: 'd2',
      headers: { 'if-match': '2026-11-02T00:00:00.000Z' },
    });
    assert.equal(others.status, 404);
    assert.equal(fetchImpl.calls.filter((call) => call.name === 'BridgeOwnerTaskDelete').length, 1);

    const missingKey = await bridge.request(`/v1/linear-owner-tasks/${uuid(62)}`, {
      method: 'DELETE',
      token,
      headers: { 'if-match': '2026-11-02T00:00:00.000Z' },
    });
    assert.equal(missingKey.status, 400);
    assert.equal(missingKey.body.error.code, 'idempotency_key_required');
  } finally {
    await bridge.close();
  }

  const stubborn = fakeLinear({ issues: [issue({ id: uuid(63) })], deleteKeepsIssue: true, deleteOutcome: 'success-false' });
  const second = await bridgeWith(stubborn);
  try {
    const response = await second.bridge.request(`/v1/linear-owner-tasks/${uuid(63)}`, {
      method: 'DELETE',
      token: second.token,
      key: 'd3',
      headers: { 'if-match': '2026-11-02T00:00:00.000Z' },
    });
    assert.equal(response.status, 503);
    assert.equal(response.body.error.code, 'linear_delete_unconfirmed');
  } finally {
    await second.bridge.close();
  }
});

test('delete reports success, already deleted and failure without turning failure into success', async () => {
  const cases = [
    { name: 'success with a readable node', options: { deleteKeepsIssue: true }, status: 200, alreadyDeleted: false },
    { name: 'success false but the issue is gone', options: { deleteOutcome: 'success-false', deleteRemovesIssue: true }, status: 200, alreadyDeleted: true },
    { name: 'success false and the node is trashed', options: { deleteOutcome: 'success-false', deleteKeepsIssue: true, deleteMarks: { trashed: true } }, status: 200, alreadyDeleted: true },
    { name: 'success false and the node is only archived', options: { deleteOutcome: 'success-false', deleteKeepsIssue: true, deleteMarks: { trashed: false, archivedAt: '2026-11-02T00:00:00.000Z' } }, status: 503, code: 'linear_delete_unconfirmed' },
    { name: 'success false and the issue is still active', options: { deleteOutcome: 'success-false', deleteKeepsIssue: true }, status: 503, code: 'linear_delete_unconfirmed' },
    { name: 'missing payload and the issue is still active', options: { deleteOutcome: 'missing', deleteKeepsIssue: true }, status: 503, code: 'linear_delete_unconfirmed' },
    { name: 'GraphQL error and the issue is still active', options: { deleteOutcome: 'graphql-error', deleteKeepsIssue: true }, status: 503, code: 'linear_request_rejected' },
  ];
  for (const item of cases) {
    const fake = fakeLinear({ issues: [issue({ id: uuid(80) })], ...item.options });
    const { bridge, token } = await bridgeWith(fake);
    try {
      const response = await bridge.request(`/v1/linear-owner-tasks/${uuid(80)}`, {
        method: 'DELETE',
        token,
        key: 'delete-case',
        headers: { 'if-match': '2026-11-02T00:00:00.000Z' },
      });
      assert.equal(response.status, item.status, item.name);
      if (item.status === 200) {
        assert.deepEqual(response.body.data, { id: uuid(80), deleted: true, alreadyDeleted: item.alreadyDeleted }, item.name);
      } else {
        assert.equal(response.body.error.code, item.code, item.name);
        assert.equal(response.body.data, undefined, item.name);
      }
    } finally {
      await bridge.close();
    }
  }
});

test('a broken issue read after a failed delete is a 503, never already-deleted success', async () => {
  for (const mode of ['missing', 'string']) {
    let deleted = false;
    const base = fakeLinear({
      issues: [issue({ id: uuid(81) })],
      deleteOutcome: 'success-false',
      deleteKeepsIssue: true,
    });
    const flaky = async (url, init) => {
      const { query } = JSON.parse(init.body);
      const name = /(?:query|mutation)\s+([A-Za-z_]+)/.exec(query)?.[1];
      if (name === 'BridgeOwnerTaskDelete') deleted = true;
      if (deleted && name === 'BridgeOwnerTask') {
        return {
          ok: true,
          status: 200,
          json: async () => (mode === 'missing' ? { data: {} } : { data: { issue: 'not-an-issue' } }),
        };
      }
      return base(url, init);
    };
    const { bridge, token } = await bridgeWith(null, { source: sourceFor(flaky) });
    try {
      const response = await bridge.request(`/v1/linear-owner-tasks/${uuid(81)}`, {
        method: 'DELETE',
        token,
        key: 'delete-broken',
        headers: { 'if-match': '2026-11-02T00:00:00.000Z' },
      });
      assert.equal(response.status, 503, mode);
      assert.equal(response.body.error.code, 'linear_delete_unconfirmed', mode);
      assert.equal(response.body.data, undefined, mode);
    } finally {
      await bridge.close();
    }
  }
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
  await source.deleteOwnerTask(uuid(72));

  const names = fetchImpl.calls.map((call) => call.name);
  assert.deepEqual(names, [
    'BridgeOwnerViewer',
    'BridgeOwnerTeam',
    'BridgeOwnerStates',
    'BridgeOwnerTasks',
    'BridgeOwnerTask',
    'BridgeOwnerTaskCreate',
    'BridgeOwnerTaskUpdate',
    'BridgeOwnerTaskDelete',
  ]);
  for (const call of fetchImpl.calls) {
    assert.match(call.query, /^(query|mutation) BridgeOwner/);
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
      ['DELETE', '/v1/linear-owner-tasks/{id}', 'tasks:write', true],
    ],
  );
});

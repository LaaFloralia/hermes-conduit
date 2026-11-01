import assert from 'node:assert/strict';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { revokeDevice } from '../src/pairing.mjs';
import { startBridge } from './helpers.mjs';

function clockAt(start = Date.parse('2026-11-01T00:00:00.000Z')) {
  let value = start;
  const now = () => value;
  now.advance = (ms) => { value += ms; };
  return now;
}

async function boot(t, options = {}) {
  const now = options.now ?? clockAt();
  const api = await startBridge({ ...options, now });
  t.after(() => api.close());
  const token = await api.token();
  return { api, token, now };
}

function createTask(api, token, body, key) {
  return api.request('/v1/owner-tasks', { method: 'POST', token, key, body });
}

function updateTask(api, token, id, body, { key = 'k-update', ifMatch = '1' } = {}) {
  return api.request(`/v1/owner-tasks/${id}`, {
    method: 'PATCH',
    token,
    key,
    body,
    headers: ifMatch === null ? {} : { 'if-match': typeof ifMatch === 'number' ? `"${ifMatch}"` : ifMatch },
  });
}

test('POST creates a task with defaults, an ETag and the documented shape', async (t) => {
  const { api, token } = await boot(t);
  const response = await createTask(api, token, { title: '契約内容を確認する' }, 'k1');

  assert.equal(response.status, 201);
  assert.equal(response.headers.get('etag'), '"1"');
  const task = response.body.data;
  assert.match(task.id, /^[0-9a-f-]{36}$/);
  assert.equal(task.title, '契約内容を確認する');
  assert.equal(task.memo, '');
  assert.equal(task.status, 'todo');
  assert.equal(task.dueDate, null);
  assert.equal(task.source, 'owner');
  assert.deepEqual(task.links, []);
  assert.equal(task.revision, 1);
  assert.match(task.createdAt, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
  assert.equal(task.createdAt, task.updatedAt);
});

test('POST accepts a reserved UUID and a full body', async (t) => {
  const { api, token } = await boot(t);
  const id = 'e0a3b11b-3d95-4b12-ad66-8d34811f1501';
  const response = await createTask(api, token, {
    id,
    title: 'A',
    memo: '# memo\n- keep raw',
    status: 'doing',
    dueDate: '2026-11-05',
    links: ['https://example.com/a', 'http://example.com/b'],
    source: 'agent',
  }, 'k1');
  assert.equal(response.status, 201);
  assert.equal(response.body.data.id, id);
  assert.equal(response.body.data.memo, '# memo\n- keep raw');
  assert.equal(response.body.data.status, 'doing');
  assert.deepEqual(response.body.data.links, ['https://example.com/a', 'http://example.com/b']);
  assert.equal(response.body.data.source, 'agent');
});

test('the same reserved UUID cannot be created twice with a new key', async (t) => {
  const { api, token } = await boot(t);
  const id = 'e0a3b11b-3d95-4b12-ad66-8d34811f1501';
  await createTask(api, token, { id, title: 'A' }, 'k1');
  const second = await createTask(api, token, { id, title: 'A' }, 'k2');
  assert.equal(second.status, 409);
  assert.equal(second.body.error.code, 'owner_task_exists');
  assert.equal(second.body.error.details.taskId, id);
});

test('the list carries summaries and the detail carries the body', async (t) => {
  const { api, token } = await boot(t);
  const created = await createTask(api, token, {
    title: 'A', memo: 'x'.repeat(5000), links: ['https://example.com/a'],
  }, 'k1');
  const list = await api.request('/v1/owner-tasks', { token });
  const row = list.body.data.items[0];
  assert.equal(row.memo, undefined);
  assert.equal(row.links, undefined);
  assert.deepEqual(Object.keys(row).sort(), ['createdAt', 'dueDate', 'id', 'revision', 'source', 'status', 'title', 'updatedAt']);

  const detail = await api.request(`/v1/owner-tasks/${created.body.data.id}`, { token });
  assert.equal(detail.body.data.memo.length, 5000);
  assert.deepEqual(detail.body.data.links, ['https://example.com/a']);
});

test('GET by id returns the task with its ETag and 404 otherwise', async (t) => {
  const { api, token } = await boot(t);
  const created = await createTask(api, token, { title: 'A' }, 'k1');
  const id = created.body.data.id;

  const detail = await api.request(`/v1/owner-tasks/${id}`, { token });
  assert.equal(detail.status, 200);
  assert.equal(detail.headers.get('etag'), '"1"');
  assert.equal(detail.body.data.title, 'A');

  for (const missing of ['11111111-1111-4111-8111-111111111111', 'not-a-uuid', '..%2F..%2Fetc']) {
    const response = await api.request(`/v1/owner-tasks/${missing}`, { token });
    assert.equal(response.status, 404);
    assert.equal(response.body.error.code, 'owner_task_not_found');
  }
});

test('PATCH requires If-Match and returns the current task on a stale revision', async (t) => {
  const { api, token } = await boot(t);
  const created = await createTask(api, token, { title: 'A' }, 'k1');
  const id = created.body.data.id;

  const missing = await updateTask(api, token, id, { status: 'doing' }, { key: 'k2', ifMatch: null });
  assert.equal(missing.status, 428);
  assert.equal(missing.body.error.code, 'precondition_required');

  const invalid = await updateTask(api, token, id, { status: 'doing' }, { key: 'k3', ifMatch: 'W/"1"' });
  assert.equal(invalid.status, 400);
  assert.equal(invalid.body.error.code, 'precondition_invalid');

  const ok = await updateTask(api, token, id, { status: 'doing' }, { key: 'k4', ifMatch: 1 });
  assert.equal(ok.status, 200);
  assert.equal(ok.headers.get('etag'), '"2"');
  assert.equal(ok.body.data.revision, 2);

  const stale = await updateTask(api, token, id, { status: 'done' }, { key: 'k5', ifMatch: 1 });
  assert.equal(stale.status, 412);
  assert.equal(stale.body.error.code, 'owner_task_revision_mismatch');
  assert.equal(stale.body.error.details.current.revision, 2);
  assert.equal(stale.body.error.details.current.status, 'doing');
});

test('PATCH changes only the fields it names and clears the due date with null', async (t) => {
  const { api, token, now } = await boot(t);
  const created = await createTask(api, token, { title: 'A', memo: 'm', dueDate: '2026-11-05', links: ['https://a.example'] }, 'k1');
  const id = created.body.data.id;
  now.advance(1000);

  const cleared = await updateTask(api, token, id, { dueDate: null }, { key: 'k2' });
  assert.equal(cleared.status, 200);
  assert.equal(cleared.body.data.dueDate, null);
  assert.equal(cleared.body.data.memo, 'm');
  assert.deepEqual(cleared.body.data.links, ['https://a.example']);
  assert.equal(cleared.body.data.revision, 2);
  assert.notEqual(cleared.body.data.updatedAt, created.body.data.updatedAt);

  const canceled = await updateTask(api, token, id, { status: 'canceled' }, { key: 'k3', ifMatch: 2 });
  assert.equal(canceled.body.data.status, 'canceled');
  const restored = await updateTask(api, token, id, { status: 'todo' }, { key: 'k4', ifMatch: 3 });
  assert.equal(restored.body.data.status, 'todo');
  assert.equal(restored.body.data.revision, 4);
});

test('a PATCH that changes nothing keeps the revision', async (t) => {
  const { api, token } = await boot(t);
  const created = await createTask(api, token, { title: 'A', status: 'todo' }, 'k1');
  const id = created.body.data.id;
  const same = await updateTask(api, token, id, { title: 'A', status: 'todo' }, { key: 'k2' });
  assert.equal(same.status, 200);
  assert.equal(same.body.data.revision, 1);
  assert.equal(same.headers.get('etag'), '"1"');
});

test('invalid bodies are refused with the field named', async (t) => {
  const { api, token } = await boot(t);
  const created = await createTask(api, token, { title: 'A' }, 'k1');
  const id = created.body.data.id;

  const cases = [
    [{ title: '' }, 'title'],
    [{ title: 'x'.repeat(501) }, 'title'],
    [{ title: 'two\nlines' }, 'title'],
    [{ memo: 'x'.repeat(20_001) }, 'memo'],
    [{ status: 'later' }, 'status'],
    [{ dueDate: '2026-02-30' }, 'dueDate'],
    [{ dueDate: '2026-2-3' }, 'dueDate'],
    [{ links: ['javascript:alert(1)'] }, 'links'],
    [{ links: ['https://user:pass@example.com/'] }, 'links'],
    [{ links: ['ftp://example.com/x'] }, 'links'],
    [{ links: Array.from({ length: 21 }, (_, i) => `https://example.com/${i}`) }, 'links'],
  ];
  for (const [body, field] of cases) {
    const response = await updateTask(api, token, id, body, { key: `k-${field}-${String(body.status ?? '')}` });
    assert.equal(response.status, 400, JSON.stringify(body));
    assert.equal(response.body.error.code, 'field_invalid');
    assert.equal(response.body.error.details.field, field);
  }

  const empty = await updateTask(api, token, id, {}, { key: 'k-empty' });
  assert.equal(empty.status, 400);
  assert.equal(empty.body.error.code, 'patch_empty');

  for (const body of [{ source: 'owner' }, { id: 'e0a3b11b-3d95-4b12-ad66-8d34811f1501' }, { revision: 2 }, { nope: 1 }]) {
    const response = await updateTask(api, token, id, body, { key: `k-unknown-${Object.keys(body)[0]}` });
    assert.equal(response.status, 400);
    assert.equal(response.body.error.code, 'unsupported_field');
  }

  const createUnknown = await createTask(api, token, { title: 'A', priority: 1 }, 'k-create-unknown');
  assert.equal(createUnknown.status, 400);
  assert.equal(createUnknown.body.error.details.field, 'priority');
  const createReservedSource = await createTask(api, token, { title: 'A', source: 'linear_import' }, 'k-create-source');
  assert.equal(createReservedSource.status, 400);
});

test('a request without an Idempotency-Key is refused', async (t) => {
  const { api, token } = await boot(t);
  const response = await api.request('/v1/owner-tasks', { method: 'POST', token, body: { title: 'A' } });
  assert.equal(response.status, 400);
  assert.equal(response.body.error.code, 'idempotency_key_required');
});

test('a retried create with the same key and body replays the recorded result', async (t) => {
  const { api, token } = await boot(t);
  const first = await createTask(api, token, { title: 'A', dueDate: '2026-11-05' }, 'k1');
  const second = await createTask(api, token, { title: 'A', dueDate: '2026-11-05' }, 'k1');

  assert.equal(second.status, 201);
  assert.equal(second.headers.get('idempotency-replayed'), 'true');
  assert.equal(second.body.data.id, first.body.data.id);
  assert.equal((await api.request('/v1/owner-tasks', { token })).body.data.total, 1);
});

test('the same key with a different body is a conflict', async (t) => {
  const { api, token } = await boot(t);
  await createTask(api, token, { title: 'A' }, 'k1');
  const changed = await createTask(api, token, { title: 'B' }, 'k1');
  assert.equal(changed.status, 409);
  assert.equal(changed.body.error.code, 'owner_task_key_conflict');
});

test('a replayed create returns the current task, not a stale copy', async (t) => {
  const { api, token } = await boot(t);
  const first = await createTask(api, token, { title: 'A' }, 'k1');
  const id = first.body.data.id;
  await updateTask(api, token, id, { status: 'doing' }, { key: 'k2' });
  const replay = await createTask(api, token, { title: 'A' }, 'k1');
  assert.equal(replay.status, 201);
  assert.equal(replay.headers.get('idempotency-replayed'), 'true');
  assert.equal(replay.body.data.revision, 2);
  assert.equal(replay.body.data.status, 'doing');
});

test('a replayed update with the same key and If-Match does not apply twice', async (t) => {
  const { api, token, now } = await boot(t);
  const created = await createTask(api, token, { title: 'A' }, 'k1');
  const id = created.body.data.id;
  const first = await updateTask(api, token, id, { status: 'doing' }, { key: 'k2', ifMatch: 1 });
  now.advance(5000);
  const replay = await updateTask(api, token, id, { status: 'doing' }, { key: 'k2', ifMatch: 1 });
  assert.equal(replay.status, 200);
  assert.equal(replay.headers.get('idempotency-replayed'), 'true');
  assert.equal(replay.body.data.revision, first.body.data.revision);
});

test('concurrent creates with the same key leave exactly one task', async (t) => {
  const { api, token } = await boot(t);
  const responses = await Promise.all(Array.from({ length: 5 }, () => (
    createTask(api, token, { title: 'race' }, 'same-key')
  )));
  for (const response of responses) assert.equal(response.status, 201);
  const ids = new Set(responses.map((response) => response.body.data.id));
  assert.equal(ids.size, 1);
  assert.equal((await api.request('/v1/owner-tasks', { token })).body.data.total, 1);
});

test('the default order puts open tasks first by due date, then by newest update', async (t) => {
  const { api, token, now } = await boot(t);
  const ids = {};
  const add = async (name, body, advance = 1000) => {
    now.advance(advance);
    const response = await createTask(api, token, body, `k-${name}`);
    ids[name] = response.body.data.id;
    return response;
  };
  await add('noDueOlder', { title: 'no due older' });
  await add('noDueNewer', { title: 'no due newer' });
  await add('dueLate', { title: 'due late', dueDate: '2026-11-10' });
  await add('dueSoon', { title: 'due soon', dueDate: '2026-11-05' });
  await add('doingNoDue', { title: 'doing', status: 'doing' });
  await add('doneDue', { title: 'done', status: 'done', dueDate: '2026-11-01' });
  await add('canceled', { title: 'canceled', status: 'canceled' });

  const list = await api.request('/v1/owner-tasks', { token });
  const order = list.body.data.items.map((task) => task.title);
  assert.deepEqual(order, [
    'due soon', 'due late', 'doing', 'no due newer', 'no due older',
    'done', 'canceled',
  ]);
  assert.deepEqual(list.body.data.counts, { open: 5, done: 1, canceled: 1 });
  assert.equal(list.body.data.total, 7);
});

test('the status filter excludes closed tasks and returns the filter echo', async (t) => {
  const { api, token, now } = await boot(t);
  await createTask(api, token, { title: 'open' }, 'k1');
  now.advance(1000);
  await createTask(api, token, { title: 'done', status: 'done' }, 'k2');
  now.advance(1000);
  await createTask(api, token, { title: 'canceled', status: 'canceled' }, 'k3');

  const open = await api.request('/v1/owner-tasks?status=open', { token });
  assert.deepEqual(open.body.data.items.map((task) => task.title), ['open']);
  assert.deepEqual(open.body.data.filter, { status: 'open' });

  // Within the closed group the newest update comes first (the cancelled task
  // was created last), the same tie-break the open group uses.
  const closed = await api.request('/v1/owner-tasks?status=closed', { token });
  assert.deepEqual(closed.body.data.items.map((task) => task.title), ['canceled', 'done']);

  const list = await api.request('/v1/owner-tasks?status=todo,done', { token });
  assert.deepEqual(list.body.data.items.map((task) => task.title), ['open', 'done']);
  assert.deepEqual(list.body.data.filter, { status: 'done,todo' });

  const invalid = await api.request('/v1/owner-tasks?status=later', { token });
  assert.equal(invalid.status, 400);
  assert.equal(invalid.body.error.details.field, 'status');
});

test('pagination returns a bound cursor and refuses a stale or foreign one', async (t) => {
  const { api, token, now } = await boot(t);
  for (let i = 0; i < 5; i += 1) {
    now.advance(1000);
    await createTask(api, token, { title: `t${i}` }, `k${i}`);
  }
  const first = await api.request('/v1/owner-tasks?limit=2', { token });
  assert.equal(first.body.data.items.length, 2);
  assert.equal(first.body.data.total, 5);
  assert.ok(first.body.data.nextCursor);

  const second = await api.request(`/v1/owner-tasks?limit=2&cursor=${first.body.data.nextCursor}`, { token });
  assert.equal(second.body.data.items.length, 2);
  assert.notEqual(second.body.data.items[0].id, first.body.data.items[0].id);

  const foreign = await api.request(`/v1/owner-tasks?limit=2&status=open&cursor=${first.body.data.nextCursor}`, { token });
  assert.equal(foreign.status, 400);
  assert.equal(foreign.body.error.code, 'cursor_filter_mismatch');

  const broken = await api.request('/v1/owner-tasks?cursor=not-a-cursor', { token });
  assert.equal(broken.status, 400);
  assert.equal(broken.body.error.code, 'cursor_invalid');

  now.advance(25 * 60 * 60 * 1000);
  const expired = await api.request(`/v1/owner-tasks?limit=2&cursor=${first.body.data.nextCursor}`, { token });
  assert.equal(expired.status, 410);
  assert.equal(expired.body.error.code, 'cursor_expired');
});

test('the scope decides what a device may do', async (t) => {
  const { api, token } = await boot(t);
  const readOnly = await api.token(['tasks:read']);
  const created = await createTask(api, token, { title: 'A' }, 'k1');
  const id = created.body.data.id;

  assert.equal((await api.request('/v1/owner-tasks', { token: readOnly })).status, 200);
  assert.equal((await api.request(`/v1/owner-tasks/${id}`, { token: readOnly })).status, 200);
  const write = await createTask(api, readOnly, { title: 'B' }, 'k2');
  assert.equal(write.status, 403);
  assert.equal(write.body.error.code, 'insufficient_scope');
  assert.equal((await updateTask(api, readOnly, id, { status: 'doing' }, { key: 'k3' })).status, 403);
});

test('a revoked device is refused before any handler runs', async (t) => {
  const { api, token } = await boot(t);
  const me = await api.request('/v1/me', { token });
  revokeDevice(api.store, { target: me.body.data.deviceId, reason: 'test' });
  const response = await createTask(api, token, { title: 'A' }, 'k1');
  assert.equal(response.status, 401);
  assert.equal(response.body.error.code, 'token_revoked');
});

test('a body over 64 KiB is refused', async (t) => {
  const { api, token } = await boot(t);
  const response = await createTask(api, token, { title: 'A', memo: 'x'.repeat(70 * 1024) }, 'k1');
  assert.equal(response.status, 400);
  assert.equal(response.body.error.code, 'payload_too_large');
});

test('a fresh store lists empty and a lost document answers 503', async (t) => {
  const { api, token } = await boot(t);
  const empty = await api.request('/v1/owner-tasks', { token });
  assert.equal(empty.status, 200);
  assert.deepEqual(empty.body.data.items, []);
  assert.equal(empty.body.data.total, 0);

  await createTask(api, token, { title: 'A' }, 'k1');
  rmSync(join(api.stateDir, 'owner-tasks.json'));
  const lost = await api.request('/v1/owner-tasks', { token });
  assert.equal(lost.status, 503);
  assert.equal(lost.body.error.code, 'owner_tasks_store_unavailable');
  assert.equal(lost.body.error.details.reason, 'missing');
});

test('existing /v1/tasks keeps working next to the new endpoints', async (t) => {
  const { api, token } = await boot(t, {
    tasks: {
      linear: {
        listTasks: async () => ({ items: [], truncated: false }),
        getTask: async () => null,
      },
      kanban: { describe: () => ({ source: 'kanban', state: 'unavailable', reason: 'test' }) },
    },
  });
  const legacy = await api.request('/v1/tasks', { token });
  assert.equal(legacy.status, 200);
  assert.deepEqual(legacy.body.data.items, []);

  const created = await createTask(api, token, { title: 'A' }, 'k1');
  assert.equal(created.status, 201);
  // The owner task never leaks into the agent task view.
  assert.deepEqual((await api.request('/v1/tasks', { token })).body.data.items, []);
});

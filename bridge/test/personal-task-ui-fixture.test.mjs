import assert from 'node:assert/strict';
import test from 'node:test';
import { startPersonalTaskUIFixture } from './fixtures/personal-task-ui-server.mjs';

test('the UI fixture serves synthetic tasks and a reproducible description conflict', async (t) => {
  const api = await startPersonalTaskUIFixture();
  t.after(() => api.close());
  const token = await api.token(['tasks:read', 'tasks:write']);
  const list = await api.request('/v1/personal-tasks?view=mine', { token });
  assert.equal(list.body.data.items[0].title, 'Fixture task');
  const detail = await api.request('/v1/personal-tasks/linear%3AFIX-1', { token });
  const changed = await api.request('/v1/personal-tasks/linear%3AFIX-1', { token, method: 'PATCH', key: 'fixture-edit',
    headers: { 'if-match': detail.body.data.task.updatedAt },
    body: { expectedViewerId: 'fixture-viewer', description: 'My fixture revision' } });
  assert.equal(changed.status, 412);
  assert.equal(changed.body.error.details.current.description, 'Fixture remote revision');
  const rebased = await api.request('/v1/personal-tasks/linear%3AFIX-1', { token, method: 'PATCH', key: 'fixture-save-mine',
    headers: { 'if-match': changed.body.error.details.current.updatedAt },
    body: { expectedViewerId: 'fixture-viewer', description: 'My fixture revision' } });
  assert.equal(rebased.status, 200);
  assert.equal(api.fixtureStats().updates, 1);
  assert.equal((await api.request('/v1/personal-tasks/linear%3AFIX-1', { token })).body.data.task.description, 'My fixture revision');
  const created = await api.request('/v1/personal-tasks', { token, method: 'POST', key: 'fixture-create',
    body: { expectedViewerId: 'fixture-viewer', teamId: 'fixture-team', title: 'Fixture new task' } });
  assert.equal(created.status, 201);
  assert.equal((await api.request('/v1/personal-tasks?view=mine', { token })).body.data.items.length, 2);
  const reply = await api.request('/v1/personal-tasks/linear%3AFIX-1/comments', { token, method: 'POST', key: 'fixture-reply',
    body: { expectedViewerId: 'fixture-viewer', parentId: 'fixture-comment-1', body: 'Fixture reply' } });
  assert.equal(reply.status, 201);
  const thread = await api.request('/v1/personal-tasks/linear%3AFIX-1/comments/fixture-comment-1/replies', { token });
  assert.equal(thread.body.data.items[0].body, 'Fixture reply');
  const pending = await api.request('/v1/task-operations', { token });
  assert.equal(pending.body.data.viewerId, 'fixture-viewer');
});

test('metadata fixture fails once then becomes available for the retry UI', async (t) => {
  const api = await startPersonalTaskUIFixture({ failMetadataOnce: true });
  t.after(() => api.close());
  const token = await api.token(['tasks:read', 'tasks:write']);
  assert.equal((await api.request('/v1/task-metadata', { token })).status, 503);
  assert.equal((await api.request('/v1/task-metadata', { token })).status, 200);
});

test('the UI fixture reads and changes only synthetic notification state', async (t) => {
  const api = await startPersonalTaskUIFixture();
  t.after(() => api.close());
  const token = await api.token(['tasks:read', 'tasks:write']);
  const path = '/v1/task-inbox/fixture-notification-1';
  assert.equal((await api.request('/v1/task-inbox', { token })).body.data.items[0].readAt, null);
  const first = await api.request(path, { token, method: 'PATCH', key: 'fixture-read',
    body: { expectedViewerId: 'fixture-viewer', action: 'read' } });
  assert.equal(first.body.data.operation.status, 'succeeded');
  assert.ok((await api.request(path, { token })).body.data.notification.readAt);
  await api.request(path, { token, method: 'PATCH', key: 'fixture-archive',
    body: { expectedViewerId: 'fixture-viewer', action: 'archive' } });
  assert.equal((await api.request('/v1/task-inbox', { token })).body.data.items.length, 0);
  assert.equal((await api.request('/v1/task-inbox?includeArchived=true', { token })).body.data.items.length, 1);
});

import assert from 'node:assert/strict';
import test from 'node:test';
import { createPersonalLinearSource } from '../src/tasks/personal.mjs';
import { startBridge } from './helpers.mjs';

const OWNER = { id: 'owner-fixture', name: 'Owner' };
const at = '2026-11-01T00:00:00.000Z';
const item = (id, user = OWNER.id) => ({ id, type: 'issueNewComment', title: 'Fixture notification', subtitle: '',
  createdAt: at, updatedAt: at, readAt: null, archivedAt: null, snoozedUntilAt: null, user: { id: user },
  actor: null, issue: { id: 'issue-uuid', identifier: 'FIX-1', title: 'Fixture task' }, comment: null });
const page = (nodes, cursor = null) => ({ nodes, pageInfo: { hasNextPage: cursor !== null, endCursor: cursor } });
const response = (data) => new Response(JSON.stringify({ data }), { status: 200 });

function fixture() {
  const notifications = new Map([['mine', item('mine')], ['foreign', item('foreign', 'other-viewer')]]);
  const calls = [];
  let behavior;
  const fetchImpl = async (_url, options) => {
    const { query, variables } = JSON.parse(options.body);
    calls.push({ query, variables });
    if (query.includes('LAAPersonalViewer')) return response({ viewer: OWNER });
    if (query.includes('LAAPersonalInbox')) {
      const values = [...notifications.values()].filter((n) => n.user.id === OWNER.id && (variables.includeArchived || !n.archivedAt));
      return response({ notifications: page(values, variables.after ? null : 'next-page') });
    }
    if (query.includes('LAAPersonalNotification(')) {
      if (variables.id === 'unknown') return new Response(JSON.stringify({ data: { notification: null }, errors: [
        { path: ['notification'], extensions: { userError: true, code: 'INPUT_ERROR' } },
      ] }), { status: 200 });
      if (variables.id === 'deleted') return response({ notification: null });
      if (variables.id === 'nested-error') return new Response(JSON.stringify({ data: { notification: null }, errors: [
        { path: ['notification', 'user'], extensions: { userError: true, code: 'INPUT_ERROR' } },
      ] }), { status: 200 });
      return response({ notification: notifications.get(variables.id) });
    }
    const match = query.match(/mutation LAAPersonalNotification(Update|Archive|Unarchive)/);
    if (!match) throw new Error('unexpected fixture request');
    if (behavior === 'rejected') {
      return new Response(JSON.stringify({ data: null, errors: [{ path: [`notification${match[1]}`],
        extensions: { userError: true, code: 'INPUT_ERROR' } }] }), { status: 200 });
    }
    const notification = notifications.get(variables.id);
    if (match[1] === 'Update') notification.readAt = variables.input.readAt;
    if (match[1] === 'Archive') notification.archivedAt = at;
    if (match[1] === 'Unarchive') notification.archivedAt = null;
    if (behavior === 'lost') throw new Error('response lost after write');
    const returned = structuredClone(notification);
    if (behavior === 'unconfirmed') returned.readAt = null;
    return match[1] === 'Update' ? response({ notificationUpdate: { success: true, notification: returned } })
      : response({ [`notification${match[1]}`]: { success: true, entity: returned } });
  };
  return { notifications, calls, setBehavior: (value) => { behavior = value; },
    source: createPersonalLinearSource({ expectedViewerId: OWNER.id, readToken: async () => 'lin_api_fixture_only', fetchImpl, now: () => Date.parse(at) }) };
}

async function setup(t) {
  const fake = fixture();
  const api = await startBridge({ tasks: { personal: fake.source } });
  t.after(() => api.close());
  const token = await api.token(['tasks:read', 'tasks:write']);
  return { fake, api, token };
}
function change(api, token, key, action, id = 'mine', viewer = OWNER.id) {
  return api.request(`/v1/task-inbox/${id}`, { method: 'PATCH', token, key, body: { expectedViewerId: viewer, action } });
}

test('inbox pages preserve unread states, bind archived filters and never write on read', async () => {
  const fake = fixture();
  const first = await fake.source.listCollection('inbox');
  assert.equal(first.items[0].readAt, null);
  assert.equal(first.viewerId, OWNER.id);
  assert.ok(first.nextCursor);
  await assert.rejects(fake.source.listCollection('inbox', { cursor: first.nextCursor, includeArchived: 'true' }), { code: 'cursor_invalid' });
  await assert.rejects(fake.source.listCollection('inbox', { includeArchived: 'yes' }), { code: 'filter_invalid' });
  await fake.source.listCollection('inbox', { cursor: first.nextCursor });
  assert.equal(fake.calls.filter(({ query }) => query.startsWith('mutation')).length, 0);
  assert.equal(fake.calls.find(({ query }) => query.includes('LAAPersonalInbox')).variables.includeArchived, false);
  fake.notifications.get('mine').readAt = undefined;
  await assert.rejects(fake.source.listCollection('inbox'), { code: 'linear_response_invalid' });
});

test('inbox actions are scoped to owner, confirmed, durable and do not start workers', async (t) => {
  const { fake, api, token } = await setup(t);
  const readOnly = await api.token(['tasks:read']);
  assert.equal((await change(api, readOnly, 'no-scope', 'read')).status, 403);
  assert.equal((await change(api, token, 'bad-viewer', 'read', 'mine', 'wrong-viewer')).body.error.code, 'linear_viewer_changed');
  assert.equal((await change(api, token, 'bad-action', 'unexpected')).status, 400);
  assert.equal((await change(api, token, 'foreign', 'read', 'foreign')).status, 404);
  assert.equal((await api.request('/v1/task-inbox/foreign', { token })).status, 404);
  assert.equal(fake.calls.filter(({ query }) => query.startsWith('mutation')).length, 0);

  const read = await change(api, token, 'read-once', 'read');
  assert.equal(read.body.data.operation.status, 'succeeded');
  assert.equal(fake.notifications.get('mine').readAt, at);
  await api.restart();
  assert.equal((await change(api, token, 'read-once', 'read')).body.data.operation.operationId, read.body.data.operation.operationId);
  assert.equal((await change(api, token, 'read-once', 'unread')).body.error.code, 'idempotency_key_conflict');
  assert.equal((await change(api, token, 'unread-once', 'unread')).status, 200);
  assert.equal(fake.notifications.get('mine').readAt, null);
  assert.equal((await change(api, token, 'archive-once', 'archive')).status, 200);
  assert.equal((await api.request('/v1/task-inbox', { token })).body.data.items.length, 0);
  assert.equal((await api.request('/v1/task-inbox?includeArchived=true', { token })).body.data.items[0].id, 'mine');
  assert.equal((await api.request('/v1/task-inbox/mine', { token })).body.data.notification.archivedAt, at);
  assert.equal((await change(api, token, 'unarchive-once', 'unarchive')).status, 200);
  assert.equal(fake.notifications.get('mine').archivedAt, null);
  assert.equal(fake.calls.filter(({ query }) => query.startsWith('mutation')).length, 4);
  assert.ok(fake.calls.every(({ query }) => !/paseo|worker/i.test(query)));
});

test('lost or unconfirmed notification mutations remain unknown until the owner reconciles', async (t) => {
  const { fake, api, token } = await setup(t);
  fake.setBehavior('lost');
  const lost = await change(api, token, 'lost-read', 'read');
  assert.equal(lost.body.error.code, 'idempotency_outcome_unknown');
  assert.equal(fake.notifications.get('mine').readAt, at);
  fake.setBehavior(null);
  assert.equal((await change(api, token, 'lost-read', 'read')).body.error.code, 'idempotency_outcome_unknown');
  assert.equal(fake.calls.filter(({ query }) => query.includes('mutation LAAPersonalNotificationUpdate')).length, 1);
  const pending = (await api.request('/v1/task-operations', { token })).body.data.items[0];
  assert.equal(pending.kind, 'inbox_read');
  assert.equal(pending.targetId, 'mine');
  assert.equal((await api.request('/v1/task-inbox/mine', { token })).body.data.notification.readAt, at);
  assert.equal((await api.request(`/v1/task-operations/${pending.operationId}/resolve`, { token, method: 'POST', key: 'resolve-read',
    body: { confirmed: true, resolution: 'applied' } })).body.data.operation.status, 'resolved');
  assert.equal((await change(api, token, 'lost-read', 'read')).body.error.code, 'operation_resolved');

  fake.notifications.get('mine').readAt = null;
  fake.setBehavior('unconfirmed');
  assert.equal((await change(api, token, 'bad-result', 'read')).body.error.code, 'idempotency_outcome_unknown');
});

test('definite Linear input rejection is recorded as rejected, with no blind retry', async (t) => {
  const { fake, api, token } = await setup(t);
  fake.setBehavior('rejected');
  const first = await change(api, token, 'refused', 'read');
  assert.equal(first.body.error.code, 'linear_rejected');
  const status = await api.request('/v1/task-operations/by-key', { token, key: 'refused' });
  assert.equal(status.body.data.operation.status, 'rejected');
  assert.equal((await change(api, token, 'refused', 'read')).body.error.code, 'task_operation_rejected');
  assert.equal(fake.notifications.get('mine').readAt, null);
});

test('identical concurrent notification writes execute once and already-applied state needs no write', async (t) => {
  const { fake, api, token } = await setup(t);
  const original = fake.source.updateNotification;
  let entered, release;
  const waiting = new Promise((resolve) => { entered = resolve; });
  const blocker = new Promise((resolve) => { release = resolve; });
  fake.source.updateNotification = async (...args) => { entered(); await blocker; return original(...args); };
  const first = change(api, token, 'parallel-read', 'read');
  await waiting;
  assert.equal((await change(api, token, 'parallel-read', 'read')).body.error.code, 'idempotency_key_in_flight');
  release();
  assert.equal((await first).body.data.operation.status, 'succeeded');
  assert.equal((await change(api, token, 'already-read', 'read')).body.data.operation.status, 'succeeded');
  assert.equal(fake.calls.filter(({ query }) => query.includes('mutation LAAPersonalNotificationUpdate')).length, 1);
});


test('unknown, foreign and deleted notifications return 404 without a write', async (t) => {
  const { fake, api, token } = await setup(t);
  for (const id of ['unknown', 'foreign', 'deleted']) {
    const get = await api.request(`/v1/task-inbox/${id}`, { token });
    assert.equal(get.status, 404); assert.equal(get.body.error.code, 'notification_not_found');
    const patch = await change(api, token, `missing-${id}`, 'read', id);
    assert.equal(patch.status, 404); assert.equal(patch.body.error.code, 'notification_not_found');
    const ledger = await api.request('/v1/task-operations/by-key', { token, key: `missing-${id}` });
    assert.equal(ledger.body.data.operation.rejection, 'notification_not_found');
  }
  assert.equal((await api.request('/v1/task-inbox/nested-error', { token })).status, 503);
  assert.equal(fake.calls.filter(({ query }) => query.startsWith('mutation')).length, 0);
});

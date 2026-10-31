import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { startBridge } from './helpers.mjs';
import { createPersonalLinearSource } from '../src/tasks/personal.mjs';
import { TaskSourceError } from '../src/tasks/errors.mjs';

const owner = { id: 'owner-fixture', name: 'Fixture Owner' };
const page = (nodes, after = null) => ({ nodes, pageInfo: { hasNextPage: after !== null, endCursor: after } });
const issue = { id: 'issue-1', identifier: 'FIX-1', title: 'Fixture', labels: page([]) };
const response = (data) => new Response(JSON.stringify({ data }), { status: 200 });

function graphFixture() {
  const calls = [];
  const source = createPersonalLinearSource({ expectedViewerId: owner.id, readToken: async () => 'lin_api_fixture',
    fetchImpl: async (_url, options) => {
      const { query, variables } = JSON.parse(options.body);
      calls.push({ query, variables });
      if (query.includes('LAAPersonalViewer')) return response({ viewer: owner });
      if (query.includes('LAAPersonalSection_comments')) {
        const start = Number(variables.after ?? 0);
        const count = Math.min(variables.first, 525 - start);
        const nodes = Array.from({ length: count }, (_, i) => ({ id: `c-${start + i}`, body: 'long '.repeat(1200),
          issueId: issue.id, parentId: start + i === 1 ? 'c-0' : null }));
        return response({ issue: { id: issue.id, comments: page(nodes, start + count < 525 ? String(start + count) : null) } });
      }
      if (query.includes('LAAPersonalIssue(')) return response({ issue });
      if (query.includes('LAAPersonalCommentReplies')) return response({ comment: { id: variables.id,
        issueId: variables.id === 'foreign' ? 'issue-other' : issue.id,
        children: page([{ id: 'reply-1', parentId: variables.id, issueId: issue.id, body: 'Reply' }]) } });
      throw new Error('unexpected fixture query');
    },
  });
  return { source, calls };
}

test('detail connections page independently, preserve full text, and bind cursors to task and section', async () => {
  const { source } = graphFixture();
  const all = [];
  let cursor;
  let firstCursor;
  do {
    const result = await source.listTaskSection('comments', 'linear:FIX-1', { limit: 50, cursor });
    if (!firstCursor) firstCursor = result.nextCursor;
    all.push(...result.items);
    cursor = result.nextCursor;
    assert.equal(result.viewerId, owner.id);
    assert.equal(result.paginationConsistency, 'live');
  } while (cursor);
  assert.equal(all.length, 525);
  assert.equal(all[0].body.length, 6000);
  assert.equal(all[1].parentId, 'c-0');
  await assert.rejects(source.listTaskSection('comments', 'linear:FIX-2', { cursor: firstCursor }), { code: 'cursor_invalid' });
  await assert.rejects(source.listTaskSection('history', 'linear:FIX-1', { cursor: firstCursor }), { code: 'cursor_invalid' });
  const replies = await source.listTaskSection('commentReplies', 'linear:FIX-1', { commentId: 'c-0' });
  assert.equal(replies.items[0].parentId, 'c-0');
  await assert.rejects(source.listTaskSection('commentReplies', 'linear:FIX-1', { commentId: 'foreign' }), { code: 'comment_not_found' });
});

function routeFixture() {
  const calls = [];
  return {
    calls, viewer: owner, fail: false,
    async session() { return { viewer: this.viewer }; },
    async getTaskInSession(_session, id) {
      if (id === 'missing') return null;
      return { task: { linearId: id === 'linear:FIX-2' ? 'issue-2' : 'issue-1' } };
    },
    async listTaskSection(name, id, options) { return { items: [{ name, id, options }], nextCursor: null, viewerId: this.viewer.id }; },
    async assertCommentInIssue(_session, id, issueId) {
      if (id !== 'parent' || issueId !== 'issue-1') throw new TaskSourceError('comment_not_found', 'not found', { status: 404 });
    },
    async createTaskItem(_session, kind, input) {
      calls.push({ kind, input });
      if (this.fail) throw new Error('private upstream output');
      return { id: kind === 'attachment' ? 'existing-attachment' : input.id };
    },
  };
}
async function setup(t, { personal = routeFixture(), now } = {}) {
  const api = await startBridge({ tasks: { personal }, ...(now ? { now } : {}) });
  t.after(() => api.close());
  return { personal, api, token: await api.token(['tasks:read', 'tasks:write']) };
}
function post(api, token, section, key, input) {
  return api.request(`/v1/personal-tasks/linear%3AFIX-1/${section}`, { token, key, method: 'POST',
    body: { expectedViewerId: owner.id, ...input } });
}

test('detail routes enforce scope and preserve section, task and reply identity', async (t) => {
  const { api, token } = await setup(t);
  const readOnly = await api.token(['tasks:read']);
  assert.equal((await post(api, readOnly, 'comments', 'scope', { body: 'fixture' })).status, 403);
  const page = await api.request('/v1/personal-tasks/linear%3AFIX-1/inverse-relations?limit=10', { token });
  assert.deepEqual(page.body.data.items[0], { name: 'inverseRelations', id: 'linear:FIX-1', options: { cursor: null, limit: '10' } });
  const replies = await api.request('/v1/personal-tasks/linear%3AFIX-1/comments/parent/replies', { token });
  assert.equal(replies.body.data.items[0].options.commentId, 'parent');
});

test('comments and relations are viewer-bound, validate parent and target, and replay safely', async (t) => {
  const { personal, api, token } = await setup(t);
  assert.equal((await post(api, token, 'comments', 'wrong-viewer', { expectedViewerId: 'other', body: 'text' })).body.error.code, 'linear_viewer_changed');
  assert.equal((await post(api, token, 'comments', 'wrong-parent', { body: 'text', parentId: 'foreign' })).status, 404);
  assert.equal((await post(api, token, 'relations', 'self', { type: 'blocks', relatedIssueId: 'linear:FIX-1' })).status, 400);
  assert.equal(personal.calls.length, 0);
  const body = { body: 'private comment fixture', parentId: 'parent' };
  const first = await post(api, token, 'comments', 'comment-key', body);
  assert.equal(first.status, 201);
  assert.equal(first.body.data.operation.contextId, 'linear:FIX-1');
  assert.equal(personal.calls[0].input.issueId, 'issue-1');
  assert.equal(personal.calls[0].input.parentId, 'parent');
  assert.equal(personal.calls[0].input.id, first.body.data.operation.targetId);
  await api.restart();
  assert.equal((await post(api, token, 'comments', 'comment-key', body)).status, 200);
  assert.equal((await post(api, token, 'comments', 'comment-key', { ...body, body: 'changed' })).body.error.code, 'idempotency_key_conflict');
  const relation = await post(api, token, 'relations', 'relation-key', { type: 'blocks', relatedIssueId: 'linear:FIX-2' });
  assert.equal(relation.status, 201);
  assert.equal(personal.calls[1].input.relatedIssueId, 'issue-2');
  assert.doesNotMatch(readFileSync(join(api.stateDir, 'task-operations.json'), 'utf8'), /private comment fixture/);
});

test('link attachments reject unsafe URLs, and a successful upsert records the returned id', async (t) => {
  const { personal, api, token } = await setup(t);
  for (const url of ['http://example.com', 'https://user:pass@example.com', 'file:///tmp/test']) {
    assert.equal((await post(api, token, 'attachments', `bad-${url.length}`, { title: 'Link', url })).status, 400);
  }
  const link = 'https://example.test/private-fixture-url';
  const result = await post(api, token, 'attachments', 'link', { title: 'private attachment title', url: link });
  assert.equal(result.status, 201);
  assert.equal(result.body.data.operation.resultId, 'existing-attachment');
  assert.notEqual(result.body.data.operation.resultId, result.body.data.operation.targetId);
  assert.equal(personal.calls.length, 1);
  assert.doesNotMatch(readFileSync(join(api.stateDir, 'task-operations.json'), 'utf8'), /private-fixture-url|private attachment title/);
});

test('unknown comment result survives restart and seven days, without a second mutation', async (t) => {
  let clock = Date.parse('2026-11-01T00:00:00Z');
  const personal = routeFixture(); personal.fail = true;
  const { api, token } = await setup(t, { personal, now: () => clock });
  const input = { body: 'private uncertain comment' };
  assert.equal((await post(api, token, 'comments', 'uncertain', input)).body.error.code, 'idempotency_outcome_unknown');
  clock += 8 * 24 * 60 * 60 * 1000;
  await api.restart();
  assert.equal((await post(api, token, 'comments', 'uncertain', input)).body.error.code, 'idempotency_outcome_unknown');
  const pending = await api.request('/v1/task-operations/by-key', { token, key: 'uncertain' });
  assert.equal(pending.body.data.operation.contextId, 'linear:FIX-1');
  assert.equal(pending.body.data.operation.status, 'outcome_unknown');
  const id = pending.body.data.operation.operationId;
  assert.equal((await api.request(`/v1/task-operations/${id}/resolve`, { token, key: 'resolve', method: 'POST',
    body: { confirmed: true, resolution: 'not_applied' } })).body.data.operation.status, 'resolved');
  assert.equal(personal.calls.length, 1);
});

test('concurrent identical comments use one downstream mutation and cannot be resolved while active', async (t) => {
  const personal = routeFixture();
  let entered, finish;
  const started = new Promise((resolve) => { entered = resolve; });
  const blocker = new Promise((resolve) => { finish = resolve; });
  personal.createTaskItem = async (_session, kind, input) => {
    personal.calls.push({ kind, input }); entered(); await blocker; return { id: input.id };
  };
  const { api, token } = await setup(t, { personal });
  const body = { body: 'fixture concurrent' };
  const first = post(api, token, 'comments', 'parallel-comment', body);
  await started;
  const second = await post(api, token, 'comments', 'parallel-comment', body);
  assert.equal(second.body.error.code, 'idempotency_key_in_flight');
  const id = second.body.error.details.operation.operationId;
  const resolving = await api.request(`/v1/task-operations/${id}/resolve`, { token, key: 'not-yet', method: 'POST',
    body: { confirmed: true, resolution: 'not_applied' } });
  assert.equal(resolving.body.error.code, 'idempotency_key_in_flight');
  finish();
  assert.equal((await first).status, 201);
  assert.equal(personal.calls.length, 1);
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createAgentInboxSource } from '../src/tasks/agent-inbox.mjs';

function fixture(t) {
  const dir = mkdtempSync(join(tmpdir(), 'laa-inbox-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  let time = Date.parse('2026-11-02T12:00:00Z');
  let viewer = 'agent'; let fails = false; let reads = 0;
  const date = new Date(time).toISOString();
  const issues = [{ id: 'assigned', identifier: 'BUS-1', title: 'Assigned', assignee: { id: 'owner' },
    description: '', updatedAt: date }, { id: 'mention', identifier: 'BUS-2', title: 'Mention', description: '', updatedAt: date },
    { id: 'other', identifier: 'BUS-3', title: 'Unrelated', description: '', updatedAt: date,
      subscribers: { nodes: [{ id: 'other' }], pageInfo: { hasNextPage: true } } }];
  const source = { ownerUserId: 'owner', agentAccount: true,
    async session() { return { viewer: { id: viewer } }; },
    async ownerProfile() { return { id: 'owner', url: 'https://linear.app/owner' }; },
    async listActivityCandidates(_s, options) { reads++; if (fails) throw new Error('read failed');
      source.last = options; return { nodes: structuredClone(issues), pageInfo: { hasNextPage: false } }; },
    async listCommentActivityCandidates() { return { nodes: source.freshComments ?? [], pageInfo: { hasNextPage: false } }; },
    async listTaskSection(name, id, options) {
      assert.equal(options.personalSession.viewer.id, viewer);
      if (name === 'comments') return { items: [{ id: id + '-comment', body: id === 'mention' ? 'Hello https://linear.app/owner' : 'Plain', updatedAt: date }], nextCursor: null };
      if (name === 'commentReplies') return { items: [{ id: id + '-reply', parentId: 'root', body: 'Plain reply', updatedAt: date }], nextCursor: null };
      if (name === 'history') return { items: [{ id: id + '-history', createdAt: date, fromAssignee: { id: 'owner' }, toAssignee: null, fromDueDate: date, toDueDate: null, fromPriority: 0, toPriority: 1, toState: { id: 'todo' } }], nextCursor: null };
      if (name === 'children') return { items: [{ id: 'child', linearId: id + '-child', updatedAt: date, title: 'Child' }], nextCursor: null };
      throw new Error('unexpected section');
    },
    async listCollection() { return { items: ['native'] }; },
  };
  const wrap = () => createAgentInboxSource({ source, store: { dir }, now: () => time });
  return { source, issues, wrap, now: () => time, tick: () => { time += 60_000; }, viewer: (v) => { viewer = v; }, fails: (v) => { fails = v; }, reads: () => reads };
}

test('agent inbox includes owner updates and mentions, excludes unrelated history, persists only local read state', async (t) => {
  const f = fixture(t); const inbox = f.wrap();
  const page = await inbox.listCollection('inbox');
  assert.equal(page.inboxMode, 'laa'); assert.equal(page.viewerId, 'agent');
  assert.equal(page.items.length, 5);
  assert.equal(page.items.filter((v) => v.issue.id === 'assigned').length, 4);
  assert.equal(page.items.find((v) => v.issue.id === 'mention').type, 'issueMention');
  assert(!page.items.some((v) => v.issue.id === 'other'));
  const item = page.items[0]; const session = await f.source.session();
  await inbox.updateNotification(session, item.id, 'read');
  await inbox.updateNotification(session, item.id, 'archive');
  assert.equal((await inbox.listCollection('inbox')).items.length, 4);
  const reopened = f.wrap();
  const archived = (await reopened.listCollection('inbox', { includeArchived: 'true' })).items.find((v) => v.id === item.id);
  assert(archived.readAt); assert(archived.archivedAt);
  assert.equal((await reopened.listCollection('projects')).items[0], 'native');
  assert.equal((await reopened.listCollection('inbox', { includeArchived: 'true' })).items.length, 5);
});

test('unassignment is observed using watched IDs; failures do not advance watermark; actors do not share read state', async (t) => {
  const f = fixture(t); const inbox = f.wrap(); await inbox.listCollection('inbox');
  f.tick(); f.fails(true); await assert.rejects(inbox.listCollection('inbox'));
  f.fails(false); f.tick(); f.issues[0].assignee = null; f.issues[0].updatedAt = new Date(f.now()).toISOString();
  await inbox.listCollection('inbox');
  assert.deepEqual(f.source.last.watched, ['assigned']);
  assert.equal(f.source.last.since, '2026-11-02T11:58:00.000Z');
  f.viewer('different-agent'); const other = await inbox.listCollection('inbox');
  assert.equal(other.viewerId, 'different-agent'); assert(other.items.every((v) => !v.readAt));
});

test('inbox cursors are scoped, bounded and invalid input returns a controlled error', async (t) => {
  const f = fixture(t); const inbox = f.wrap();
  const first = await inbox.listCollection('inbox', { limit: 1 }); assert(first.nextCursor);
  const second = await inbox.listCollection('inbox', { limit: 1, cursor: first.nextCursor });
  assert.notEqual(first.items[0].id, second.items[0].id);
  for (const cursor of ['{', Buffer.from(JSON.stringify({ viewer: 'agent', archive: false, offset: -1 })).toString('base64url'), first.nextCursor]) {
    const opts = cursor === first.nextCursor ? { includeArchived: 'true' } : {};
    await assert.rejects(inbox.listCollection('inbox', { ...opts, cursor }), { code: 'cursor_invalid', status: 400 });
  }
});


test('comment activity is captured even when the issue updatedAt is unchanged', async (t) => {
  const f = fixture(t); const inbox = f.wrap(); await inbox.listCollection('inbox');
  f.tick();
  f.source.freshComments = [{ id: 'new-reply', body: 'New reply', updatedAt: new Date(f.now()).toISOString(), issue: f.issues[0] }];
  const page = await inbox.listCollection('inbox');
  assert.equal(page.items.length, 6);
  assert.equal(page.items.find((v) => v.subtitle === 'New reply').type, 'issueNewComment');
});


test('subtask activity does not depend on the parent updatedAt changing', async (t) => {
  const f = fixture(t); const inbox = f.wrap(); await inbox.listCollection('inbox');
  f.tick();
  f.issues.push({ id: 'new-child', identifier: 'BUS-4', title: 'New child', updatedAt: new Date(f.now()).toISOString(), parent: f.issues[0] });
  const page = await inbox.listCollection('inbox');
  assert.equal(page.items.find((v) => v.subtitle === 'New child').issue.id, 'assigned');
});

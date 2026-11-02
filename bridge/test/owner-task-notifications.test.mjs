import test from 'node:test';
import assert from 'node:assert/strict';
import { createOwnerTaskNotificationPoller } from '../src/tasks/owner-notifications.mjs';

test('task notifications require owner authorization and retry undelivered notifications with a stable key', async () => {
  let reads = 0, sends = [];
  const source = { ownerInboxAvailable: false, async listCollection() { reads++; return { items: [
    { id: 'n1', type: 'issueNewComment', title: '新しいコメント', updatedAt: 'v1', readAt: null,
      archivedAt: null, issue: { id: 'issue-1', title: 'Fixture' } },
    { id: 'n2', type: 'issueMention', updatedAt: 'v1', readAt: 'read', issue: { id: 'issue-1' } },
  ], nextCursor: null }; } };
  const poller = createOwnerTaskNotificationPoller({ source, notify: async (value) => {
    sends.push(value); return { delivered: sends.length > 1 };
  } });
  await poller.poll(); assert.equal(reads, 0);
  source.ownerInboxAvailable = true;
  await poller.poll(); await poller.poll(); await poller.poll();
  assert.equal(sends.length, 2);
  assert.equal(sends[0].dedupeKey, sends[1].dedupeKey);
  assert.equal(sends[0].deepLink, 'laa://work/tasks/issue-1');
  assert.equal(sends[0].kind, 'task');
});

test('polling bounds pages and never overlaps', async () => {
  let release, reads = 0;
  const gate = new Promise((r) => { release = r; });
  const source = { ownerInboxAvailable: true, async listCollection() {
    reads++; await gate; return { items: [], nextCursor: `page-${reads}` };
  } };
  const poller = createOwnerTaskNotificationPoller({ source });
  const first = poller.poll(); await poller.poll(); assert.equal(reads, 1);
  release(); assert.equal((await first).incomplete, true); assert.equal(reads, 5);
});

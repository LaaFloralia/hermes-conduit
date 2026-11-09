// The events long-poll has to hand a change back as soon as the journal grows,
// and must not lose one when a client disconnects or two clients wait at once.
// These pin the wait itself: the app re-polls on every empty answer, so a poll
// that sat out the full wait after a change was already journaled was the
// 2-second delay seen in the log (bridge.md §1-c).

import assert from 'node:assert/strict';
import test from 'node:test';
import { startBridge } from './helpers.mjs';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Paseo stands in as one agent whose phase flips when the owner replies, which
// is what turns into a `session.phase` event.
function fixture() {
  const state = { phase: 'running', replies: 0 };
  const daemon = {
    capabilities: () => ({ effortUpdate: true }),
    async status() {
      return {
        title: 'bench',
        daemonStatus: state.phase,
        activeTurn: false,
        archivedAt: null,
        phase: state.phase,
        pending: [],
        modelCheck: { observed: { provider: 'dsh', model: 'm', effort: 'high' }, runtimeVerified: true },
        features: null,
        updatedAt: '2026-11-09T00:00:00Z',
        observedAt: new Date(0).toISOString(),
        workspaceTitle: null,
      };
    },
    async list() { return []; },
    async workspacePins() { return []; },
    async exists() { return true; },
    async reply() {
      state.replies += 1;
      state.phase = state.phase === 'running' ? 'awaiting_review' : 'running';
      return {};
    },
    async tidyWorkspaces() {},
    async decision() { return null; },
  };
  const adapter = {
    origin: 'laa-bridge',
    async create() {
      return { sessionId: 'agent-1', requested: { provider: 'dsh', model: 'm', effort: 'high' }, phase: 'created', reused: false };
    },
  };
  return { state, daemon, adapter };
}

async function boot(t, requestId) {
  const f = fixture();
  const bridge = await startBridge({
    workspace: { roots: ['/tmp'] },
    sessions: { adapter: f.adapter, daemon: f.daemon, pollMs: 2500 },
  });
  t.after(() => bridge.close());
  const token = await bridge.token();
  const created = await bridge.request('/v1/sessions', {
    method: 'POST', token, key: `${requestId}-create`,
    body: { requestId, profile: 'deepseek', prompt: 'bench' },
  });
  assert.ok([200, 201].includes(created.status), `create failed: ${created.status} ${JSON.stringify(created.body)}`);
  const id = created.body.data.id;
  const opened = await bridge.request(`/v1/sessions/${id}/events?afterSeq=0`, { token });
  assert.equal(opened.status, 200);
  return { bridge, token, id, cursor: opened.body.data.nextCursor, headSeq: opened.body.data.headSeq, ...f };
}

// The owner replies from another request while this one is waiting: the event
// must reach the waiter as soon as it exists, not when the wait expires.
test('a reply during the wait wakes the long-poll instead of waiting it out', async (t) => {
  const ctx = await boot(t, 'wake-1');
  const started = Date.now();
  const poll = ctx.bridge.request(`/v1/sessions/${ctx.id}/events?cursor=${ctx.cursor}&wait=5&limit=100`, { token: ctx.token });
  await sleep(150);
  const replied = await ctx.bridge.request(`/v1/sessions/${ctx.id}/reply`, { method: 'POST', token: ctx.token, key: 'wake-1-reply', body: { text: 'はい' } });
  assert.equal(replied.status, 200);
  const page = await poll;
  const elapsed = Date.now() - started;

  assert.equal(page.status, 200);
  const types = page.body.data.items.map((event) => event.type);
  assert.ok(types.includes('session.phase'), `expected the reply's event, got ${types.join(',') || 'nothing'}`);
  assert.ok(page.body.data.items.every((event) => event.seq > ctx.headSeq));
  assert.equal(page.body.data.resyncRequired, false);
  assert.ok(elapsed < 2500, `the poll waited ${elapsed}ms; a journaled change must wake it (wait was 5000ms)`);
});

// A client that goes away leaves nothing behind: the next long-poll still gets
// woken by a change, and the event that arrives meanwhile is not lost.
test('a disconnected poll is released and its successor still sees the change', async (t) => {
  const ctx = await boot(t, 'wake-2');
  const abort = new AbortController();
  const abandoned = ctx.bridge.request(`/v1/sessions/${ctx.id}/events?cursor=${ctx.cursor}&wait=5`, { token: ctx.token, signal: abort.signal });
  await sleep(150);
  abort.abort();
  await abandoned.catch(() => null);
  await sleep(50);

  const started = Date.now();
  const poll = ctx.bridge.request(`/v1/sessions/${ctx.id}/events?cursor=${ctx.cursor}&wait=5&limit=100`, { token: ctx.token });
  await sleep(150);
  const replied = await ctx.bridge.request(`/v1/sessions/${ctx.id}/reply`, { method: 'POST', token: ctx.token, key: 'wake-2-reply', body: { text: 'はい' } });
  assert.equal(replied.status, 200);
  const page = await poll;
  const elapsed = Date.now() - started;

  assert.equal(page.body.data.items.length > 0, true, 'the change after the disconnect must still arrive');
  assert.ok(elapsed < 2500, `the poll after a disconnect waited ${elapsed}ms`);

  // The cursor the abandoned poll was given still replays the whole change.
  const replayed = await ctx.bridge.request(`/v1/sessions/${ctx.id}/events?cursor=${ctx.cursor}`, { token: ctx.token });
  assert.equal(replayed.status, 200);
  assert.deepEqual(replayed.body.data.items.map((event) => event.seq), page.body.data.items.map((event) => event.seq));
});

// Two clients waiting on the same session both get the change once, in order,
// and neither one's cursor is skipped.
test('two concurrent waits on one session both receive the append, once', async (t) => {
  const ctx = await boot(t, 'wake-3');
  const first = ctx.bridge.request(`/v1/sessions/${ctx.id}/events?cursor=${ctx.cursor}&wait=5&limit=100`, { token: ctx.token });
  const second = ctx.bridge.request(`/v1/sessions/${ctx.id}/events?cursor=${ctx.cursor}&wait=5&limit=100`, { token: ctx.token });
  await sleep(200);
  await ctx.bridge.request(`/v1/sessions/${ctx.id}/reply`, { method: 'POST', token: ctx.token, key: 'wake-3-reply', body: { text: 'はい' } });
  const [a, b] = await Promise.all([first, second]);

  for (const page of [a, b]) {
    assert.equal(page.status, 200);
    assert.ok(page.body.data.items.length > 0);
    const seqs = page.body.data.items.map((event) => event.seq);
    assert.deepEqual(seqs, [...seqs].sort((x, y) => x - y));
    assert.equal(new Set(seqs).size, seqs.length);
  }
  const firstSeq = a.body.data.items.map((event) => event.seq);
  assert.deepEqual(b.body.data.items.map((event) => event.seq), firstSeq);

  // Reading again from the returned cursor yields nothing: the change is
  // delivered once, not repeated.
  const next = await ctx.bridge.request(`/v1/sessions/${ctx.id}/events?cursor=${a.body.data.nextCursor}`, { token: ctx.token });
  assert.equal(next.body.data.items.length, 0);
});

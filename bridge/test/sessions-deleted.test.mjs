// A session whose Paseo agent no longer exists must stop looking live: it
// leaves the default list (and releases its short number) but stays readable
// through a requestId lookup or scope=all. Only Paseo's own 404 is proof.

import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { createRefService } from '../src/refs/service.mjs';
import { daemonAdapter, daemonSessionID } from '../src/sessions/daemon.mjs';
import { createSessionService } from '../src/sessions/service.mjs';
import { createSessionStore } from '../src/sessions/store.mjs';
import { startBridge } from './helpers.mjs';

function fixture(options = {}) {
  const calls = [];
  const rows = [{ id: 'live', title: '残る会話', workspaceId: 'wks_a', provider: 'dsh', status: 'idle',
    createdAt: options.createdAt, updatedAt: '2026-11-02T00:00:00Z', labels: {} }];
  const client = { close: async () => {},
    fetchAgent: async ({ agentId }) => {
      calls.push(['agent', agentId]);
      if (options.fetchThrows) throw new Error('daemon down');
      return { agent: rows.find((agent) => agent.id === agentId) };
    },
    fetchAgents: async () => {
      if (options.listFails) throw new Error('directory down');
      return { entries: rows.map((agent) => ({ agent })), pageInfo: { nextCursor: null } };
    },
    fetchWorkspaces: async () => ({ entries: [{ id: 'wks_a', title: null }], pageInfo: { nextCursor: null } }),
  };
  return { rows, calls, options, daemon: daemonAdapter({ connect: async () => client }) };
}

async function makeService(t, options = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'paseo-deleted-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  let clock = Date.parse(options.start ?? '2026-11-09T00:00:00Z');
  const now = () => clock;
  const f = fixture({ createdAt: new Date(clock - (options.ageMs ?? 60 * 60 * 1000)).toISOString(), ...options });
  const store = createSessionStore({ file: join(dir, 'sessions.json'), now });
  const service = createSessionService({ sessionStore: store, daemon: f.daemon, adapter: {}, findWorkspace: async () => null, notify: async () => {}, now });
  return { dir, f, store, service, id: daemonSessionID('live'), advance: (ms) => { clock += ms; } };
}

test('a session gone from Paseo is hidden, readable through scope/requestId, and comes back', async (t) => {
  const ctx = await makeService(t);
  assert.equal((await ctx.service.listSessions()).items.length, 1);

  ctx.f.rows.length = 0;
  await ctx.service.syncDaemon();
  const deleted = ctx.store.get(ctx.id);
  assert.equal(typeof deleted.daemonDeletedAt, 'string');
  assert.deepEqual((await ctx.service.listSessions()).items, []);
  assert.deepEqual(ctx.service.visibleRecords(), []);
  assert.deepEqual((await ctx.service.listSessions({ archived: 'only' })).items, []);
  // Nothing was destroyed: an explicit re-read still finds it and says why.
  assert.equal((await ctx.service.listSessions({ scope: 'all' })).items.length, 1);
  assert.equal((await ctx.service.listSessions({ requestId: 'paseo-live' })).items.length, 1);
  const detail = await ctx.service.getSession(ctx.id);
  assert.equal(detail.observation.available, false);
  assert.equal(detail.observation.code, 'not_found');

  // The same agent reappearing in Paseo's directory makes it live again.
  ctx.f.rows.push({ id: 'live', title: '戻った会話', workspaceId: 'wks_a', provider: 'dsh', status: 'idle',
    createdAt: '2026-11-01T00:00:00Z', updatedAt: '2026-11-02T00:00:00Z', labels: {} });
  await ctx.service.syncDaemon();
  assert.equal(ctx.store.get(ctx.id).daemonDeletedAt, null);
  assert.equal((await ctx.service.listSessions()).items.length, 1);
});

test('a daemon that cannot answer "still there?" leaves the session alone', async (t) => {
  const ctx = await makeService(t);
  await ctx.service.listSessions();
  ctx.f.rows.length = 0;
  ctx.f.options.fetchThrows = true;
  await ctx.service.syncDaemon();
  assert.equal(ctx.store.get(ctx.id).daemonDeletedAt ?? null, null);
  assert.equal((await ctx.service.listSessions()).items.length, 1);
});

test('a failed directory read changes nothing', async (t) => {
  const ctx = await makeService(t);
  await ctx.service.listSessions();
  ctx.f.rows.length = 0;
  ctx.f.options.listFails = true;
  await assert.rejects(ctx.service.syncDaemon(), { code: 'paseo_unavailable' });
  assert.equal(ctx.store.get(ctx.id).daemonDeletedAt ?? null, null);
  assert.equal(ctx.service.visibleRecords().length, 1);
});

test('a session younger than two minutes is not checked for deletion', async (t) => {
  const ctx = await makeService(t, { ageMs: 60 * 1000 });
  await ctx.service.listSessions();
  ctx.f.rows.length = 0;
  await ctx.service.syncDaemon();
  assert.equal(ctx.store.get(ctx.id).daemonDeletedAt ?? null, null);
  assert.equal((await ctx.service.listSessions()).items.length, 1);
  assert.equal(ctx.f.calls.filter((call) => call[0] === 'agent').length, 0);

  // Once it is older than the grace window, the missing agent is checked.
  ctx.advance(3 * 60 * 1000);
  await ctx.service.syncDaemon();
  assert.equal(typeof ctx.store.get(ctx.id).daemonDeletedAt, 'string');
  assert.deepEqual((await ctx.service.listSessions()).items, []);
});

test('one sync checks at most twenty departed sessions', async (t) => {
  const ctx = await makeService(t);
  for (let n = 0; n < 25; n += 1) {
    ctx.store.create({ record: { id: `ses_${String(n).padStart(16, '0')}`, requestId: `paseo-many-${n}`, name: `残り${n}`,
      nameSource: 'agent', parentId: null, projectId: null, workspaceId: 'wks_a', cwd: '/tmp',
      phase: 'awaiting_review', createdAt: '2026-11-01T00:00:00Z', updatedAt: '2026-11-01T00:00:00Z',
      delegate: { sessionId: `agent-${n}` } } });
  }
  await ctx.service.syncDaemon();
  assert.equal(ctx.f.calls.filter((call) => call[0] === 'agent').length, 20);
  const marked = ctx.store.all().filter((record) => record.daemonDeletedAt);
  assert.equal(marked.length, 20);
});

test('a session gone from Paseo releases its short number', async (t) => {
  const f = fixture({ createdAt: '2026-11-01T00:00:00Z' });
  const bridge = await startBridge({
    sessions: { daemon: f.daemon, notify: async () => {} },
    refs: (stateDir) => createRefService({ file: join(stateDir, 'refs.json') }),
  });
  t.after(() => bridge.close());
  const token = await bridge.token();

  const first = await bridge.request('/v1/sessions', { token });
  assert.equal(first.body.data.items.length, 1);
  assert.equal(first.body.data.items[0].ref, 'S1');

  f.rows.length = 0;
  const second = await bridge.request('/v1/sessions', { token });
  assert.equal(second.body.data.items.length, 0);
  assert.equal((await bridge.request('/v1/refs/S1', { token })).body.data.status, 'released');

  // scope=all still returns the record, and reading it must not re-hold S1.
  const all = await bridge.request('/v1/sessions?scope=all', { token });
  assert.equal(all.body.data.items.length, 1);
  assert.equal((await bridge.request('/v1/refs/S1', { token })).body.data.status, 'released');
});

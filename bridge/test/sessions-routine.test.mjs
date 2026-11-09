// Scheduled runs (`laa-cron`, hq/harness/paseo_job.py) and the agents they
// start stay out of Work: no default or archived row, no S number, no
// notice. The records stay readable through scope=all and requestId.

import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { createRefService } from '../src/refs/service.mjs';
import { daemonAdapter } from '../src/sessions/daemon.mjs';
import { createSessionService, routineAgents } from '../src/sessions/service.mjs';
import { createSessionStore } from '../src/sessions/store.mjs';
import { startBridge } from './helpers.mjs';

const agent = (id, title, labels = {}, extra = {}) => ({ id, title, workspaceId: 'wks_a', provider: 'dsh', status: 'idle',
  createdAt: '2026-11-09T00:00:00Z', updatedAt: '2026-11-09T00:00:00Z', labels, ...extra });

function daemonFor(rows) {
  const client = { close: async () => {},
    fetchAgent: async ({ agentId }) => ({ agent: rows.find((a) => a.id === agentId) }),
    fetchAgents: async () => ({ entries: rows.map((a) => ({ agent: a })), pageInfo: { nextCursor: null } }),
    fetchWorkspaces: async () => ({ entries: [{ id: 'wks_a', title: null }], pageInfo: { nextCursor: null } }),
  };
  return daemonAdapter({ connect: async () => client });
}

test('a scheduled run and what it starts are routine; other agents are not', () => {
  const routines = routineAgents([
    agent('kid', '子', { 'paseo.parent-agent-id': 'cron' }),
    agent('grandkid', '孫', { 'paseo.parent-agent-id': 'kid' }),
    agent('cron', 'チャート外分析 Daily 20261109-0900', { 'laa-cron': 'daily-20261109-0900' }),
    agent('owner', '社長の会話'),
    agent('owner-kid', '子｜作業', { 'paseo.parent-agent-id': 'owner' }),
  ]);
  assert.deepEqual([...routines.entries()].sort(), [
    ['cron', 'daily-20261109-0900'], ['grandkid', 'daily-20261109-0900'], ['kid', 'daily-20261109-0900']]);
});

test('scheduled runs leave the Work list and its S numbers, and stay readable', async (t) => {
  const rows = [agent('owner', '社長の会話'),
    agent('cron', 'Pokémon GO 20261109', { 'laa-cron': 'pokemon-go-20261109' }),
    agent('cron-kid', '子｜調査', { 'paseo.parent-agent-id': 'cron' }),
    agent('cron-done', '技術調査 2026-11-07', { 'laa-cron': 'tech-audit-2026-11-07' }, { status: 'closed', archivedAt: '2026-11-07T00:00:00Z' })];
  const bridge = await startBridge({
    sessions: { daemon: daemonFor(rows), notify: async () => {} },
    refs: (stateDir) => createRefService({ file: join(stateDir, 'refs.json') }),
  });
  t.after(() => bridge.close());
  const token = await bridge.token();

  const list = await bridge.request('/v1/sessions', { token });
  assert.deepEqual(list.body.data.items.map((item) => [item.name, item.ref]), [['社長の会話', 'S1']]);
  assert.deepEqual((await bridge.request('/v1/sessions?archived=only', { token })).body.data.items, []);
  const all = await bridge.request('/v1/sessions?scope=all', { token });
  assert.equal(all.body.data.items.length, 4);
  assert.deepEqual(all.body.data.items.filter((item) => item.ref).map((item) => item.ref), ['S1']);
  const found = await bridge.request('/v1/sessions?requestId=paseo-cron', { token });
  assert.equal(found.body.data.items.length, 1);
  assert.equal((await bridge.request('/v1/refs/S2', { token })).status, 404);
});

test('a session that held an S number before the change gives it back', async (t) => {
  const rows = [agent('cron', 'チャート外分析 Daily 20261109-0900')];
  const bridge = await startBridge({
    sessions: { daemon: daemonFor(rows), notify: async () => {} },
    refs: (stateDir) => createRefService({ file: join(stateDir, 'refs.json') }),
  });
  t.after(() => bridge.close());
  const token = await bridge.token();
  assert.equal((await bridge.request('/v1/sessions', { token })).body.data.items[0].ref, 'S1');

  // Records imported before this change carry no mark; the next read adds it.
  rows[0].labels = { 'laa-cron': 'daily-20261109-0900' };
  assert.deepEqual((await bridge.request('/v1/sessions', { token })).body.data.items, []);
  assert.equal((await bridge.request('/v1/refs/S1', { token })).body.data.status, 'released');
});

test('a scheduled run sends no notice', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'paseo-routine-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  let clock = Date.parse('2026-11-09T00:00:00Z');
  const now = () => clock;
  let status = 'running';
  const daemon = { workspacePins: async () => [],
    list: async () => [
      agent('cron', 'Pokémon GO 20261109', { 'laa-cron': 'pokemon-go-20261109' }, { status }),
      agent('owner', '社長の会話', {}, { status })] };
  const notices = [];
  const service = createSessionService({ sessionStore: createSessionStore({ file: join(dir, 'sessions.json'), now }), daemon,
    adapter: {}, findWorkspace: async () => null, notify: async (notice) => { notices.push(notice); }, now });
  await service.syncDaemon();
  status = 'idle';
  clock += 1000;
  await service.syncDaemon();
  assert.deepEqual(notices.map((notice) => [notice.kind, notice.title]), [['session.finished', '社長の会話']]);
});

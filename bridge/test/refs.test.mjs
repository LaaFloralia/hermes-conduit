// Short numbers (refs): allocation, release, history, HTTP decoration and the
// read-only CLI. The registry is the single source of truth; every test uses a
// throwaway state directory and never opens the live Bridge state.

import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { createRefRegistry, normalizeRefInput } from '../src/refs/registry.mjs';
import { createRefService } from '../src/refs/service.mjs';
import { skillRefItems } from '../src/refs/items.mjs';
import { startBridge } from './helpers.mjs';

const CLI = new URL('../src/cli.mjs', import.meta.url).pathname;

function tempDir(t) {
  const dir = mkdtempSync(join(tmpdir(), 'laa-refs-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function fixture(t, start = '2026-11-08T00:00:00.000Z') {
  const dir = tempDir(t);
  let clock = Date.parse(start);
  const now = () => clock;
  const file = join(dir, 'refs.json');
  const registry = createRefRegistry({ file, now });
  return {
    dir, file, registry, now,
    advance(ms) { clock += ms; },
    set(iso) { clock = Date.parse(iso); },
  };
}

function task(key, linear, title = `タスク${key}`) {
  return { key, title, external: { linear, url: `https://linear.app/laa/issue/${linear}` } };
}

test('the smallest free number is used and a freed number is reused after the cooldown', (t) => {
  const { registry, advance } = fixture(t);
  assert.equal(registry.assign({ kind: 'task', key: 'a', title: 'A' }).ref, 'T1');
  assert.equal(registry.assign({ kind: 'task', key: 'b', title: 'B' }).ref, 'T2');
  registry.release('task', 'a');
  // Another key cannot take T1 while the 24 h cooldown runs.
  assert.equal(registry.assign({ kind: 'task', key: 'c', title: 'C' }).ref, 'T3');
  advance(24 * 60 * 60 * 1000 + 1);
  registry.release('task', 'b');
  advance(24 * 60 * 60 * 1000 + 1);
  // T1 and T2 are free again; the smallest wins.
  assert.equal(registry.assign({ kind: 'task', key: 'd', title: 'D' }).ref, 'T1');
  assert.equal(registry.assign({ kind: 'task', key: 'e', title: 'E' }).ref, 'T2');
});

test('a key gets its own number back, even inside the cooldown', (t) => {
  const { registry } = fixture(t);
  assert.equal(registry.assign({ kind: 'session', key: 'ses_a', title: 'A' }).ref, 'S1');
  registry.release('session', 'ses_a');
  // Another key would be kept off S1 for a day, but the same key restores it.
  assert.equal(registry.assign({ kind: 'session', key: 'ses_a', title: 'A again' }).ref, 'S1');
  assert.equal(registry.held('session').length, 1);
});

test('only a complete read releases; a missing key is released and re-observed as history', (t) => {
  const { registry } = fixture(t);
  registry.observeComplete('task', [task('a', 'BUS-1'), task('b', 'BUS-2')]);
  assert.deepEqual(registry.held('task').map((r) => r.ref), ['T1', 'T2']);
  registry.observeComplete('task', [task('a', 'BUS-1')]);
  assert.deepEqual(registry.held('task').map((r) => r.key), ['a']);
  const resolved = registry.resolve('T2');
  assert.equal(resolved.status, 'released');
  assert.equal(resolved.previous[0].key, 'b');
});

test('a failed or absent source read never releases anything', async (t) => {
  const { file, now } = fixture(t);
  const service = createRefService({ file, now });
  service.observe('task', [task('a', 'BUS-1'), task('b', 'BUS-2')]);
  service.registerSource('task', async () => { throw new Error('source down'); });
  await service.observeSource('task');
  assert.equal(service.refFor('task', 'b'), 'T2');
  // A cold cache is `null`, not an empty list.
  const cold = createRefService({ file, now });
  cold.observe('task', [task('a', 'BUS-1'), task('b', 'BUS-2')]);
  cold.registerSource('task', () => null);
  await cold.observeSource('task');
  assert.equal(cold.refFor('task', 'b'), 'T2');
});

test('initial bulk assignment follows the per-kind order', (t) => {
  const { registry } = fixture(t);
  registry.observeComplete('task', [
    task('k130', 'BUS-130'), task('k12', 'BUS-12'), task('k45', 'BUS-45'),
  ]);
  assert.deepEqual(registry.held('task').map((r) => [r.ref, r.external.linear]), [
    ['T1', 'BUS-12'], ['T2', 'BUS-45'], ['T3', 'BUS-130'],
  ]);
  registry.observeComplete('session', [
    { key: 'ses_b', title: 'B', createdAt: '2026-01-02T00:00:00.000Z' },
    { key: 'ses_a', title: 'A', createdAt: '2026-01-01T00:00:00.000Z' },
  ]);
  assert.deepEqual(registry.held('session').map((r) => [r.ref, r.key]), [['S1', 'ses_a'], ['S2', 'ses_b']]);
});

test('ref input normalisation accepts spoken and typed forms', () => {
  for (const raw of ['t12', 'Ｔ１２', 'T-12', 'T 12', 'T_12', ' t012 ']) {
    assert.equal(normalizeRefInput(raw)?.ref, 'T12', raw);
  }
  assert.equal(normalizeRefInput('k1').ref, 'K1');
  for (const raw of ['X12', 'T0', 'T', '12', 'T123456', '', 'TT12']) {
    assert.equal(normalizeRefInput(raw), null, raw);
  }
});

test('history is kept for 30 days and then pruned', (t) => {
  const { registry, advance } = fixture(t);
  registry.assign({ kind: 'task', key: 'a', title: 'A' });
  registry.release('task', 'a');
  advance(29 * 24 * 60 * 60 * 1000);
  assert.equal(registry.resolve('T1').status, 'released');
  advance(2 * 24 * 60 * 60 * 1000);
  // Any complete read prunes history; it is then unknown, not released.
  registry.observeComplete('project', []);
  assert.equal(registry.resolve('T1').status, 'unknown');
  assert.deepEqual(registry.resolve('T1').previous, []);
});

test('a skill installed for Claude and Hermes is one ref with both sources', (t) => {
  const { registry } = fixture(t);
  registry.observeComplete('skill', skillRefItems([
    { name: 'docx', source: 'Claude' },
    { name: 'docx', source: 'Hermes' },
    { name: 'github', source: 'Hermes' },
  ]));
  assert.deepEqual(registry.held('skill').map((r) => [r.ref, r.key]), [['K1', 'docx'], ['K2', 'github']]);
  assert.deepEqual(registry.held('skill')[0].external.sources, ['Claude', 'Hermes']);
});

test('a corrupt registry is surfaced and never reset', (t) => {
  const { dir, file } = fixture(t);
  const original = '{"schema":1,"records":';
  writeFileSync(file, original, { mode: 0o600 });
  const logs = [];
  const service = createRefService({ file, log: (entry) => logs.push(entry) });
  assert.equal(service.observe('task', [task('a', 'BUS-1')]), null);
  assert.equal(service.refFor('task', 'a'), null);
  assert.equal(readFileSync(file, 'utf8'), original);
  assert.equal(logs.length, 1);
  assert.equal(logs[0].event, 'refs_error');
  // A structurally wrong document is refused as well.
  writeFileSync(file, JSON.stringify({ schema: 1, records: {}, observedAt: {} }));
  const registry = createRefRegistry({ file });
  assert.throws(() => registry.observeComplete('task', [task('a', 'BUS-1')]), (error) => error.code === 'state_corrupt');
  assert.ok(readFileSync(join(dir, 'refs.json'), 'utf8').includes('"records":{}'));
});

test('GET /v1/refs and /v1/refs/<ref> resolve normalised numbers within scope', async (t) => {
  const bridge = await startBridge({ refs: (stateDir) => createRefService({ file: join(stateDir, 'refs.json') }) });
  t.after(() => bridge.close());
  bridge.refs.observe('task', [task('id1', 'BUS-12', '契約を確認する')]);
  bridge.refs.observe('project', [{ key: 'prj_a', title: 'LAAアプリ' }]);
  const token = await bridge.token();
  const sessionsOnly = await bridge.token(['sessions:read']);

  const list = await bridge.request('/v1/refs', { token });
  assert.equal(list.status, 200);
  assert.deepEqual(list.body.data.items.map((i) => i.ref), ['T1', 'P1']);
  assert.ok(list.body.data.observedAt.task);
  assert.ok(list.body.data.fetchedAt);

  const onlyProjects = await bridge.request('/v1/refs?kind=project', { token });
  assert.deepEqual(onlyProjects.body.data.items.map((i) => i.ref), ['P1']);

  const resolved = await bridge.request('/v1/refs/t-01', { token });
  assert.equal(resolved.status, 200);
  assert.equal(resolved.body.data.ref, 'T1');
  assert.equal(resolved.body.data.status, 'active');
  assert.equal(resolved.body.data.holder.title, '契約を確認する');

  const scopedList = await bridge.request('/v1/refs', { token: sessionsOnly });
  assert.deepEqual(scopedList.body.data.items.map((i) => i.ref), ['P1']);
  assert.equal((await bridge.request('/v1/refs?kind=task', { token: sessionsOnly })).status, 403);

  assert.equal((await bridge.request('/v1/refs/X1', { token })).status, 400);
  const unknown = await bridge.request('/v1/refs/T99', { token });
  assert.equal(unknown.status, 404);
  assert.equal(unknown.body.error.code, 'ref_unknown');
});

test('task and routine lists carry refs, and archive releases immediately', async (t) => {
  const tasks = [
    { id: '00000000-0000-4000-8000-000000000001', identifier: 'BUS-12', title: '契約を確認', url: 'https://linear.app/laa/issue/BUS-12', updatedAt: '2026-11-08T00:00:00.000Z', archivedAt: null },
    { id: '00000000-0000-4000-8000-000000000002', identifier: 'BUS-130', title: '請求書', url: 'https://linear.app/laa/issue/BUS-130', updatedAt: '2026-11-08T00:00:00.000Z', archivedAt: null },
  ];
  const source = {
    async listOwnerTasks({ archived = false } = {}) {
      return { items: tasks.filter((item) => Boolean(item.archivedAt) === archived) };
    },
    async readOwnerTask(id) { return tasks.find((item) => item.id === id) ?? null; },
    async archiveOwnerTask(id) {
      Object.assign(tasks.find((item) => item.id === id), { archivedAt: '2026-11-08T01:00:00.000Z', updatedAt: '2026-11-08T01:00:00.000Z' });
    },
    async restoreOwnerTask(id) {
      Object.assign(tasks.find((item) => item.id === id), { archivedAt: null, updatedAt: '2026-11-08T02:00:00.000Z' });
    },
  };
  const bridge = await startBridge({
    linearOwnerTasks: { source, refs: undefined },
    routines: { read: async () => ({ data: [{ id: 'job:a', name: 'Daily', schedule: 'daily', reading: {} }] }) },
    refs: (stateDir) => createRefService({ file: join(stateDir, 'refs.json') }),
  });
  t.after(() => bridge.close());
  const token = await bridge.token();

  const list = await bridge.request('/v1/linear-owner-tasks', { token });
  assert.deepEqual(list.body.data.items.map((item) => [item.ref, item.identifier]), [['T1', 'BUS-12'], ['T2', 'BUS-130']]);
  assert.equal((await bridge.request('/v1/linear-owner-tasks?archived=only', { token })).body.data.items.length, 0);

  const url = '/v1/linear-owner-tasks/00000000-0000-4000-8000-000000000001/archive';
  const archived = await bridge.request(url, { method: 'POST', token, key: 'a1', headers: { 'if-match': '2026-11-08T00:00:00.000Z' } });
  assert.equal(archived.status, 200);
  assert.equal((await bridge.request('/v1/refs/T1', { token })).body.data.status, 'released');
  const restored = await bridge.request('/v1/linear-owner-tasks/00000000-0000-4000-8000-000000000001/restore', { method: 'POST', token, key: 'r1', headers: { 'if-match': '2026-11-08T01:00:00.000Z' } });
  assert.equal(restored.status, 200);
  assert.equal((await bridge.request('/v1/refs/T1', { token })).body.data.holder.ref, 'T1');

  const routines = await bridge.request('/v1/routines', { token });
  assert.equal(routines.status, 200);
  assert.equal(routines.body.data.items[0].ref, 'R1');
});

test('skill rows of one skill share a ref and both sources are recorded', async (t) => {
  const dir = tempDir(t);
  const claude = join(dir, 'claude');
  const hermes = join(dir, 'hermes');
  for (const [root, name] of [[claude, 'docx'], [hermes, 'docx']]) {
    mkdirSync(join(root, name), { recursive: true });
    writeFileSync(join(root, name, 'SKILL.md'), '---\nname: docx\ndescription: Word文書\n---\n');
  }
  const bridge = await startBridge({
    skills: { roots: [{ source: 'Claude', dir: claude }, { source: 'Hermes', dir: hermes }], brainRoots: [] },
    refs: (stateDir) => createRefService({ file: join(stateDir, 'refs.json') }),
  });
  t.after(() => bridge.close());
  const token = await bridge.token();
  const response = await bridge.request('/v1/skills', { token });
  assert.equal(response.status, 200);
  assert.deepEqual(response.body.data.items.map((item) => item.ref), ['K1', 'K1']);
  const refs = await bridge.request('/v1/refs?kind=skill', { token });
  assert.deepEqual(refs.body.data.items[0].external.sources, ['Claude', 'Hermes']);
});

test('projects and sessions carry refs from creation, and archiving releases them', async (t) => {
  const dir = tempDir(t);
  const repoPath = join(dir, 'repo');
  mkdirSync(join(repoPath, '.git'), { recursive: true });
  const repo = realpathSync(repoPath);
  const workspaceId = `ws_${createHash('sha256').update(repo, 'utf8').digest('hex').slice(0, 16)}`;
  const adapter = {
    origin: 'test',
    async create() {
      return {
        sessionId: 'agent-1',
        requested: { profile: 'deepseek-flash-high', provider: 'dsh', model: '["opencode-go","deepseek-v4.1-flash"]', effort: 'high' },
        phase: 'created',
        reused: false,
      };
    },
    async status() {
      return { phase: 'awaiting_review', daemonStatus: 'idle', pending: [], result: null, stopRequestedAt: null };
    },
  };
  const bridge = await startBridge({
    workspace: { roots: [dir], gitRun: async () => '' },
    sessions: { adapter, pollMs: 25 },
    refs: (stateDir) => createRefService({ file: join(stateDir, 'refs.json') }),
  });
  t.after(() => bridge.close());
  const token = await bridge.token();

  const project = await bridge.request('/v1/projects', { method: 'POST', token, key: 'p1', body: { name: 'LAAアプリ' } });
  assert.equal(project.status, 201);
  assert.equal(project.body.data.ref, 'P1');
  const projects = await bridge.request('/v1/projects', { token });
  assert.equal(projects.body.data.items[0].ref, 'P1');
  const archivedProject = await bridge.request(`/v1/projects/${project.body.data.id}`, {
    method: 'PATCH', token, key: 'p2', headers: { 'if-match': project.body.data.etag }, body: { archived: true },
  });
  assert.equal(archivedProject.status, 200);
  assert.equal((await bridge.request('/v1/refs/P1', { token })).body.data.status, 'released');

  const session = await bridge.request('/v1/sessions', {
    method: 'POST', token, key: 's1',
    body: { workspaceId, requestId: 'req-1', profile: 'deepseek-flash-high', prompt: 'Reply with ok.' },
  });
  assert.equal(session.status, 201, JSON.stringify(session.body));
  assert.equal(session.body.data.ref, 'S1');
  const sessions = await bridge.request('/v1/sessions', { token });
  assert.equal(sessions.body.data.items[0].ref, 'S1');
  const archived = await bridge.request(`/v1/sessions/${session.body.data.id}`, {
    method: 'PATCH', token, key: 's2', body: { archived: true },
  });
  assert.equal(archived.status, 200);
  assert.equal(archived.body.data.ref, null);
  assert.equal((await bridge.request('/v1/refs/S1', { token })).body.data.status, 'released');
  const restored = await bridge.request(`/v1/sessions/${session.body.data.id}`, {
    method: 'PATCH', token, key: 's3', body: { archived: false },
  });
  assert.equal(restored.body.data.ref, 'S1');
});

function run(args, env) {
  return new Promise((resolve) => {
    execFile(process.execPath, [CLI, ...args], { env: { ...process.env, ...env, LAA_BRIDGE_QUIET: '1' } },
      (error, stdout, stderr) => resolve({ code: typeof error?.code === 'number' ? error.code : error ? 1 : 0, stdout, stderr }));
  });
}

test('laa-bridge ref/refs print a resolved number, a released number and held refs', async (t) => {
  const { dir, registry } = fixture(t);
  for (let n = 1; n <= 12; n += 1) registry.assign({ kind: 'task', key: `id${n}`, title: `タスク${n}`, external: { linear: `BUS-${n}`, url: `https://linear.app/laa/issue/BUS-${n}` } });
  registry.release('task', 'id12');
  const env = { LAA_BRIDGE_STATE_DIR: dir };

  const human = await run(['ref', 't-1'], env);
  assert.equal(human.code, 0, human.stderr);
  assert.match(human.stdout, /^T1 タスク「タスク1」 Linear BUS-1 https:\/\/linear\.app\/laa\/issue\/BUS-1$/m);

  const json = await run(['ref', 'Ｔ１２', '--json'], env);
  assert.equal(json.code, 0, json.stderr);
  const resolved = JSON.parse(json.stdout);
  assert.equal(resolved.ref, 'T12');
  assert.equal(resolved.status, 'released');
  assert.deepEqual(resolved.previous.map((r) => r.key), ['id12']);
  assert.equal(resolved.brief, null);

  const active = await run(['ref', 'T1', '--json'], env);
  assert.equal(active.code, 0);
  assert.match(JSON.parse(active.stdout).brief, /^T1＝社長のタスク「タスク1」（Linear BUS-1 https:\/\/linear\.app\/laa\/issue\/BUS-1）。最初にLinearで本文とコメントを読んでから進める。$/);

  const held = await run(['refs', '--kind', 'task', '--json'], env);
  assert.equal(held.code, 0, held.stderr);
  const body = JSON.parse(held.stdout);
  assert.equal(body.items.length, 11);
  assert.equal(body.items[0].ref, 'T1');
  assert.ok(body.observedAt.task === null);

  const unknown = await run(['ref', 'T99', '--json'], env);
  assert.equal(unknown.code, 0);
  assert.equal(JSON.parse(unknown.stdout).status, 'unknown');

  assert.equal((await run(['ref', 'X1'], env)).code, 2);
  assert.equal((await run(['refs', '--kind', 'nope'], env)).code, 2);
});

test('laa-bridge ref fails on a corrupt registry without rewriting it', async (t) => {
  const { dir, file } = fixture(t);
  const original = '{"schema":1,"records":';
  writeFileSync(file, original, { mode: 0o600 });
  const result = await run(['ref', 'T1'], { LAA_BRIDGE_STATE_DIR: dir });
  assert.equal(result.code, 1);
  assert.match(result.stderr, /unreadable \(state_corrupt\)/);
  assert.equal(readFileSync(file, 'utf8'), original);
});

import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { startBridge } from './helpers.mjs';

const CLI = new URL('../src/cli.mjs', import.meta.url).pathname;

function stateDir(t) {
  const dir = mkdtempSync(join(tmpdir(), 'laa-owner-cli-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function run(args, { env = {}, input } = {}) {
  return new Promise((resolve) => {
    const child = execFile(process.execPath, [CLI, ...args], {
      env: { ...process.env, ...env, LAA_BRIDGE_QUIET: '1' },
      maxBuffer: 4 * 1024 * 1024,
    }, (error, stdout, stderr) => {
      resolve({ code: typeof error?.code === 'number' ? error.code : error ? 1 : 0, stdout, stderr });
    });
    if (input === undefined) child.stdin.end();
    else child.stdin.end(input);
  });
}

test('add reads a JSON body from stdin and list shows it', async (t) => {
  const dir = stateDir(t);
  const env = { LAA_BRIDGE_STATE_DIR: dir };
  const added = await run(['tasks', 'add', '--request-id', 'r1', '--input', '-', '--json'], {
    env,
    input: JSON.stringify({ title: '契約内容を確認する', memo: '# メモ', dueDate: '2026-11-05', links: ['https://example.com'] }),
  });
  assert.equal(added.code, 0, added.stderr);
  const created = JSON.parse(added.stdout);
  assert.equal(created.ok, true);
  assert.equal(created.replayed, false);
  assert.equal(created.task.title, '契約内容を確認する');
  assert.equal(created.task.source, 'agent');

  const listed = await run(['tasks', 'list', '--json'], { env });
  assert.equal(listed.code, 0);
  const body = JSON.parse(listed.stdout);
  assert.equal(body.total, 1);
  assert.equal(body.items[0].id, created.task.id);
});

test('add also accepts flags and cannot leak the body into arguments for long text', async (t) => {
  const dir = stateDir(t);
  const env = { LAA_BRIDGE_STATE_DIR: dir };
  const added = await run(['tasks', 'add', '--request-id', 'r1', '--title', 'A', '--status', 'doing', '--due', '2026-11-05', '--link', 'https://example.com/a', '--link', 'https://example.com/b', '--json'], { env });
  assert.equal(added.code, 0, added.stderr);
  const task = JSON.parse(added.stdout).task;
  assert.equal(task.status, 'doing');
  assert.deepEqual(task.links, ['https://example.com/a', 'https://example.com/b']);
});

test('usage errors exit 2', async (t) => {
  const dir = stateDir(t);
  const env = { LAA_BRIDGE_STATE_DIR: dir };
  const missingKey = await run(['tasks', 'add', '--title', 'A'], { env });
  assert.equal(missingKey.code, 2);
  const missingTitle = await run(['tasks', 'add', '--request-id', 'r1'], { env });
  assert.equal(missingTitle.code, 2);
  const badCombination = await run(['tasks', 'add', '--request-id', 'r1', '--title', 'A', '--input', '-'], { env, input: '{}' });
  assert.equal(badCombination.code, 2);
  const noIfMatch = await run(['tasks', 'update', '--id', '11111111-1111-4111-8111-111111111111', '--request-id', 'r2', '--status', 'done'], { env });
  assert.equal(noIfMatch.code, 2);
});

test('update refuses a stale revision (4) and an unknown id (3)', async (t) => {
  const dir = stateDir(t);
  const env = { LAA_BRIDGE_STATE_DIR: dir };
  const added = await run(['tasks', 'add', '--request-id', 'r1', '--title', 'A', '--json'], { env });
  const id = JSON.parse(added.stdout).task.id;

  const ok = await run(['tasks', 'update', '--id', id, '--if-match', '1', '--request-id', 'r2', '--status', 'doing', '--json'], { env });
  assert.equal(ok.code, 0, ok.stderr);
  assert.equal(JSON.parse(ok.stdout).task.revision, 2);

  const stale = await run(['tasks', 'update', '--id', id, '--if-match', '1', '--request-id', 'r3', '--status', 'done', '--json'], { env });
  assert.equal(stale.code, 4);
  assert.equal(JSON.parse(stale.stdout).error.code, 'owner_task_revision_mismatch');

  const missing = await run(['tasks', 'update', '--id', '11111111-1111-4111-8111-111111111111', '--if-match', '1', '--request-id', 'r4', '--status', 'done'], { env });
  assert.equal(missing.code, 3);
});

test('input rejection exits 5 and the failed body is not stored', async (t) => {
  const dir = stateDir(t);
  const env = { LAA_BRIDGE_STATE_DIR: dir };
  const bad = await run(['tasks', 'add', '--request-id', 'r1', '--title', 'A', '--status', 'later', '--json'], { env });
  assert.equal(bad.code, 5);
  assert.equal(JSON.parse(bad.stdout).error.details.field, 'status');
  const listed = await run(['tasks', 'list', '--json'], { env });
  assert.equal(JSON.parse(listed.stdout).total, 0);
});

test('a locked store exits 6', async (t) => {
  const dir = stateDir(t);
  await run(['tasks', 'add', '--request-id', 'r1', '--title', 'A', '--json'], { env: { LAA_BRIDGE_STATE_DIR: dir } });
  writeFileSync(join(dir, 'owner-tasks.json.lock'), JSON.stringify({ pid: process.pid, startedAt: new Date().toISOString() }));
  const locked = await run(['tasks', 'add', '--request-id', 'r2', '--title', 'B', '--json'], {
    env: { LAA_BRIDGE_STATE_DIR: dir, LAA_BRIDGE_OWNER_TASKS_LOCK_TIMEOUT_MS: '150' },
  });
  assert.equal(locked.code, 6);
  assert.equal(JSON.parse(locked.stdout).error.details.reason, 'locked');
});

test('a CLI task is visible over HTTP and an HTTP task over the CLI', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const token = await api.token();
  const env = { LAA_BRIDGE_STATE_DIR: api.stateDir };

  const added = await run(['tasks', 'add', '--request-id', 'r1', '--title', 'from cli', '--json'], { env });
  assert.equal(added.code, 0, added.stderr);
  const id = JSON.parse(added.stdout).task.id;
  const overHttp = await api.request(`/v1/owner-tasks/${id}`, { token });
  assert.equal(overHttp.status, 200);
  assert.equal(overHttp.body.data.title, 'from cli');

  const created = await api.request('/v1/owner-tasks', { method: 'POST', token, key: 'http-1', body: { title: 'from http' } });
  assert.equal(created.status, 201);
  const listed = await run(['tasks', 'list', '--json'], { env });
  const titles = JSON.parse(listed.stdout).items.map((task) => task.title);
  assert.deepEqual(titles.sort(), ['from cli', 'from http']);

  // A phone write and a CLI write share the revision counter.
  const updated = await run(['tasks', 'update', '--id', created.body.data.id, '--if-match', '1', '--request-id', 'r2', '--status', 'done', '--json'], { env });
  assert.equal(updated.code, 0, updated.stderr);
  const reread = await api.request(`/v1/owner-tasks/${created.body.data.id}`, { token });
  assert.equal(reread.body.data.status, 'done');
  assert.equal(reread.body.data.revision, 2);
});

test('parallel CLI writes serialise through the lock', async (t) => {
  const dir = stateDir(t);
  const env = { LAA_BRIDGE_STATE_DIR: dir };

  const [a, b] = await Promise.all([
    run(['tasks', 'add', '--request-id', 'same', '--title', 'same', '--json'], { env }),
    run(['tasks', 'add', '--request-id', 'same', '--title', 'same', '--json'], { env }),
  ]);
  assert.equal(a.code, 0, a.stderr);
  assert.equal(b.code, 0, b.stderr);
  assert.equal(JSON.parse(a.stdout).task.id, JSON.parse(b.stdout).task.id);

  const listed = await run(['tasks', 'list', '--json'], { env });
  assert.equal(JSON.parse(listed.stdout).total, 1);

  const [c, d] = await Promise.all([
    run(['tasks', 'add', '--request-id', 'one', '--title', 'one', '--json'], { env }),
    run(['tasks', 'add', '--request-id', 'two', '--title', 'two', '--json'], { env }),
  ]);
  assert.equal(c.code, 0, c.stderr);
  assert.equal(d.code, 0, d.stderr);
  assert.equal(JSON.parse((await run(['tasks', 'list', '--json'], { env })).stdout).total, 3);
});

test('list prints one line per task and the cursor for the next page', async (t) => {
  const dir = stateDir(t);
  const env = { LAA_BRIDGE_STATE_DIR: dir };
  for (let i = 0; i < 3; i += 1) {
    await run(['tasks', 'add', '--request-id', `r${i}`, '--title', `task ${i}`], { env });
  }
  const listed = await run(['tasks', 'list', '--limit', '2'], { env });
  assert.equal(listed.code, 0);
  assert.match(listed.stdout, /task \d/);
  assert.match(listed.stdout, /next: --cursor /);
  assert.match(listed.stdout, /3 task\(s\): open 3/);
});

test('status reports the store and the last backup', async (t) => {
  const dir = stateDir(t);
  const env = { LAA_BRIDGE_STATE_DIR: dir };
  await run(['tasks', 'add', '--request-id', 'r1', '--title', 'A'], { env });
  await run(['tasks', 'backup'], { env });
  const status = await run(['tasks', 'status', '--json'], { env });
  assert.equal(status.code, 0);
  const body = JSON.parse(status.stdout).status;
  assert.equal(body.counts.tasks, 1);
  assert.equal(body.marker, true);
  assert.ok(body.lastBackup);
  assert.equal(readFileSync(join(dir, 'owner-tasks.json'), 'utf8').includes('"schema":1'), true);
});

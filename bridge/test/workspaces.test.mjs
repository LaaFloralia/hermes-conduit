import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { startBridge } from './helpers.mjs';

// A porcelain v2 --branch record set. The scanner and the creator are
// deterministic, so the fake git only needs to answer status and rev-parse.
function statusOutput({ oid = '9e728ce2aaaa', head = 'master', upstream = 'origin/master', ab = '+0 -0', entries = [] } = {}) {
  const headers = [`# branch.oid ${oid}`, `# branch.head ${head}`];
  if (upstream) headers.push(`# branch.upstream ${upstream}`);
  if (ab) headers.push(`# branch.ab ${ab}`);
  return `${[...headers, ...entries].join('\u0000')}\u0000`;
}

function makeRepo(path, { worktree = false } = {}) {
  mkdirSync(path, { recursive: true });
  if (worktree) {
    writeFileSync(join(path, '.git'), 'gitdir: /Users/laa/dev/hermes-conduit/.git/worktrees/x\n');
  } else {
    mkdirSync(join(path, '.git'), { recursive: true });
  }
  return realpathSync(path);
}

function fixture(t) {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), 'laa-bridge-ws-')));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const root = join(dir, 'workspaces');
  mkdirSync(root, { recursive: true });
  const repoA = makeRepo(join(root, 'repo-a'));
  const repoB = makeRepo(join(root, 'nested', 'deep', 'repo-b'));
  const worktree = makeRepo(join(root, 'wtroot', 'abc123', 'laa-x'), { worktree: true });
  const outside = makeRepo(join(dir, 'outside'));
  symlinkSync(outside, join(root, 'linked-out'));
  return { dir, root, repoA, repoB, worktree, outside };
}

function fakeGit({ statusByPath, branches = new Set() }) {
  const calls = [];
  return {
    calls,
    async run(args, { cwd } = {}) {
      calls.push({ args, cwd });
      if (args[0] === 'status') {
        const output = statusByPath.get(cwd);
        if (output === undefined) throw new Error(`unexpected git status in ${cwd}`);
        return output;
      }
      if (args[0] === 'rev-parse') {
        const name = args[args.length - 1].replace(/^refs\/heads\//, '');
        return branches.has(name) ? 'abc1234\n' : '';
      }
      throw new Error(`unexpected git command: ${args.join(' ')}`);
    },
  };
}

test('existing repos and worktrees are listed with branch and status', async (t) => {
  const paths = fixture(t);
  const statusByPath = new Map([
    [paths.repoA, statusOutput()],
    [paths.repoB, statusOutput({
      head: 'feature/x',
      upstream: null,
      ab: null,
      entries: ['1 .M N... 100644 100644 100644 a b changed.txt', '1 M. N... 100644 100644 100644 a b staged.txt', '? new.txt'],
    })],
    [paths.worktree, statusOutput({ head: 'laa-projects-13', ab: '+1 -2' })],
    [paths.outside, statusOutput()],
  ]);
  const git = fakeGit({ statusByPath });
  const bridge = await startBridge({ workspace: { roots: [paths.root], gitRun: git.run } });
  t.after(() => bridge.close());
  const token = await bridge.token();

  const listed = await bridge.request('/v1/workspaces', { token });
  assert.equal(listed.status, 200);
  const pathsListed = listed.body.data.items.map((item) => item.path);
  assert.deepEqual(pathsListed, [paths.repoA, paths.repoB, paths.worktree].sort((a, b) => a.localeCompare(b)));
  assert.equal(pathsListed.includes(paths.outside), false, 'a symlink must not pull in a path outside the roots');

  const repoA = listed.body.data.items.find((item) => item.path === paths.repoA);
  assert.equal(repoA.kind, 'repo');
  assert.equal(repoA.branch, 'master');
  assert.equal(repoA.head, '9e728ce2aaaa');
  assert.equal(repoA.status.clean, true);

  const repoB = listed.body.data.items.find((item) => item.path === paths.repoB);
  assert.equal(repoB.kind, 'repo');
  assert.equal(repoB.status.clean, false);
  assert.equal(repoB.status.modified, 1);
  assert.equal(repoB.status.staged, 1);
  assert.equal(repoB.status.untracked, 1);
  assert.equal(repoB.status.branch, 'feature/x');

  const worktree = listed.body.data.items.find((item) => item.path === paths.worktree);
  assert.equal(worktree.kind, 'worktree');
  assert.equal(worktree.status.ahead, 1);
  assert.equal(worktree.status.behind, 2);
  assert.ok(worktree.displayPath.startsWith('~') || worktree.displayPath.startsWith('/'));

  const fetched = await bridge.request(`/v1/workspaces/${repoA.id}`, { token });
  assert.equal(fetched.status, 200);
  assert.equal(fetched.body.data.path, paths.repoA);
  assert.match(fetched.headers.get('etag'), /^"ws_[0-9a-f]{16}:/);

  const unknown = await bridge.request('/v1/workspaces/ws_0000000000000000', { token });
  assert.equal(unknown.status, 404);
  const malformed = await bridge.request('/v1/workspaces/not-an-id', { token });
  assert.equal(malformed.status, 404);
});

test('a worktree is created through paseo and the project link persists', async (t) => {
  const paths = fixture(t);
  const statusByPath = new Map([
    [paths.repoA, statusOutput()],
    [paths.worktree, statusOutput({ head: 'laa-projects-13' })],
  ]);
  const git = fakeGit({ statusByPath });
  const created = [];
  const createWorktree = async (args) => {
    created.push(args);
    const target = makeRepo(join(paths.root, 'wtroot', 'newid', args.branch), { worktree: true });
    statusByPath.set(target, statusOutput({ head: args.branch }));
    return { worktreePath: target, branchName: args.branch };
  };
  const bridge = await startBridge({ workspace: { roots: [paths.root], gitRun: git.run, createWorktree } });
  t.after(() => bridge.close());
  const token = await bridge.token();
  const reader = await bridge.token(['sessions:read']);

  const listed = await bridge.request('/v1/workspaces', { token });
  const repoA = listed.body.data.items.find((item) => item.path === paths.repoA);

  const anonymous = await bridge.request('/v1/workspaces');
  assert.equal(anonymous.status, 401);

  const denied = await bridge.request('/v1/workspaces', {
    method: 'POST',
    token: reader,
    key: 'ws-deny',
    body: { repoId: repoA.id, worktreeName: 'laa-denied' },
  });
  assert.equal(denied.status, 403);
  assert.equal(denied.body.error.code, 'insufficient_scope');

  const missingKey = await bridge.request('/v1/workspaces', {
    method: 'POST',
    token,
    body: { repoId: repoA.id, worktreeName: 'laa-nokey' },
  });
  assert.equal(missingKey.status, 400);
  assert.equal(missingKey.body.error.code, 'idempotency_key_required');

  const project = (await bridge.request('/v1/projects', {
    method: 'POST',
    token,
    key: 'ws-project',
    body: { name: 'LAA｜環境認識' },
  })).body.data;

  const request = {
    method: 'POST',
    token,
    key: 'ws-create',
    body: { repoId: repoA.id, worktreeName: 'laa-projects-13', projectId: project.id },
  };
  const response = await bridge.request('/v1/workspaces', request);
  assert.equal(response.status, 201);
  assert.equal(created.length, 1);
  assert.deepEqual(created[0], { repoPath: paths.repoA, branch: 'laa-projects-13', base: null });
  assert.equal(response.body.data.branch, 'laa-projects-13');
  assert.equal(response.body.data.kind, 'worktree');
  assert.equal(response.body.data.projectId, project.id);
  assert.equal(response.body.data.repoId, repoA.id);
  assert.equal(response.body.data.status.clean, true);

  const replay = await bridge.request('/v1/workspaces', request);
  assert.equal(replay.status, 201);
  assert.equal(replay.headers.get('idempotency-replayed'), 'true');
  assert.equal(created.length, 1, 'a replayed create must not run paseo again');

  const filtered = await bridge.request(`/v1/workspaces?projectId=${project.id}`, { token });
  assert.deepEqual(filtered.body.data.items.map((item) => item.path), [response.body.data.path]);

  await bridge.restart();
  const afterRestart = await bridge.request('/v1/workspaces', { token });
  const record = afterRestart.body.data.items.find((item) => item.path === response.body.data.path);
  assert.equal(record.projectId, project.id, 'the project link is persisted, not recomputed');

  const del = await bridge.request(`/v1/workspaces/${response.body.data.id}`, { method: 'DELETE', token });
  assert.equal(del.status, 405, 'a workspace can never be removed through the Bridge');
});

test('worktree creation refuses conflicts and dependency failures without touching anything', async (t) => {
  const paths = fixture(t);
  const statusByPath = new Map([
    [paths.repoA, statusOutput()],
    [paths.worktree, statusOutput({ head: 'laa-projects-13' })],
  ]);
  const calls = [];
  let outcome = { path: join(paths.root, 'wtroot', 'x', 'laa-new') };
  const createWorktree = async (args) => {
    calls.push(args);
    if (outcome instanceof Error) throw outcome;
    if (outcome.rawPath) return { worktreePath: outcome.rawPath, branchName: args.branch };
    const target = makeRepo(outcome.path, { worktree: true });
    statusByPath.set(target, statusOutput({ head: args.branch }));
    return { worktreePath: target, branchName: args.branch };
  };
  const git = fakeGit({ statusByPath, branches: new Set(['laa-taken']) });
  const bridge = await startBridge({ workspace: { roots: [paths.root], gitRun: git.run, createWorktree } });
  t.after(() => bridge.close());
  const token = await bridge.token();

  const items = (await bridge.request('/v1/workspaces', { token })).body.data.items;
  const repoA = items.find((item) => item.path === paths.repoA);
  const worktree = items.find((item) => item.path === paths.worktree);

  const taken = await bridge.request('/v1/workspaces', {
    method: 'POST',
    token,
    key: 'ws-taken',
    body: { repoId: repoA.id, worktreeName: 'laa-taken' },
  });
  assert.equal(taken.status, 409);
  assert.equal(taken.body.error.code, 'worktree_exists');
  assert.equal(calls.length, 0, 'an existing branch must not reach paseo');

  const fromWorktree = await bridge.request('/v1/workspaces', {
    method: 'POST',
    token,
    key: 'ws-from-worktree',
    body: { repoId: worktree.id, worktreeName: 'laa-child' },
  });
  assert.equal(fromWorktree.status, 409);
  assert.equal(fromWorktree.body.error.code, 'repo_is_worktree');
  assert.equal(calls.length, 0);

  const unknownProject = await bridge.request('/v1/workspaces', {
    method: 'POST',
    token,
    key: 'ws-unknown-project',
    body: { repoId: repoA.id, worktreeName: 'laa-x', projectId: 'prj_000000000000' },
  });
  assert.equal(unknownProject.status, 404);

  const badName = await bridge.request('/v1/workspaces', {
    method: 'POST',
    token,
    key: 'ws-bad-name',
    body: { repoId: repoA.id, worktreeName: '../escape' },
  });
  assert.equal(badName.status, 400);

  outcome = new Error('paseo daemon unreachable');
  const failed = await bridge.request('/v1/workspaces', {
    method: 'POST',
    token,
    key: 'ws-fail',
    body: { repoId: repoA.id, worktreeName: 'laa-failing' },
  });
  assert.equal(failed.status, 503);
  assert.equal(failed.body.error.code, 'dependency_unavailable');

  outcome = { rawPath: paths.outside };
  const escaped = await bridge.request('/v1/workspaces', {
    method: 'POST',
    token,
    key: 'ws-escape',
    body: { repoId: repoA.id, worktreeName: 'laa-escape' },
  });
  assert.equal(escaped.status, 503);
  assert.match(escaped.body.error.message, /outside the allowlisted roots/);
  assert.equal(escaped.body.data, undefined);
});

test('pagination and limits are validated', async (t) => {
  const paths = fixture(t);
  const statusByPath = new Map([
    [paths.repoA, statusOutput()],
    [paths.repoB, statusOutput()],
    [paths.worktree, statusOutput()],
  ]);
  const git = fakeGit({ statusByPath });
  const bridge = await startBridge({ workspace: { roots: [paths.root], gitRun: git.run } });
  t.after(() => bridge.close());
  const token = await bridge.token();

  const first = await bridge.request('/v1/workspaces?limit=1', { token });
  assert.equal(first.body.data.items.length, 1);
  assert.ok(first.body.data.nextCursor);

  const second = await bridge.request(`/v1/workspaces?limit=1&cursor=${first.body.data.nextCursor}`, { token });
  assert.equal(second.body.data.items.length, 1);
  assert.notEqual(second.body.data.items[0].id, first.body.data.items[0].id);

  const badLimit = await bridge.request('/v1/workspaces?limit=0', { token });
  assert.equal(badLimit.status, 400);
  assert.equal(badLimit.body.error.code, 'limit_invalid');

  const badCursor = await bridge.request('/v1/workspaces?cursor=%%%', { token });
  assert.equal(badCursor.status, 400);
  assert.equal(badCursor.body.error.code, 'cursor_invalid');
});

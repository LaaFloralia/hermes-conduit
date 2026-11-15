import assert from 'node:assert/strict';
import { dirname } from 'node:path';
import test from 'node:test';
import { resolvePaseoBin, resolveWorkClient, resolveWorkHome, WORK_ROUTER } from '../src/config.mjs';
import { paseoWorktreeCreator } from '../src/routes/workspaces.mjs';

test('the paseo creator builds a branch-off create with the repo as cwd', async () => {
  const calls = [];
  const run = async (bin, args, options) => {
    calls.push({ bin, args, options });
    return { stdout: JSON.stringify({ name: 'laa-x', branchName: 'laa-x', worktreePath: '/Users/laa/.paseo/worktrees/abc/laa-x' }) };
  };
  const create = paseoWorktreeCreator({ bin: '/opt/homebrew/bin/paseo', run });
  const result = await create({ repoPath: '/Users/laa/dev/hermes-conduit', branch: 'laa-x', base: 'origin/master' });

  assert.deepEqual(result, { worktreePath: '/Users/laa/.paseo/worktrees/abc/laa-x', branchName: 'laa-x' });
  assert.equal(calls[0].bin, '/opt/homebrew/bin/paseo');
  assert.deepEqual(calls[0].args, [
    'worktree', 'create', '--mode', 'branch-off',
    '--cwd', '/Users/laa/dev/hermes-conduit',
    '--new-branch', 'laa-x', '--json', '--base', 'origin/master',
  ]);
  // The CLI's shebang runs `node` through env, which launchd's PATH lacks.
  assert.equal(calls[0].options.env.PATH.split(':')[0], dirname(process.execPath));
  assert.equal(calls[0].options.env.PATH.includes('/opt/homebrew/bin'), true);
});

test('an existing branch reported by paseo becomes a conflict, other failures stay failures', async () => {
  const taken = Object.assign(new Error('Command failed'), {
    stderr: "fatal: a branch named 'laa-x' already exists",
  });
  const create = paseoWorktreeCreator({ run: async () => { throw taken; } });
  await assert.rejects(create({ repoPath: '/repo', branch: 'laa-x' }), (err) => err.code === 'branch_exists');

  const broken = new Error('daemon unreachable');
  const failing = paseoWorktreeCreator({ run: async () => { throw broken; } });
  await assert.rejects(failing({ repoPath: '/repo', branch: 'laa-y' }), (err) => err === broken);

  const noJson = paseoWorktreeCreator({ run: async () => ({ stdout: 'not json' }) });
  await assert.rejects(noJson({ repoPath: '/repo', branch: 'laa-z' }), /no JSON/);

  const noPath = paseoWorktreeCreator({ run: async () => ({ stdout: '{}' }) });
  await assert.rejects(noPath({ repoPath: '/repo', branch: 'laa-w' }), /no worktreePath/);
});

test('Work paths do not fall back when the router or CLI is missing', () => {
  const present = () => true;
  const missing = () => false;
  assert.equal(resolvePaseoBin({ LAA_BRIDGE_PASEO_BIN: '/custom/work' }, present), '/custom/work');
  assert.match(resolvePaseoBin({}, present), /\/laa-work$/);
  assert.throws(() => resolvePaseoBin({}, missing), /Work CLI not found/);
  assert.throws(() => resolvePaseoBin({ LAA_BRIDGE_PASEO_BIN: '/missing' }, missing), /Work CLI not found/);
  assert.equal(resolveWorkClient({}, present), WORK_ROUTER);
  assert.equal(resolveWorkClient({ LAA_BRIDGE_WORK_CLIENT: '/custom/router.mjs' }, present), '/custom/router.mjs');
  assert.throws(() => resolveWorkClient({}, missing), /Work router not found/);
  assert.throws(() => resolveWorkClient({ LAA_BRIDGE_WORK_CLIENT: '/missing' }, missing), /Work router not found/);
  assert.match(resolveWorkHome({}), /\/\.local\/share\/laa-work$/);
  assert.equal(resolveWorkHome({ LAA_BRIDGE_WORK_HOME: '/custom/home' }), '/custom/home');
});

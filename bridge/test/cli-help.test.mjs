import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const cli = fileURLToPath(new URL('../src/cli.mjs', import.meta.url));

const commands = [[], ['pair'], ['serve'], ['revoke'], ['grant'], ['grant-studio'], ['grant-instructions'], ['tasks'], ['tasks', 'restore'], ['tasks', 'import-linear'], ['devices'], ['status'], ['version'], ['ref'], ['refs']];
for (const args of commands) {
  for (const flag of ['--help', '-h']) {
  test(`${[...args, flag].join(' ')} prints usage without touching state or starting work`, () => {
    const dir = mkdtempSync(join(tmpdir(), 'laa-bridge-help-'));
    const state = join(dir, 'state.json');
    const original = '{"schema":1,"devices":{},"pairings":{},"idempotency":{}}\n';
    writeFileSync(state, original, { mode: 0o600 });
    try {
      const result = spawnSync(process.execPath, [cli, ...args, flag], {
        env: { ...process.env, LAA_BRIDGE_STATE_DIR: dir },
        encoding: 'utf8',
        timeout: 5000,
      });
      assert.equal(result.error, undefined, 'help must finish without starting a service');
      assert.equal(result.status, 0);
      assert.ok(result.stdout.includes('Usage:'), 'help must show usage');
      assert.ok(!result.stdout.includes('Pairing code :'), 'help must not issue credentials');
      assert.equal(result.stderr, '');
      assert.equal(readFileSync(state, 'utf8'), original, 'help must preserve existing state');
      assert.equal(existsSync(join(dir, 'state.lock')), false);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
  }
}

test('pair help rejects unexpected positional input without creating state', () => {
  const dir = mkdtempSync(join(tmpdir(), 'laa-bridge-help-'));
  const stateDir = join(dir, 'absent');
  try {
    for (const args of [['pair', 'help'], ['pair', '--help'], ['help']]) {
      const result = spawnSync(process.execPath, [cli, ...args], {
        env: { ...process.env, LAA_BRIDGE_STATE_DIR: stateDir }, encoding: 'utf8', timeout: 5000,
      });
      assert.equal(result.error, undefined);
      assert.equal(result.status, args[1] === 'help' ? 2 : 0);
      assert.equal(existsSync(stateDir), false, 'help or invalid input must not create state');
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

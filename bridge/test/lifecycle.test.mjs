import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { startBridge } from './helpers.mjs';

const cliPath = join(dirname(fileURLToPath(import.meta.url)), '..', 'src', 'cli.mjs');

function runCli(api, args) {
  const result = spawnSync(process.execPath, [cliPath, ...args], {
    env: { ...process.env, LAA_BRIDGE_STATE_DIR: api.stateDir, LAA_BRIDGE_QUIET: '1' },
    encoding: 'utf8',
  });
  assert.equal(result.status, 0, `laa-bridge ${args.join(' ')} failed: ${result.stderr}`);
  return result.stdout;
}

test('devices and pairing codes survive a restart', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const paired = await api.pair();
  const { token } = (await api.enroll(paired.code)).body.data;

  const pending = await api.pair({ name: 'iPad' });
  await api.restart();

  assert.equal((await api.request('/v1/me', { token })).status, 200, 'token still valid after restart');
  const enrolled = await api.enroll(pending.code, 'iPad');
  assert.equal(enrolled.status, 201, 'a code issued before the restart still works once');
});

test('laa-bridge revoke is seen by an already running server', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const paired = await api.pair();
  const { deviceId, token } = (await api.enroll(paired.code)).body.data;

  const output = runCli(api, ['revoke', deviceId, '--reason', 'lost phone', '--json']);
  const result = JSON.parse(output);
  assert.equal(result.deviceId, deviceId);
  assert.equal(result.status, 'revoked');

  const after = await api.request('/v1/me', { token });
  assert.equal(after.status, 401);
  assert.equal(after.body.error.code, 'token_revoked');

  const devices = JSON.parse(runCli(api, ['devices', '--json']));
  assert.equal(devices.length, 1);
  assert.equal(devices[0].status, 'revoked');
});

test('laa-bridge pair issues a code the service accepts', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());

  const issued = JSON.parse(runCli(api, ['pair', '--name', 'CLI iPhone', '--json']));
  assert.match(issued.code, /^[2-9A-Z]{4}-[2-9A-Z]{4}$/);
  assert.ok(issued.scopes.includes('brain:read'));
  assert.ok(!issued.scopes.includes('brain:write'));

  const enrolled = await api.enroll(issued.code, 'CLI iPhone');
  assert.equal(enrolled.status, 201);
  assert.deepEqual(enrolled.body.data.scopes, issued.scopes);

  // The code is never printed outside that one command.
  const devices = JSON.parse(runCli(api, ['devices', '--json']));
  assert.ok(!JSON.stringify(devices).includes(issued.code));
});

test('corrupt state stops the service instead of silently resetting', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  await api.pair(); // create the state file
  writeFileSync(join(api.stateDir, 'state.json'), '{ not json', 'utf8');
  assert.throws(() => api.store.read(), (err) => err.code === 'state_corrupt');
});

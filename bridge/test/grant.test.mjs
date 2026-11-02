import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { grantScopes } from '../src/pairing.mjs';
import { startBridge } from './helpers.mjs';

async function device(api) {
  const token = await api.token();
  const me = await api.request('/v1/me', { token });
  assert.equal(me.status, 200);
  return { token, id: me.body.data.deviceId, scopes: me.body.data.scopes };
}

test('grant allows only calendar:read and brain:create, and rejects a mixed request atomically', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const target = await device(api);

  const before = api.store.read().devices[target.id];
  for (const scopes of [
    ['calendar:read', 'brain:write'],
    ['brain:create', 'gui:operate'],
    ['calendar:read', 'archives:restore'],
    ['devices:admin'],
    ['sessions:*'],
    ['calendar:read', 'not-a-scope'],
  ]) {
    const result = grantScopes(api.store, { target: target.id, scopes, reason: 'mixed request' });
    assert.match(result.error, /not grantable/, scopes.join(','));
    const after = api.store.read().devices[target.id];
    assert.deepEqual(after.scopes, before.scopes, scopes.join(','));
    assert.equal(after.scopeGrants, undefined, scopes.join(','));
  }

  const calendar = grantScopes(api.store, { target: target.id, scopes: ['calendar:read'], reason: 'Today', now: 1000, operatorUid: 123 });
  assert.equal(calendar.error, undefined);
  assert.equal(calendar.alreadyGranted, false);
  assert.deepEqual(calendar.device.scopes, [...before.scopes, 'calendar:read'].sort());
  assert.deepEqual(calendar.device.scopeGrants, [{
    scopes: ['calendar:read'],
    grantedAt: '1970-01-01T00:00:01.000Z',
    operatorUid: 123,
    reason: 'Today',
    wasAlreadyGranted: false,
  }]);

  const repeated = grantScopes(api.store, { target: target.id, scopes: ['calendar:read'], reason: 'again', now: 2000 });
  assert.equal(repeated.alreadyGranted, true);
  assert.equal(api.store.read().devices[target.id].scopeGrants.length, 1, 'a repeated grant does not add another record');

  const brain = grantScopes(api.store, { target: target.id, scopes: ['brain:create'], reason: 'Inbox', now: 3000, operatorUid: 123 });
  assert.equal(brain.alreadyGranted, false);
  assert.ok(brain.device.scopes.includes('brain:create'));
  assert.equal(api.store.read().devices[target.id].scopeGrants.length, 2);

  const prefix = grantScopes(api.store, { target: target.id.slice(0, 4), scopes: ['calendar:read'], reason: 'prefix', now: 4000 });
  assert.equal(prefix.device.id, target.id);
  assert.equal(prefix.alreadyGranted, true);

  api.store.mutate((state) => { state.devices[target.id].revokedAt = new Date(5000).toISOString(); });
  const revoked = grantScopes(api.store, { target: target.id, scopes: ['calendar:read'], reason: 'revoked', now: 5000 });
  assert.match(revoked.error, /revoked/);
});

test('grant rejects an ambiguous prefix without changing either device', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const target = await device(api);
  api.store.mutate((state) => {
    const base = state.devices[target.id];
    for (const suffix of ['000000000001', '000000000002']) {
      state.devices[`dev_aaaa${suffix}`] = {
        ...structuredClone(base),
        id: `dev_aaaa${suffix}`,
        name: `Test ${suffix}`,
      };
    }
  });

  const result = grantScopes(api.store, { target: 'dev_aaaa', scopes: ['calendar:read'], reason: 'ambiguous' });
  assert.match(result.error, /ambiguous/);
  const state = api.store.read();
  assert.equal(state.devices['dev_aaaa000000000001'].scopeGrants, undefined);
  assert.equal(state.devices['dev_aaaa000000000002'].scopeGrants, undefined);
});

test('the CLI exposes grant, its JSON output and the recorded audit', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const target = await device(api);
  const cli = fileURLToPath(new URL('../src/cli.mjs', import.meta.url));
  const env = { ...process.env, LAA_BRIDGE_STATE_DIR: api.stateDir };

  const noScopes = spawnSync(process.execPath, [cli, 'grant', target.id, '--reason', 'x'], { env, encoding: 'utf8' });
  assert.equal(noScopes.status, 2);
  assert.match(noScopes.stderr, /--scopes/);

  const noReason = spawnSync(process.execPath, [cli, 'grant', target.id, '--scopes', 'calendar:read'], { env, encoding: 'utf8' });
  assert.equal(noReason.status, 2);
  assert.match(noReason.stderr, /--reason/);
  assert.equal(api.store.read().devices[target.id].scopeGrants, undefined);

  const mixed = spawnSync(process.execPath, [cli, 'grant', target.id, '--scopes', 'calendar:read,brain:write', '--reason', 'mixed'], { env, encoding: 'utf8' });
  assert.equal(mixed.status, 1);
  assert.match(mixed.stderr, /not grantable/);
  assert.equal(api.store.read().devices[target.id].scopeGrants, undefined);

  const output = execFileSync(process.execPath, [
    cli, 'grant', target.id, '--scopes', 'calendar:read,brain:create', '--reason', 'Owner phone', '--json',
  ], { env, encoding: 'utf8' });
  const granted = JSON.parse(output);
  assert.equal(granted.deviceId, target.id);
  assert.equal(granted.alreadyGranted, false);
  assert.deepEqual(granted.requested, ['brain:create', 'calendar:read']);
  assert.ok(granted.scopes.includes('calendar:read'));
  assert.ok(granted.scopes.includes('brain:create'));
  assert.equal(granted.scopeGrants.length, 1);
  assert.equal(granted.scopeGrants[0].reason, 'Owner phone');

  const again = JSON.parse(execFileSync(process.execPath, [
    cli, 'grant', target.id, '--scopes', 'calendar:read', '--reason', 'again', '--json',
  ], { env, encoding: 'utf8' }));
  assert.equal(again.alreadyGranted, true);

  const devices = JSON.parse(execFileSync(process.execPath, [cli, 'devices', '--json'], { env, encoding: 'utf8' }));
  assert.equal(devices.find((item) => item.id === target.id).scopeGrants[0].reason, 'Owner phone');

  api.store.mutate((state) => { state.devices[target.id].revokedAt = new Date().toISOString(); });
  const revoked = spawnSync(process.execPath, [cli, 'grant', target.id, '--scopes', 'calendar:read', '--reason', 'revoked'], { env, encoding: 'utf8' });
  assert.equal(revoked.status, 1);
  assert.match(revoked.stderr, /revoked/);
});

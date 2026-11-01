import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, readdirSync, symlinkSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startBridge } from './helpers.mjs';

test('instruction endpoints restrict access, preserve backups and reject stale revisions', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'instruction-test-'));
  const agents = join(dir, 'AGENTS.md'), claude = join(dir, 'CLAUDE.md');
  writeFileSync(agents, '# Original\n'); writeFileSync(claude, '# Claude\n');
  const api = await startBridge({ instructions: { enabled: true, files: { agents, claude } } });
  t.after(async () => { await api.close(); rmSync(dir, { recursive: true, force: true }); });
  const token = await api.token(['instructions:read', 'instructions:write']);
  const readOnly = await api.token(['instructions:read']);
  const oldScopes = await api.token(['sessions:read', 'sessions:write']);
  assert.equal((await api.request('/v1/instructions/agents', { token: oldScopes })).status, 403);
  assert.equal((await api.request('/v1/instructions/agents')).status, 401);
  assert.equal((await api.request('/v1/instructions/other', { token })).status, 404);
  const first = await api.request('/v1/instructions/agents', { token });
  assert.equal(first.body.data.text, '# Original\n');
  assert.equal((await api.request('/v1/instructions/agents', { method: 'PUT', token: readOnly, body: { text: 'no' }, headers: { 'if-match': first.body.data.etag } })).status, 403);
  assert.equal((await api.request('/v1/instructions/agents', { method: 'PUT', token, body: { text: 'no' } })).status, 428);
  const saved = await api.request('/v1/instructions/agents', { method: 'PUT', token, body: { text: '# Changed\n' }, headers: { 'if-match': first.body.data.etag } });
  assert.equal(saved.status, 200);
  assert.equal(readFileSync(agents, 'utf8'), '# Changed\n');
  assert.notEqual(saved.body.data.etag, first.body.data.etag);
  const backups = readdirSync(join(api.stateDir, 'instruction-backups'));
  assert.equal(backups.length, 1);
  assert.equal(readFileSync(join(api.stateDir, 'instruction-backups', backups[0]), 'utf8'), '# Original\n');
  const stale = await api.request('/v1/instructions/agents', { method: 'PUT', token, body: { text: 'stale' }, headers: { 'if-match': first.body.data.etag } });
  assert.equal(stale.status, 412);
  assert.equal(readFileSync(agents, 'utf8'), '# Changed\n');
  assert.equal(readdirSync(join(api.stateDir, 'instruction-backups')).length, 1);
  const revision = saved.body.data.etag;
  const simultaneous = await Promise.all(['one', 'two'].map(text => api.request('/v1/instructions/agents', { method: 'PUT', token, body: { text }, headers: { 'if-match': revision } })));
  assert.deepEqual(simultaneous.map(result => result.status).sort(), [200, 412]);
  assert.equal((await api.request('/v1/instructions/claude', { token })).body.data.text, '# Claude\n');
});

test('instruction endpoint refuses symlinks', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'instruction-test-'));
  const target = join(dir, 'target'), link = join(dir, 'AGENTS.md');
  writeFileSync(target, 'untouched'); symlinkSync(target, link);
  const api = await startBridge({ instructions: { enabled: true, files: { agents: link, claude: target } } });
  t.after(async () => { await api.close(); rmSync(dir, { recursive: true, force: true }); });
  const token = await api.token(['instructions:read', 'instructions:write']);
  assert.equal((await api.request('/v1/instructions/agents', { token })).status, 503);
  assert.equal(readFileSync(target, 'utf8'), 'untouched');
});

test('instruction permission requires an explicit grant to a live device', async (t) => {
  const { grantInstructions } = await import('../src/pairing.mjs');
  const api = await startBridge({ instructions: { enabled: true } });
  t.after(() => api.close());
  const token = await api.token();
  const device = (await api.request('/v1/me', { token })).body.data;
  assert.equal((await api.request('/v1/instructions/agents', { token })).status, 403);
  assert.match(grantInstructions(api.store, { target: device.deviceId, reason: 'bad\nreason' }).error, /reason/);
  assert.equal(grantInstructions(api.store, { target: device.deviceId, reason: 'Owner requested' }).alreadyGranted, false);
  assert.equal(grantInstructions(api.store, { target: device.deviceId, reason: 'Owner requested' }).alreadyGranted, true);
  const updated = (await api.request('/v1/me', { token })).body.data;
  assert.ok(updated.scopes.includes('instructions:read'));
  assert.ok(updated.scopes.includes('instructions:write'));
  api.store.mutate(state => { state.devices[device.deviceId].revokedAt = new Date().toISOString(); });
  assert.match(grantInstructions(api.store, { target: device.deviceId, reason: 'Owner requested' }).error, /revoked/);
});


test('instruction endpoints are disabled by default even for authorized devices', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'instruction-disabled-'));
  const agents = join(dir, 'AGENTS.md');
  writeFileSync(agents, 'unchanged');
  const api = await startBridge({ instructions: { files: { agents, claude: agents } } });
  t.after(async () => { await api.close(); rmSync(dir, { recursive: true, force: true }); });
  const token = await api.token(['instructions:read', 'instructions:write']);
  assert.equal((await api.request('/v1/instructions/agents', { token })).status, 404);
  assert.equal((await api.request('/v1/instructions/agents', { method: 'PUT', token, body: { text: 'changed' }, headers: { 'if-match': 'anything' } })).status, 404);
  assert.equal(readFileSync(agents, 'utf8'), 'unchanged');
});

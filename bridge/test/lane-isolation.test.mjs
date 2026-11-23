import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync } from 'node:fs';
import { request as httpRequest } from 'node:http';
import { tmpdir, userInfo } from 'node:os';
import { dirname, join } from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { LANE_HEADER, productionStateDir } from '../src/lane/guard.mjs';
import { laneClient } from '../src/lane/client.mjs';
import { createDecisionStore } from '../src/decisions/store.mjs';
import { createStore } from '../src/store.mjs';
import { startBridge } from './helpers.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const main = join(here, '../src/main.mjs');
const cli = join(here, '../bin/laa-bridge');
const state = (root) => join(root, 'state');
const production = productionStateDir();
const id = 'lane-test-a';
const seed = { title: 'Synthetic decision', summary: 'No delivery off this Mac', options: [{ label: 'A' }, { label: 'B' }], requestId: 'seed' };

function layout(t) {
  const root = mkdtempSync(join(tmpdir(), 'laa-lane-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  for (const child of ['home', 'tmp', 'state', 'brain', 'sink']) mkdirSync(join(root, child), { mode: 0o700 });
  const env = { HOME: join(root, 'home'), TMPDIR: join(root, 'tmp'), PATH: `${dirname(process.execPath)}:/usr/bin:/bin`,
    LAA_LANE_ID: id, LAA_LANE_ROOT: root, LAA_BRIDGE_STATE_DIR: state(root), LAA_BRIDGE_PORT: '0', LAA_BRIDGE_BRAIN_ROOT: join(root, 'brain') };
  return { root, env };
}

function run(script, args, env) {
  return script === cli ? spawnSync(script, args, { env, timeout: 4000, encoding: 'utf8' })
    : spawnSync(process.execPath, [script, ...args], { env, timeout: 4000, encoding: 'utf8' });
}

for (const [edge, value] of [
  ['HOME', userInfo().homedir], ['TEMP escape via TMPDIR', userInfo().homedir],
  ['LAA_BRIDGE_STATE_DIR', production], ['LAA_BRIDGE_BRAIN_ROOT', join(userInfo().homedir, 'Brain')],
  ['LAA_BRIDGE_PORT', '9137'], ['LAA_BRIDGE_PASEO_BIN', '/usr/bin/false'],
  ['LAA_BRIDGE_WORK_CLIENT', '/tmp/router.mjs'], ['LAA_WORK_SOCKET', '/tmp/work.sock'],
  ['LAA_BRIDGE_BRAIN_SEARCH_BIN', '/usr/bin/false'], ['LAA_BRIDGE_BRAIN_SYNCTHING_URL', 'http://127.0.0.1:8384'],
  ['LAA_BRIDGE_USAGE_FEED_URL', 'http://127.0.0.1:8081/widget'], ['LAA_BRIDGE_STORAGE_STATUS', '/tmp/status.json'],
  ['LAA_BRIDGE_LINEAR_TOKEN_HELPER', '/usr/bin/false'], ['LAA_GOOGLE_REMINDERS_ENABLED', '1'],
  ['LAA_VOICE_WORKER', '/usr/bin/false'], ['LAA_CAMPAIGN_LEDGER', '/tmp/ledger.py'],
  ['LAA_BRIDGE_HERMES_SKILLS', '/tmp/hermes'], ['APNS_KEY_ID', 'synthetic'],
]) {
  const key = edge === 'TEMP escape via TMPDIR' ? 'TMPDIR' : edge;
  test(`a lane Bridge refuses ${edge} before opening state`, (t) => {
    const { root, env } = layout(t);
    const result = run(main, ['serve'], { ...env, [key]: value });
    assert.equal(result.status, 1, result.stderr);
    assert.match(result.stderr, /lane_config_unsafe/);
    assert.ok(result.stderr.includes(key), result.stderr);
    assert.equal(existsSync(join(state(root), 'state.json')), false);
    assert.equal(result.stdout.includes('listening'), false);
  });
}

test('the launcher refuses a scratch parent inside production before creating a lane', () => {
  const result = run(join(here, '../../scripts/laa/lab/lane.mjs'), ['up', '--json'], { ...process.env, LAA_LANE_PARENT: production });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /LAA_LANE_PARENT.*production/);
  assert.equal(result.stdout, '');
});

test('a lane cannot hide a path to host state behind a symlink', (t) => {
  const { root, env } = layout(t);
  const alias = join(root, 'alias');
  symlinkSync(userInfo().homedir, alias, 'dir');
  const result = run(main, ['serve'], { ...env, LAA_BRIDGE_BRAIN_ROOT: alias });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /LAA_BRIDGE_BRAIN_ROOT.*escapes/);
  symlinkSync(join(production, 'decisions.json'), join(state(root), 'decisions.json'));
  const fileEscape = run(main, ['serve'], env);
  assert.equal(fileEscape.status, 1);
  assert.match(fileEscape.stderr, /LAA_BRIDGE_STATE_DIR.*links/);
});

test('Node tests, CLI and fixtures refuse the default live state and a symlink alias', (t) => {
  const { root } = layout(t);
  assert.throws(() => createStore({ dir: production }), /LAA_BRIDGE_STATE_DIR.*production/);
  assert.throws(() => createDecisionStore({ dir: production }), /LAA_BRIDGE_STATE_DIR.*production/);
  const alias = join(root, 'alias');
  symlinkSync(userInfo().homedir, alias, 'dir');
  assert.throws(() => createStore({ dir: join(alias, '.local/state/laa-bridge') }), /LAA_BRIDGE_STATE_DIR.*production/);
  const env = { HOME: userInfo().homedir, TMPDIR: join(root, 'tmp'), PATH: `${dirname(process.execPath)}:/usr/bin:/bin`, NODE_TEST_CONTEXT: 'child-v8' };
  for (const args of [['devices', '--json'], ['decide', 'list', '--json'], ['habits', 'week', '--json']]) {
    const result = run(cli, args, env);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /LAA_BRIDGE_STATE_DIR.*production/);
  }
  const usage = run(join(here, '../../scripts/laa/usage-ui-fixture.mjs'), [], { ...env, LAA_USAGE_UI_REAL_STATE: production });
  assert.equal(usage.status, 1);
  assert.match(usage.stderr, /LAA_BRIDGE_STATE_DIR.*production/);
  const phone = run(join(here, '../../scripts/laa/phone-use-ui-fixture.mjs'), [production], env);
  assert.equal(phone.status, 1);
  assert.match(phone.stderr, /LAA_BRIDGE_STATE_DIR.*production/);
});

test('a production-mode Bridge drops lane-tagged decisions, before any body/Continue or store access', async (t) => {
  const notices = [];
  const h = await startBridge({ testEndpoints: false, decisions: { notify: async (value) => { notices.push(value); } } });
  t.after(h.close);
  const token = await h.token();
  const decision = createDecisionStore({ dir: h.stateDir }).add(seed).decision;
  const snapshot = () => ['decisions.json', 'state.json'].map((name) => readFileSync(join(h.stateDir, name)));
  const before = snapshot();
  const api = laneClient(h.base, id);
  await assert.rejects(() => api(`/v1/decisions/${decision.id}/answer`, {
    method: 'POST', headers: { authorization: `Bearer ${token}`, 'idempotency-key': 'test' }, body: '{"optionIndex":0}',
  }), { code: 'lane_mismatch', status: 421 });
  for (const stamp of [id, '']) {
    const refused = await h.request('/v1/decisions', { method: 'POST', headers: { [LANE_HEADER]: stamp }, token, body: 'not even JSON', key: 'test' });
    assert.equal(refused.status, 421);
    assert.equal(refused.headers.has(LANE_HEADER), false);
    assert.equal(refused.body.error.code, 'lane_mismatch');
  }
  await new Promise((ok, fail) => {
    const req = httpRequest(`${h.base}/v1/decisions`, { method: 'POST', headers: {
      [LANE_HEADER]: id, expect: '100-continue', 'content-length': '999',
    } }, (res) => { res.resume(); assert.equal(res.statusCode, 421); res.on('end', ok); });
    req.setTimeout(1500, () => req.destroy(new Error('header refusal waited for body')));
    req.on('continue', () => req.destroy(new Error('server accepted body before checking lane')));
    req.on('error', fail);
    req.flushHeaders();
  });
  assert.deepEqual(snapshot(), before);
  assert.deepEqual(notices, []);
});

async function startLane(t, env) {
  const proc = spawn(process.execPath, [main, 'serve'], { env, stdio: ['ignore', 'pipe', 'pipe'] });
  let stderr = '';
  proc.stderr.on('data', (chunk) => { stderr += chunk; });
  t.after(async () => {
    if (proc.exitCode !== null || proc.signalCode !== null) return;
    await new Promise((done) => { proc.once('exit', done); proc.kill('SIGTERM'); });
  });
  const port = await new Promise((ok, fail) => {
    proc.once('exit', (code) => fail(new Error(`lane exit ${code}: ${stderr}`)));
    createInterface({ input: proc.stdout }).on('line', (line) => {
      const item = JSON.parse(line);
      if (item.event === 'listening') ok(item.port);
    });
  });
  return `http://127.0.0.1:${port}`;
}

test('lane matches only its own stamp and every removed outbound route refuses', async (t) => {
  const { root, env } = layout(t);
  const base = await startLane(t, env);
  for (const headers of [{}, { [LANE_HEADER]: 'some-other-lane' }]) {
    const response = await fetch(`${base}/v1/health`, { headers });
    assert.equal(response.status, 421);
    assert.equal(response.headers.get(LANE_HEADER), id);
    assert.equal((await response.json()).error.code, 'lane_mismatch');
  }
  const call = laneClient(base, id);
  assert.equal((await (await call('/v1/health')).json()).data.lane, id);
  for (const path of ['/v1/drive/files', '/v1/calendar/events', '/v1/tasks', '/v1/linear-owner-tasks', '/v1/personal-tasks',
    '/v1/voice/transcribe', '/v1/usage', '/v1/mac/status', '/v1/brain/search', '/v1/brain/files', '/v1/brain/gates',
    '/v1/campaigns', '/v1/routines', '/v1/studio/catalog', '/v1/instructions']) {
    const response = await call(path);
    assert.equal(response.status, 503, path);
    assert.equal((await response.json()).error.code, 'lane_adapter_missing', path);
  }
  const { stdout: pairing, status } = run(cli, ['pair', '--json'], env);
  assert.equal(status, 0);
  const { data: auth } = await (await call('/v1/devices/enroll', { method: 'POST', body: JSON.stringify({ code: JSON.parse(pairing).code, name: 'test-runner' }) })).json();
  const headers = { authorization: `Bearer ${auth.token}` };
  createDecisionStore({ dir: state(root) }).add(seed);
  assert.equal((await (await call('/v1/decisions', { headers })).json()).data.items.length, 1);
  const sink = readFileSync(join(root, 'sink/notify.jsonl'), 'utf8').trim();
  assert.equal(JSON.parse(sink).kind, 'decision.new');
  assert.equal(existsSync(join(root, 'sink/apns.jsonl')), false);
  assert.equal((await (await call('/v1/workspaces', { headers })).json()).data.items.length, 0);
  const refusal = await call('/v1/sessions', { method: 'POST', headers: { ...headers, 'idempotency-key': 'q' },
    body: JSON.stringify({ requestId: 'q', prompt: 'test', profile: 'lab-echo' }) });
  assert.equal((await refusal.json()).error.code, 'lane_adapter_missing');
});

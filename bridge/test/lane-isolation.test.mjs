import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
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
const timeoutMs = 90_000;
const seed = { title: 'Synthetic decision', summary: 'No delivery off this Mac', impact: '【必ず社長：選択】', options: [{ label: 'A' }, { label: 'B' }], requestId: 'seed' };

function layout(t, beforeRemove = () => {}) {
  const root = mkdtempSync(join(tmpdir(), 'laa-lane-'));
  t.after(async () => {
    try { await beforeRemove(); }
    finally { rmSync(root, { recursive: true, force: true }); }
  });
  // Leave state absent so a negative test catches even an empty mkdir, not
  // just a write to state.json.
  for (const child of ['home', 'tmp', 'brain', 'sink']) mkdirSync(join(root, child), { mode: 0o700 });
  const env = { HOME: join(root, 'home'), TMPDIR: join(root, 'tmp'), PATH: `${dirname(process.execPath)}:/usr/bin:/bin`,
    LAA_LANE_ID: id, LAA_LANE_ROOT: root, LAA_BRIDGE_STATE_DIR: state(root), LAA_BRIDGE_PORT: '0', LAA_BRIDGE_BRAIN_ROOT: join(root, 'brain') };
  return { root, env };
}

function run(script, args, env) {
  const options = { env, timeout: timeoutMs, killSignal: 'SIGKILL', encoding: 'utf8' };
  const result = script === cli ? spawnSync(script, args, options)
    : spawnSync(process.execPath, [script, ...args], options);
  assert.ifError(result.error);
  assert.equal(result.signal, null, `${script} must exit normally`);
  return result;
}

function assertStartupRefusal(result, key, target) {
  assert.equal(result.status, 1, result.stderr);
  const fatal = JSON.parse(result.stderr.trim());
  assert.equal(fatal.event, 'fatal');
  assert.equal(fatal.code, 'lane_config_unsafe');
  assert.ok(fatal.message.startsWith(`${key}:`), fatal.message);
  assert.equal(existsSync(target), false, 'Bridge created a state directory before refusing');
  assert.equal(result.stdout, '');
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
    assertStartupRefusal(result, key, state(root));
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
  assertStartupRefusal(result, 'LAA_BRIDGE_BRAIN_ROOT', state(root));
  assert.match(result.stderr, /escapes/);
  mkdirSync(state(root), { mode: 0o700 });
  symlinkSync(join(production, 'decisions.json'), join(state(root), 'decisions.json'));
  const fileEscape = run(main, ['serve'], env);
  assert.equal(fileEscape.status, 1);
  assert.match(fileEscape.stderr, /LAA_BRIDGE_STATE_DIR.*links/);
  assert.equal(existsSync(join(state(root), 'state.json')), false);
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
  const usage = run(join(here, '../../scripts/laa/usage-ui-fixture.mjs'), [], { ...env, LAA_BRIDGE_STATE_DIR: production });
  assert.equal(usage.status, 1);
  assert.match(usage.stderr, /LAA_BRIDGE_STATE_DIR.*production/);
  const phone = run(join(here, '../../scripts/laa/phone-use-ui-fixture.mjs'), [production], env);
  assert.equal(phone.status, 1);
  assert.match(phone.stderr, /LAA_BRIDGE_STATE_DIR.*production/);
});

test('the CLI delivers a proxy response through the lane Work adapter only once', (t) => {
  const { root, env } = layout(t);
  const client = join(root, 'runtime/client');
  mkdirSync(client, { recursive: true, mode: 0o700 });
  const sink = join(root, 'sink', 'work.jsonl');
  env.LAA_WORK_SOCKET = join(realpathSync(root), 'w.sock');
  writeFileSync(join(client, 'engine-client.mjs'), `
    import { appendFileSync } from 'node:fs';
    export async function connectEngine({ socket }) {
      if (socket !== ${JSON.stringify(env.LAA_WORK_SOCKET)}) throw Error('unexpected socket');
      let sent = false;
      return {
        fetchAgent: async ({ agentId }) => ({ agent: { id: agentId, status: sent ? 'running' : 'idle',
          updatedAt: new Date().toISOString(), ...(sent ? { activeTurn: { id: 'turn-1' } } : {}) } }),
        fetchWorkspaces: async () => ({ entries: [] }),
        sendMessage: async (agentId, text, options) => {
          sent = true;
          appendFileSync(${JSON.stringify(sink)}, JSON.stringify({ agentId, text, ...options }) + '\\n');
        },
        close: async () => {},
      };
    }`);
  const decision = createDecisionStore({ dir: state(root) }).add({ ...seed, impact: '【任せられる】', source: { paseoAgentId: 'test-agent' } }).decision;
  const args = ['decide', 'answer', decision.id, '--option', '2', '--by', 'monet', '--reason', 'テスト', '--json'];
  const first = run(cli, args, env);
  assert.equal(first.status, 0, first.stderr);
  const delivery = JSON.parse(first.stdout).decision.delivery;
  assert.equal(delivery.state, 'delivered', delivery.error);
  const replay = run(cli, args, env);
  assert.equal(replay.status, 0, replay.stderr);
  assert.equal(JSON.parse(replay.stdout).replayed, true);
  const events = readFileSync(sink, 'utf8').trim().split('\n').map(JSON.parse);
  assert.equal(events.length, 1);
  assert.equal(events[0].agentId, 'test-agent');
  assert.equal(events[0].messageId, `${decision.id}:answer:1`);
  assert.match(events[0].text, /選択: B/);
});

test('a production-mode Bridge drops lane-tagged decisions, before any body/Continue or store access', async (t) => {
  const notices = [];
  const h = await startBridge({ testEndpoints: false, decisions: { notify: async (value) => { notices.push(value); } } });
  t.after(h.close);
  const token = await h.token();
  const decision = createDecisionStore({ dir: h.stateDir }).add(seed).decision;
  const snapshot = () => ['decisions.json', 'state.json'].map((name) => readFileSync(join(h.stateDir, name)));
  const before = snapshot();
  const api = laneClient(h.base, id, { timeoutMs });
  await assert.rejects(() => api(`/v1/decisions/${decision.id}/answer`, {
    method: 'POST', headers: { authorization: `Bearer ${token}`, 'idempotency-key': 'test' }, body: '{"optionIndex":0}',
  }), { code: 'lane_mismatch', status: 421 });
  for (const path of ['/v1/decisions', '/v1/sessions/ses_0000000000000000/messages']) {
    for (const stamp of [id, '']) {
      const refused = await h.request(path, { method: 'POST', headers: { [LANE_HEADER]: stamp }, token, body: 'not even JSON', key: 'test' });
      assert.equal(refused.status, 421);
      assert.equal(refused.headers.has(LANE_HEADER), false);
      assert.equal(refused.body.error.code, 'lane_mismatch');
    }
  }
  const status = await new Promise((ok, fail) => {
    const req = httpRequest(`${h.base}/v1/decisions`, { method: 'POST', headers: {
      [LANE_HEADER]: id, expect: '100-continue', 'content-length': '999',
    } }, (res) => {
      res.on('error', fail);
      res.on('end', () => ok(res.statusCode));
      res.resume();
    });
    req.setTimeout(timeoutMs, () => req.destroy(new Error('server did not refuse while the client withheld the body')));
    req.on('continue', () => req.destroy(new Error('server accepted body before checking lane')));
    req.on('error', fail);
    req.flushHeaders();
  });
  assert.equal(status, 421);
  assert.deepEqual(snapshot(), before);
  assert.deepEqual(notices, []);
});

async function startLane(t) {
  let stop = () => {};
  const { root, env } = layout(t, () => stop());
  const proc = spawn(process.execPath, [main, 'serve'], { env, stdio: ['ignore', 'pipe', 'pipe'] });
  const closed = new Promise((ok) => proc.once('close', ok));
  stop = async () => {
    if (proc.exitCode !== null || proc.signalCode !== null) return closed;
    const watchdog = setTimeout(() => proc.kill('SIGKILL'), timeoutMs);
    try { proc.kill('SIGTERM'); await closed; }
    finally { clearTimeout(watchdog); }
  };
  let stderr = '';
  proc.stderr.on('data', (chunk) => { stderr += chunk; });
  const lines = createInterface({ input: proc.stdout });
  let watchdog;
  const port = await new Promise((ok, fail) => {
    watchdog = setTimeout(() => fail(new Error(`lane never reported listening: ${stderr}`)), timeoutMs);
    proc.once('error', fail);
    proc.once('close', (code, signal) => fail(new Error(`lane exit ${code ?? signal}: ${stderr}`)));
    lines.on('line', (line) => {
      try {
        const item = JSON.parse(line);
        if (item.event === 'listening') ok(item.port);
      } catch (error) { fail(error); }
    });
  }).finally(() => { clearTimeout(watchdog); lines.close(); proc.stdout.resume(); });
  return { root, env, base: `http://127.0.0.1:${port}` };
}

test('lane matches only its own stamp and every removed outbound route refuses', async (t) => {
  const { root, env, base } = await startLane(t);
  for (const headers of [{}, { [LANE_HEADER]: 'some-other-lane' }]) {
    const response = await fetch(`${base}/v1/health`, { headers, signal: AbortSignal.timeout(timeoutMs) });
    assert.equal(response.status, 421);
    assert.equal(response.headers.get(LANE_HEADER), id);
    assert.equal((await response.json()).error.code, 'lane_mismatch');
  }
  const call = laneClient(base, id, { timeoutMs });
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

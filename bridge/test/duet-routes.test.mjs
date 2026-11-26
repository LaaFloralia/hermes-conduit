import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { laneClient } from '../src/lane/client.mjs';

async function labBridge(t) {
  const root = mkdtempSync(join(tmpdir(), 'laa-lane-'));
  const id = `duet-${randomUUID()}`;
  for (const name of ['home', 'tmp', 'brain', 'sink']) mkdirSync(join(root, name), { mode: 0o700 });
  const env = { HOME: join(root, 'home'), TMPDIR: join(root, 'tmp'), PATH: `${dirname(process.execPath)}:/usr/bin:/bin`,
    LAA_LANE_ROOT: root, LAA_LANE_ID: id, LAA_BRIDGE_STATE_DIR: join(root, 'state'), LAA_BRIDGE_PORT: '0', LAA_BRIDGE_BRAIN_ROOT: join(root, 'brain') };
  const child = spawn(process.execPath, [fileURLToPath(new URL('../src/main.mjs', import.meta.url))], { env, stdio: ['ignore', 'pipe', 'pipe'] });
  const closed = new Promise((resolve) => child.once('close', resolve));
  t.after(async () => {
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
    const watchdog = setTimeout(() => child.kill('SIGKILL'), 10_000);
    try { await closed; } finally { clearTimeout(watchdog); rmSync(root, { recursive: true, force: true }); }
  });
  let stderr = '';
  child.stderr.setEncoding('utf8').on('data', (text) => { stderr += text; });
  const lines = createInterface({ input: child.stdout });
  let watchdog;
  const port = await new Promise((resolve, reject) => {
    watchdog = setTimeout(() => reject(new Error(`Bridge lane did not start: ${stderr}`)), 15_000);
    child.once('error', reject);
    child.once('exit', () => reject(new Error(`Bridge lane exited: ${stderr}`)));
    lines.on('line', (line) => {
      try { const event = JSON.parse(line); if (event.event === 'listening') resolve(event.port); } catch (error) { reject(error); }
    });
  }).finally(() => { clearTimeout(watchdog); lines.close(); child.stdout.resume(); });
  const call = laneClient(`http://127.0.0.1:${port}`, id);
  const proof = await call('/v1/health');
  assert.equal((await proof.json()).data.lane, id);
  return {
    call, root,
    async token(scopes) {
      const cli = fileURLToPath(new URL('../bin/laa-bridge', import.meta.url));
      const created = spawnSync(cli, ['pair', '--json', '--scopes', scopes], { env, encoding: 'utf8', timeout: 10_000 });
      assert.equal(created.status, 0, created.stderr);
      const { code } = JSON.parse(created.stdout);
      const response = await call('/v1/devices/enroll', { method: 'POST', body: JSON.stringify({ code, name: 'Duet test device' }) });
      assert.equal(response.status, 201);
      return (await response.json()).data.token;
    },
  };
}

const items = '/v1/duet/items';
const notes = '/v1/duet/notes';
const auth = (token) => ({ Authorization: `Bearer ${token}` });
const post = (token, text, key, other = {}) => ({ method: 'POST', headers: { ...auth(token), 'Content-Type': 'application/json',
  ...(key ? { 'Idempotency-Key': key } : {}) }, body: JSON.stringify({ text, ...other }) });

test('Duet HTTP routes use device auth and scopes; lab remains offline; note writes are bounded and idempotent', async (t) => {
  const { call, root, token } = await labBridge(t);
  const [reader, writer, other] = await Promise.all([token('sessions:read'), token('sessions:write'), token('tasks:read')]);
  assert.equal((await call(items)).status, 401);
  assert.equal((await call(items, { headers: auth('wrong') })).status, 401);
  assert.equal((await call(items, { headers: auth(other) })).status, 403);
  assert.equal((await call(notes, { headers: auth(writer) })).status, 403);
  assert.equal((await call(notes, post(reader, 'no write', 'test-forbidden'))).status, 403);
  assert.equal((await call(notes, post(writer, 'no key'))).status, 400);
  const unconfigured = await call(`${items}?limit=1`, { headers: auth(reader) });
  assert.deepEqual((await unconfigured.json()).data, { items: [], status: { configured: false, lastPullAt: null, lastError: 'not_configured' } });
  for (const limit of ['201', 'abc', '0', '1e2']) assert.equal((await call(`${items}?limit=${limit}`, { headers: auth(reader) })).status, 400);
  for (const [text, otherFields] of [[null], ['🌷'.repeat(2001)], ['fine', { link: 'unexpected' }]]) {
    const result = await call(notes, post(writer, text, 'invalid-then-reuse', otherFields));
    assert.equal(result.status, 400);
    assert.equal((await result.json()).error.code, 'duet_note_invalid');
  }
  const text = '<img> **plain** ' + '🌷'.repeat(1984);
  const saved = await call(notes, post(writer, text, 'invalid-then-reuse'));
  assert.equal(saved.status, 201);
  const { id, state } = (await saved.json()).data;
  assert.match(id, /^[a-f0-9-]{36}$/);
  assert.equal(state, 'queued');
  const replay = await call(notes, post(writer, text, 'invalid-then-reuse'));
  assert.equal(replay.headers.get('idempotency-replayed'), 'true');
  assert.deepEqual((await replay.json()).data, { id, state });
  assert.equal((await call(notes, post(writer, 'different body', 'invalid-then-reuse'))).status, 409);
  const { data } = await (await call(notes, { headers: auth(reader) })).json();
  assert.equal(data.length, 1);
  assert.deepEqual(data[0], { id, state, text, createdAt: data[0].createdAt });
  assert.equal(existsSync(join(root, 'sink', 'notify.jsonl')), false);
});

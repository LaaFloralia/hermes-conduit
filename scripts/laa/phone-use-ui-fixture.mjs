// A throwaway Bridge and control port for phone-use tests. APNs is recorded
// locally; this fixture must never load signing credentials or send a push.
// node scripts/laa/phone-use-ui-fixture.mjs <state dir> [port]
//
// Control (port + 1): GET /code (a fresh pairing code), /registered,
// /ask?timeout=<s>, /status?id=, /end?id=.
import { spawn } from 'node:child_process';
import { appendFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { createLaneFixtureServer, listenLaneFixture, reportFixturePort } from '../../bridge/src/lane/fixture.mjs';
import { assertTestStateDir, laneEnabled, PRODUCTION_PORTS, validateLane } from '../../bridge/src/lane/guard.mjs';
import { laneRecorder } from '../../bridge/src/lane/adapters.mjs';
import { DEFAULT_SCOPES, IDEMPOTENCY_RETENTION_MS, resolvePort } from '../../bridge/src/config.mjs';
import { createStore } from '../../bridge/src/store.mjs';
import { createBridge } from '../../bridge/src/http.mjs';
import { issuePairing } from '../../bridge/src/pairing.mjs';
import { createPhoneUse } from '../../bridge/src/phone-use/service.mjs';

const [dir, portText = '19593'] = process.argv.slice(2);
if (!dir) { process.stderr.write('usage: phone-use-ui-fixture.mjs <state dir> [port]\n'); process.exit(2); }
const port = laneEnabled() ? resolvePort() : Number(portText);
if (!laneEnabled() && (PRODUCTION_PORTS.includes(port) || PRODUCTION_PORTS.includes(port + 1))) {
  throw new Error('fixture refuses production ports');
}
assertTestStateDir(dir, { ...process.env, NODE_TEST_CONTEXT: 'ui-fixture' });
const lane = validateLane(process.env, { stateDir: dir, port });
mkdirSync(dir, { recursive: true, mode: 0o700 });
const store = createStore({ dir, idempotencyRetentionMs: IDEMPOTENCY_RETENTION_MS });
const record = lane ? laneRecorder(lane, 'apns') : ({ kind }) => appendFileSync(join(dir, 'apns.jsonl'), `${JSON.stringify({ kind })}\n`, { mode: 0o600 });
const testSimulator = 'DFFD3966-F54E-4C7A-A161-59201C7EA105'; // LAA 16 Pro Max only
let simulator;
const push = async ({ kind, payload }) => {
  record({ kind });
  if (!simulator) return { sent: true }; // recorder-only node smoke
  // simctl supports application pushes only, not the APNs liveactivity push
  // type or topic. Preserve the service's payload inside a local app push.
  // iOS 27's simulator rejects content-available alone (UNError 1401).
  // The foreground lab delegate consumes this transport alert without a banner.
  const body = { aps: { 'content-available': 1, alert: { title: 'Lab Phone Use', body: 'Simulator fixture' } },
    laa_lab_lane: lane.id, laa_lab_phone_use: payload };
  // Use a regular .apns file, not Node's socket-backed child stdin. Keep the
  // temporary payload out of logs and remove it even on a simctl refusal.
  const scratch = mkdtempSync(join(dir, 'local-push-'));
  try {
    const file = join(scratch, 'payload.apns');
    writeFileSync(file, JSON.stringify(body), { mode: 0o600 });
    await new Promise((resolve, reject) => {
      const proc = spawn('/usr/bin/xcrun', ['simctl', 'push', simulator, 'com.laa-inc.laa', file], {
        stdio: ['ignore', 'ignore', 'pipe'], signal: AbortSignal.timeout(15_000),
      });
      let stderr = '';
      proc.stderr.setEncoding('utf8').on('data', (text) => { stderr = (stderr + text).slice(-640); });
      proc.once('error', reject);
      proc.once('close', (status, signal) => {
        if (status === 0) return resolve();
        const reason = `simctl push exit ${status ?? signal}: ${stderr.trim()}`;
        process.stderr.write(`${reason}\n`);
        reject(new Error(reason));
      });
    });
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
  return { sent: true };
};
const phoneUse = createPhoneUse({ dir, push, devices: (id) => store.read().devices?.[id] ?? null });
const bridge = createBridge({ store, drive: null, routeOptions: {
  workspaces: { roots: [dir] },
  usage: { capacitySource: { read: () => [], close() {} } },
  routines: { read: async () => ({ data: [] }) },
  phoneUse: { service: phoneUse },
} });
const apiAddress = await bridge.listen({ port, host: '127.0.0.1' });
reportFixturePort('phone-use', apiAddress.port);

const send = (res, status, body) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };
const control = createLaneFixtureServer(async (req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  try {
    if (url.pathname === '/code') return send(res, 200, { code: issuePairing(store, { name: 'LAA phone-use UI test', scopes: DEFAULT_SCOPES, ttlMs: 600_000 }).code });
    if (url.pathname === '/registered') {
      let token = null;
      try { token = JSON.parse(readFileSync(phoneUse.file, 'utf8')).startToken; } catch {}
      return send(res, 200, { registered: Boolean(token), wake: Boolean(token?.wakeToken), environment: token?.environment ?? null });
    }
    if (url.pathname === '/reset-start' && lane) return send(res, 200, phoneUse.reset());
    if (url.pathname === '/ask') {
      const destination = url.searchParams.get('simulator');
      if (destination !== null) {
        if (!lane || destination.toUpperCase() !== testSimulator) return send(res, 400, { error: 'invalid_test_simulator' });
        simulator = testSimulator;
      }
      const asked = await phoneUse.ask({ who: 'iPhone Use｜UIテスト', purpose: 'LAAアプリの表示を確認',
        timeoutMs: Number(url.searchParams.get('timeout') ?? 60) * 1000 });
      if (asked.ok) phoneUse.waitForAnswer(asked.request.id).catch(() => {});
      return send(res, asked.ok ? 200 : 409, asked);
    }
    if (url.pathname === '/status') return send(res, 200, phoneUse.status(url.searchParams.get('id')));
    if (url.pathname === '/end') return send(res, 200, await phoneUse.end(url.searchParams.get('id')));
    send(res, 404, { error: 'not_found' });
  } catch (e) { send(res, 500, { error: e?.code ?? 'failed', message: String(e?.message ?? e).slice(0, 200) }); }
});
listenLaneFixture(control, 'phone-use-control', port + 1, () => {
  process.stdout.write(`phone-use fixture on ${apiAddress.port}, control ${control.address().port}\n`);
});
process.on('SIGTERM', async () => { await bridge.close(); process.exit(0); });

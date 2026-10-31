// Local-only fixture for LAAUsageUITests. It never logs pairing codes or tokens.
// Start an isolated Bridge on port 19491 with an empty LAA_BRIDGE_STATE_DIR,
// and start this helper with LAA_USAGE_UI_REAL_STATE set to that same directory.
// Use an ad-hoc-signed LAA_BUILD simulator; the real-cache test also needs a
// successful usage-feed cache. Revoke the test device and purge the test state.
import { createServer } from 'node:http';
import { execFile } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { promisify } from 'node:util';

const exec = promisify(execFile);
const fixtureRoot = new URL('../../docs/laa/fixtures/usage/', import.meta.url);
const cli = new URL('../../bridge/bin/laa-bridge', import.meta.url).pathname;
const stateDir = process.env.LAA_USAGE_UI_REAL_STATE;
let mode = 'normal';
let usageRequests = 0;
const send = (res, status, body) => {
  res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
  res.end(JSON.stringify(body));
};
const readFixture = async (name) => JSON.parse(await readFile(new URL(name, fixtureRoot), 'utf8'));

createServer(async (req, res) => {
  try {
    if (req.method === 'POST' && req.url === '/v1/devices/enroll') {
      req.resume();
      send(res, 201, { data: { deviceId: 'dev_fixture', token: 'fixture-token', scopes: ['usage:read'] }, requestId: 'fixture' });
      return;
    }
    if (!['/v1/usage', '/v1/mac/status'].includes(req.url)) { send(res, 404, {}); return; }
    if (req.url === '/v1/usage') usageRequests++;
    if (req.headers.authorization !== 'Bearer fixture-token') { send(res, 401, {}); return; }
    if (mode === 'offline') { req.socket.destroy(); return; }
    if (mode === 'error') {
      send(res, 503, { error: { code: 'unavailable', message: 'unavailable', retryable: true }, requestId: 'fixture' });
      return;
    }
    if (mode === 'slow') await new Promise(resolve => setTimeout(resolve, 3000));
    const name = req.url === '/v1/usage' ? 'usage-normal.json' : 'mac-status-normal.json';
    const body = await readFixture(name);
    if (req.url === '/v1/usage') {
      for (const quota of body.data.items.filter(item => item.kind === 'quota' && item.detail?.windows)) {
        const observed = Date.now() - (mode === 'stale' ? 30 * 60_000 : 60_000);
        quota.observedAt = new Date(observed).toISOString();
        quota.stale = mode === 'stale';
        quota.detail.freshUntil = new Date(observed + 20 * 60_000).toISOString();
        for (const window of quota.detail.windows) window.resetsAt = new Date(Date.now() + 3_600_000).toISOString();
        quota.expired = false;
      }
      const liquid = body.data.items.find(item => item.id === 'provider.liquid.usage');
      if (liquid) { liquid.detail.recordedCostUsd = 1.31; liquid.detail.recordedRequestCount = 6473; }
    }
    if (mode === 'empty') body.data.items = [];
    if (mode === 'degraded' && req.url === '/v1/usage') {
      const first = body.data.items[0];
      first.availability = 'unavailable'; first.nullReason = 'fetch_failed'; first.value = null;
      first.observedAt = null; delete first.detail;
    }
    send(res, 200, body);
  } catch { send(res, 500, {}); }
}).listen(19492, '127.0.0.1');

createServer(async (req, res) => {
  try {
    if (req.url === '/health') { res.end('ok'); return; }
    if (req.url === '/fixture-code') { res.end('TEST-TEST'); return; }
    if (req.url === '/counts') { res.end(String(usageRequests)); return; }
    if (req.url?.startsWith('/mode/')) {
      const next = req.url.slice('/mode/'.length);
      if (!['normal', 'degraded', 'error', 'offline', 'empty', 'slow', 'stale'].includes(next)) { send(res, 404, {}); return; }
      mode = next; res.end('ok'); return;
    }
    // The real server and its state are explicitly isolated by the test runner.
    if (!stateDir) { send(res, 404, {}); return; }
    const env = { ...process.env, LAA_BRIDGE_STATE_DIR: stateDir };
    if (req.url === '/real-code') {
      const before = await exec(cli, ['devices', '--json'], { env });
      if (JSON.parse(before.stdout).some(device => device.status === 'active')) {
        throw new Error('the isolated test state must have no active devices');
      }
      const { stdout } = await exec(cli, ['pair', '--name', 'LAA Usage v2 simulator', '--scopes', 'usage:read', '--json'], { env });
      const result = JSON.parse(stdout);
      res.writeHead(200, { 'cache-control': 'no-store' }); res.end(result.code); return;
    }
    if (req.url === '/revoke') {
      const { stdout } = await exec(cli, ['devices', '--json'], { env });
      const devices = JSON.parse(stdout).filter(d => d.status === 'active');
      if (devices.length !== 1) throw new Error('expected exactly one active test device');
      await exec(cli, ['revoke', devices[0].id, '--reason', 'simulator test'], { env });
      res.end('ok'); return;
    }
    send(res, 404, {});
  } catch { send(res, 500, {}); }
}).listen(19493, '127.0.0.1');

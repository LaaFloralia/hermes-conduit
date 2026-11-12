// A throwaway Bridge for LAAPhoneUseUITests: the real Bridge routes on a
// private state directory (no Work daemon, no Linear), plus a control port
// for the test. Run under 1Password with the LAA APNs key so the asks reach
// the simulator through the APNs sandbox:
//
//   /Users/laa/.config/laa/op-run-batch.sh ~/.config/laa/conduit-relay-laa.env.tpl \
//     node scripts/laa/phone-use-ui-fixture.mjs <state dir> [port]
//
// Control (port + 1): GET /code (a fresh pairing code), /registered,
// /ask?timeout=<s>, /status?id=, /end?id=.
import http from 'node:http';
import { mkdirSync, readFileSync } from 'node:fs';
import { DEFAULT_SCOPES, IDEMPOTENCY_RETENTION_MS } from '../../bridge/src/config.mjs';
import { createStore } from '../../bridge/src/store.mjs';
import { createBridge } from '../../bridge/src/http.mjs';
import { issuePairing } from '../../bridge/src/pairing.mjs';
import { createPhoneUse } from '../../bridge/src/phone-use/service.mjs';
import { apnsSenderFromEnv } from '../../bridge/src/phone-use/apns.mjs';

const [dir, portText = '19593'] = process.argv.slice(2);
if (!dir) { process.stderr.write('usage: phone-use-ui-fixture.mjs <state dir> [port]\n'); process.exit(2); }
const port = Number(portText);
mkdirSync(dir, { recursive: true, mode: 0o700 });
const store = createStore({ dir, idempotencyRetentionMs: IDEMPOTENCY_RETENTION_MS });
const push = apnsSenderFromEnv();
if (!push) process.stderr.write('phone-use fixture: no APNs key in the environment; asks will fail\n');
const phoneUse = createPhoneUse({ dir, push, devices: (id) => store.read().devices?.[id] ?? null });
const bridge = createBridge({ store, routeOptions: {
  workspaces: { roots: [dir] },
  usage: { capacitySource: { read: () => [], close() {} } },
  routines: { read: async () => ({ data: [] }) },
  phoneUse: { service: phoneUse },
} });
await bridge.listen({ port, host: '127.0.0.1' });

const send = (res, status, body) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };
http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  try {
    if (url.pathname === '/code') return send(res, 200, { code: issuePairing(store, { name: 'LAA phone-use UI test', scopes: DEFAULT_SCOPES, ttlMs: 600_000 }).code });
    if (url.pathname === '/registered') {
      let token = null;
      try { token = JSON.parse(readFileSync(phoneUse.file, 'utf8')).startToken; } catch {}
      return send(res, 200, { registered: Boolean(token), environment: token?.environment ?? null });
    }
    if (url.pathname === '/ask') {
      const asked = await phoneUse.ask({ who: 'iPhone Use｜UIテスト', purpose: 'LAAアプリの表示を確認',
        timeoutMs: Number(url.searchParams.get('timeout') ?? 60) * 1000 });
      if (asked.ok) phoneUse.waitForAnswer(asked.request.id).catch(() => {});
      return send(res, asked.ok ? 200 : 409, asked);
    }
    if (url.pathname === '/status') return send(res, 200, phoneUse.status(url.searchParams.get('id')));
    if (url.pathname === '/end') return send(res, 200, await phoneUse.end(url.searchParams.get('id')));
    send(res, 404, { error: 'not_found' });
  } catch (e) { send(res, 500, { error: e?.code ?? 'failed', message: String(e?.message ?? e).slice(0, 200) }); }
}).listen(port + 1, '127.0.0.1');
process.stdout.write(`phone-use fixture on ${port}, control ${port + 1}\n`);
process.on('SIGTERM', async () => { await bridge.close(); process.exit(0); });

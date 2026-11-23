// Controls only; usage responses and enrollment go through the authenticated lane Bridge.
import { readFileSync, writeFileSync } from 'node:fs';
import { createLaneFixtureServer, listenLaneFixture } from '../../bridge/src/lane/fixture.mjs';
import { assertTestStateDir, validateLane } from '../../bridge/src/lane/guard.mjs';
import { usageCountPath, usageModePath, usageModes } from '../../bridge/src/lane/usage.mjs';
import { createStore } from '../../bridge/src/store.mjs';
import { issuePairing } from '../../bridge/src/pairing.mjs';
import { IDEMPOTENCY_RETENTION_MS } from '../../bridge/src/config.mjs';

const dir = process.env.LAA_BRIDGE_STATE_DIR;
if (dir) assertTestStateDir(dir, { ...process.env, NODE_TEST_CONTEXT: 'ui-fixture' });
if (!validateLane(process.env, { stateDir: dir, port: 0 })) throw new Error('Start with lane.mjs up --fixture usage');
const store = createStore({ dir, idempotencyRetentionMs: IDEMPOTENCY_RETENTION_MS });
const control = createLaneFixtureServer((req, res) => {
  const path = new URL(req.url, 'http://127.0.0.1').pathname;
  if (path === '/health') return res.end('ok');
  if (path === '/fixture-code') {
    res.setHeader('cache-control', 'no-store');
    return res.end(issuePairing(store, { name: 'Usage simulator', scopes: ['usage:read'], ttlMs: 600_000 }).code);
  }
  if (path === '/counts') {
    try { return res.end(readFileSync(usageCountPath(dir))); }
    catch (error) { if (error.code === 'ENOENT') return res.end('0'); throw error; }
  }
  const mode = path.startsWith('/mode/') && path.slice('/mode/'.length);
  if (usageModes.includes(mode)) {
    writeFileSync(usageModePath(dir), mode, { mode: 0o600 });
    return res.end('ok');
  }
  res.writeHead(404).end();
});
listenLaneFixture(control, 'usage-control', 0);

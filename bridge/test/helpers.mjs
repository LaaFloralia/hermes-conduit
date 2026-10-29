// Shared test harness: a real HTTP server on an ephemeral loopback port with a
// throwaway state directory, so tests exercise the same code path as launchd.
//
// Workspace roots default to an empty directory inside the throwaway state, so
// a test run never scans the developer's real ~/dev or ~/.paseo.

import { mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DEFAULT_SCOPES, IDEMPOTENCY_RETENTION_MS, PAIRING_TTL_MS } from '../src/config.mjs';
import { createStore } from '../src/store.mjs';
import { createBridge } from '../src/http.mjs';
import { issuePairing } from '../src/pairing.mjs';

export async function startBridge({ now, testEndpoints = true, drive = null, workspace, projects = null, tasks = null, sessions = null, brain = null, usage = null } = {}) {
  const clock = now ?? (() => Date.now());
  const dir = mkdtempSync(join(tmpdir(), 'laa-bridge-test-'));
  const stateDir = join(dir, 'state');
  const store = createStore({ dir: stateDir, idempotencyRetentionMs: IDEMPOTENCY_RETENTION_MS, now: clock });

  const workspaceRoots = workspace?.roots ?? [join(dir, 'workspaces')];
  for (const root of workspaceRoots) mkdirSync(root, { recursive: true });
  const routeOptions = {
    workspaces: { ...(workspace ?? {}), roots: workspaceRoots },
    ...(projects ? { projects } : {}),
    ...(tasks ? { tasks } : {}),
    ...(sessions ? { sessions } : {}),
    ...(brain ? { brain } : {}),
    ...(usage ? { usage } : {}),
  };

  let bridge = createBridge({ store, testEndpoints, drive, now: clock, log: null, routeOptions });
  let address = await bridge.listen({ port: 0, host: '127.0.0.1' });

  async function request(path, { method = 'GET', body, token, key, headers = {} } = {}) {
    const finalHeaders = { ...headers };
    if (body !== undefined) finalHeaders['content-type'] = 'application/json';
    if (token) finalHeaders.authorization = `Bearer ${token}`;
    if (key) finalHeaders['idempotency-key'] = key;
    const response = await fetch(`http://127.0.0.1:${address.port}${path}`, {
      method,
      headers: finalHeaders,
      body: body === undefined ? undefined : (typeof body === 'string' ? body : JSON.stringify(body)),
    });
    const text = await response.text();
    return { status: response.status, headers: response.headers, body: text === '' ? null : JSON.parse(text) };
  }

  return {
    dir,
    stateDir,
    store,
    get base() {
      return `http://127.0.0.1:${address.port}`;
    },
    request,
    async pair(overrides = {}) {
      return issuePairing(store, {
        name: 'iPhone',
        scopes: DEFAULT_SCOPES,
        ttlMs: PAIRING_TTL_MS,
        now: clock(),
        ...overrides,
      });
    },
    async enroll(code, name = 'iPhone') {
      const response = await request('/v1/devices/enroll', { method: 'POST', body: { code, name } });
      return response;
    },
    async token(scopes = DEFAULT_SCOPES) {
      const paired = await this.pair({ scopes });
      const enrolled = await this.enroll(paired.code);
      return enrolled.body.data.token;
    },
    async restart() {
      await bridge.close();
      bridge = createBridge({ store, testEndpoints, drive, now: clock, log: null, routeOptions });
      address = await bridge.listen({ port: 0, host: '127.0.0.1' });
    },
    async close() {
      await bridge.close();
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

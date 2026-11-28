// Shared test harness: a real HTTP server on an ephemeral loopback port with a
// throwaway state directory, so tests exercise the same code path as launchd.
//
// Workspace roots default to an empty directory inside the throwaway state, so
// a test run never scans the developer's real ~/dev or ~/.paseo.

import { mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DEFAULT_SCOPES, IDEMPOTENCY_RETENTION_MS, PAIRING_TTL_MS, STUDIO_SCOPES } from '../src/config.mjs';
import { isAdapterEnvKey } from '../src/lane/guard.mjs';
import { createStore } from '../src/store.mjs';
import { createBridge } from '../src/http.mjs';
import { grantStudio, issuePairing } from '../src/pairing.mjs';

export async function startBridge({ now, testEndpoints = true, drive = null, workspace, tasks = null, sessions = null, decisions = null, brain = null, usage = null, studio = null, ownerTasks = null, habits = null, linearOwnerTasks = null, skills = null, routines = null, staff = null, calls = null, calendar = null, instructions = null, voice = null, campaigns = null, rejectedUploadDrainer, log = null, refs = null, monet = null, supervisorFile = null } = {}) {
  const clock = now ?? (() => Date.now());
  const dir = mkdtempSync(join(tmpdir(), 'laa-bridge-test-'));
  const stateDir = join(dir, 'state');
  const store = createStore({ dir: stateDir, idempotencyRetentionMs: IDEMPOTENCY_RETENTION_MS, now: clock });

  const workspaceRoots = workspace?.roots ?? [join(dir, 'workspaces')];
  for (const root of workspaceRoots) mkdirSync(root, { recursive: true });
  const refsService = typeof refs === 'function' ? refs(stateDir) : refs;
  const routeOptions = {
    supervisorFile: supervisorFile?.(dir),
    workspaces: { ...(workspace ?? {}), roots: workspaceRoots },
    ...(tasks ? { tasks } : {}),
    ...(sessions ? { sessions } : {}),
    ...(decisions ? { decisions } : {}),
    ...(monet ? { monet } : {}),
    ...(brain ? { brain } : {}),
    // Tests never run the real Google or MacBook authentication helpers.
    usage: { capacitySource: { read: () => [], close() {} }, ...(usage ?? {}) },
    ...(studio ? { studio } : {}),
    ...(ownerTasks ? { ownerTasks } : {}),
    ...(habits ? { habits } : {}),
    ...(linearOwnerTasks ? { linearOwnerTasks } : {}),
    ...(skills ? { skills } : {}),
    // A stub keeps every test from spawning the real `laa-console jobs` at startup.
    routines: routines ?? { read: async () => ({ data: [] }) },
    staff: staff ?? { path: join(dir, 'roster.yaml') },
    // Never the owner's real engine switch or Hermes env template.
    calls: calls ?? { file: join(dir, 'staff-call-engine.json'), hermesEnvFile: join(dir, 'hermes-personal.env.tpl') },
    ...(calendar ? { calendar } : {}),
    ...(instructions ? { instructions } : {}),
    ...(voice ? { voice } : {}),
    // A stub keeps tests from reading the owner's real campaign ledger.
    campaigns: campaigns ?? { command: [process.execPath, '-e', 'process.exit(1)'] },
    ...(refsService ? { refs: refsService } : {}),
  };

  let bridge = createBridge({ store, testEndpoints, drive, now: clock, log, routeOptions, ...(rejectedUploadDrainer ? { rejectedUploadDrainer } : {}) });
  let address = await bridge.listen({ port: 0, host: '127.0.0.1' });

  async function request(path, { method = 'GET', body, token, key, headers = {}, signal } = {}) {
    const finalHeaders = { ...headers };
    if (body !== undefined) finalHeaders['content-type'] = 'application/json';
    if (token) finalHeaders.authorization = `Bearer ${token}`;
    if (key) finalHeaders['idempotency-key'] = key;
    const response = await fetch(`http://127.0.0.1:${address.port}${path}`, {
      method,
      headers: finalHeaders,
      body: body === undefined ? undefined : (typeof body === 'string' ? body : JSON.stringify(body)),
      signal,
    });
    const text = await response.text();
    return { status: response.status, headers: response.headers, body: text === '' ? null : JSON.parse(text) };
  }

  return {
    dir,
    stateDir,
    store,
    refs: refsService,
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
      const pairScopes = scopes.filter((scope) => !STUDIO_SCOPES.includes(scope));
      const paired = await this.pair({ scopes: pairScopes });
      const enrolled = await this.enroll(paired.code);
      if (scopes.some((scope) => STUDIO_SCOPES.includes(scope))) {
        const id = enrolled.body.data.deviceId;
        grantStudio(store, { target: id, reason: 'Test device', now: clock() });
        // Fixtures may model a partially granted legacy device for scope tests.
        store.mutate((state) => { state.devices[id].scopes = [...scopes]; });
      }
      return enrolled.body.data.token;
    },
    async restart() {
      await bridge.close();
      bridge = createBridge({ store, testEndpoints, drive, now: clock, log, routeOptions, ...(rejectedUploadDrainer ? { rejectedUploadDrainer } : {}) });
      address = await bridge.listen({ port: 0, host: '127.0.0.1' });
    },
    async close() {
      await bridge.close();
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

/// A lane built inside a Work session inherits that session's wiring
/// (`LAA_WORK_*`, `PASEO_*`), which the lane guard refuses on purpose: a lane may
/// not take an adapter from the environment. Clear those keys for the test and
/// put them back afterwards, so the suite gives the same verdict from an agent
/// session as from a plain login shell.
export function clearInheritedAdapters(t) {
  const saved = [];
  for (const key of Object.keys(process.env)) {
    if (!isAdapterEnvKey(key)) continue;
    saved.push([key, process.env[key]]);
    delete process.env[key];
  }
  t.after(() => {
    for (const [key, value] of saved) process.env[key] = value;
  });
}

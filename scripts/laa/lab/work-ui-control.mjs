// Setup for UI tests of the real Bridge and isolated Work engine. The test
// runner never receives the setup bearer, and the client proves the lane first.
import { randomUUID } from 'node:crypto';
import { createStore } from '../../../bridge/src/store.mjs';
import { DEFAULT_SCOPES, IDEMPOTENCY_RETENTION_MS } from '../../../bridge/src/config.mjs';
import { hashPairingCode, normalizePairingCode } from '../../../bridge/src/auth.mjs';
import { issuePairing, revokeDevice } from '../../../bridge/src/pairing.mjs';
import { laneClient } from '../../../bridge/src/lane/client.mjs';
import { validateLane } from '../../../bridge/src/lane/guard.mjs';

export function workUIControl(env = process.env) {
  if (!env.LAA_LANE_BRIDGE || !env.LAA_LAB_SETUP_TOKEN) return null;
  const stateDir = env.LAA_BRIDGE_STATE_DIR;
  const lane = validateLane(env, { stateDir, port: 0 });
  if (!lane) throw new Error('Work UI setup requires a lab lane');
  const store = createStore({ dir: stateDir, idempotencyRetentionMs: IDEMPOTENCY_RETENTION_MS });
  const fetch = laneClient(env.LAA_LANE_BRIDGE, lane.id);
  async function request(path, { method = 'GET', body, etag } = {}) {
    const response = await fetch(path, { method, headers: { authorization: `Bearer ${env.LAA_LAB_SETUP_TOKEN}`,
      ...(etag ? { 'if-match': etag } : {}),
      ...(body ? { 'content-type': 'application/json', 'idempotency-key': randomUUID() } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}) });
    if (!response.ok) throw new Error(`setup API failed: ${method} ${path} (${response.status})`);
    return (await response.json()).data;
  }
  const codes = new Map();
  return async (url) => {
    const tag = url.searchParams.get('tag');
    if (url.pathname === '/lab/pair') {
      if (!/^[a-zA-Z0-9-]{1,80}$/.test(tag ?? '')) throw new Error('bad pairing tag');
      const { code } = issuePairing(store, { name: 'Lab Work UI', scopes: DEFAULT_SCOPES, ttlMs: 600_000 });
      codes.set(tag, hashPairingCode(normalizePairingCode(code)));
      return { code };
    }
    if (url.pathname === '/lab/revoke') {
      const key = codes.get(tag);
      const target = key && store.read().pairings[key]?.deviceId;
      if (!target) throw new Error('unknown paired lab UI device');
      const result = revokeDevice(store, { target, reason: 'lab UI test' });
      if (!result.device) throw new Error('lab UI revocation failed');
      codes.delete(tag);
      return { revoked: true };
    }
    if (url.pathname === '/lab/project') {
      const name = url.searchParams.get('name');
      if (!/^Lab [\w -]{1,45}$/.test(name ?? '')) throw new Error('bad lab project');
      return request('/v1/projects', { method: 'POST', body: { name, ...(url.searchParams.has('instructions') ?
        { instructions: url.searchParams.get('instructions') } : {}) } });
    }
    if (url.pathname === '/lab/revise-project') {
      const id = url.searchParams.get('id');
      if (!/^prj_[a-f0-9]{12}$/.test(id ?? '')) throw new Error('bad lab project id');
      const project = await request(`/v1/projects/${id}`);
      return request(`/v1/projects/${id}`, { method: 'PATCH', etag: project.etag, body: { instructions: 'Server revision' } });
    }
    if (url.pathname === '/lab/session') {
      const name = url.searchParams.get('name');
      if (!/^Lab [\w -]{1,45}$/.test(name ?? '')) throw new Error('bad lab Work name');
      return request('/v1/sessions', { method: 'POST', body: { requestId: randomUUID(), profile: 'lab-echo', name, prompt: 'Lab start' } });
    }
    if (url.pathname === '/lab/empty-sessions') {
      const { items } = await request('/v1/sessions');
      for (const { id } of items) await request(`/v1/sessions/${id}`, { method: 'PATCH', body: { archived: true } });
      return { empty: (await request('/v1/sessions')).items.length === 0 };
    }
    return null;
  };
}

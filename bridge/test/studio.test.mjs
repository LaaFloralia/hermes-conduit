import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { chmodSync, mkdtempSync, rmSync, writeFileSync, renameSync, symlinkSync } from 'node:fs';
import { lstat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { Readable } from 'node:stream';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { startBridge } from './helpers.mjs';
import { createStudioBackend } from '../src/studio/backend.mjs';
import { BridgeError } from '../src/errors.mjs';
import { grantStudio } from '../src/pairing.mjs';
import { DEFAULT_SCOPES } from '../src/config.mjs';
import { hashPairingCode, normalizePairingCode } from '../src/auth.mjs';
import { mockStudioBackend } from './studio-mock.mjs';

const id = '44831665-6bc4-4444-8f84-52c3e8276d12';
const approvalId = 'db831665-6bc4-4444-8f84-52c3e8276d12';
const path = `/v1/studio/media/project1/${'a'.repeat(64)}.mp4`;
const draft = { id, projectId: 'project1', expectedRevision: 2, prompt: 'Make a document' };
const body = Buffer.from('0123456789');

function fakeBackend() {
  const state = { created: [], actions: [], approvals: [{ id: approvalId, supported: true, allowSession: false,
    fields: [{ name: 'count', type: 'integer', required: true }, { name: 'confirm', type: 'boolean', required: false }] }] };
  return {
    state,
    async snapshot() { return { online: true, accepting: true, lastSeen: null, projects: [], principles: [], requests: [] }; },
    async getRequest() { return { request: draft, status: state.status ?? 'approval', report: { approvals: state.approvals } }; },
    async createRequest(payload) { state.created.push(payload); return { request: payload, status: 'queued' }; },
    async action(payload) { state.actions.push(payload); return { ok: true }; },
    async media(_path, options) {
      if (state.mediaStatus === 404) return Object.assign(Readable.from([]), { statusCode: 404, headers: {} });
      if (state.mediaStatus === 416) return Object.assign(Readable.from([]), { statusCode: 416, headers: { 'content-range': `bytes */${body.length}` } });
      const sliced = options.range === 'bytes=2-5';
      const stream = Object.assign(Readable.from([sliced ? body.subarray(2, 6) : body]), {
        statusCode: sliced ? 206 : 200,
        headers: { 'content-type': state.mediaType ?? 'video/mp4', 'content-length': String(state.mediaLength ?? (sliced ? 4 : body.length)),
          'accept-ranges': 'bytes', ...(sliced ? { 'content-range': state.badRange ? 'bytes 2-20/10' : `bytes 2-5/${body.length}` } : {}) },
      });
      state.lastMediaStream = stream;
      return stream;
    },
  };
}

describe('Studio Bridge routes', () => {
  let bridge, backend, readToken, requestToken, allToken, noToken;
  before(async () => {
    backend = fakeBackend();
    bridge = await startBridge({ studio: { backend } });
    readToken = await bridge.token(['studio:read']);
    requestToken = await bridge.token(['studio:request']);
    allToken = await bridge.token(['studio:read', 'studio:request']);
    noToken = await bridge.token(['media:read']);
  });
  after(async () => bridge.close());
  it('separates read, request, media and missing authentication', async () => {
    assert.equal((await bridge.request('/v1/studio/snapshot')).status, 401);
    assert.equal((await bridge.request('/v1/studio/snapshot', { token: noToken })).status, 403);
    assert.equal((await bridge.request('/v1/studio/snapshot', { token: readToken })).status, 200);
    assert.equal((await bridge.request(`/v1/studio/requests/${id}`, { token: readToken })).status, 200);
    assert.match((await bridge.request('/v1/studio/request-id', { token: requestToken })).body.data.id, /^[0-9a-f-]{36}$/);
    assert.equal((await bridge.request('/v1/studio/requests', { method: 'POST', token: readToken, key: 'deny', body: draft })).status, 403);
    assert.equal((await bridge.request('/v1/studio/snapshot', { token: requestToken })).status, 403);
    const denied = await fetch(bridge.base + path, { headers: { authorization: `Bearer ${noToken}` } });
    assert.equal(denied.status, 403);
  });
  it('validates strictly and sends the same creation only once for one idempotency key', async () => {
    for (const bad of [{ ...draft, projectId: 3 }, { ...draft, prompt: ' ' }, { ...draft, extra: true }, { ...draft, create: { title: 'New' } }, { ...draft, prompt: 'x'.repeat(10001) }]) {
      const response = await bridge.request('/v1/studio/requests', { method: 'POST', token: allToken, key: randomUUID(), body: bad });
      assert.equal(response.status, 400);
    }
    const first = await bridge.request('/v1/studio/requests', { method: 'POST', token: allToken, key: 'create-one', body: draft });
    backend.state.status = 'completed';
    const again = await bridge.request('/v1/studio/requests', { method: 'POST', token: allToken, key: 'create-one', body: draft });
    assert.equal(first.status, 202); assert.equal(again.status, 202); assert.equal(backend.state.created.length, 1);
    assert.equal(first.body.data.status, 'queued'); assert.equal(again.body.data.status, 'completed');
    assert.equal(again.headers.get('idempotency-replayed'), 'true');
    backend.state.status = undefined;
    assert.equal((await bridge.request('/v1/studio/requests', { method: 'POST', token: allToken, key: 'create-one', body: { ...draft, prompt: 'changed' } })).status, 409);
  });
  it('blocks unsupported, stale, malformed and disallowed persistent answers', async () => {
    const answer = { action: 'answer', id, approvalId, accept: true, content: { count: 2 }, persist: false };
    const post = (data) => bridge.request('/v1/studio/action', { method: 'POST', token: allToken, key: randomUUID(), body: data });
    assert.equal((await post({ ...answer, content: { count: 2.2 } })).status, 400);
    assert.equal((await post({ ...answer, persist: true })).status, 400);
    assert.equal((await post({ ...answer, content: {} })).status, 400);
    backend.state.approvals[0].supported = false;
    assert.equal((await post(answer)).body.error.code, 'studio_approval_on_mac');
    backend.state.approvals[0].supported = true;
    assert.equal((await post({ ...answer, approvalId: randomUUID() })).status, 409);
    assert.equal((await post({ action: 'resume', id })).body.error.code, 'studio_resume_unsupported');
    assert.equal((await post(answer)).status, 200);
    assert.equal((await bridge.request('/v1/studio/action', { method: 'POST', token: readToken, key: randomUUID(), body: answer })).status, 403);
    assert.equal(backend.state.actions.length, 1);
  });
  it('forwards Range and keeps its byte headers; rejects arbitrary media paths', async () => {
    const result = await fetch(bridge.base + path, { headers: { authorization: `Bearer ${readToken}`, range: 'bytes=2-5' } });
    assert.equal(result.status, 206); assert.equal(result.headers.get('content-range'), 'bytes 2-5/10');
    assert.equal(await result.text(), '2345');
    assert.equal((await fetch(bridge.base + '/v1/studio/media/%2e%2e%2fsecret', { headers: { authorization: `Bearer ${readToken}` } })).status, 404);
    backend.state.badRange = true;
    const invalid = await bridge.request(path, { token: readToken, headers: { range: 'bytes=2-5' } });
    assert.equal(invalid.status, 502);
    backend.state.badRange = false;
    backend.state.mediaStatus = 404;
    const missing = await bridge.request(path, { token: readToken });
    assert.equal(missing.body.error.code, 'studio_media_not_found');
    backend.state.mediaStatus = 416;
    const outside = await fetch(bridge.base + path, { headers: { authorization: `Bearer ${readToken}`, range: 'bytes=100-101' } });
    assert.equal(outside.status, 416);
    assert.equal(outside.headers.get('content-range'), 'bytes */10');
    assert.equal(outside.headers.get('cache-control'), 'no-store');
    assert.equal((await outside.json()).error.retryable, false);
    backend.state.mediaStatus = undefined;
    backend.state.mediaType = 'text/html';
    assert.equal((await bridge.request(path, { token: readToken })).body.error.code, 'studio_media_invalid');
    backend.state.mediaType = undefined;
    backend.state.mediaLength = 16 * 1024 * 1024 + 1;
    assert.equal((await bridge.request(path, { token: readToken })).body.error.code, 'studio_media_invalid');
    backend.state.mediaLength = undefined;
    const head = await fetch(bridge.base + path, { method: 'HEAD', headers: { authorization: `Bearer ${readToken}` } });
    assert.equal(head.status, 200);
    assert.equal(backend.state.lastMediaStream.destroyed, true);
  });
  it('accepts contract-sized multi-field answers and rejects bodies above 1 MiB', async () => {
    const original = backend.state.approvals;
    const fields = Array.from({ length: 20 }, (_, i) => ({ name: `field${i}`, type: 'string', required: true }));
    backend.state.approvals = [{ id: approvalId, supported: true, allowSession: false, fields }];
    const content = Object.fromEntries(fields.map(({ name }) => [name, 'x'.repeat(4000)]));
    const response = await bridge.request('/v1/studio/action', { method: 'POST', token: allToken, key: randomUUID(),
      body: { action: 'answer', id, approvalId, accept: true, content, persist: false } });
    assert.equal(response.status, 200);
    const oversized = await bridge.request('/v1/studio/action', { method: 'POST', token: allToken, key: randomUUID(),
      body: 'x'.repeat(1024 * 1024 + 1) });
    assert.equal(oversized.status, 413);
    backend.state.approvals = original;
  });
  it('only grants the two scopes to an active, unambiguous existing device', async () => {
    const state = bridge.store.read();
    const existing = Object.values(state.devices).find((d) => d.scopes.includes('media:read'));
    assert.ok(existing);
    const granted = grantStudio(bridge.store, { target: existing.id, reason: 'Owner device', now: 1000, operatorUid: 123 });
    assert.deepEqual(granted.device.scopes, ['media:read', 'studio:read', 'studio:request']);
    assert.deepEqual(granted.device.studioGrant, { grantedAt: '1970-01-01T00:00:01.000Z', operatorUid: 123, reason: 'Owner device', wasAlreadyGranted: false });
    assert.equal(grantStudio(bridge.store, { target: existing.id, reason: 'second', now: 2000 }).alreadyGranted, true);
    assert.deepEqual(bridge.store.read().devices[existing.id].studioGrant, granted.device.studioGrant);
    assert.match(grantStudio(bridge.store, { target: existing.id, reason: 'invalid\nline' }).error, /one line/);
    assert.equal((await bridge.request('/v1/studio/snapshot', { token: noToken })).status, 200);
    bridge.store.mutate((s) => { s.devices[existing.id].revokedAt = new Date().toISOString(); });
    assert.match(grantStudio(bridge.store, { target: existing.id, reason: 'Revoked device' }).error, /revoked/);
  });
  it('requires an explicit Studio grant even for a stale pre-upgrade pairing code', async () => {
    assert.ok(!DEFAULT_SCOPES.some((scope) => scope.startsWith('studio:')));
    await assert.rejects(bridge.pair({ scopes: ['studio:request'] }), /grant-studio/);
    const paired = await bridge.pair();
    bridge.store.mutate((state) => {
      state.pairings[hashPairingCode(normalizePairingCode(paired.code))].scopes.push('studio:read', 'studio:request');
    });
    const enrolled = await bridge.enroll(paired.code);
    assert.equal(enrolled.status, 201);
    assert.ok(!enrolled.body.data.scopes.some((scope) => scope.startsWith('studio:')));
    const token = enrolled.body.data.token;
    assert.equal((await bridge.request('/v1/studio/snapshot', { token })).status, 403);
    assert.equal((await bridge.request('/v1/studio/requests', { method: 'POST', token, key: randomUUID(), body: draft })).status, 403);
    grantStudio(bridge.store, { target: enrolled.body.data.deviceId, reason: 'Test device' });
    assert.equal((await bridge.request('/v1/studio/snapshot', { token })).status, 200);
  });
  it('records the first explicit management operation for an old already-granted device', async () => {
    const paired = await bridge.pair();
    const enrolled = await bridge.enroll(paired.code);
    const deviceId = enrolled.body.data.deviceId;
    bridge.store.mutate((state) => { state.devices[deviceId].scopes.push('studio:read', 'studio:request'); });
    const result = grantStudio(bridge.store, { target: deviceId, reason: 'Legacy grant confirmed', now: 2000, operatorUid: 123 });
    assert.equal(result.alreadyGranted, true);
    assert.deepEqual(result.device.studioGrant, { grantedAt: '1970-01-01T00:00:02.000Z', operatorUid: 123, reason: 'Legacy grant confirmed', wasAlreadyGranted: true });
  });
  it('exposes the recorded grant through the operator CLI and rejects pair-time Studio scopes', async () => {
    const cli = fileURLToPath(new URL('../src/cli.mjs', import.meta.url));
    const env = { ...process.env, LAA_BRIDGE_STATE_DIR: bridge.stateDir };
    const rejected = spawnSync(process.execPath, [cli, 'pair', '--scopes', 'studio:request'], { env, encoding: 'utf8' });
    assert.equal(rejected.status, 2);
    assert.match(rejected.stderr, /grant-studio/);
    const paired = await bridge.pair();
    const enrolled = await bridge.enroll(paired.code);
    const deviceId = enrolled.body.data.deviceId;
    const missingReason = spawnSync(process.execPath, [cli, 'grant-studio', deviceId], { env, encoding: 'utf8' });
    assert.equal(missingReason.status, 2);
    assert.match(missingReason.stderr, /--reason/);
    assert.equal(bridge.store.read().devices[deviceId].studioGrant, undefined);
    const output = execFileSync(process.execPath, [cli, 'grant-studio', deviceId, '--reason', 'Owner device', '--json'], { env, encoding: 'utf8' });
    const grant = JSON.parse(output);
    assert.equal(grant.studioGrant.reason, 'Owner device');
    assert.equal(grant.name, 'iPhone');
    assert.ok(!grant.previousScopes.includes('studio:request'));
    assert.ok(grant.scopes.includes('studio:request'));
    const devices = JSON.parse(execFileSync(process.execPath, [cli, 'devices', '--json'], { env, encoding: 'utf8' }));
    assert.equal(devices.find((device) => device.id === deviceId).studioGrant.reason, 'Owner device');
  });
});

describe('Studio mock contract', () => {
  it('replays the same action key after a lost response without applying twice and returns current state', async () => {
    const backend = mockStudioBackend({ projects: [{ id: 'project1', revision: 2, title: 'Work', pages: [] }] });
    let applied = 0;
    const originalAction = backend.action;
    backend.action = async (action) => { applied += 1; return originalAction(action); };
    const bridge = await startBridge({ studio: { backend } });
    try {
      const token = await bridge.token(['studio:read', 'studio:request']);
      await bridge.request('/v1/studio/requests', { method: 'POST', token, key: 'create-lost-action', body: draft });
      backend.report(id, { status: 'approval', bootId: id, approvals: [{ id: approvalId, supported: true, allowSession: false, fields: [] }] });
      const answer = { action: 'answer', id, approvalId, accept: true, content: {}, persist: false };
      const attempt = { method: 'POST', token, key: 'same-action-key', body: answer };
      const first = await bridge.request('/v1/studio/action', attempt);
      assert.equal(first.status, 200); // The client loses this response after Studio applied the action.
      assert.equal(applied, 1);
      backend.report(id, { status: 'completed', bootId: id });
      const retry = await bridge.request('/v1/studio/action', attempt);
      assert.equal(retry.status, 200);
      assert.equal(retry.headers.get('idempotency-replayed'), 'true');
      assert.equal(retry.body.data.status, 'completed');
      assert.equal(applied, 1);
      const different = await bridge.request('/v1/studio/action', { ...attempt, body: { ...answer, accept: false } });
      assert.equal(different.body.error.code, 'idempotency_key_conflict');
      assert.equal(applied, 1);
    } finally { await bridge.close(); }
  });

  it('does not repeat an action when the Studio response was lost before Bridge could record it', async () => {
    const backend = mockStudioBackend({ projects: [{ id: 'project1', revision: 2, title: 'Work', pages: [] }] });
    let calls = 0;
    const originalAction = backend.action;
    backend.action = async (action) => {
      calls += 1;
      await originalAction(action);
      throw new BridgeError(503, 'studio_not_connected', 'response lost');
    };
    const bridge = await startBridge({ studio: { backend } });
    try {
      const token = await bridge.token(['studio:read', 'studio:request']);
      await bridge.request('/v1/studio/requests', { method: 'POST', token, key: 'create-upstream-loss', body: draft });
      backend.report(id, { status: 'approval', bootId: id, approvals: [{ id: approvalId, supported: true, allowSession: false, fields: [] }] });
      const attempt = { method: 'POST', token, key: 'upstream-loss-action',
        body: { action: 'answer', id, approvalId, accept: true, content: {}, persist: false } };
      assert.equal((await bridge.request('/v1/studio/action', attempt)).status, 503);
      const retry = await bridge.request('/v1/studio/action', attempt);
      assert.equal(retry.body.error.code, 'idempotency_key_in_flight');
      assert.equal(calls, 1);
      assert.equal((await bridge.request(`/v1/studio/requests/${id}`, { token })).body.data.status, 'running');
    } finally { await bridge.close(); }
  });

  it('allows a newly confirmed action after the original failed before reaching Studio', async () => {
    let clock = Date.now();
    const backend = mockStudioBackend({ projects: [{ id: 'project1', revision: 2, title: 'Work', pages: [] }] });
    const originalAction = backend.action;
    let calls = 0;
    backend.action = async () => { calls += 1; throw new BridgeError(503, 'studio_not_connected', 'not sent'); };
    const bridge = await startBridge({ now: () => clock, studio: { backend } });
    try {
      const token = await bridge.token(['studio:read', 'studio:request']);
      await bridge.request('/v1/studio/requests', { method: 'POST', token, key: 'create-no-action', body: draft });
      const attempt = { method: 'POST', token, key: 'not-sent-action', body: { action: 'stop', id } };
      assert.equal((await bridge.request('/v1/studio/action', attempt)).status, 503);
      assert.equal((await bridge.request('/v1/studio/action', attempt)).body.error.code, 'idempotency_key_in_flight');
      assert.equal(calls, 1);
      clock += 60_001;
      assert.equal((await bridge.request('/v1/studio/action', attempt)).body.error.code, 'idempotency_outcome_unknown');
      assert.equal(calls, 1);
      assert.equal((await bridge.request(`/v1/studio/requests/${id}`, { token })).body.data.status, 'queued');
      backend.action = originalAction;
      const confirmed = await bridge.request('/v1/studio/action', { ...attempt, key: 'newly-confirmed-action' });
      assert.equal(confirmed.body.data.status, 'stopped');
    } finally { await bridge.close(); }
  });

  it('accepts a fresh stop key after a lost response and reports an already finished request', async () => {
    const backend = mockStudioBackend({ projects: [{ id: 'project1', revision: 2, title: 'Work', pages: [] }] });
    const originalAction = backend.action;
    let calls = 0;
    backend.action = async (action) => {
      calls += 1;
      const result = await originalAction(action);
      if (calls === 1) throw new BridgeError(503, 'studio_not_connected', 'response lost');
      return result;
    };
    const bridge = await startBridge({ studio: { backend } });
    try {
      const token = await bridge.token(['studio:read', 'studio:request']);
      await bridge.request('/v1/studio/requests', { method: 'POST', token, key: 'create-stop-lost', body: draft });
      const attempt = { method: 'POST', token, key: 'stop-lost', body: { action: 'stop', id } };
      assert.equal((await bridge.request('/v1/studio/action', attempt)).status, 503);
      assert.equal((await bridge.request('/v1/studio/action', attempt)).body.error.code, 'idempotency_key_in_flight');
      const retry = await bridge.request('/v1/studio/action', { ...attempt, key: 'stop-retry' });
      assert.equal(retry.status, 409);
      assert.equal(retry.body.error.code, 'studio_request_finished');
      assert.equal(calls, 2);
      assert.equal((await bridge.request(`/v1/studio/requests/${id}`, { token })).body.data.status, 'stopped');
    } finally { await bridge.close(); }
  });

  it('states that creation was accepted when replay cannot obtain the current Studio record', async () => {
    const backend = mockStudioBackend({ projects: [{ id: 'project1', revision: 2, title: 'Work', pages: [] }] });
    const bridge = await startBridge({ studio: { backend } });
    try {
      const token = await bridge.token(['studio:read', 'studio:request']);
      const attempt = { method: 'POST', token, key: 'create-offline-replay', body: draft };
      assert.equal((await bridge.request('/v1/studio/requests', attempt)).status, 202);
      backend.state.connected = false;
      const retry = await bridge.request('/v1/studio/requests', attempt);
      assert.equal(retry.status, 503);
      assert.equal(retry.body.error.code, 'studio_not_connected');
      assert.match(retry.body.error.message, /accepted earlier.*GET/);
      assert.equal(backend.state.records.size, 1);
    } finally { await bridge.close(); }
  });

  it('states that an action was accepted when replay cannot obtain the current Studio record', async () => {
    const backend = mockStudioBackend({ projects: [{ id: 'project1', revision: 2, title: 'Work', pages: [] }] });
    const bridge = await startBridge({ studio: { backend } });
    try {
      const token = await bridge.token(['studio:read', 'studio:request']);
      await bridge.request('/v1/studio/requests', { method: 'POST', token, key: 'create-action-offline-replay', body: draft });
      const attempt = { method: 'POST', token, key: 'action-offline-replay', body: { action: 'stop', id } };
      assert.equal((await bridge.request('/v1/studio/action', attempt)).status, 200);
      backend.state.connected = false;
      const retry = await bridge.request('/v1/studio/action', attempt);
      assert.equal(retry.status, 503);
      assert.equal(retry.body.error.code, 'studio_not_connected');
      assert.match(retry.body.error.message, /accepted earlier.*GET/);
      backend.state.connected = true;
      assert.equal((await bridge.request(`/v1/studio/requests/${id}`, { token })).body.data.status, 'stopped');
    } finally { await bridge.close(); }
  });

  it('preserves request identity, conflicts and 45-second unreceived state without retrying', async () => {
    let clock = Date.parse('2026-11-01T03:12:40.512Z');
    const backend = mockStudioBackend({ now: () => clock, projects: [{ id: 'project1', revision: 2, title: 'Work', pages: [] }],
      principles: [{ id: 'principle1', version: '6', revision: 3 }] });
    const bridge = await startBridge({ studio: { backend } });
    try {
      const token = await bridge.token(['studio:read', 'studio:request']);
      const post = (route, value) => bridge.request(route, { method: 'POST', token, key: randomUUID(), body: value });
      const first = await post('/v1/studio/requests', draft);
      assert.equal(first.status, 202);
      assert.equal((await post('/v1/studio/requests', draft)).body.data.request.id, id);
      assert.equal((await post('/v1/studio/requests', { ...draft, prompt: 'different' })).body.error.code, 'studio_request_id_conflict');
      assert.equal((await post('/v1/studio/requests', { ...draft, id: randomUUID() })).body.error.code, 'studio_work_busy');
      assert.equal((await bridge.request(`/v1/studio/requests/${randomUUID()}`, { token })).body.error.code, 'studio_request_missing');
      clock += 44_999;
      assert.equal((await bridge.request(`/v1/studio/requests/${id}`, { token })).body.data.status, 'queued');
      clock += 1;
      assert.equal((await bridge.request(`/v1/studio/requests/${id}`, { token })).body.data.status, 'unreceived');
      assert.equal((await post('/v1/studio/requests', draft)).body.data.status, 'unreceived');
      assert.equal(backend.state.records.size, 1);
      assert.equal((await post('/v1/studio/action', { action: 'stop', id })).body.data.status, 'stopped');
      assert.equal((await post('/v1/studio/action', { action: 'stop', id })).body.error.code, 'studio_request_finished');
      const next = { ...draft, id: randomUUID() };
      assert.equal((await post('/v1/studio/requests', next)).status, 202);
      backend.report(next.id, { status: 'approval', bootId: id, approvals: [{ id: approvalId, supported: true, allowSession: false, fields: [] }] });
      const answer = { action: 'answer', id: next.id, approvalId, accept: true, content: {}, persist: false };
      assert.equal((await post('/v1/studio/action', answer)).body.data.status, 'running');
      assert.equal((await post('/v1/studio/action', answer)).body.error.code, 'studio_approval_changed');
      assert.equal((await post('/v1/studio/action', { action: 'stop', id: next.id })).body.data.status, 'stopped');
      assert.equal((await post('/v1/studio/requests', { ...draft, id: randomUUID(), expectedRevision: 1 })).body.error.code, 'studio_revision_changed');
      const changedPrinciple = { ...draft, id: randomUUID(), principle: { id: 'principle1', version: '5', revision: 3 } };
      assert.equal((await post('/v1/studio/requests', changedPrinciple)).body.error.code, 'studio_principle_changed');
      backend.state.connected = false;
      const offline = await bridge.request('/v1/studio/snapshot', { token });
      assert.equal(offline.status, 503);
      assert.equal(offline.body.error.code, 'studio_not_connected');
    } finally { await bridge.close(); }
  });
});

describe('Studio UDS backend', () => {
  it('does not expose the device or intake bearer token through Studio responses or Bridge logs', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'studio-log-'));
    const socket = join(dir, 'intake.sock'), secret = 'e'.repeat(64);
    chmodSync(dir, 0o700);
    writeFileSync(join(dir, 'intake.json'), JSON.stringify({ version: 1, socketPath: socket, token: secret, bootId: id, pid: process.pid }), { mode: 0o600 });
    const server = createServer((req, res) => {
      assert.equal(req.headers.authorization, `Bearer ${secret}`);
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end('{"online":true,"accepting":true,"projects":[],"principles":[],"requests":[]}');
    });
    const logs = []; let bridge;
    try {
      await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socket, resolve); });
      chmodSync(socket, 0o600);
      bridge = await startBridge({ studio: { backend: createStudioBackend({ directory: dir, launch: async () => {} }) }, log: (entry) => logs.push(entry) });
      const token = await bridge.token(['studio:read']);
      const result = await bridge.request('/v1/studio/snapshot', { token });
      assert.equal(result.status, 200);
      for (const data of [JSON.stringify(result.body), JSON.stringify(logs)]) {
        assert.equal(data.includes(token), false);
        assert.equal(data.includes(secret), false);
      }
    } finally {
      if (bridge) await bridge.close();
      server.closeAllConnections?.();
      await new Promise((resolve) => server.close(resolve));
      rmSync(dir, { recursive: true, force: true });
    }
  });
  it('retries a POST once after 401 with reloaded credentials, but never after a timeout', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'studio-post-'));
    const socket = join(dir, 'intake.sock');
    const meta = join(dir, 'intake.json');
    const first = 'a'.repeat(64), second = 'b'.repeat(64);
    const save = (token) => writeFileSync(meta, JSON.stringify({ version: 1, socketPath: socket, token, bootId: id, pid: process.pid }), { mode: 0o600 });
    chmodSync(dir, 0o700); save(first);
    let calls = 0, mode = 'rotate';
    const bodies = [];
    const server = createServer((req, res) => {
      calls += 1;
      let input = '';
      req.on('data', (chunk) => { input += chunk; });
      req.on('end', () => {
        bodies.push(input);
        if (mode === 'timeout') return;
        if (mode === 'deny' || req.headers.authorization === `Bearer ${first}`) {
          save(second); res.writeHead(401); res.end(); return;
        }
        res.writeHead(202, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ request: JSON.parse(input), status: 'queued' }));
      });
    });
    try {
      await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socket, resolve); });
      chmodSync(socket, 0o600);
      const backend = createStudioBackend({ directory: dir, launch: async () => {}, requestTimeoutMs: 80 });
      assert.equal((await backend.createRequest(draft)).status, 'queued');
      assert.equal(calls, 2); assert.deepEqual(bodies.map(JSON.parse), [draft, draft]);
      calls = 0; mode = 'deny';
      await assert.rejects(backend.createRequest(draft), { code: 'studio_not_connected' });
      assert.equal(calls, 2);
      calls = 0; mode = 'timeout';
      await assert.rejects(backend.createRequest(draft), { code: 'studio_not_connected' });
      assert.equal(calls, 1);
    } finally {
      server.closeAllConnections?.();
      await new Promise((resolve) => server.close(resolve));
      rmSync(dir, { recursive: true, force: true });
    }
  });
  it('refuses unsafe modes, symlinks, owners and invalid intake metadata before connecting', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'studio-boundary-'));
    const socket = join(dir, 'intake.sock'), meta = join(dir, 'intake.json');
    const doc = { version: 1, socketPath: socket, token: 'c'.repeat(64), bootId: id, pid: process.pid };
    const save = (value = doc) => writeFileSync(meta, JSON.stringify(value), { mode: 0o600 });
    chmodSync(dir, 0o700); save();
    let calls = 0;
    const server = createServer((_req, res) => { calls += 1; res.end('{"online":true}'); });
    try {
      await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socket, resolve); });
      chmodSync(socket, 0o600);
      const backend = createStudioBackend({ directory: dir, launch: async () => {} });
      for (const [target, unsafe, safe] of [[dir, 0o755, 0o700], [meta, 0o644, 0o600], [socket, 0o755, 0o600]]) {
        chmodSync(target, unsafe);
        await assert.rejects(backend.snapshot(), { code: 'studio_not_connected' });
        chmodSync(target, safe);
      }
      for (const target of [dir, meta, socket]) {
        const statPath = async (path) => {
          const result = await lstat(path);
          if (path === target) Object.defineProperty(result, 'uid', { value: process.getuid() + 1 });
          return result;
        };
        await assert.rejects(createStudioBackend({ directory: dir, statPath, launch: async () => {} }).snapshot(), { code: 'studio_not_connected' });
      }
      for (const target of [meta, socket]) {
        const real = `${target}.real`;
        renameSync(target, real); symlinkSync(real, target);
        await assert.rejects(backend.snapshot(), { code: 'studio_not_connected' });
        rmSync(target); renameSync(real, target);
      }
      for (const bad of [{ socketPath: `${socket}.other` }, { token: 'invalid' }, { bootId: 'invalid' }, { pid: 0 }, { version: 2 }]) {
        save({ ...doc, ...bad });
        await assert.rejects(backend.snapshot(), { code: 'studio_not_connected' });
      }
      assert.equal(calls, 0);
      save();
      assert.equal((await backend.snapshot()).online, true);
      assert.equal(calls, 1);
    } finally {
      server.closeAllConnections?.();
      await new Promise((resolve) => server.close(resolve));
      rmSync(dir, { recursive: true, force: true });
    }
  });
  it('follows intake v1 status codes and JSON error codes', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'studio-contract-'));
    chmodSync(dir, 0o700);
    const socket = join(dir, 'intake.sock');
    writeFileSync(join(dir, 'intake.json'), JSON.stringify({ version: 1, socketPath: socket, token: 'c'.repeat(64), bootId: id, pid: process.pid }), { mode: 0o600 });
    const server = createServer((req, res) => {
      res.setHeader('content-type', 'application/json');
      if (req.method === 'POST' && req.url === '/api/studio/requests') {
        let input = '';
        req.on('data', (chunk) => { input += chunk; });
        req.on('end', () => {
          if (JSON.parse(input).principle) { res.writeHead(409); res.end('{"error":"studio_principle_changed"}'); }
          else { res.writeHead(202); res.end(JSON.stringify({ request: JSON.parse(input), status: 'queued' })); }
        });
      } else { res.writeHead(404); res.end('{"error":"studio_request_missing"}'); }
    });
    try {
      await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socket, resolve); });
      chmodSync(socket, 0o600);
      const backend = createStudioBackend({ directory: dir, launch: async () => {} });
      const record = await backend.createRequest(draft);
      assert.equal(record.status, 'queued');
      await assert.rejects(backend.getRequest(id), { status: 404, code: 'studio_request_missing' });
      await assert.rejects(backend.createRequest({ ...draft, principle: { id: 'p', version: '6', revision: 1 } }),
        { status: 409, code: 'studio_principle_changed' });
    } finally { await new Promise((resolve) => server.close(resolve)); rmSync(dir, { recursive: true, force: true }); }
  });
  it('authenticates locally, reloads rotated credentials after 401, and bounds launch retries', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'studio-intake-'));
    chmodSync(dir, 0o700);
    const socket = join(dir, 'intake.sock');
    const meta = join(dir, 'intake.json');
    const oldToken = 'a'.repeat(64);
    const newToken = 'b'.repeat(64);
    const save = (token) => writeFileSync(meta, JSON.stringify({ version: 1, socketPath: socket, token, bootId: id, pid: process.pid }), { mode: 0o600 });
    save(oldToken);
    let calls = 0; let launches = 0;
    const server = createServer((req, res) => {
      calls += 1;
      if (req.headers.authorization === `Bearer ${oldToken}`) { save(newToken); res.writeHead(401); res.end(); return; }
      res.writeHead(200, { 'content-type': 'application/json' }); res.end('{"online":true}');
    });
    try {
      await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socket, resolve); });
      chmodSync(socket, 0o600);
      const backend = createStudioBackend({ directory: dir, launch: async () => { launches += 1; }, now: () => 1000 });
      assert.deepEqual(await backend.snapshot(), { online: true });
      assert.equal(calls, 2); assert.equal(launches, 0);
      await new Promise((resolve) => server.close(resolve));
      await assert.rejects(backend.snapshot(), { code: 'studio_not_connected' });
      await assert.rejects(backend.snapshot(), { code: 'studio_not_connected' });
      assert.equal(launches, 1);
    } finally { server.close(); rmSync(dir, { recursive: true, force: true }); }
  });
});

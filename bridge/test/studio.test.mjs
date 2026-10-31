import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { Readable } from 'node:stream';
import { startBridge } from './helpers.mjs';
import { createStudioBackend } from '../src/studio/backend.mjs';
import { grantStudio } from '../src/pairing.mjs';
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
    async getRequest() { return { request: draft, status: 'approval', report: { approvals: state.approvals } }; },
    async createRequest(payload) { state.created.push(payload); return { request: payload, status: 'queued' }; },
    async action(payload) { state.actions.push(payload); return { ok: true }; },
    async media(_path, options) {
      if (state.mediaStatus === 404) return Object.assign(Readable.from([]), { statusCode: 404, headers: {} });
      if (state.mediaStatus === 416) return Object.assign(Readable.from([]), { statusCode: 416, headers: { 'content-range': `bytes */${body.length}` } });
      const sliced = options.range === 'bytes=2-5';
      return Object.assign(Readable.from([sliced ? body.subarray(2, 6) : body]), {
        statusCode: sliced ? 206 : 200,
        headers: { 'content-type': 'video/mp4', 'content-length': String(sliced ? 4 : body.length),
          'accept-ranges': 'bytes', ...(sliced ? { 'content-range': state.badRange ? 'bytes 2-20/10' : `bytes 2-5/${body.length}` } : {}) },
      });
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
    const again = await bridge.request('/v1/studio/requests', { method: 'POST', token: allToken, key: 'create-one', body: draft });
    assert.equal(first.status, 202); assert.equal(again.status, 202); assert.equal(backend.state.created.length, 1);
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
    assert.equal(backend.state.actions.length, 1);
  });
  it('forwards Range and keeps its byte headers; rejects arbitrary media paths', async () => {
    const result = await fetch(bridge.base + path, { headers: { authorization: `Bearer ${readToken}`, range: 'bytes=2-5' } });
    assert.equal(result.status, 206); assert.equal(result.headers.get('content-range'), 'bytes 2-5/10');
    assert.equal(await result.text(), '2345');
    assert.equal((await fetch(bridge.base + '/v1/studio/media/../../secret', { headers: { authorization: `Bearer ${readToken}` } })).status, 404);
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
    backend.state.mediaStatus = undefined;
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
    const granted = grantStudio(bridge.store, { target: existing.id });
    assert.deepEqual(granted.device.scopes, ['media:read', 'studio:read', 'studio:request']);
    assert.equal((await bridge.request('/v1/studio/snapshot', { token: noToken })).status, 200);
    bridge.store.mutate((s) => { s.devices[existing.id].revokedAt = new Date().toISOString(); });
    assert.match(grantStudio(bridge.store, { target: existing.id }).error, /revoked/);
  });
});

describe('Studio mock contract', () => {
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

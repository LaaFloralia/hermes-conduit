// Isolated local mock Bridge for LAAStudioUITests; no real Studio or device state.
import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { IDEMPOTENCY_INFLIGHT_GRACE_MS } from '../../bridge/src/config.mjs';
import { IDEMPOTENCY_KEY_PATTERN, complete, requestFingerprint, reserve } from '../../bridge/src/idempotency.mjs';

const projectId = '70175325-5cf4-421f-8a6f-95beae8fca92';
const requestId = '0f6b1c2e-6f1a-4c55-9d43-0d5f6f3b8a11';
const approvalId = '5e2c1c2e-6f1a-4c55-9d43-0d5f6f3b8a11';
const stamp = '2026-10-31T09:00:00Z';
const project = { id: projectId, title: 'サービス紹介資料', revision: 3, pages: [{ id: 'page1', name: 'Cover' }], assets: [], syncedAt: stamp };
const makeRecord = () => ({ request: { id: requestId, projectId, expectedRevision: 3, prompt: '新しい紹介資料を作ってください。' }, status: 'approval', bootId: projectId, updatedAt: stamp,
  report: { id: requestId, bootId: projectId, sequence: 1, status: 'approval', text: '構成を確認しています。', approvals: [{ id: approvalId, message: '画面操作を許可しますか。', supported: true, allowSession: true, fields: [] }] } });
const send = (res, status, data, headers = {}) => { res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store', ...headers }); res.end(JSON.stringify(data)); };
const ok = (res, status, data, headers) => send(res, status, { data, requestId: 'fixture' }, headers);
const fail = (res, status, code) => send(res, status, { error: { code, message: code, retryable: code === 'idempotency_key_in_flight' }, requestId: 'fixture' });
const read = async (req) => { const parts = []; for await (const part of req) parts.push(part); return Buffer.concat(parts); };

export function createStudioUIFixture() {
  let mode = 'normal';
  let record = makeRecord();
  let actionCalls = 0;
  let actionRequests = 0;
  let clockOffset = 0;
  const records = new Map();
  const ledger = { idempotency: {} };
  const now = () => Date.now() + clockOffset;
  const unavailable = (res) => {
    if (mode !== 'disconnected' && mode !== 'error') return false;
    fail(res, 503, mode === 'disconnected' ? 'studio_not_connected' : 'unavailable');
    return true;
  };
  const findRecord = (id) => id === requestId ? record : records.get(id);

  function begin(req, res, rawBody) {
    const key = req.headers['idempotency-key'];
    if (typeof key !== 'string' || !key) { fail(res, 400, 'idempotency_key_required'); return null; }
    if (!IDEMPOTENCY_KEY_PATTERN.test(key)) { fail(res, 400, 'idempotency_key_invalid'); return null; }
    const outcome = reserve(ledger, { deviceId: 'studio_fixture', key, method: req.method, path: req.url,
      fingerprint: requestFingerprint(req.method, req.url, rawBody), now: now(), inflightGraceMs: IDEMPOTENCY_INFLIGHT_GRACE_MS });
    if (outcome.action === 'conflict') { fail(res, 409, 'idempotency_key_conflict'); return null; }
    if (outcome.action === 'in_flight') { fail(res, 409, 'idempotency_key_in_flight'); return null; }
    if (outcome.action === 'unresolved') { fail(res, 409, 'idempotency_outcome_unknown'); return null; }
    if (outcome.action === 'replay') {
      // Studio routes replay a completed ledger entry with the current record.
      if (unavailable(res)) return null;
      const id = JSON.parse(rawBody.toString('utf8')).id;
      const current = findRecord(id);
      if (!current) { fail(res, 404, 'studio_request_missing'); return null; }
      ok(res, outcome.entry.httpStatus, current, { 'idempotency-replayed': 'true' });
      return null;
    }
    return key;
  }
  function finish(res, key, status, data) {
    complete(ledger, { deviceId: 'studio_fixture', key, httpStatus: status, response: data, now: now() });
    ok(res, status, data);
  }

  const api = createServer(async (req, res) => {
    try {
      if (req.url === '/v1/devices/enroll' && req.method === 'POST') {
        req.resume(); ok(res, 201, { deviceId: 'studio_fixture', token: 'fixture-token', scopes: ['studio:read', 'studio:request'] }); return;
      }
      if (req.headers.authorization !== 'Bearer fixture-token') { fail(res, 401, 'unauthorized'); return; }
      if (mode === 'offline') { req.socket.destroy(); return; }
      if (req.url === '/v1/studio/snapshot') {
        if (!unavailable(res)) ok(res, 200, { online: true, accepting: true, lastSeen: stamp, projects: mode === 'empty' ? [] : [project], principles: [], requests: mode === 'empty' ? [] : [record] });
        return;
      }
      if (req.url === '/v1/studio/request-id') { ok(res, 200, { id: randomUUID() }); return; }
      if (req.method === 'POST' && (req.url === '/v1/studio/requests' || req.url === '/v1/studio/action')) {
        const rawBody = await read(req);
        if (req.url === '/v1/studio/action') actionRequests += 1;
        const key = begin(req, res, rawBody);
        if (key === null || unavailable(res)) return;
        const body = JSON.parse(rawBody.toString('utf8'));
        if (req.url === '/v1/studio/requests') {
          const created = { request: body, status: 'queued', bootId: null, updatedAt: stamp, report: null };
          records.set(body.id, created); finish(res, key, 202, created); return;
        }
        actionCalls += 1;
        if (mode === 'action-fail-once') { mode = 'normal'; fail(res, 503, 'studio_not_connected'); return; }
        if (['completed', 'failed', 'stopped', 'interrupted'].includes(record.status)) { fail(res, 409, 'studio_request_finished'); return; }
        if (body.action === 'answer' && record.status !== 'approval') { fail(res, 409, 'studio_approval_changed'); return; }
        record = { ...record, status: body.action === 'stop' ? 'stopped' : 'running', report: { ...record.report, approvals: [] } };
        finish(res, key, 200, record); return;
      }
      if (req.url?.startsWith('/v1/studio/requests/')) {
        if (unavailable(res)) return;
        const found = findRecord(req.url.slice('/v1/studio/requests/'.length));
        if (found) ok(res, 200, found); else fail(res, 404, 'studio_request_missing');
        return;
      }
      fail(res, 404, 'not_found');
    } catch { fail(res, 500, 'fixture_error'); }
  });

  const control = createServer((req, res) => {
    if (req.url === '/health') { res.end('ok'); return; }
    if (req.url === '/reset') {
      mode = 'normal'; record = makeRecord(); actionCalls = 0; actionRequests = 0; clockOffset = 0;
      records.clear(); ledger.idempotency = {}; res.end('ok'); return;
    }
    if (req.url === '/action-count') { res.end(String(actionCalls)); return; }
    if (req.url === '/action-requests') { res.end(String(actionRequests)); return; }
    if (req.url === '/advance-clock/61001') { clockOffset += 61001; res.end('ok'); return; }
    if (req.url?.startsWith('/mode/')) { mode = req.url.slice('/mode/'.length); res.end('ok'); return; }
    res.writeHead(404); res.end();
  });
  return { api, control };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const fixture = createStudioUIFixture();
  fixture.api.listen(19582, '127.0.0.1');
  fixture.control.listen(19583, '127.0.0.1');
}

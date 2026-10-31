// Isolated local mock Bridge for LAAStudioUITests; no real Studio or device state.
import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { IDEMPOTENCY_INFLIGHT_GRACE_MS } from '../../bridge/src/config.mjs';
import { IDEMPOTENCY_KEY_PATTERN, complete, release, requestFingerprint, reserve } from '../../bridge/src/idempotency.mjs';

const projectId = '70175325-5cf4-421f-8a6f-95beae8fca92';
const requestId = '0f6b1c2e-6f1a-4c55-9d43-0d5f6f3b8a11';
const approvalId = '5e2c1c2e-6f1a-4c55-9d43-0d5f6f3b8a11';
const stamp = '2026-10-31T09:00:00Z';
const project = { id: projectId, title: 'サービス紹介資料', revision: 3, pages: [{ id: 'page1', name: 'Cover' }], assets: [], syncedAt: stamp };
const sha = 'a'.repeat(64);
const media = `/api/studio/media/${projectId}/${sha}.png`;
const v2Project = { ...project, pages: [{ id: 'page1', name: 'Cover', preview: media }],
  assets: [{ id: 'model1', name: 'Example model', kind: 'model', preparing: true }] };
const versions = [
  { id: sha, revision: 3, kind: 'image', name: 'Example.png', createdAt: stamp, bytes: 70, media },
  { id: 'b'.repeat(64), revision: 2, kind: 'other', name: 'Website.zip', createdAt: stamp, bytes: 1024, unavailable: 'unsupported_format' },
];
const catalog = { etag: 'c'.repeat(64), updatedAt: stamp,
  principles: [{ id: 'principle1', name: 'Sample', version: '1', revision: 1, status: 'adopted', description: 'Fixture principle',
    colors: [{ name: 'Ink', value: '#222222', rgb: [34, 34, 34] }], fonts: [{ name: 'Body', family: 'System', weight: 400, size: 16 }],
    references: [{ name: 'Sample image', role: 'primary', adoptedElements: '余白', media }], templates: ['Cards'],
    priorities: [{ title: 'Clarity', description: 'Keep the purpose clear.' }] }], adoptedPrincipleId: 'principle1',
  documents: [{ id: 'fixture-document', title: 'Sample document', category: 'Cards', detail: 'Fixture', format: 'PDF',
    driveUrl: 'https://drive.google.com/file/d/1234567890/view', unavailable: 'source_unreadable' }],
  capabilities: [{ id: 'image', title: 'Image', description: 'Sample', prompt: '画像を作ってください。' }], brief: ['用途と相手'] };
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNQUlL6DwACNgFm9i22cwAAAABJRU5ErkJggg==', 'base64');
const makeRecord = () => ({ request: { id: requestId, projectId, expectedRevision: 3, prompt: '新しい紹介資料を作ってください。' }, status: 'approval', bootId: projectId, updatedAt: stamp,
  report: { id: requestId, bootId: projectId, sequence: 1, status: 'approval', text: '構成を確認しています。', approvals: [{ id: approvalId, message: '画面操作を許可しますか。', supported: true, allowSession: true, fields: [] }] } });
const send = (res, status, data, headers = {}) => { res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store', ...headers }); res.end(JSON.stringify(data)); };
const ok = (res, status, data, headers) => send(res, status, { data, requestId: 'fixture' }, headers);
const fail = (res, status, code) => send(res, status, { error: { code, message: code, retryable: ['idempotency_key_in_flight', 'studio_work_busy'].includes(code) }, requestId: 'fixture' });
const read = async (req) => { const parts = []; for await (const part of req) parts.push(part); return Buffer.concat(parts); };

export function createStudioUIFixture() {
  let mode = 'normal';
  let fixtureDeviceId = `studio-${randomUUID()}`;
  let record = makeRecord();
  let actionCalls = 0;
  let actionRequests = 0;
  const createAttempts = [];
  const reviewAttempts = [];
  let clockOffset = 0;
  const records = new Map();
  const reviews = new Map();
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
      const current = req.url === '/v1/studio/reviews' ? reviews.get(id) : findRecord(id);
      if (!current) { fail(res, 404, 'studio_request_missing'); return null; }
      ok(res, req.url === '/v1/studio/reviews' ? 200 : outcome.entry.httpStatus, current, { 'idempotency-replayed': 'true' });
      return null;
    }
    return { deviceId: 'studio_fixture', key, fingerprint: outcome.entry.fingerprint, createdAt: outcome.entry.createdAt };
  }
  function finish(res, key, status, data) {
    complete(ledger, { deviceId: 'studio_fixture', key, httpStatus: status, response: data, now: now() });
    ok(res, status, data);
  }

  const api = createServer(async (req, res) => {
    try {
      if (req.url === '/v1/devices/enroll' && req.method === 'POST') {
        req.resume(); ok(res, 201, { deviceId: fixtureDeviceId, token: 'fixture-token', scopes: ['studio:read', 'studio:request'] }); return;
      }
      if (req.headers.authorization !== 'Bearer fixture-token') { fail(res, 401, 'unauthorized'); return; }
      if (mode === 'offline') { req.socket.destroy(); return; }
      if (req.url === '/v1/studio/snapshot') {
        if (!unavailable(res)) {
          const isV2 = mode.startsWith('v2');
          ok(res, 200, { online: true, accepting: true, lastSeen: stamp, projects: mode === 'empty' ? [] : [isV2 ? v2Project : project],
            principles: isV2 ? catalog.principles : [], requests: mode === 'empty' ? [] : [record], ...(isV2 ? { contract: 2 } : {}) });
        }
        return;
      }
      if (req.url === '/v1/studio/request-id') { ok(res, 200, { id: randomUUID() }); return; }
      if (req.url === '/v1/studio/catalog' && req.method === 'GET') {
        const etag = `"${catalog.etag}"`;
        if (req.headers['if-none-match'] === etag) { res.writeHead(304, { etag, 'cache-control': 'no-store' }); res.end(); }
        else ok(res, 200, catalog, { etag });
        return;
      }
      if (req.url === `/v1/studio/projects/${projectId}` && req.method === 'GET') {
        ok(res, 200, { project: v2Project, versions, delivery: { driveUrl: 'https://drive.google.com/file/d/1234567890/view', revision: 2 },
          reviews: [...reviews.values()].reverse() }); return;
      }
      if (req.url === `/v1/studio/media/${projectId}/${sha}.png` && req.method === 'GET') {
        const match = /^bytes=(\d+)-(\d+)$/.exec(req.headers.range ?? '');
        if (!match || Number(match[1]) >= png.length) { res.writeHead(416, { 'content-range': `bytes */${png.length}` }); res.end(); return; }
        const start = Number(match[1]), end = Math.min(Number(match[2]), png.length - 1);
        res.writeHead(206, { 'content-type': 'image/png', 'content-length': end - start + 1,
          'content-range': `bytes ${start}-${end}/${png.length}`, 'cache-control': 'no-store' });
        res.end(png.subarray(start, end + 1)); return;
      }
      if (req.method === 'POST' && req.url === '/v1/studio/reviews') {
        const rawBody = await read(req);
        reviewAttempts.push({ key: req.headers['idempotency-key'], body: rawBody.toString('utf8') });
        const reservation = begin(req, res, rawBody);
        if (reservation === null || unavailable(res)) return;
        const body = JSON.parse(rawBody.toString('utf8'));
        const previous = reviews.get(body.id);
        const comparable = (value) => JSON.stringify([value.projectId, value.revision, value.target, value.verdict ?? null, value.comment ?? null]);
        if (previous && comparable(previous) !== comparable(body)) {
          release(ledger, reservation); fail(res, 409, 'studio_review_id_conflict'); return;
        }
        const saved = previous ?? { ...body, createdAt: stamp };
        reviews.set(body.id, saved);
        if (mode === 'v2-review-lost') {
          mode = 'v2'; complete(ledger, { deviceId: 'studio_fixture', key: reservation.key, httpStatus: 201, response: saved, now: now() });
          req.socket.destroy(); return;
        }
        finish(res, reservation.key, previous ? 200 : 201, saved); return;
      }
      if (req.method === 'POST' && (req.url === '/v1/studio/requests' || req.url === '/v1/studio/action')) {
        const rawBody = await read(req);
        if (req.url === '/v1/studio/action') actionRequests += 1;
        const reservation = begin(req, res, rawBody);
        if (reservation === null || unavailable(res)) return;
        const body = JSON.parse(rawBody.toString('utf8'));
        if (req.url === '/v1/studio/requests') {
          createAttempts.push({ key: reservation.key, body: rawBody.toString('utf8') });
          if (mode === 'create-busy-once') {
            mode = 'normal'; release(ledger, reservation); fail(res, 409, 'studio_work_busy'); return;
          }
          const created = { request: body, status: 'queued', bootId: null, updatedAt: stamp, report: null };
          records.set(body.id, created); finish(res, reservation.key, 202, created); return;
        }
        actionCalls += 1;
        if (mode === 'action-fail-once') { mode = 'normal'; fail(res, 503, 'studio_not_connected'); return; }
        if (['completed', 'failed', 'stopped', 'interrupted'].includes(record.status)) { fail(res, 409, 'studio_request_finished'); return; }
        if (body.action === 'answer' && record.status !== 'approval') { fail(res, 409, 'studio_approval_changed'); return; }
        record = { ...record, status: body.action === 'stop' ? 'stopped' : 'running', report: { ...record.report, approvals: [] } };
        finish(res, reservation.key, 200, record); return;
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
      mode = 'normal'; fixtureDeviceId = `studio-${randomUUID()}`; record = makeRecord(); actionCalls = 0; actionRequests = 0; clockOffset = 0;
      records.clear(); reviews.clear(); createAttempts.length = 0; reviewAttempts.length = 0; ledger.idempotency = {}; res.end('ok'); return;
    }
    if (req.url === '/action-count') { res.end(String(actionCalls)); return; }
    if (req.url === '/action-requests') { res.end(String(actionRequests)); return; }
    if (req.url === '/create-consistent') {
      res.end(String(createAttempts.length === 2 && createAttempts[0].key === createAttempts[1].key && createAttempts[0].body === createAttempts[1].body)); return;
    }
    if (req.url === '/review-count') { res.end(String(reviews.size)); return; }
    if (req.url === '/review-consistent') {
      res.end(String(reviewAttempts.length === 2 && reviewAttempts[0].key !== reviewAttempts[1].key && reviewAttempts[0].body === reviewAttempts[1].body)); return;
    }
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

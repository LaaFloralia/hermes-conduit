// Isolated local mock Bridge for LAAStudioUITests; no real Studio or device state.
import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';

const projectId = '70175325-5cf4-421f-8a6f-95beae8fca92';
const requestId = '0f6b1c2e-6f1a-4c55-9d43-0d5f6f3b8a11';
const approvalId = '5e2c1c2e-6f1a-4c55-9d43-0d5f6f3b8a11';
const stamp = '2026-10-31T09:00:00Z';
const project = { id: projectId, title: 'サービス紹介資料', revision: 3, pages: [{ id: 'page1', name: 'Cover' }], assets: [], syncedAt: stamp };
const makeRecord = () => ({ request: { id: requestId, projectId, expectedRevision: 3, prompt: '新しい紹介資料を作ってください。' }, status: 'approval', bootId: projectId, updatedAt: stamp,
  report: { id: requestId, bootId: projectId, sequence: 1, status: 'approval', text: '構成を確認しています。', approvals: [{ id: approvalId, message: '画面操作を許可しますか。', supported: true, allowSession: true, fields: [] }] } });
let mode = 'normal';
let record = makeRecord();
let actionCalls = 0;
const records = new Map();
const send = (res, status, data) => { res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' }); res.end(JSON.stringify(data)); };
const ok = (res, status, data) => send(res, status, { data, requestId: 'fixture' });
const fail = (res, status, code) => send(res, status, { error: { code, message: code }, requestId: 'fixture' });
const read = async (req) => { const parts = []; for await (const part of req) parts.push(part); return JSON.parse(Buffer.concat(parts).toString('utf8')); };

createServer(async (req, res) => {
  try {
    if (req.url === '/v1/devices/enroll' && req.method === 'POST') {
      req.resume(); ok(res, 201, { deviceId: 'studio_fixture', token: 'fixture-token', scopes: ['studio:read', 'studio:request'] }); return;
    }
    if (req.headers.authorization !== 'Bearer fixture-token') { fail(res, 401, 'unauthorized'); return; }
    if (mode === 'offline') { req.socket.destroy(); return; }
    if (mode === 'disconnected' || mode === 'error') { fail(res, 503, mode === 'disconnected' ? 'studio_not_connected' : 'unavailable'); return; }
    if (req.url === '/v1/studio/snapshot') {
      ok(res, 200, { online: true, accepting: true, lastSeen: stamp, projects: mode === 'empty' ? [] : [project], principles: [], requests: mode === 'empty' ? [] : [record] }); return;
    }
    if (req.url === '/v1/studio/request-id') { ok(res, 200, { id: randomUUID() }); return; }
    if (req.method === 'POST' && req.url === '/v1/studio/requests') {
      const request = await read(req);
      const created = { request, status: 'queued', bootId: null, updatedAt: stamp, report: null };
      records.set(request.id, created); ok(res, 202, created); return;
    }
    if (req.method === 'POST' && req.url === '/v1/studio/action') {
      const action = await read(req);
      actionCalls += 1;
      if (mode === 'action-fail-once') { mode = 'normal'; fail(res, 503, 'studio_not_connected'); return; }
      record = { ...record, status: action.action === 'stop' ? 'stopped' : 'running', report: { ...record.report, approvals: [] } };
      ok(res, 200, record); return;
    }
    if (req.url?.startsWith('/v1/studio/requests/')) {
      const id = req.url.slice('/v1/studio/requests/'.length);
      const found = id === requestId ? record : records.get(id);
      if (found) ok(res, 200, found); else fail(res, 404, 'studio_request_missing');
      return;
    }
    fail(res, 404, 'not_found');
  } catch { fail(res, 500, 'fixture_error'); }
}).listen(19582, '127.0.0.1');

createServer((req, res) => {
  if (req.url === '/health') { res.end('ok'); return; }
  if (req.url === '/reset') { mode = 'normal'; record = makeRecord(); actionCalls = 0; records.clear(); res.end('ok'); return; }
  if (req.url === '/action-count') { res.end(String(actionCalls)); return; }
  if (req.url?.startsWith('/mode/')) { mode = req.url.slice('/mode/'.length); res.end('ok'); return; }
  res.writeHead(404); res.end();
}).listen(19583, '127.0.0.1');

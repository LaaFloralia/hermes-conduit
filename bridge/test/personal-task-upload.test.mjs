import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { request as httpRequest } from 'node:http';
import { join } from 'node:path';
import { PassThrough } from 'node:stream';
import test from 'node:test';
import { createRejectedUploadDrainer } from '../src/http.mjs';
import { createPersonalLinearSource } from '../src/tasks/personal.mjs';
import { startBridge } from './helpers.mjs';

const owner = { id: 'owner-fixture', name: 'Owner' };
const bytes = Buffer.from('private upload fixture');
const hash = (data) => createHash('sha256').update(data).digest('hex');
const response = (data) => new Response(JSON.stringify({ data }), { status: 200 });
function fixture() {
  const calls = [];
  const config = { uploadURL: 'https://storage.googleapis.com/linear-fixture/upload?signature=secret',
    assetURL: 'https://uploads.linear.app/fixture/file',
    headers: [{ key: 'x-goog-acl', value: 'private' }], failAttachment: false, failPut: false };
  const source = createPersonalLinearSource({ expectedViewerId: owner.id, readToken: async () => 'lin_api_fixture',
    fetchImpl: async (url, options) => {
      calls.push({ url: String(url), options });
      if (String(url).startsWith('https://storage.googleapis.com/')) {
        if (config.failPut === 'lost') throw new Error('private connection loss');
        return new Response(null, { status: config.failPut ? 500 : 200 });
      }
      const { query, variables } = JSON.parse(options.body);
      if (query.includes('LAAPersonalViewer')) return response({ viewer: owner });
      if (query.includes('LAAPersonalIssue(')) return response({ issue: { id: 'issue-1', identifier: 'FIX-1',
        title: 'Fixture', labels: { nodes: [], pageInfo: { hasNextPage: false } } } });
      if (query.includes('LAAPersonalFileUpload')) return response({ fileUpload: { success: true, uploadFile: {
        assetUrl: config.assetURL, uploadUrl: config.uploadURL, headers: config.headers,
      } } });
      if (query.includes('LAAPersonalAttachmentCreate')) {
        if (config.failAttachment === 'rejected') return new Response(JSON.stringify({ data: null, errors: [{
          path: ['attachmentCreate'], extensions: { userError: true, code: 'INPUT_ERROR' },
        }] }), { status: 200 });
        if (config.failAttachment) throw new Error('fixture association response lost');
        return response({ attachmentCreate: { success: true, attachment: { id: variables.input.id } } });
      }
      if (query.includes('LAAPersonalDeleteUpload')) {
        if (config.failCleanup) throw new Error('fixture cleanup failed');
        return response({ fileUploadDangerouslyDelete: { success: true } });
      }
      throw new Error('unexpected fixture operation');
    },
  });
  return { source, config, calls };
}
async function upload(api, token, key, data = bytes, overrides = {}) {
  return fetch(`${api.base}/v1/personal-tasks/FIX-1/files`, { method: 'POST', headers: {
    authorization: `Bearer ${token}`, 'idempotency-key': key,
    'x-linear-viewer-id': owner.id, 'x-linear-file-name': Buffer.from('private note.txt').toString('base64'),
    'x-linear-content-sha256': hash(data), 'content-type': 'text/plain', ...overrides,
  }, body: data }).then(async (r) => ({ status: r.status, body: await r.json() }));
}
const count = (calls, needle) => calls.filter(({ options }) => String(options.body).includes(needle)).length;

test('streamed file is scoped, digest-bound and replayed without another upload', async (t) => {
  const { source, calls } = fixture();
  const api = await startBridge({ tasks: { personal: source } }); t.after(() => api.close());
  const token = await api.token(['tasks:read', 'tasks:write']);
  const reader = await api.token(['tasks:read']);
  assert.equal((await upload(api, reader, 'no-write')).status, 403);
  assert.equal((await upload(api, token, 'bad-hash', bytes, { 'x-linear-content-sha256': '0'.repeat(64) })).status, 400);
  assert.equal((await upload(api, token, 'wrong-viewer', bytes, { 'x-linear-viewer-id': 'someone-else' })).status, 409);
  assert.equal(count(calls, 'LAAPersonalFileUpload'), 0);
  const first = await upload(api, token, 'upload-key');
  assert.equal(first.status, 201);
  assert.equal(first.body.data.operation.kind, 'file');
  const put = calls.find(({ options }) => options.method === 'PUT');
  assert.deepEqual(put.options.body, bytes);
  assert.equal(put.options.redirect, 'manual');
  assert.equal(put.options.headers.authorization, undefined);
  assert.equal(put.options.headers['x-goog-acl'], 'private');
  assert.equal(put.options.headers['cache-control'], undefined);
  await api.restart();
  assert.equal((await upload(api, token, 'upload-key')).status, 200);
  assert.equal((await upload(api, token, 'upload-key', Buffer.from('changed'))).body.error.code, 'idempotency_key_conflict');
  assert.equal(count(calls, 'LAAPersonalFileUpload'), 1);
  assert.equal(count(calls, 'LAAPersonalAttachmentCreate'), 1);
  const ledger = readFileSync(join(api.stateDir, 'task-operations.json'), 'utf8');
  assert.doesNotMatch(ledger, /private note|private upload fixture|signature=secret/);
});

test('incomplete and oversized streams do not reserve or attach a file; failed PUT is rejected', async (t) => {
  const { source, config, calls } = fixture();
  const api = await startBridge({ tasks: { personal: source } }); t.after(() => api.close());
  const token = await api.token(['tasks:read', 'tasks:write']);
  const headers = { authorization: `Bearer ${token}`, 'idempotency-key': 'interrupted',
    'x-linear-viewer-id': owner.id, 'x-linear-file-name': Buffer.from('fixture.txt').toString('base64'),
    'x-linear-content-sha256': hash(bytes), 'content-type': 'text/plain', 'content-length': String(bytes.length * 2) };
  await new Promise((resolve) => {
    const req = httpRequest(`${api.base}/v1/personal-tasks/FIX-1/files`, { method: 'POST', headers });
    req.on('error', resolve);
    req.flushHeaders(); req.write(bytes);
    setTimeout(() => req.destroy(), 25);
  });
  await new Promise((resolve) => setTimeout(resolve, 50));
  const lookup = await fetch(`${api.base}/v1/task-operations/by-key`, { headers: {
    authorization: `Bearer ${token}`, 'idempotency-key': 'interrupted',
  } });
  assert.equal(lookup.status, 404);
  assert.equal(count(calls, 'LAAPersonalFileUpload'), 0);
  config.failPut = true;
  assert.equal((await upload(api, token, 'failed-put')).status, 503);
  assert.equal((await upload(api, token, 'failed-put')).body.error.code, 'task_operation_rejected');
  config.failPut = 'lost';
  const lost = await upload(api, token, 'lost-put');
  assert.equal(lost.status, 503); assert.equal(lost.body.error.retryable, false);
  assert.equal((await upload(api, token, 'lost-put')).body.error.code, 'task_operation_rejected');
  assert.equal(count(calls, 'LAAPersonalAttachmentCreate'), 0);
});

test('an ambiguous association never repeats; upload target and returned headers are constrained', async (t) => {
  const { source, config, calls } = fixture();
  const api = await startBridge({ tasks: { personal: source } }); t.after(() => api.close());
  const token = await api.token(['tasks:read', 'tasks:write']);
  config.uploadURL = 'https://evil.test/collect';
  assert.equal((await upload(api, token, 'unsafe-host')).status, 503);
  assert.equal(calls.some(({ url }) => url.includes('evil.test')), false);
  config.uploadURL = 'https://storage.googleapis.com/linear-fixture/upload?signature=secret';
  config.headers = [{ key: 'authorization', value: 'unexpected' }];
  assert.equal((await upload(api, token, 'unsafe-header')).status, 503);
  assert.equal(calls.some(({ options }) => options.method === 'PUT'), false);
  config.headers = [{ key: 'x-goog-acl', value: 'private' }];
  config.failAttachment = true;
  const uncertain = await upload(api, token, 'unknown');
  assert.equal(uncertain.body.error.code, 'idempotency_outcome_unknown');
  assert.equal((await upload(api, token, 'unknown')).body.error.code, 'idempotency_outcome_unknown');
  assert.equal(count(calls, 'LAAPersonalAttachmentCreate'), 1);
  assert.equal(calls.filter(({ options }) => options.method === 'PUT').length, 1);
});


// Real socket clients stream the entire body, exercising backpressure and the
// response that previously arrived as ECONNRESET for large uploads.
function streamLarge(api, token, key, size = 20 * 1024 * 1024, delayMs = 0) {
  return new Promise((resolve, reject) => {
    const headers = { authorization: `Bearer ${token}`, 'idempotency-key': key,
      'x-linear-viewer-id': owner.id, 'x-linear-file-name': Buffer.from('fixture.txt').toString('base64'),
      'x-linear-content-sha256': '0'.repeat(64), 'content-type': 'text/plain', 'content-length': String(size) };
    const req = httpRequest(`${api.base}/v1/personal-tasks/FIX-1/files`, { method: 'POST', headers }, (res) => {
      const parts = []; res.on('data', (part) => parts.push(part));
      res.on('end', () => resolve({ status: res.statusCode, body: JSON.parse(Buffer.concat(parts)) }));
      res.on('error', reject);
    });
    req.on('error', reject);
    const chunk = Buffer.alloc(delayMs ? 1024 * 1024 : 64 * 1024); let sent = 0;
    function write() {
      while (sent < size) {
        const remaining = Math.min(chunk.length, size - sent); sent += remaining;
        const ready = req.write(chunk.subarray(0, remaining));
        if (delayMs) {
          const next = () => setTimeout(write, delayMs);
          if (ready) next(); else req.once('drain', next);
          return;
        }
        if (!ready) { req.once('drain', write); return; }
      }
      req.end();
    }
    write();
  });
}

test('rejected large uploads drain before returning 413, 429, 401 and 403', async (t) => {
  const { source } = fixture();
  let entered = 0, notify;
  const waiting = new Promise((resolve) => { notify = resolve; });
  let release;
  const blocked = new Promise((resolve) => { release = resolve; });
  const originalSession = source.session;
  source.session = async (...args) => { entered++; if (entered === 2) notify(); await blocked; return originalSession(...args); };
  const api = await startBridge({ tasks: { personal: source } });
  t.after(async () => { release(); await api.close(); });
  const writer = await api.token(['tasks:read', 'tasks:write']);
  const reader = await api.token(['tasks:read']);
  for (const [token, size, status] of [[writer, 20 * 1024 * 1024 + 1, 413], ['bad-token', 20 * 1024 * 1024, 401], [reader, 20 * 1024 * 1024, 403]]) {
    const result = await streamLarge(api, token, `large-${status}`, size);
    assert.equal(result.status, status);
  }
  // Two legitimate requests occupy the upload slots while their sessions wait.
  const held = [streamLarge(api, writer, 'held-one'), streamLarge(api, writer, 'held-two')];
  await waiting;
  assert.equal((await streamLarge(api, writer, 'large-429')).status, 429);
  release(); await Promise.all(held);
});

test('slow rejected 20 MiB upload receives the HTTP error', async (t) => {
  const { source } = fixture();
  const api = await startBridge({ tasks: { personal: source } }); t.after(() => api.close());
  const started = Date.now();
  const result = await streamLarge(api, 'bad-token', 'slow-401', 20 * 1024 * 1024, 150);
  assert.equal(result.status, 401);
  assert.ok(Date.now() - started >= 2500);
});

test('rejected drain bounds time and bytes without destroying the request before response', async () => {
  const drain = createRejectedUploadDrainer({ timeoutMs: 20 });
  const timed = new PassThrough();
  const timedResult = drain(timed);
  // The timer is unref'd, so keep the test process alive while it expires.
  const keeper = setTimeout(() => {}, 100);
  assert.equal(await timedResult, 'limit'); clearTimeout(keeper);
  assert.equal(timed.destroyed, false);
  const byteDrain = createRejectedUploadDrainer();
  const oversized = new PassThrough();
  const byteResult = byteDrain(oversized);
  oversized.write(Buffer.alloc(32 * 1024 * 1024 + 1));
  assert.equal(await byteResult, 'limit');
  assert.equal(oversized.destroyed, false);
  timed.destroy(); oversized.destroy();
});

function heldUpload(api, token, key, length) {
  let req, responded = false;
  const finished = new Promise((resolve, reject) => {
    req = httpRequest(`${api.base}/v1/personal-tasks/FIX-1/files`, { method: 'POST', headers: {
      authorization: `Bearer ${token}`, 'idempotency-key': key, 'x-linear-viewer-id': owner.id,
      'x-linear-file-name': Buffer.from('fixture.txt').toString('base64'),
      'x-linear-content-sha256': '0'.repeat(64), 'content-type': 'text/plain', 'content-length': String(length),
    } }, (res) => {
      responded = true; const parts = [];
      res.on('data', (part) => parts.push(part));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: JSON.parse(Buffer.concat(parts)) }));
      res.on('error', reject);
    });
    req.on('error', (error) => { if (!responded) reject(error); });
    req.flushHeaders(); req.write('x');
  });
  finished.catch(() => {});
  const closed = new Promise((resolve) => req.once('close', resolve));
  return { req, finished, closed };
}

test('real Bridge returns 413 on the fifth rejected upload before closing it', { timeout: 10000 }, async (t) => {
  const { source } = fixture();
  const drain = createRejectedUploadDrainer();
  let entered = 0, ready;
  const fourEntered = new Promise((resolve) => { ready = resolve; });
  const observed = (req) => {
    const result = drain(req);
    if (++entered === 4) ready();
    return result;
  };
  const api = await startBridge({ tasks: { personal: source }, rejectedUploadDrainer: observed });
  const writer = await api.token(['tasks:read', 'tasks:write']);
  const held = Array.from({ length: 4 }, (_, i) => heldUpload(api, 'invalid-token', `held-${i}`, 4));
  t.after(async () => { held.forEach(({ req }) => req.destroy()); await api.close(); });
  await fourEntered;
  const excess = heldUpload(api, writer, 'fifth-too-large', 20 * 1024 * 1024 + 1);
  t.after(() => excess.req.destroy());
  const response = await excess.finished;
  assert.equal(response.status, 413);
  assert.equal(response.body.error.code, 'file_too_large');
  assert.equal(response.headers.connection, 'close');
  await excess.closed;
  held.forEach(({ req }) => req.end('yyy'));
  assert.deepEqual((await Promise.all(held.map(({ finished }) => finished))).map((r) => r.status), [401, 401, 401, 401]);
  const replacement = heldUpload(api, 'invalid-token', 'replacement', 4);
  replacement.req.end('yyy');
  assert.equal((await replacement.finished).status, 401);
});

test('real Bridge returns the refusal at the rejected drain time and byte limits', { timeout: 10000 }, async (t) => {
  const { source } = fixture();
  const api = await startBridge({ tasks: { personal: source },
    rejectedUploadDrainer: createRejectedUploadDrainer({ timeoutMs: 50, maxBytes: 1024 }) });
  t.after(() => api.close());
  const writer = await api.token(['tasks:read', 'tasks:write']);
  const slow = heldUpload(api, writer, 'slow-limit', 20 * 1024 * 1024 + 1);
  t.after(() => slow.req.destroy());
  assert.equal((await slow.finished).status, 413);
  const tooMany = heldUpload(api, writer, 'bytes-limit', 40 * 1024 * 1024);
  t.after(() => tooMany.req.destroy());
  tooMany.req.write(Buffer.alloc(1024));
  const response = await tooMany.finished;
  assert.equal(response.status, 413);
  assert.equal(response.headers.connection, 'close');
});

test('real Bridge returns 413 after more than 32 MiB of a rejected upload', { timeout: 10000 }, async (t) => {
  const { source } = fixture();
  const api = await startBridge({ tasks: { personal: source } });
  t.after(() => api.close());
  const writer = await api.token(['tasks:read', 'tasks:write']);
  const upload = heldUpload(api, writer, 'default-byte-limit', 40 * 1024 * 1024);
  t.after(() => upload.req.destroy());
  upload.req.write(Buffer.alloc(32 * 1024 * 1024));
  const response = await upload.finished;
  assert.equal(response.status, 413);
  assert.equal(response.headers.connection, 'close');
});

test('definite attachment refusal attempts hashed-audit cleanup; unknown never deletes', async (t) => {
  const { source, config, calls } = fixture();
  const api = await startBridge({ tasks: { personal: source } }); t.after(() => api.close());
  const token = await api.token(['tasks:read', 'tasks:write']);
  config.failAttachment = 'rejected'; config.failCleanup = true;
  assert.equal((await upload(api, token, 'cleanup-refusal')).body.error.code, 'linear_rejected');
  assert.equal((await upload(api, token, 'cleanup-refusal')).body.error.code, 'task_operation_rejected');
  assert.equal(count(calls, 'LAAPersonalDeleteUpload'), 1);
  const ledger = readFileSync(join(api.stateDir, 'task-operations.json'), 'utf8');
  assert.match(ledger, new RegExp(hash(Buffer.from(config.assetURL))));
  assert.doesNotMatch(ledger, /uploads\.linear\.app|private note|signature=secret/);
  config.failAttachment = true; config.failCleanup = false;
  assert.equal((await upload(api, token, 'unknown-cleanup')).body.error.code, 'idempotency_outcome_unknown');
  assert.equal(count(calls, 'LAAPersonalDeleteUpload'), 1);
  config.failAttachment = 'rejected';
  assert.equal((await upload(api, token, 'cleaned-refusal')).body.error.code, 'linear_rejected');
  const cleanups = calls.filter(({ options }) => String(options.body).includes('LAAPersonalDeleteUpload'));
  assert.equal(cleanups.length, 2);
  assert.equal(JSON.parse(cleanups[1].options.body).variables.assetUrl, config.assetURL);
});

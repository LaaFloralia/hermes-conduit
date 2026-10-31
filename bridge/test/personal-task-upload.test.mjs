import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { request as httpRequest } from 'node:http';
import { join } from 'node:path';
import test from 'node:test';
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
        if (config.failAttachment) throw new Error('fixture association response lost');
        return response({ attachmentCreate: { success: true, attachment: { id: variables.input.id } } });
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
  const tooLarge = await new Promise((resolve, reject) => {
    const req = httpRequest(`${api.base}/v1/personal-tasks/FIX-1/files`, { method: 'POST',
      headers: { ...headers, 'idempotency-key': 'oversized', 'content-length': String(20 * 1024 * 1024 + 1) } },
    (res) => { res.resume(); res.on('end', () => resolve(res.statusCode)); });
    req.on('error', reject); req.end();
  });
  assert.equal(tooLarge, 413);
  config.failPut = true;
  assert.equal((await upload(api, token, 'failed-put')).status, 503);
  assert.equal((await upload(api, token, 'failed-put')).body.error.code, 'task_operation_rejected');
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

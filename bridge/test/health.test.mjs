import assert from 'node:assert/strict';
import test from 'node:test';
import { startBridge } from './helpers.mjs';

test('health is public and exposes version and uptime only', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const res = await api.request('/v1/health');
  assert.equal(res.status, 200);
  assert.deepEqual(Object.keys(res.body.data).sort(), ['uptimeSeconds', 'version']);
  assert.equal(res.body.data.version, '0.1.0');
  assert.ok(res.body.data.uptimeSeconds >= 0);
  assert.match(res.body.requestId, /^req_[0-9a-f]{16}$/);
  assert.equal(res.headers.get('cache-control'), 'no-store');
  assert.equal(res.headers.get('x-request-id'), res.body.requestId);
});

test('unknown path and wrong method use the error envelope', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());

  const missing = await api.request('/v1/nope');
  assert.equal(missing.status, 404);
  assert.deepEqual(missing.body.error, {
    code: 'not_found',
    message: 'no such endpoint',
    retryable: false,
  });
  assert.match(missing.body.requestId, /^req_/);

  const wrongMethod = await api.request('/v1/me', { method: 'DELETE' });
  assert.equal(wrongMethod.status, 405);
  assert.equal(wrongMethod.body.error.code, 'method_not_allowed');
});

test('a foreign Origin header is rejected', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const res = await api.request('/v1/health', { headers: { origin: 'https://evil.example' } });
  assert.equal(res.status, 403);
  assert.equal(res.body.error.code, 'origin_rejected');
});

test('the idempotency test endpoint is hidden unless test endpoints are enabled', async (t) => {
  const api = await startBridge({ testEndpoints: false });
  t.after(() => api.close());
  const paired = await api.pair();
  const enrolled = await api.enroll(paired.code);
  const res = await api.request('/v1/_test/echo', {
    method: 'POST',
    token: enrolled.body.data.token,
    key: 'k1',
    body: { hello: 'world' },
  });
  assert.equal(res.status, 404);
  assert.equal(res.body.error.code, 'not_found');
});

test('an oversized body is refused before it is parsed', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const paired = await api.pair();
  const enrolled = await api.enroll(paired.code);
  const res = await api.request('/v1/_test/echo', {
    method: 'POST',
    token: enrolled.body.data.token,
    key: 'big',
    body: JSON.stringify({ padding: 'x'.repeat(70 * 1024) }),
  });
  assert.equal(res.status, 400);
  assert.equal(res.body.error.code, 'payload_too_large');
});

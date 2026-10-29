import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { DEFAULT_SCOPES } from '../src/config.mjs';
import { revokeDevice } from '../src/pairing.mjs';
import { hashToken } from '../src/auth.mjs';
import { startBridge } from './helpers.mjs';

test('requests without a bearer token are 401 unauthenticated', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const res = await api.request('/v1/me');
  assert.equal(res.status, 401);
  assert.equal(res.body.error.code, 'unauthenticated');
  assert.equal(res.body.error.retryable, false);

  const malformed = await api.request('/v1/me', { headers: { authorization: 'Basic abc' } });
  assert.equal(malformed.status, 401);
  assert.equal(malformed.body.error.code, 'unauthenticated');
});

test('an unknown token is 401 invalid_token', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const res = await api.request('/v1/me', { token: 'A'.repeat(43) });
  assert.equal(res.status, 401);
  assert.equal(res.body.error.code, 'invalid_token');
});

test('pair then enroll grants the section 9 scopes and /v1/me reports the device', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());

  const paired = await api.pair();
  assert.match(paired.code, /^[2-9A-Z]{4}-[2-9A-Z]{4}$/);

  const enrolled = await api.enroll(paired.code, 'iPhone (test)');
  assert.equal(enrolled.status, 201);
  assert.match(enrolled.body.data.deviceId, /^dev_[0-9a-f]{16}$/);
  assert.ok(enrolled.body.data.token.length >= 40);
  assert.deepEqual(enrolled.body.data.scopes, [...DEFAULT_SCOPES]);

  const me = await api.request('/v1/me', { token: enrolled.body.data.token });
  assert.equal(me.status, 200);
  assert.equal(me.body.data.deviceId, enrolled.body.data.deviceId);
  assert.equal(me.body.data.name, 'iPhone (test)');
  assert.deepEqual(me.body.data.scopes, [...DEFAULT_SCOPES]);
  // Section 9 keeps these ungranted until their own gates are met.
  for (const withheld of ['brain:write', 'gui:operate', 'archives:restore', 'devices:admin']) {
    assert.ok(!me.body.data.scopes.includes(withheld), `${withheld} must not be granted by default`);
  }
});

test('a pairing code is single use', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const paired = await api.pair();
  assert.equal((await api.enroll(paired.code)).status, 201);
  const second = await api.enroll(paired.code);
  assert.equal(second.status, 401);
  assert.equal(second.body.error.code, 'pairing_code_used');
});

test('an expired pairing code is refused', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const paired = await api.pair({ ttlMs: -1000 });
  const res = await api.enroll(paired.code);
  assert.equal(res.status, 401);
  assert.equal(res.body.error.code, 'pairing_code_expired');
});

test('an unknown pairing code is refused', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const res = await api.enroll('ZZZZ-ZZZZ');
  assert.equal(res.status, 401);
  assert.equal(res.body.error.code, 'pairing_code_invalid');
});

test('a revoked device is 401 token_revoked', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const paired = await api.pair();
  const { deviceId, token } = (await api.enroll(paired.code)).body.data;
  assert.equal((await api.request('/v1/me', { token })).status, 200);

  const revoked = revokeDevice(api.store, { target: deviceId, reason: 'test' });
  assert.equal(revoked.alreadyRevoked, false);

  const after = await api.request('/v1/me', { token });
  assert.equal(after.status, 401);
  assert.equal(after.body.error.code, 'token_revoked');

  // Revoking twice is not an error, but never resurrects the device.
  assert.equal(revokeDevice(api.store, { target: deviceId }).alreadyRevoked, true);
  assert.equal((await api.request('/v1/me', { token })).body.error.code, 'token_revoked');
});

test('a device without the required scope is 403 insufficient_scope', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const paired = await api.pair({ scopes: ['sessions:read'] });
  const { token } = (await api.enroll(paired.code)).body.data;

  const res = await api.request('/v1/_test/echo', { method: 'POST', token, key: 'k1', body: { a: 1 } });
  assert.equal(res.status, 403);
  assert.equal(res.body.error.code, 'insufficient_scope');
  assert.match(res.body.error.message, /sessions:write/);

  // The same device may still use endpoints that need no scope.
  assert.equal((await api.request('/v1/me', { token })).status, 200);
});

test('the state file keeps only the token hash', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const paired = await api.pair();
  const { token } = (await api.enroll(paired.code)).body.data;

  const raw = readFileSync(join(api.stateDir, 'state.json'), 'utf8');
  assert.ok(!raw.includes(token), 'plaintext token must never be stored');
  assert.ok(raw.includes(hashToken(token)), 'the token hash must be stored');
});

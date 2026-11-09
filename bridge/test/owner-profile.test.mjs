import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { startBridge } from './helpers.mjs';
import { OWNER_AVATAR_MAX_BYTES } from '../src/routes/owner-profile.mjs';

const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');
const JPEG = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(64, 7), Buffer.from([0xff, 0xd9])]);
const body = (bytes, contentType) => ({ contentType, data: bytes.toString('base64') });

test('owner avatar: unset, set, conditional read, replace and remove', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const token = await api.token(['sessions:read', 'sessions:write']);
  const path = '/v1/owner/avatar';

  const missing = await api.request(path, { token });
  assert.equal(missing.status, 404);
  assert.equal(missing.body.error.code, 'owner_avatar_not_set');

  const saved = await api.request(path, { method: 'PUT', token, body: body(PNG, 'image/png') });
  assert.equal(saved.status, 200);
  assert.equal(saved.body.data.contentType, 'image/png');
  assert.equal(saved.body.data.size, PNG.length);
  assert.equal(saved.headers.get('etag'), saved.body.data.etag);
  const file = join(api.stateDir, 'owner-avatar.img');
  assert.deepEqual(readFileSync(file), PNG);
  assert.equal(statSync(file).mode & 0o777, 0o600);
  // The atomic write leaves no temporary file behind.
  assert.deepEqual(readdirSync(api.stateDir).filter((name) => name.startsWith('owner-avatar')), ['owner-avatar.img']);

  const read = await api.request(path, { token });
  assert.equal(read.status, 200);
  assert.equal(read.body.data.data, PNG.toString('base64'));
  assert.equal(read.body.data.etag, saved.body.data.etag);
  assert.equal(read.headers.get('etag'), saved.body.data.etag);

  const unchanged = await fetch(`${api.base}${path}`, { headers: { authorization: `Bearer ${token}`, 'if-none-match': saved.body.data.etag } });
  assert.equal(unchanged.status, 304);
  assert.equal(unchanged.headers.get('etag'), saved.body.data.etag);
  assert.equal(await unchanged.text(), '');

  const replaced = await api.request(path, { method: 'PUT', token, body: body(JPEG, 'image/jpeg') });
  assert.equal(replaced.status, 200);
  assert.notEqual(replaced.body.data.etag, saved.body.data.etag);
  const stale = await api.request(path, { token, headers: { 'if-none-match': saved.body.data.etag } });
  assert.equal(stale.status, 200);
  assert.equal(stale.body.data.contentType, 'image/jpeg');

  const removed = await api.request(path, { method: 'DELETE', token });
  assert.deepEqual([removed.status, removed.body.data.removed], [200, true]);
  assert.equal(existsSync(file), false);
  assert.equal((await api.request(path, { token })).status, 404);
  const again = await api.request(path, { method: 'DELETE', token });
  assert.deepEqual([again.status, again.body.data.removed], [200, false]);
});

test('owner avatar: scopes and authentication', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const path = '/v1/owner/avatar';
  const readOnly = await api.token(['sessions:read']);
  const none = await api.token(['tasks:read']);
  assert.equal((await api.request(path)).status, 401);
  assert.equal((await api.request(path, { token: none })).status, 403);
  assert.equal((await api.request(path, { token: readOnly })).status, 404);
  assert.equal((await api.request(path, { method: 'PUT', token: readOnly, body: body(PNG, 'image/png') })).status, 403);
  assert.equal((await api.request(path, { method: 'DELETE', token: readOnly })).status, 403);
  assert.equal(existsSync(join(api.stateDir, 'owner-avatar.img')), false);
});

test('owner avatar: refuses other formats, mislabelled bytes, oversize images and extra fields', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const token = await api.token(['sessions:read', 'sessions:write']);
  const path = '/v1/owner/avatar';
  const put = (payload) => api.request(path, { method: 'PUT', token, body: payload });

  assert.equal((await put(body(PNG, 'image/gif'))).status, 415);
  assert.equal((await put(body(PNG, 'image/jpeg'))).body.error.code, 'image_invalid');
  assert.equal((await put({ contentType: 'image/png', data: 'not base64!' })).status, 400);
  assert.equal((await put({ ...body(PNG, 'image/png'), name: 'x' })).status, 400);
  const big = Buffer.concat([PNG.subarray(0, 8), Buffer.alloc(OWNER_AVATAR_MAX_BYTES, 1)]);
  assert.equal((await put(body(big, 'image/png'))).status, 413);
  const exact = Buffer.concat([JPEG.subarray(0, 4), Buffer.alloc(OWNER_AVATAR_MAX_BYTES - 4, 1)]);
  assert.equal((await put(body(exact, 'image/jpeg'))).status, 200);
  // Nothing refused replaced the stored image.
  assert.equal(readFileSync(join(api.stateDir, 'owner-avatar.img')).length, OWNER_AVATAR_MAX_BYTES);
});

test('owner avatar: a foreign file in its place is not served as the owner', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const token = await api.token(['sessions:read', 'sessions:write']);
  writeFileSync(join(api.stateDir, 'owner-avatar.img'), 'plain text');
  const read = await api.request('/v1/owner/avatar', { token });
  assert.equal(read.status, 503);
  assert.equal(read.body.error.code, 'owner_avatar_unavailable');
  // The owner can still replace it.
  assert.equal((await api.request('/v1/owner/avatar', { method: 'PUT', token, body: body(PNG, 'image/png') })).status, 200);
});

import assert from 'node:assert/strict';
import test from 'node:test';
import { generateKeyPairSync, createVerify } from 'node:crypto';
import { statSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createPhoneUse } from '../src/phone-use/service.mjs';
import { apnsJwt, apnsSenderFromEnv } from '../src/phone-use/apns.mjs';
import { phoneUseCommand } from '../src/cli-phone-use.mjs';
import { startBridge } from './helpers.mjs';

const START = 'ab'.repeat(32), ACTIVITY = 'cd'.repeat(32);

async function fixture(t) {
  let time = Date.parse('2026-11-12T00:00:00Z');
  const now = () => time;
  const h = await startBridge({ now });
  t.after(() => h.close());
  const pushes = [];
  const devices = (id) => h.store.read().devices[id] ?? null;
  const cli = createPhoneUse({ dir: h.stateDir, now, devices, push: async (p) => { pushes.push(p); return { status: 200 }; } });
  // A paired device of the given platform, as the app enrolls.
  const device = async (platform = 'ios', scopes = ['sessions:read', 'sessions:write']) => {
    const paired = await h.pair({ scopes });
    const enrolled = await h.request('/v1/devices/enroll', { method: 'POST', body: { code: paired.code, name: 'iPhone', platform } });
    return { token: enrolled.body.data.token, id: enrolled.body.data.deviceId };
  };
  const iphone = await device();
  return { h, cli, pushes, phone: iphone.token, phoneId: iphone.id, device, devices, now, advance: (ms) => { time += ms; } };
}
const register = (f, token = f.phone) => f.h.request('/v1/phone-use/start-token', { method: 'PUT', token, body: { token: START, environment: 'production' } });
const answer = (f, id, value, token = f.phone) => f.h.request(`/v1/phone-use/requests/${id}/answer`, { method: 'POST', token, body: { answer: value } });

test('ask before the phone registered: not_registered, nothing pushed', async (t) => {
  const f = await fixture(t);
  const r = await f.cli.ask({ who: 'Claude', purpose: '設定の確認' });
  assert.deepEqual([r.ok, r.error, f.pushes.length], [false, 'not_registered', 0]);
});

test('start token needs sessions:write and a hex token; file is private', async (t) => {
  const f = await fixture(t);
  const reader = (await f.device('ios', ['sessions:read'])).token;
  assert.equal((await register(f, reader)).status, 403);
  assert.equal((await register(f, (await f.device('macos')).token)).body.error.code, 'phone_use_not_iphone');
  assert.equal((await f.h.request('/v1/phone-use/start-token', { method: 'PUT', token: f.phone, body: { token: 'zz', environment: 'production' } })).status, 400);
  assert.equal((await f.h.request('/v1/phone-use/start-token', { method: 'PUT', token: f.phone, body: { token: START, environment: 'staging' } })).status, 400);
  assert.equal((await register(f)).status, 200);
  assert.equal(statSync(f.cli.file).mode & 0o777, 0o600);
});

test('allow: push-to-start payload, owner allows, operating until end, end push sent once', async (t) => {
  const f = await fixture(t);
  await register(f);
  const asked = await f.cli.ask({ who: 'Claude｜iPhone Use', purpose: 'LAAアプリの\n表示確認', timeoutMs: 60_000 });
  assert.equal(asked.ok, true);
  const id = asked.request.id;
  assert.match(id, /^pu_[0-9a-f]{16}$/);
  const [start] = f.pushes;
  assert.equal(start.kind, 'start'); assert.equal(start.token, START); assert.equal(start.environment, 'production');
  assert.equal(start.payload.aps.event, 'start');
  assert.equal(start.payload.aps['attributes-type'], 'LAAPhoneUseAttributes');
  assert.deepEqual(start.payload.aps.attributes, { requestID: id, who: 'Claude｜iPhone Use', purpose: 'LAAアプリの 表示確認', answerBy: (f.now() + 60_000) / 1000 });
  assert.deepEqual(start.payload.aps['content-state'], { phase: 'ask' });
  assert.equal(start.payload.aps['input-push-token'], 1);
  assert.equal(start.payload.aps.alert.body, 'Claude｜iPhone Use：LAAアプリの 表示確認');

  assert.equal((await f.h.request(`/v1/phone-use/requests/${id}/activity-token`, { method: 'PUT', token: f.phone, body: { token: ACTIVITY } })).status, 200);
  const waiting = f.cli.waitForAnswer(id, { pollMs: 1 });
  const allowed = await answer(f, id, 'allow');
  assert.equal(allowed.status, 200); assert.equal(allowed.body.data.status, 'allowed');
  assert.equal((await waiting).status, 'allowed');
  assert.equal((await answer(f, id, 'allow')).status, 409);
  assert.equal((await f.cli.ask({ who: 'Other', purpose: 'x' })).error, 'busy');

  const ended = await f.cli.end(id);
  assert.equal(ended.status, 'ended'); assert.equal(ended.endPush, 'sent');
  const end = f.pushes.at(-1);
  assert.deepEqual([end.kind, end.token, end.payload.aps.event, end.payload.aps['content-state'].phase], ['end', ACTIVITY, 'end', 'ended']);
  assert.equal((await f.cli.end(id)).endPush, 'already_ended');
  assert.equal(f.pushes.length, 2);
  assert.equal((await answer(f, id, 'stop')).status, 409);
});

test('deny and stop close the request; another device cannot answer', async (t) => {
  const f = await fixture(t);
  await register(f);
  const other = (await f.device()).token;
  assert.equal((await register(f, other)).body.error.code, 'phone_use_device_pinned', 'the first iPhone keeps the place');
  const a = (await f.cli.ask({ who: 'GPT', purpose: '確認' })).request.id;
  assert.equal((await answer(f, a, 'allow', other)).status, 403);
  assert.equal((await answer(f, a, 'stop')).status, 409, 'stop only while operating');
  assert.equal((await answer(f, a, 'deny')).body.data.status, 'denied');
  assert.equal((await f.cli.waitForAnswer(a, { pollMs: 1 })).status, 'denied');

  const b = (await f.cli.ask({ who: 'GPT', purpose: '確認' })).request.id;
  await answer(f, b, 'allow');
  assert.equal((await answer(f, b, 'stop')).body.data.status, 'stopped');
  assert.equal(f.cli.status(b).status, 'stopped');

  // The phone reads its own requests (to take down an activity no end push reached), only its own.
  const read = (token) => f.h.request(`/v1/phone-use/requests/${b}`, { token });
  assert.deepEqual([(await read(f.phone)).status, (await read(f.phone)).body.data.status], [200, 'stopped']);
  assert.equal((await read(other)).status, 403);
  assert.equal((await f.h.request('/v1/phone-use/requests/pu_0000000000000000', { token: f.phone })).body.error.code, 'phone_use_not_found');
});

test('no answer: expires at answerBy, the wait ends the activity; allowed one ends at its limit', async (t) => {
  const f = await fixture(t);
  await register(f);
  const id = (await f.cli.ask({ who: 'DeepSeek', purpose: '確認', timeoutMs: 10_000 })).request.id;
  await f.h.request(`/v1/phone-use/requests/${id}/activity-token`, { method: 'PUT', token: f.phone, body: { token: ACTIVITY } });
  const result = await f.cli.waitForAnswer(id, { sleep: async () => f.advance(5_000) });
  assert.equal(result.status, 'expired');
  assert.equal(f.pushes.at(-1).payload.aps['content-state'].phase, 'expired');
  assert.equal((await answer(f, id, 'allow')).status, 409);

  const b = (await f.cli.ask({ who: 'DeepSeek', purpose: '確認', limitMs: 60_000 })).request.id;
  await answer(f, b, 'allow');
  f.advance(61_000);
  assert.equal(f.cli.status(b).status, 'ended');
  assert.equal((await f.cli.ask({ who: 'DeepSeek', purpose: '次' })).ok, true, 'a lapsed session does not block the next ask');
});

test('a revoked iPhone is never asked and cannot answer; reset hands the place over', async (t) => {
  const f = await fixture(t);
  await register(f);
  const id = (await f.cli.ask({ who: 'Claude', purpose: '確認' })).request.id;
  f.h.store.mutate((s) => { s.devices[f.phoneId].revokedAt = new Date(f.now()).toISOString(); });
  assert.equal((await answer(f, id, 'allow')).status, 401, 'a revoked token is refused before the route');
  assert.equal(f.cli.answer.length, 1);
  assert.throws(() => f.cli.answer({ id, deviceId: f.phoneId, answer: 'allow' }), (e) => e.code === 'phone_use_other_device');
  await f.cli.end(id);
  assert.equal((await f.cli.ask({ who: 'Claude', purpose: '確認' })).error, 'not_registered');
  const next = await f.device();
  assert.equal((await register(f, next.token)).status, 200, 'a revoked holder gives up the place');
  assert.equal((await f.cli.ask({ who: 'Claude', purpose: '確認' })).ok, true);
  assert.deepEqual(f.cli.reset(), { reset: true });
  assert.equal((await f.cli.ask({ who: 'Claude', purpose: '確認' })).error, 'not_registered');
});

test('a failed push marks the request failed and reports it', async (t) => {
  const f = await fixture(t);
  await register(f);
  const cli = createPhoneUse({ dir: f.h.stateDir, now: f.now, devices: f.devices, push: async () => { throw Object.assign(new Error('x'), { code: 'apns_410_Unregistered' }); } });
  const r = await cli.ask({ who: 'Claude', purpose: '確認' });
  assert.deepEqual([r.ok, r.error, r.reason, r.request.status], [false, 'push_failed', 'apns_410_Unregistered', 'failed']);
  assert.equal((await cli.ask({ who: 'Claude', purpose: '確認' })).error, 'push_failed', 'a failed one does not block');
});

test('CLI: usage errors exit 2, status and end print JSON', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'laa-phone-use-cli-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const out = [];
  const service = createPhoneUse({ dir, push: async () => ({ status: 200 }) });
  const io = { service, write: (s) => out.push(s) };
  assert.equal(await phoneUseCommand(['ask'], { who: 'x' }, io), 2);
  assert.equal(await phoneUseCommand(['ask'], { who: 'x', purpose: 'y', bogus: '1' }, io), 2);
  assert.equal(await phoneUseCommand(['ask'], { who: 'x', purpose: 'y', json: true }, io), 1);
  assert.equal(JSON.parse(out.at(-1)).error, 'not_registered');
  assert.equal(await phoneUseCommand(['status', 'pu_0000000000000000'], { json: true }, io), 1);
  assert.equal(JSON.parse(out.at(-1)).error, 'phone_use_not_found');
});

test('APNs JWT is ES256 over header.claims; sender needs both env values', () => {
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const key = privateKey.export({ type: 'pkcs8', format: 'pem' });
  const jwt = apnsJwt({ key, keyId: 'KEY123', teamId: 'TEAM', now: 1_700_000_000_000 });
  const [h, c, s] = jwt.split('.');
  assert.deepEqual(JSON.parse(Buffer.from(h, 'base64url')), { alg: 'ES256', kid: 'KEY123' });
  assert.deepEqual(JSON.parse(Buffer.from(c, 'base64url')), { iss: 'TEAM', iat: 1_700_000_000 });
  assert.ok(createVerify('SHA256').update(`${h}.${c}`).verify({ key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(s, 'base64url')));
  assert.equal(apnsSenderFromEnv({ APNS_KEY: key }), null);
  assert.equal(apnsSenderFromEnv({ APNS_KEY: 'op://x', APNS_KEY_ID: 'k' }), null);
  assert.equal(typeof apnsSenderFromEnv({ APNS_KEY: key, APNS_KEY_ID: 'k' }), 'function');
});

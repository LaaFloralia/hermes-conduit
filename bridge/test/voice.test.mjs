// Contract tests for POST /v1/voice/polish, POST /v1/voice/transcribe and
// POST /v1/devices/self/revoke.
//
// The worker is a stub that speaks the real stdio protocol, so these tests
// exercise the Bridge's parsing, authorization, single-flight rules, process
// supervision, cancellation and non-disclosure without loading a model.
// Synthetic text and synthetic PCM only.

import assert from 'node:assert/strict';
import test from 'node:test';
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startBridge } from './helpers.mjs';
import { revokeDevice } from '../src/pairing.mjs';
import { createLineFramer, createVoiceWorker } from '../src/voice/worker.mjs';
import { errorForLog } from '../src/http.mjs';
import { voiceRoutes } from '../src/routes/voice.mjs';
import { ALL_SCOPES, DEFAULT_SCOPES, VOICE_TRANSCRIBE_MAX_BYTES } from '../src/config.mjs';

const STUB = fileURLToPath(new URL('./fixtures/voice-worker-stub.mjs', import.meta.url));
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function stubWorker(env = {}, options = {}) {
  return createVoiceWorker({
    command: process.execPath,
    args: [STUB],
    env: { PATH: process.env.PATH ?? '/usr/bin:/bin', ...env },
    requestTimeoutMs: 2000,
    coldTimeoutMs: 2000,
    killGraceMs: 300,
    restartDelayMs: 0,
    ...options,
  });
}

async function bridge(t, { worker = null, scopes = ['voice:polish'], timeoutMs = 2000, log = null } = {}) {
  const api = await startBridge({ voice: { worker, timeoutMs }, log });
  t.after(async () => {
    await worker?.stop();
    await api.close();
  });
  const token = await api.token(scopes);
  return { api, token };
}

function markerDir(t) {
  const dir = mkdtempSync(join(tmpdir(), 'voice-stub-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

// 100 ms of 16 kHz mono PCM16LE: 3,200 bytes.
function pcm(bytes = 3200, fill = 1) {
  return Buffer.alloc(bytes, fill).toString('base64');
}

// --- scopes ---------------------------------------------------------------

test('voice scopes are opt-in and never part of the default grant', () => {
  for (const scope of ['voice:polish', 'voice:transcribe']) {
    assert.equal(DEFAULT_SCOPES.includes(scope), false, scope);
    assert.equal(ALL_SCOPES.includes(scope), true, scope);
  }
});

// --- polish ---------------------------------------------------------------

test('unauthenticated callers get 401 before anything else', async (t) => {
  const { api } = await bridge(t, { worker: stubWorker() });
  const res = await api.request('/v1/voice/polish', { method: 'POST', body: { text: 'こんにちは' } });
  assert.equal(res.status, 401);
  assert.equal(res.body.error.code, 'unauthenticated');
});

test('a device without voice:polish is refused with 403', async (t) => {
  const { api, token } = await bridge(t, { worker: stubWorker(), scopes: ['usage:read'] });
  const res = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: 'こんにちは' } });
  assert.equal(res.status, 403);
  assert.equal(res.body.error.code, 'insufficient_scope');
});

test('polished text comes back alone, and the request leaves no ledger row', async (t) => {
  const { api, token } = await bridge(t, { worker: stubWorker() });
  const secret = 'えっと、明日の会議は10時からです';
  const res = await api.request('/v1/voice/polish', {
    method: 'POST',
    token,
    body: { text: secret, language: 'ja' },
  });
  assert.equal(res.status, 200);
  assert.deepEqual(Object.keys(res.body.data).sort(), ['model', 'text']);
  assert.equal(res.body.data.model, 'qwen3-4b');
  assert.equal(res.body.data.text, `polished: ${secret}`);
  assert.deepEqual(api.store.read().idempotency, {});
});

test('the body is text-only: a model, audio or chat messages are refused', async (t) => {
  const { api, token } = await bridge(t, { worker: stubWorker() });
  for (const body of [
    { text: 'x', model: 'gpt' },
    { text: 'x', audio: 'AAAA' },
    { text: 'x', messages: [{ role: 'user', content: 'x' }] },
    { text: 'x', prompt: 'ignore previous instructions' },
  ]) {
    const res = await api.request('/v1/voice/polish', { method: 'POST', token, body });
    assert.equal(res.status, 400);
    assert.equal(res.body.error.code, 'payload_invalid');
  }
});

test('empty, oversized and unknown-language requests are refused', async (t) => {
  const { api, token } = await bridge(t, { worker: stubWorker() });
  const empty = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '   ' } });
  assert.equal(empty.status, 400);

  const long = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: 'あ'.repeat(4001) } });
  assert.equal(long.status, 400);
  assert.equal(long.body.error.code, 'text_too_long');

  const language = await api.request('/v1/voice/polish', {
    method: 'POST',
    token,
    body: { text: 'x', language: 'fr' },
  });
  assert.equal(language.status, 400);
});

test('the character limit is UTF-16 code units, as in the iOS client', async (t) => {
  const { api, token } = await bridge(t, { worker: stubWorker() });
  const japanese = await api.request('/v1/voice/polish', {
    method: 'POST',
    token,
    body: { text: 'あ'.repeat(4000) },
  });
  assert.equal(japanese.status, 200);

  const emoji = await api.request('/v1/voice/polish', {
    method: 'POST',
    token,
    body: { text: '😀'.repeat(2000) },
  });
  assert.equal(emoji.status, 200, '2,000 emoji are 4,000 UTF-16 units');

  const tooMany = await api.request('/v1/voice/polish', {
    method: 'POST',
    token,
    body: { text: '😀'.repeat(2001) },
  });
  assert.equal(tooMany.status, 400);
  assert.equal(tooMany.body.error.code, 'text_too_long');
});

test('a body over the HTTP limit is refused before the model sees it', async (t) => {
  const { api, token } = await bridge(t, { worker: stubWorker() });
  const res = await api.request('/v1/voice/polish', {
    method: 'POST',
    token,
    body: JSON.stringify({ text: 'x'.repeat(70 * 1024) }),
  });
  assert.equal(res.status, 400);
  assert.equal(res.body.error.code, 'payload_too_large');
});

test('without a configured worker the endpoint says so and names nothing else', async (t) => {
  const { api, token } = await bridge(t, { worker: null });
  const res = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: 'こんにちは' } });
  assert.equal(res.status, 503);
  assert.deepEqual(res.body.error, {
    code: 'voice_not_configured',
    message: 'voice polish is not configured on this Mac',
    retryable: false,
  });
});

test('a crashed worker is 503 and the next request starts a fresh one', async (t) => {
  const dir = markerDir(t);
  const worker = stubWorker({ STUB_ONCE: 'exit', STUB_ONCE_FILE: join(dir, 'first') });
  const { api, token } = await bridge(t, { worker });

  const failed = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '一つ目' } });
  assert.equal(failed.status, 503);
  assert.equal(failed.body.error.code, 'voice_unavailable');

  const recovered = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '二つ目' } });
  assert.equal(recovered.status, 200);
  assert.equal(recovered.body.data.text, 'polished: 二つ目');
});

test('a wedged worker is killed on timeout and the next request recovers', async (t) => {
  const dir = markerDir(t);
  const worker = stubWorker(
    { STUB_ONCE: 'hang', STUB_ONCE_FILE: join(dir, 'first') },
    // The first request of a child always uses the cold budget, so the hang
    // must exceed that; recovery then spawns another child under the same one.
    { requestTimeoutMs: 150, coldTimeoutMs: 1000 },
  );
  const { api, token } = await bridge(t, { worker, timeoutMs: 150 });

  const timedOut = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '固まる' } });
  assert.equal(timedOut.status, 504);
  assert.equal(timedOut.body.error.code, 'voice_timeout');

  // No new child is started until the old one has exited.
  const during = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: 'まだ' } });
  assert.equal(during.status, 429);

  await delay(400);
  const recovered = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '次' } });
  assert.equal(recovered.status, 200);
});

test('the first request pays for the model load, later ones do not', async (t) => {
  const worker = stubWorker({ STUB_DELAY_MS: '350' }, { requestTimeoutMs: 150, coldTimeoutMs: 900 });
  const { api, token } = await bridge(t, { worker, timeoutMs: 150 });

  const cold = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '最初' } });
  assert.equal(cold.status, 200, 'the cold budget covers the model load');

  const warm = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '二度目' } });
  assert.equal(warm.status, 504, 'a warm request that takes 350 ms exceeds the 150 ms generation budget');
});

test('while a request is running the next one is refused immediately', async (t) => {
  const worker = stubWorker({ STUB_DELAY_MS: '300' }, { requestTimeoutMs: 1500, coldTimeoutMs: 1500 });
  const { api, token } = await bridge(t, { worker, timeoutMs: 1500 });

  const first = api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '先' } });
  await delay(100);

  const startedAt = Date.now();
  const second = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '後' } });
  assert.equal(second.status, 429);
  assert.equal(second.body.error.code, 'voice_busy');
  assert.ok(Date.now() - startedAt < 150, 'busy is answered without waiting for the queue');

  assert.equal((await first).status, 200);
});

test('a child that ignores TERM is not replaced until it has exited', async (t) => {
  const dir = markerDir(t);
  const termFile = join(dir, 'term');
  const worker = stubWorker(
    // Request 1 answers, request 2 hangs and ignores SIGTERM.
    { STUB_HANG_AFTER: '1', STUB_TERM_FILE: termFile },
    { requestTimeoutMs: 150, coldTimeoutMs: 1000, killGraceMs: 1000 },
  );
  const { api, token } = await bridge(t, { worker, timeoutMs: 150 });

  assert.equal((await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '温め' } })).status, 200);

  const hung = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '固まる' } });
  assert.equal(hung.status, 504);

  // SIGTERM was ignored; the child is still terminating, so no second model
  // may be started for this request.
  const during = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: 'まだ' } });
  assert.equal(during.status, 429);
  assert.equal(during.body.error.code, 'voice_busy');

  // Signal delivery and the child's filesystem write are asynchronous.
  const signalDeadline = Date.now() + 600;
  while (!existsSync(termFile) && Date.now() < signalDeadline) await delay(10);
  assert.equal(existsSync(termFile), true, 'the Bridge asked the child to stop');

  // After SIGKILL the exit is confirmed and a new child is allowed.
  await delay(1400);
  const after = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '後' } });
  assert.equal(after.status, 200);
});

test('a client disconnect cancels the generation and reclaims the child', async (t) => {
  const dir = markerDir(t);
  const termFile = join(dir, 'term');
  const worker = stubWorker(
    { STUB_ONCE: 'hang', STUB_ONCE_FILE: join(dir, 'first'), STUB_TERM_FILE: termFile },
    { requestTimeoutMs: 5000, coldTimeoutMs: 5000, killGraceMs: 300 },
  );
  const { api, token } = await bridge(t, { worker, timeoutMs: 5000 });

  const controller = new AbortController();
  const pending = api.request('/v1/voice/polish', {
    method: 'POST',
    token,
    body: { text: '切断される' },
    signal: controller.signal,
  });
  await delay(150);
  controller.abort();
  await assert.rejects(pending);

  await delay(700);
  assert.equal(existsSync(termFile), true, 'the child was stopped when the client left');
  assert.equal(worker.busy, false);

  const next = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '次' } });
  assert.equal(next.status, 200);
});

test('a revocation does not cancel work that was already admitted', async (t) => {
  const worker = stubWorker({ STUB_DELAY_MS: '300' }, { requestTimeoutMs: 1500, coldTimeoutMs: 1500 });
  const { api, token } = await bridge(t, { worker, timeoutMs: 1500 });

  const me = await api.request('/v1/me', { token });
  const deviceId = me.body.data.deviceId;

  const pending = api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '着手済み' } });
  await delay(80);
  revokeDevice(api.store, { target: deviceId });

  const finished = await pending;
  assert.equal(finished.status, 200, 'admitted work finishes; revocation is for new requests');
  assert.equal(finished.body.data.text, 'polished: 着手済み');

  const refused = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '新規' } });
  assert.equal(refused.status, 401);
  assert.equal(refused.body.error.code, 'token_revoked');
});

test('a killed worker cannot inject its late answer into the next request', async (t) => {
  const dir = markerDir(t);
  const worker = stubWorker(
    {
      STUB_ONCE: 'stale',
      STUB_ONCE_FILE: join(dir, 'first'),
      STUB_SLOW_TEXT: 'ゆっくり',
      STUB_SLOW_MS: '300',
      STUB_STALE_MS: '300',
    },
    { requestTimeoutMs: 2000, coldTimeoutMs: 400, killGraceMs: 200 },
  );
  const { api, token } = await bridge(t, { worker, timeoutMs: 2000 });

  const timedOut = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '古い' } });
  assert.equal(timedOut.status, 504);

  // The old child is still terminating, so nothing may start yet.
  const during = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: 'まだ' } });
  assert.equal(during.status, 429);

  // Its late reply (id p1) lands around here; it must not answer or retire the
  // replacement that takes over next.
  await delay(400);
  const fresh = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '新しい' } });
  assert.equal(fresh.status, 200);
  assert.equal(fresh.body.data.text, 'polished: 新しい');
  assert.notEqual(fresh.body.data.text, 'stale reply');
});

test('an unavailable worker is retired and the next request can recover', async (t) => {
  const dir = markerDir(t);
  const worker = stubWorker(
    { STUB_ONCE: 'unavailable', STUB_ONCE_FILE: join(dir, 'first') },
    { killGraceMs: 300 },
  );
  const { api, token } = await bridge(t, { worker });

  const unavailable = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '駄目' } });
  assert.equal(unavailable.status, 503);
  assert.equal(unavailable.body.error.code, 'voice_unavailable');

  // The child is retired, not kept around as an unusable worker.
  const during = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: 'まだ' } });
  assert.equal(during.status, 429);

  await delay(400);
  const after = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '回復' } });
  assert.equal(after.status, 200, 'a fresh child may recover after the old one exited');
});

test('a request whose socket is already closed never starts the model', async () => {
  let calls = 0;
  const route = voiceRoutes({
    worker: {
      request: () => {
        calls += 1;
        return Promise.resolve({ text: 'x' });
      },
    },
  })[0];

  const res = { destroyed: true, writableEnded: false, once() {}, off() {} };
  await assert.rejects(
    route.handler({ rawBody: Buffer.from(JSON.stringify({ text: '本文' })), res }),
    (error) => error.code === 'client_closed' && error.status === 499,
  );
  assert.equal(calls, 0);

  const ended = { destroyed: false, writableEnded: true, once() {}, off() {} };
  await assert.rejects(
    route.handler({ rawBody: Buffer.from(JSON.stringify({ text: '本文' })), res: ended }),
    (error) => error.code === 'client_closed',
  );
  assert.equal(calls, 0);
});

test('an unexpected error keeps only a known class and a known system code', () => {
  const secret = '極秘の本文 /Users/laa/dev/secret';
  const plain = errorForLog(new Error(secret));
  assert.deepEqual(plain, { error: 'Error' });
  assert.equal(JSON.stringify(plain).includes('極秘'), false);
  assert.equal(JSON.stringify(plain).includes('/Users'), false);

  const system = Object.assign(new Error(`ENOENT: no such file, open '${secret}'`), { code: 'ENOENT' });
  assert.deepEqual(errorForLog(system), { error: 'Error', code: 'ENOENT' });

  // name and code are strings the thrower controls: unknown values are dropped.
  const forged = Object.assign(new Error(secret), { name: '極秘クラス', code: '極秘コード' });
  assert.deepEqual(errorForLog(forged), { error: 'Error' });
  const knownName = Object.assign(new TypeError(secret), { code: 'ENOTDIR' });
  assert.deepEqual(errorForLog(knownName), { error: 'TypeError', code: 'ENOTDIR' });
});

test('the line framer counts bytes per line and never merges chunks', () => {
  assert.deepEqual(createLineFramer(8).push(Buffer.from('12345678\n')), { lines: ['12345678'], tooLong: false });
  assert.deepEqual(createLineFramer(8).push(Buffer.from('12345678\nab\n')), { lines: ['12345678', 'ab'], tooLong: false });
  assert.deepEqual(createLineFramer(8).push(Buffer.from('123456789\n')), { lines: [], tooLong: true });

  const split = createLineFramer(8);
  assert.deepEqual(split.push(Buffer.from('1234')), { lines: [], tooLong: false });
  assert.deepEqual(split.push(Buffer.from('5678\n')), { lines: ['12345678'], tooLong: false });

  // 6 bytes of Japanese fit a 6-byte line; 6 bytes without a newline still fit.
  assert.deepEqual(createLineFramer(6).push(Buffer.from('ああ\n')), { lines: ['ああ'], tooLong: false });
  assert.deepEqual(createLineFramer(5).push(Buffer.from('ああ\n')), { lines: [], tooLong: true });
});

test('a worker that cannot take the model lock is transiently busy', async (t) => {
  const dir = markerDir(t);
  const worker = stubWorker({ STUB_ONCE: 'exit3', STUB_ONCE_FILE: join(dir, 'first') });
  const { api, token } = await bridge(t, { worker });

  const busy = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '待機' } });
  assert.equal(busy.status, 429);
  assert.equal(busy.body.error.code, 'voice_busy');

  const after = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '次' } });
  assert.equal(after.status, 200, 'the lock is free once the other worker has exited');
});

test('a worker that fails to prepare is unavailable, not busy', async (t) => {
  const dir = markerDir(t);
  const worker = stubWorker({ STUB_ONCE: 'exit4', STUB_ONCE_FILE: join(dir, 'first') });
  const { api, token } = await bridge(t, { worker });

  const failed = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '失敗' } });
  assert.equal(failed.status, 503);
  assert.equal(failed.body.error.code, 'voice_unavailable');
});

test('non-ASCII lines are capped in bytes, not UTF-16 units', async (t) => {
  for (const mode of ['huge_utf8', 'huge_utf8_split']) {
    const dir = markerDir(t);
    const worker = stubWorker({ STUB_ONCE: mode, STUB_ONCE_FILE: join(dir, 'first') }, { killGraceMs: 300 });
    const { api, token } = await bridge(t, { worker });

    const res = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '巨大' } });
    assert.equal(res.status, 503, mode);
    assert.equal(res.body.error.code, 'voice_bad_reply', mode);

    await delay(400);
    const after = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '次' } });
    assert.equal(after.status, 200, mode);
  }
});

test('a model failure inside the worker is distinct from a protocol failure', async (t) => {
  const dir = markerDir(t);
  const worker = stubWorker({ STUB_ONCE: 'internal', STUB_ONCE_FILE: join(dir, 'first') });
  const { api, token } = await bridge(t, { worker });

  const failed = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '失敗' } });
  assert.equal(failed.status, 503);
  assert.equal(failed.body.error.code, 'voice_failed');
  assert.equal(failed.body.error.retryable, true);
  assert.equal(worker.busy, false, 'the child stays alive: a model error is not a protocol error');

  const after = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '次' } });
  assert.equal(after.status, 200);
});

test('a nothing reply is a successful no-op, not text', async (t) => {
  const dir = markerDir(t);
  const worker = stubWorker({ STUB_ONCE: 'nothing', STUB_ONCE_FILE: join(dir, 'first') });
  const { api, token } = await bridge(t, { worker });

  const res = await api.request('/v1/voice/polish', {
    method: 'POST',
    token,
    body: { text: '嗯 那个 就是 呃' },
  });
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.data, { text: '', nothing: true, model: 'qwen3-4b' });
});

test('a nothing reply carrying text is a protocol failure', async (t) => {
  const dir = markerDir(t);
  const worker = stubWorker({ STUB_ONCE: 'nothing_bad', STUB_ONCE_FILE: join(dir, 'first') });
  const { api, token } = await bridge(t, { worker });

  const res = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '本文' } });
  assert.equal(res.status, 503);
  assert.equal(res.body.error.code, 'voice_bad_reply');
  assert.equal(res.body.error.retryable, false);
});

test('an empty model reply is distinct from a protocol failure and keeps the child', async (t) => {
  const dir = markerDir(t);
  const worker = stubWorker({ STUB_ONCE: 'empty', STUB_ONCE_FILE: join(dir, 'first') });
  const { api, token } = await bridge(t, { worker });

  const empty = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '本文' } });
  assert.equal(empty.status, 503);
  assert.equal(empty.body.error.code, 'voice_empty');
  assert.equal(empty.body.error.retryable, false);
  assert.equal(worker.busy, false, 'an empty reply is a content outcome, not a protocol fault');

  const after = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '次' } });
  assert.equal(after.status, 200);
});

test('the route returns an empty 200 for a nothing worker result', async () => {
  const route = voiceRoutes({ worker: { request: async () => ({ nothing: true }) } })[0];
  const res = { destroyed: false, writableEnded: false, once() {}, off() {} };
  const result = await route.handler({ rawBody: Buffer.from(JSON.stringify({ text: '嗯' })), res });
  assert.deepEqual(result, { status: 200, data: { text: '', nothing: true, model: 'qwen3-4b' } });
});

test('the route refuses a nothing result that also carries text', async () => {
  const route = voiceRoutes({ worker: { request: async () => ({ nothing: true, text: 'x' }) } })[0];
  const res = { destroyed: false, writableEnded: false, once() {}, off() {} };
  await assert.rejects(
    route.handler({ rawBody: Buffer.from(JSON.stringify({ text: 'x' })), res }),
    (error) => error.status === 503 && error.code === 'voice_bad_reply',
  );
});

test('a 300 KiB line with a newline is refused by size', async (t) => {
  const dir = markerDir(t);
  const worker = stubWorker({ STUB_ONCE: 'huge', STUB_ONCE_FILE: join(dir, 'first') });
  const { api, token } = await bridge(t, { worker });

  const res = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '巨大' } });
  assert.equal(res.status, 503);
  assert.equal(res.body.error.code, 'voice_bad_reply');

  await delay(400);
  const after = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '次' } });
  assert.equal(after.status, 200);
});

test('a 300 KiB line without a newline is refused before it is buffered', async (t) => {
  const dir = markerDir(t);
  const worker = stubWorker({ STUB_ONCE: 'huge_no_newline', STUB_ONCE_FILE: join(dir, 'first') });
  const { api, token } = await bridge(t, { worker });

  const res = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '巨大' } });
  assert.equal(res.status, 503);
  assert.equal(res.body.error.code, 'voice_bad_reply');
});

test('errors never quote the transcript or the worker diagnostics', async (t) => {
  const dir = markerDir(t);
  const secret = '極秘の下書き本文です';
  const worker = stubWorker({
    STUB_ONCE: 'exit',
    STUB_ONCE_FILE: join(dir, 'first'),
    STUB_STDERR: secret,
  });
  const { api, token } = await bridge(t, { worker });

  const res = await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: secret } });
  assert.equal(res.status, 503);
  const serialised = JSON.stringify(res.body);
  assert.equal(serialised.includes(secret), false);
  assert.equal(serialised.includes('stderr'), false);
  assert.equal(serialised.includes('/'), false);
  assert.equal('details' in res.body.error, false);
});

test('the access log records no body, no text and no error detail', async (t) => {
  const dir = markerDir(t);
  const entries = [];
  const secret = 'ログに出てはいけない本文';
  const worker = stubWorker({ STUB_ONCE: 'exit', STUB_ONCE_FILE: join(dir, 'first') });
  const { api, token } = await bridge(t, { worker, log: (entry) => entries.push(entry) });

  await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: secret } });
  await api.request('/v1/voice/polish', { method: 'POST', token, body: { text: secret } });

  assert.equal(entries.length >= 2, true);
  for (const entry of entries) {
    assert.deepEqual(
      Object.keys(entry).sort(),
      ['code', 'deviceId', 'level', 'method', 'ms', 'path', 'requestId', 'status'].filter((key) => key in entry).sort(),
    );
    assert.equal(JSON.stringify(entry).includes(secret), false);
  }
  assert.equal(entries.some((entry) => entry.status === 503), true);
});

// --- transcribe -----------------------------------------------------------

test('a transcribe request returns the recognised text and the ASR model name', async (t) => {
  const { api, token } = await bridge(t, { worker: stubWorker(), scopes: ['voice:transcribe'] });
  const audio = pcm();
  const res = await api.request('/v1/voice/transcribe', {
    method: 'POST',
    token,
    body: { pcm16: audio, sampleRate: 16000 },
  });
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.data, { text: 'transcribed 3200 bytes at 16000', model: 'haas-ja-v1.0-q8_0' });
  assert.deepEqual(api.store.read().idempotency, {}, 'the audio never reaches the ledger');
});

test('silence is a successful result with empty text', async (t) => {
  const { api, token } = await bridge(t, { worker: stubWorker(), scopes: ['voice:transcribe'] });
  const res = await api.request('/v1/voice/transcribe', {
    method: 'POST',
    token,
    body: { pcm16: pcm(3200, 0), sampleRate: 16000, language: 'ja' },
  });
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.data, { text: '', model: 'haas-ja-v1.0-q8_0' });
});

test('the two voice scopes do not imply each other', async (t) => {
  const polishOnly = await bridge(t, { worker: stubWorker(), scopes: ['voice:polish'] });
  const refusedTranscribe = await polishOnly.api.request('/v1/voice/transcribe', {
    method: 'POST',
    token: polishOnly.token,
    body: { pcm16: pcm(), sampleRate: 16000 },
  });
  assert.equal(refusedTranscribe.status, 403);
  assert.equal(refusedTranscribe.body.error.code, 'insufficient_scope');
  assert.equal((await polishOnly.api.request('/v1/voice/polish', {
    method: 'POST', token: polishOnly.token, body: { text: '本文' },
  })).status, 200);

  const transcribeOnly = await bridge(t, { worker: stubWorker(), scopes: ['voice:transcribe'] });
  const refusedPolish = await transcribeOnly.api.request('/v1/voice/polish', {
    method: 'POST', token: transcribeOnly.token, body: { text: '本文' },
  });
  assert.equal(refusedPolish.status, 403);
  assert.equal(refusedPolish.body.error.code, 'insufficient_scope');
});

test('transcribe refuses an unauthenticated caller', async (t) => {
  const { api } = await bridge(t, { worker: stubWorker(), scopes: ['voice:transcribe'] });
  const res = await api.request('/v1/voice/transcribe', {
    method: 'POST',
    body: { pcm16: pcm(), sampleRate: 16000 },
  });
  assert.equal(res.status, 401);
});

test('transcribe refuses a non-canonical, empty or odd-length recording', async (t) => {
  const { api, token } = await bridge(t, { worker: stubWorker(), scopes: ['voice:transcribe'] });
  const canonical = pcm(3200);
  for (const body of [
    {},
    { pcm16: '', sampleRate: 16000 },
    { pcm16: 12345, sampleRate: 16000 },
    { pcm16: `${canonical.slice(0, 8)} ${canonical.slice(8)}`, sampleRate: 16000 },
    { pcm16: `${canonical.slice(0, 8)}\n${canonical.slice(8)}`, sampleRate: 16000 },
    // Not a multiple of four characters.
    { pcm16: canonical.slice(0, -1), sampleRate: 16000 },
    // Padding bits that are not zero: decodes, but is not the canonical form.
    { pcm16: 'AB==', sampleRate: 16000 },
    // Too much padding, and the URL-safe alphabet.
    { pcm16: 'AAAA===', sampleRate: 16000 },
    { pcm16: 'AA-_', sampleRate: 16000 },
    // 3 bytes: one and a half samples.
    { pcm16: Buffer.from([1, 2, 3]).toString('base64'), sampleRate: 16000 },
  ]) {
    const res = await api.request('/v1/voice/transcribe', { method: 'POST', token, body });
    assert.equal(res.status, 400, JSON.stringify(body).slice(0, 60));
    assert.equal(res.body.error.code, 'audio_invalid', JSON.stringify(body).slice(0, 60));
  }
});

test('transcribe requires 16 kHz and rejects unknown fields and languages', async (t) => {
  const { api, token } = await bridge(t, { worker: stubWorker(), scopes: ['voice:transcribe'] });
  const audio = pcm();
  for (const body of [
    { pcm16: audio },
    { pcm16: audio, sampleRate: 48000 },
    { pcm16: audio, sampleRate: '16000' },
    { pcm16: audio, sampleRate: 16000, model: 'whisper' },
    { pcm16: audio, sampleRate: 16000, text: 'x' },
    { pcm16: audio, sampleRate: 16000, language: 'fr' },
  ]) {
    const res = await api.request('/v1/voice/transcribe', { method: 'POST', token, body });
    assert.equal(res.status, 400, JSON.stringify(body).slice(0, 60));
    assert.equal(res.body.error.code, 'payload_invalid', JSON.stringify(body).slice(0, 60));
  }
});

test('transcribe accepts exactly 25 seconds and refuses one sample more', async (t) => {
  const { api, token } = await bridge(t, { worker: stubWorker(), scopes: ['voice:transcribe'] });
  assert.equal(VOICE_TRANSCRIBE_MAX_BYTES, 800_000);

  const longest = await api.request('/v1/voice/transcribe', {
    method: 'POST',
    token,
    body: { pcm16: pcm(VOICE_TRANSCRIBE_MAX_BYTES), sampleRate: 16000 },
  });
  assert.equal(longest.status, 200);
  assert.equal(longest.body.data.text, `transcribed ${VOICE_TRANSCRIBE_MAX_BYTES} bytes at 16000`);

  const longer = await api.request('/v1/voice/transcribe', {
    method: 'POST',
    token,
    body: { pcm16: pcm(VOICE_TRANSCRIBE_MAX_BYTES + 2), sampleRate: 16000 },
  });
  assert.equal(longer.status, 400);
  assert.equal(longer.body.error.code, 'audio_too_large');
});

test('a transcribe body over the HTTP limit is refused before the model sees it', async (t) => {
  const { api, token } = await bridge(t, { worker: stubWorker(), scopes: ['voice:transcribe'] });
  const res = await api.request('/v1/voice/transcribe', {
    method: 'POST',
    token,
    body: { pcm16: pcm(1_000_000), sampleRate: 16000 },
  });
  assert.equal(res.status, 413);
  assert.equal(res.body.error.code, 'payload_too_large');
});

test('transcribe without a configured worker says so and names nothing else', async (t) => {
  const { api, token } = await bridge(t, { worker: null, scopes: ['voice:transcribe'] });
  const res = await api.request('/v1/voice/transcribe', {
    method: 'POST',
    token,
    body: { pcm16: pcm(), sampleRate: 16000 },
  });
  assert.equal(res.status, 503);
  assert.deepEqual(res.body.error, {
    code: 'voice_not_configured',
    message: 'voice transcribe is not configured on this Mac',
    retryable: false,
  });
});

test('transcribe is refused while the model is busy with a polish', async (t) => {
  const worker = stubWorker({ STUB_DELAY_MS: '300' }, { requestTimeoutMs: 1500, coldTimeoutMs: 1500 });
  const { api, token } = await bridge(t, { worker, scopes: ['voice:polish', 'voice:transcribe'], timeoutMs: 1500 });

  const first = api.request('/v1/voice/polish', { method: 'POST', token, body: { text: '先' } });
  await delay(100);
  const second = await api.request('/v1/voice/transcribe', {
    method: 'POST',
    token,
    body: { pcm16: pcm(), sampleRate: 16000 },
  });
  assert.equal(second.status, 429);
  assert.equal(second.body.error.code, 'voice_busy');
  assert.equal((await first).status, 200);
});

test('a client disconnect cancels its own transcription and reclaims the child', async (t) => {
  const dir = markerDir(t);
  const termFile = join(dir, 'term');
  const worker = stubWorker(
    { STUB_ONCE: 'hang', STUB_ONCE_FILE: join(dir, 'first'), STUB_TERM_FILE: termFile },
    { requestTimeoutMs: 5000, coldTimeoutMs: 5000, killGraceMs: 300 },
  );
  const { api, token } = await bridge(t, { worker, scopes: ['voice:transcribe'], timeoutMs: 5000 });

  const controller = new AbortController();
  const pending = api.request('/v1/voice/transcribe', {
    method: 'POST',
    token,
    body: { pcm16: pcm(), sampleRate: 16000 },
    signal: controller.signal,
  });
  await delay(150);
  controller.abort();
  await assert.rejects(pending);

  await delay(700);
  assert.equal(existsSync(termFile), true, 'the child was stopped when the client left');
  assert.equal(worker.busy, false);

  const next = await api.request('/v1/voice/transcribe', {
    method: 'POST',
    token,
    body: { pcm16: pcm(), sampleRate: 16000 },
  });
  assert.equal(next.status, 200);
});

test('a request refused as busy cannot cancel the generation already running', async (t) => {
  // The route registers its cancel hook before it knows whether the worker can
  // take the request. If that hook were global, a second client hanging up
  // would kill the first client's generation.
  const worker = stubWorker({ STUB_DELAY_MS: '300' }, { requestTimeoutMs: 2000, coldTimeoutMs: 2000 });
  t.after(() => worker.stop());

  const running = worker.request({ text: '先' });
  const controller = new AbortController();
  await assert.rejects(
    worker.request({ text: '後' }, { signal: controller.signal }),
    (error) => error.kind === 'busy',
  );
  controller.abort();
  assert.equal(worker.busy, true, 'the refused caller did not stop the running one');

  const first = await running;
  assert.equal(first.text, 'polished: 先');
});

test('the access log records no audio for a transcribe request', async (t) => {
  const entries = [];
  const worker = stubWorker();
  const { api, token } = await bridge(t, { worker, scopes: ['voice:transcribe'], log: (entry) => entries.push(entry) });
  const audio = pcm(3200, 7);
  const res = await api.request('/v1/voice/transcribe', {
    method: 'POST',
    token,
    body: { pcm16: audio, sampleRate: 16000 },
  });
  assert.equal(res.status, 200);
  assert.equal(entries.length >= 1, true);
  for (const entry of entries) {
    assert.equal(JSON.stringify(entry).includes(audio.slice(0, 40)), false);
    assert.equal('pcm16' in entry, false);
  }
});

// --- self-revoke ----------------------------------------------------------

test('a dedicated voice pairing leaves the existing app token valid', async (t) => {
  const { api, token: appToken } = await bridge(t, { worker: stubWorker(), scopes: DEFAULT_SCOPES });

  const paired = await api.pair({ scopes: ['voice:polish'], name: 'iPhone Voice' });
  const enrolled = await api.enroll(paired.code, 'iPhone Voice');
  assert.equal(enrolled.status, 201);
  const voiceToken = enrolled.body.data.token;

  assert.equal((await api.request('/v1/me', { token: appToken })).status, 200);
  assert.equal((await api.request('/v1/me', { token: voiceToken })).status, 200);

  const revoke = await api.request('/v1/devices/self/revoke', { method: 'POST', token: voiceToken });
  assert.equal(revoke.status, 200);

  const app = await api.request('/v1/me', { token: appToken });
  assert.equal(app.status, 200, 'the LAA app credential is untouched');
  assert.equal((await api.request('/v1/me', { token: voiceToken })).status, 401);
});

test('a voice-only device holding both scopes can revoke itself', async (t) => {
  const { api } = await bridge(t, { worker: stubWorker() });
  const token = await api.token(['voice:polish', 'voice:transcribe']);
  const me = await api.request('/v1/me', { token });
  assert.deepEqual([...me.body.data.scopes].sort(), ['voice:polish', 'voice:transcribe']);

  const revoke = await api.request('/v1/devices/self/revoke', { method: 'POST', token });
  assert.equal(revoke.status, 200);
  assert.equal(revoke.body.data.deviceId, me.body.data.deviceId);
  assert.equal((await api.request('/v1/me', { token })).status, 401);
});

test('self-revoke needs a voice scope, so the app cannot retire itself by accident', async (t) => {
  const { api, token } = await bridge(t, { worker: stubWorker(), scopes: DEFAULT_SCOPES });

  const attempt = await api.request('/v1/devices/self/revoke', { method: 'POST', token });
  assert.equal(attempt.status, 403);
  assert.equal(attempt.body.error.code, 'insufficient_scope');
  assert.equal((await api.request('/v1/me', { token })).status, 200);
});

test('a device cannot use self-revoke to retire another device', async (t) => {
  const { api } = await bridge(t, { worker: stubWorker() });
  const mine = await api.token(['voice:polish']);
  const theirs = await api.token(['voice:polish']);
  const other = await api.request('/v1/me', { token: theirs });
  const otherId = other.body.data.deviceId;

  const attempt = await api.request('/v1/devices/self/revoke', {
    method: 'POST',
    token: mine,
    body: { deviceId: otherId },
  });
  assert.equal(attempt.status, 400);
  assert.equal(attempt.body.error.code, 'payload_invalid');

  assert.equal((await api.request('/v1/me', { token: theirs })).status, 200);
  assert.equal((await api.request('/v1/me', { token: mine })).status, 200);
});

// --- process ownership ----------------------------------------------------

test('the worker exits when its parent dies, so no model is left orphaned', async (t) => {
  const harness = `
    import { createVoiceWorker } from ${JSON.stringify(new URL('../src/voice/worker.mjs', import.meta.url).href)};
    const worker = createVoiceWorker({
      command: process.execPath,
      args: [${JSON.stringify(STUB)}],
      requestTimeoutMs: 60000,
      coldTimeoutMs: 60000,
    });
    worker.request({ text: 'x' }).catch(() => {});
    setTimeout(() => { process.stdout.write(String(worker.pid) + '\\n'); }, 400);
    setInterval(() => {}, 1000);
  `;
  const child = spawn(process.execPath, ['--input-type=module', '-e', harness], {
    stdio: ['ignore', 'pipe', 'ignore'],
    env: { PATH: process.env.PATH ?? '/usr/bin:/bin' },
  });
  t.after(() => {
    try {
      child.kill('SIGKILL');
    } catch {
      // Already gone.
    }
  });

  const workerPid = await new Promise((resolve, reject) => {
    let text = '';
    const timer = setTimeout(() => reject(new Error('harness did not report a pid')), 5000);
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      text += chunk;
      const line = text.split('\n')[0];
      if (line && /^\d+$/.test(line)) {
        clearTimeout(timer);
        resolve(Number(line));
      }
    });
    child.on('exit', () => {
      clearTimeout(timer);
      reject(new Error('harness exited early'));
    });
  });

  const alive = () => {
    try {
      process.kill(workerPid, 0);
      return true;
    } catch {
      return false;
    }
  };
  assert.equal(alive(), true);

  process.kill(child.pid, 'SIGKILL');
  for (let i = 0; i < 50 && alive(); i += 1) await delay(100);
  assert.equal(alive(), false, 'the worker must exit on stdin EOF after its parent dies');
});

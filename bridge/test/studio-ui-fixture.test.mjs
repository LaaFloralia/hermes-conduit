import assert from 'node:assert/strict';
import { once } from 'node:events';
import { test } from 'node:test';
import { createStudioUIFixture } from '../../scripts/laa/studio-ui-fixture.mjs';

const id = '0f6b1c2e-6f1a-4c55-9d43-0d5f6f3b8a11';
const approvalId = '5e2c1c2e-6f1a-4c55-9d43-0d5f6f3b8a11';

async function fixture(t) {
  const { api, control } = createStudioUIFixture();
  api.listen(0, '127.0.0.1'); control.listen(0, '127.0.0.1');
  await Promise.all([once(api, 'listening'), once(control, 'listening')]);
  t.after(async () => {
    api.closeAllConnections(); control.closeAllConnections();
    await Promise.all([new Promise((done) => api.close(done)), new Promise((done) => control.close(done))]);
  });
  const base = `http://127.0.0.1:${api.address().port}`;
  const controlBase = `http://127.0.0.1:${control.address().port}`;
  return {
    async control(path) { return (await fetch(`${controlBase}/${path}`)).text(); },
    async get(path, headers = {}) {
      return fetch(`${base}${path}`, { headers: { authorization: 'Bearer fixture-token', ...headers } });
    },
    async post(path, key, body) {
      const response = await fetch(`${base}${path}`, { method: 'POST', headers: {
        authorization: 'Bearer fixture-token', 'content-type': 'application/json', 'idempotency-key': key,
      }, body: JSON.stringify(body) });
      return { status: response.status, headers: response.headers, body: await response.json() };
    },
  };
}

test('UI fixture preserves action ledger results and rejects uncertain or conflicting retries', async (t) => {
  const f = await fixture(t);
  const answer = { action: 'answer', id, approvalId, accept: true, content: {}, persist: false };
  await f.control('mode/action-fail-once');
  assert.equal((await f.post('/v1/studio/action', 'answer-one', answer)).status, 503);
  assert.equal((await f.post('/v1/studio/action', 'answer-one', answer)).body.error.code, 'idempotency_key_in_flight');
  assert.equal((await f.post('/v1/studio/action', 'answer-one', { ...answer, accept: false })).body.error.code, 'idempotency_key_conflict');
  assert.equal(await f.control('action-count'), '1');
  await f.control('advance-clock/61001');
  assert.equal((await f.post('/v1/studio/action', 'answer-one', answer)).body.error.code, 'idempotency_outcome_unknown');
  assert.equal(await f.control('action-count'), '1');

  const first = await f.post('/v1/studio/action', 'answer-two', answer);
  const replay = await f.post('/v1/studio/action', 'answer-two', answer);
  assert.equal(first.status, 200);
  assert.equal(replay.status, 200);
  assert.equal(replay.headers.get('idempotency-replayed'), 'true');
  assert.deepEqual(replay.body.data, first.body.data);
  assert.equal(await f.control('action-count'), '2');
  assert.equal((await f.post('/v1/studio/action', 'stop-one', { action: 'stop', id })).body.data.status, 'stopped');
  assert.equal((await f.post('/v1/studio/action', 'answer-two', answer)).body.data.status, 'stopped');
  assert.equal(await f.control('action-count'), '3');
});

test('v2 fixture serves conditional catalog, ranged media and preserves a review after a lost reply', async (t) => {
  const f = await fixture(t);
  await f.control('mode/v2');
  const snapshot = await (await f.get('/v1/studio/snapshot')).json();
  assert.equal(snapshot.data.contract, 2);
  const catalog = await f.get('/v1/studio/catalog');
  assert.equal(catalog.status, 200);
  const tag = catalog.headers.get('etag');
  assert.equal(tag, `"${'c'.repeat(64)}"`);
  assert.equal((await catalog.json()).data.etag, 'c'.repeat(64));
  const unchanged = await f.get('/v1/studio/catalog', { 'if-none-match': tag });
  assert.equal(unchanged.status, 304);
  assert.equal(unchanged.headers.get('etag'), tag);
  assert.equal(await unchanged.text(), '');

  const project = '70175325-5cf4-421f-8a6f-95beae8fca92';
  const image = await f.get(`/v1/studio/media/${project}/${'a'.repeat(64)}.png`, { range: 'bytes=0-15' });
  assert.equal(image.status, 206);
  assert.match(image.headers.get('content-range'), /^bytes 0-15\/\d+$/);
  assert.equal((await image.arrayBuffer()).byteLength, 16);

  const review = { id, projectId: project, revision: 3, target: { kind: 'project' }, verdict: 'revise', comment: 'Fixture comment' };
  await f.control('mode/v2-review-lost');
  await assert.rejects(f.post('/v1/studio/reviews', 'review-first', review));
  assert.equal(await f.control('review-count'), '1');
  const detail = await (await f.get(`/v1/studio/projects/${project}`)).json();
  assert.equal(detail.data.reviews[0].id, id);
  const retry = await f.post('/v1/studio/reviews', 'review-retry', review);
  assert.equal(retry.status, 200);
  assert.deepEqual(retry.body.data, detail.data.reviews[0]);
  assert.equal(await f.control('review-consistent'), 'true');
  assert.equal((await f.post('/v1/studio/reviews', 'review-conflict', { ...review, comment: 'Different' })).status, 409);
  assert.equal(await f.control('review-count'), '1');
});

test('UI fixture can retry a failed stop with a fresh key and rejects a repeated stop', async (t) => {
  const f = await fixture(t);
  const stop = { action: 'stop', id };
  await f.control('mode/action-fail-once');
  assert.equal((await f.post('/v1/studio/action', 'stop-one', stop)).status, 503);
  assert.equal((await f.post('/v1/studio/action', 'stop-one', stop)).body.error.code, 'idempotency_key_in_flight');
  assert.equal((await f.post('/v1/studio/action', 'stop-two', stop)).body.data.status, 'stopped');
  assert.equal((await f.post('/v1/studio/action', 'stop-three', stop)).body.error.code, 'studio_request_finished');
});

test('UI fixture reserves and replays request creation keys', async (t) => {
  const f = await fixture(t);
  const draft = { id: 'create-test', prompt: 'Create' };
  const first = await f.post('/v1/studio/requests', 'create-key', draft);
  const replay = await f.post('/v1/studio/requests', 'create-key', draft);
  assert.equal(first.status, 202);
  assert.deepEqual(replay.body.data, first.body.data);
  assert.equal(replay.headers.get('idempotency-replayed'), 'true');
  assert.equal((await f.post('/v1/studio/requests', 'create-key', { ...draft, prompt: 'Different' })).body.error.code, 'idempotency_key_conflict');
});

test('UI fixture releases a busy creation and records exact retry identity', async (t) => {
  const f = await fixture(t);
  const draft = { id: 'create-busy', prompt: 'Create' };
  await f.control('mode/create-busy-once');
  const busy = await f.post('/v1/studio/requests', 'busy-key', draft);
  assert.equal(busy.status, 409); assert.equal(busy.body.error.code, 'studio_work_busy');
  assert.equal(busy.body.error.retryable, true);
  assert.equal((await f.post('/v1/studio/requests', 'busy-key', draft)).status, 202);
  assert.equal(await f.control('create-consistent'), 'true');
});

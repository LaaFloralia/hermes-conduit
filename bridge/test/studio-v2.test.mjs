// End-to-end contract fixtures: Bridge -> private mock Studio Unix socket.
// These contain no Studio, Drive, or user data.
import { after, before, describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { createStudioBackend } from '../src/studio/backend.mjs';
import { startBridge } from './helpers.mjs';

const mib = 1024 * 1024;
const projectId = '70175325-5cf4-421f-8a6f-95beae8fca92';
const digest = 'a'.repeat(64);
const tag = `"${'b'.repeat(64)}"`;
const token = 'c'.repeat(64);
const now = '2026-11-01T03:00:00.000Z';
const project = { id: projectId, title: 'Fixture', revision: 7, pages: [{ id: 'page1', name: 'Cover' }], assets: [] };
const catalog = { etag: 'b'.repeat(64), updatedAt: now, principles: [], adoptedPrincipleId: null,
  documents: [{ id: 'doc1', title: 'Fixture', media: `/api/studio/media/catalog/${digest}.pdf` }], capabilities: [], brief: [] };
const detail = { project, versions: [
  { id: digest, revision: 7, kind: 'video', name: 'preview.mp4', createdAt: now, bytes: 200 * mib,
    media: `/api/studio/media/${projectId}/${digest}.mp4`, previewOnly: true },
  { id: 'd'.repeat(64), revision: 7, kind: 'other', name: 'bundle.zip', createdAt: now, bytes: 12, unavailable: 'unsupported_format' },
  { id: 'e'.repeat(64), revision: 7, kind: 'model', name: 'model.glb', createdAt: now, bytes: 12, preparing: true },
], delivery: null, reviews: [] };
const response = (res, status, data) => {
  const bytes = Buffer.from(JSON.stringify(data));
  res.writeHead(status, { 'content-type': 'application/json', 'content-length': bytes.length });
  res.end(bytes);
};

describe('Studio v2 mock socket contract', () => {
  let dir, socket, server, bridge, readToken, writeToken, allToken, clock = 1_000_000;
  const state = { reviews: new Map(), calls: [], forcedError: null, dropReviewResponse: false, v2: true, closedStream: false, catalogFault: null };

  before(async () => {
    dir = mkdtempSync(join(tmpdir(), 'laa-studio-v2-'));
    socket = join(dir, 'intake.sock');
    writeFileSync(join(dir, 'intake.json'), JSON.stringify({ version: 1, socketPath: socket, token, bootId: randomUUID(), pid: process.pid }), { mode: 0o600 });
    server = createServer(async (req, res) => {
      if (req.headers.authorization !== `Bearer ${token}`) return response(res, 401, { error: 'invalid_token' });
      state.calls.push({ method: req.method, path: req.url, range: req.headers.range, ifNoneMatch: req.headers['if-none-match'] });
      if (req.url === '/api/studio/snapshot') return response(res, 200, { online: true, accepting: true, contract: state.v2 ? 2 : 1, projects: [], principles: [], requests: [] });
      if (!state.v2) return response(res, 404, { error: 'not_found' });
      if (req.url === '/api/studio/catalog') {
        if (state.catalogFault === 'unexpected304') { res.writeHead(304, { etag: tag }); return res.end(); }
        const matches = (req.headers['if-none-match'] ?? '').split(',').some((item) => item.trim().replace(/^W\//, '') === tag);
        if (matches) { res.writeHead(304, state.catalogFault === 'missingTag' ? {} : { etag: tag }); return res.end(); }
        if (state.catalogFault !== 'missingTag') res.setHeader('etag', tag);
        return response(res, 200, catalog);
      }
      if (req.url === `/api/studio/projects/${projectId}`) return response(res, 200, detail);
      if (req.url?.startsWith('/api/studio/projects/')) return response(res, 404, { error: 'studio_project_missing' });
      if (req.url === '/api/studio/reviews' && req.method === 'POST') {
        const chunks = [];
        for await (const chunk of req) chunks.push(chunk);
        const review = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        if (state.forcedError) return response(res, state.forcedError.status, { error: state.forcedError.code });
        const existing = state.reviews.get(review.id);
        if (existing) {
          const { createdAt, ...prior } = existing;
          if (!isDeepStrictEqual(prior, review)) return response(res, 409, { error: 'studio_review_id_conflict' });
          return response(res, 200, existing);
        }
        const record = { ...review, createdAt: now };
        state.reviews.set(review.id, record);
        if (state.dropReviewResponse) { state.dropReviewResponse = false; return req.socket.destroy(); }
        return response(res, 201, record);
      }
      const media = /^\/api\/studio\/media\/([\w-]+)\/([a-f0-9]{64})\.(mp4|mp3|pdf|usdz)$/.exec(req.url ?? '');
      if (media) {
        const [, , hash, ext] = media;
        const type = { mp4: 'video/mp4', mp3: 'audio/mpeg', pdf: 'application/pdf', usdz: 'model/vnd.usdz+zip' }[ext];
        const limit = (ext === 'mp4' || ext === 'mp3' ? 256 : 128) * mib;
        const total = hash.startsWith('f') ? limit + 1 : limit;
        if (hash.startsWith('e')) {
          res.writeHead(200, { 'content-type': type, 'content-length': 1024 * 1024 });
          res.write(Buffer.alloc(1024));
          res.on('close', () => { state.closedStream = true; });
          return;
        }
        if (req.headers.range === 'bytes=999999999-') { res.writeHead(416, { 'content-range': `bytes */${total}` }); return res.end(); }
        const range = hash.startsWith('d') ? `bytes 0-4/${total}` : `bytes 0-3/${total}`;
        res.writeHead(206, { 'content-type': type, 'content-length': 4, 'content-range': range, 'accept-ranges': 'bytes' });
        return res.end('abcd');
      }
      return response(res, 404, { error: 'not_found' });
    });
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socket, resolve); });
    chmodSync(socket, 0o600);
    const backend = createStudioBackend({ directory: dir, launch: async () => { throw new Error('unexpected launch'); } });
    bridge = await startBridge({ studio: { backend }, now: () => clock });
    readToken = await bridge.token(['studio:read']);
    writeToken = await bridge.token(['studio:request']);
    allToken = await bridge.token(['studio:read', 'studio:request']);
  });

  after(async () => {
    await bridge?.close();
    if (server) await new Promise((resolve) => server.close(resolve));
    if (dir) rmSync(dir, { recursive: true, force: true });
  });

  it('keeps scope boundaries and preserves catalog validators including weak or multiple tags', async () => {
    assert.equal((await bridge.request('/v1/studio/catalog')).status, 401);
    assert.equal((await bridge.request('/v1/studio/catalog', { token: writeToken })).status, 403);
    assert.equal((await bridge.request(`/v1/studio/projects/${projectId}`, { token: writeToken })).status, 403);
    const first = await bridge.request('/v1/studio/catalog', { token: readToken });
    assert.equal(first.status, 200);
    assert.equal(first.headers.get('etag'), tag);
    assert.equal(first.headers.get('cache-control'), 'no-store');
    assert.deepEqual(first.body.data, catalog);
    const conditions = `"other", W/${tag}`;
    const cached = await bridge.request('/v1/studio/catalog', { token: readToken, headers: { 'if-none-match': conditions } });
    assert.equal(cached.status, 304);
    assert.equal(cached.body, null);
    assert.equal(cached.headers.get('etag'), tag);
    assert.equal(state.calls.at(-1).ifNoneMatch, conditions);
    assert.equal((await bridge.request('/v1/studio/catalog', { token: readToken, headers: { 'if-none-match': 'x'.repeat(1025) } })).status, 400);
    state.catalogFault = 'missingTag';
    assert.equal((await bridge.request('/v1/studio/catalog', { token: readToken })).status, 502);
    assert.equal((await bridge.request('/v1/studio/catalog', { token: readToken, headers: { 'if-none-match': tag } })).status, 502);
    state.catalogFault = 'unexpected304';
    assert.equal((await bridge.request('/v1/studio/catalog', { token: readToken })).status, 502);
    state.catalogFault = null;
  });

  it('returns project details without erasing preparing, other, or previewOnly, and maps missing projects', async () => {
    const result = await bridge.request(`/v1/studio/projects/${projectId}`, { token: readToken });
    assert.deepEqual(result.body.data, detail);
    const missing = await bridge.request('/v1/studio/projects/missing', { token: readToken });
    assert.equal(missing.status, 404);
    assert.equal(missing.body.error.code, 'studio_project_missing');
    assert.equal((await bridge.request('/v1/studio/projects/bad%2Fpath', { token: readToken })).status, 404);
    state.v2 = false;
    assert.equal((await bridge.request('/v1/studio/snapshot', { token: readToken })).body.data.contract, 1);
    assert.equal((await bridge.request('/v1/studio/catalog', { token: readToken })).status, 404);
    state.v2 = true;
  });

  it('validates target shapes and preserves UUID, omitted optional fields, and the same record on retry', async () => {
    const input = { id: randomUUID(), projectId, revision: 7, target: { kind: 'project' }, verdict: 'adopt', comment: null };
    const post = (body, key, bearer = allToken) => bridge.request('/v1/studio/reviews', { method: 'POST', token: bearer, key, body });
    assert.equal((await post(input, 'denied-read', readToken)).status, 403);
    assert.equal((await post(input, undefined)).body.error.code, 'idempotency_key_required');
    for (const bad of [
      { ...input, target: { kind: 'project', id: projectId } },
      { ...input, target: { kind: 'page' } },
      { ...input, target: { kind: 'version', id: 'bad' } },
      { ...input, verdict: null, comment: null },
      { ...input, verdict: null, comment: '  ' },
      { ...input, comment: 'x'.repeat(4001) },
      { ...input, verdict: 'unknown' },
      { ...input, extra: true },
    ]) assert.equal((await post(bad, randomUUID())).status, 400);
    const first = await post(input, 'review-one');
    assert.equal(first.status, 201);
    assert.equal(first.body.data.id, input.id);
    assert.equal(first.body.data.createdAt, now);
    assert.ok(!Object.hasOwn(first.body.data, 'comment'));
    const sameKey = await post(input, 'review-one');
    assert.equal(sameKey.status, 200);
    assert.equal(sameKey.headers.get('idempotency-replayed'), 'true');
    assert.deepEqual(sameKey.body.data, first.body.data);
    const newKey = await post({ ...input, comment: undefined }, 'review-two');
    assert.equal(newKey.status, 200);
    assert.deepEqual(newKey.body.data, first.body.data);
    assert.equal((await post({ ...input, verdict: 'reject' }, 'review-three')).body.error.code, 'studio_review_id_conflict');
    assert.equal(state.reviews.size, 1);
  });

  it('handles concurrent and lost-response retries using the same review UUID', async () => {
    const input = { id: randomUUID(), projectId, revision: 7, target: { kind: 'version', id: digest }, comment: 'Fixture review' };
    const post = (body, key) => bridge.request('/v1/studio/reviews', { method: 'POST', token: allToken, key, body });
    const concurrent = await Promise.all([post(input, randomUUID()), post(input, randomUUID())]);
    assert.deepEqual(concurrent.map((entry) => entry.status).sort(), [200, 201]);
    assert.deepEqual(concurrent[0].body.data, concurrent[1].body.data);
    const lost = { ...input, id: randomUUID(), target: { kind: 'page', id: 'page1' } };
    state.dropReviewResponse = true;
    assert.equal((await post(lost, 'lost-first')).status, 503);
    clock += 61_000;
    assert.equal((await post(lost, 'lost-first')).body.error.code, 'idempotency_outcome_unknown');
    await bridge.restart();
    const retried = await post(lost, 'lost-second');
    assert.equal(retried.status, 200);
    assert.equal(retried.body.data.id, lost.id);
    assert.equal(state.reviews.size, 3);
  });

  it('preserves Studio v2 error codes', async () => {
    const input = { id: randomUUID(), projectId, revision: 7, target: { kind: 'project' }, comment: 'Fixture' };
    for (const [status, code] of [[404, 'studio_project_missing'], [404, 'studio_review_target_missing'],
      [409, 'studio_review_id_conflict'], [409, 'studio_revision_unknown']]) {
      state.forcedError = { status, code };
      const result = await bridge.request('/v1/studio/reviews', { method: 'POST', token: allToken, key: randomUUID(), body: input });
      assert.equal(result.status, status);
      assert.equal(result.body.error.code, code);
    }
    state.forcedError = null;
  });

  it('streams PDF, USDZ, and large converted media with exact ranges and limits', async () => {
    for (const [ext, total] of [['mp4', 256 * mib], ['mp3', 256 * mib], ['pdf', 128 * mib], ['usdz', 128 * mib]]) {
      const path = `/v1/studio/media/${projectId}/${digest}.${ext}`;
      const result = await fetch(bridge.base + path, { headers: { authorization: `Bearer ${readToken}`, range: 'bytes=0-3' } });
      assert.equal(result.status, 206);
      assert.equal(result.headers.get('content-range'), `bytes 0-3/${total}`);
      assert.equal(result.headers.get('cache-control'), 'no-store');
      assert.equal(await result.text(), 'abcd');
      assert.equal(state.calls.at(-1).range, 'bytes=0-3');
      const outside = await fetch(bridge.base + path, { headers: { authorization: `Bearer ${readToken}`, range: 'bytes=999999999-' } });
      assert.equal(outside.status, 416);
      assert.equal(outside.headers.get('content-range'), `bytes */${total}`);
      const tooLarge = await bridge.request(`/v1/studio/media/${projectId}/${'f'.repeat(64)}.${ext}`, { token: readToken, headers: { range: 'bytes=0-3' } });
      assert.equal(tooLarge.body.error.code, 'studio_media_invalid');
      const malformed = await bridge.request(`/v1/studio/media/${projectId}/${'d'.repeat(64)}.${ext}`, { token: readToken, headers: { range: 'bytes=0-3' } });
      assert.equal(malformed.body.error.code, 'studio_media_invalid');
    }
  });

  it('closes the upstream stream when the client cancels', async () => {
    const abort = new AbortController();
    const path = `/v1/studio/media/${projectId}/${'e'.repeat(64)}.mp4`;
    const result = await fetch(bridge.base + path, { headers: { authorization: `Bearer ${readToken}` }, signal: abort.signal });
    const reader = result.body.getReader();
    assert.equal((await reader.read()).value.length, 1024);
    abort.abort();
    for (let attempt = 0; attempt < 100 && !state.closedStream; attempt += 1) await new Promise((resolve) => setTimeout(resolve, 10));
    assert.equal(state.closedStream, true);
  });
});

// End-to-end contract fixtures: Bridge -> private mock Studio Unix socket.
// These contain no Studio, Drive, or user data.
import { after, before, describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { createStudioBackend } from '../src/studio/backend.mjs';
import { startBridge } from './helpers.mjs';

const mib = 1024 * 1024;
const projectId = '70175325-5cf4-421f-8a6f-95beae8fca92';
const versionKey = 'a'.repeat(64);
const tag = `"${'b'.repeat(64)}"`;
const token = 'c'.repeat(64);
const now = '2026-11-01T03:00:00.000Z';
const project = { id: projectId, title: 'Fixture', revision: 7, pages: [{ id: 'page1', name: 'Cover' }], assets: [] };
const catalog = { etag: 'b'.repeat(64), updatedAt: now, principles: [], adoptedPrincipleId: null,
  documents: [{ id: 'doc1', title: 'Fixture', media: `/api/studio/media/catalog/${versionKey}.pdf` },
    { id: 'doc2', title: 'Unavailable fixture', driveUrl: 'https://drive.google.com/file/d/1234567890/view', unavailable: 'source_unreadable' }],
  capabilities: [], brief: [] };
const pdf = (() => {
  let body = '%PDF-1.4\n';
  const offsets = [0];
  for (const [index, object] of [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>',
  ].entries()) {
    offsets.push(Buffer.byteLength(body));
    body += `${index + 1} 0 obj\n${object}\nendobj\n`;
  }
  const xref = Buffer.byteLength(body);
  body += `xref\n0 4\n0000000000 65535 f \n${offsets.slice(1).map((value) => `${String(value).padStart(10, '0')} 00000 n \n`).join('')}`;
  body += `trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(body);
})();
// Opaque keys deliberately differ from the bytes' SHA-256.
const pdfKey = '9'.repeat(64);
const nextPdfKey = '8'.repeat(64);
assert.notEqual(pdfKey, createHash('sha256').update(pdf).digest('hex'));
assert.notEqual(nextPdfKey, createHash('sha256').update(pdf).digest('hex'));
const detail = { project, versions: [
  { id: versionKey, revision: 7, kind: 'video', name: 'preview.mp4', createdAt: now, bytes: 200 * mib,
    media: `/api/studio/media/${projectId}/${versionKey}.mp4`, previewOnly: true },
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
  const state = { reviews: new Map(), calls: [], forcedError: null, dropReviewResponse: false, v2: true, closedStream: false,
    catalog, catalogTag: tag, catalogFault: null, catalogDelayMs: 0, projectDelayMs: 0, snapshotDelayMs: 0,
    detail, retiredVersion: null, retiredPdfKey: null };

  before(async () => {
    dir = mkdtempSync(join(tmpdir(), 'laa-studio-v2-'));
    socket = join(dir, 'intake.sock');
    writeFileSync(join(dir, 'intake.json'), JSON.stringify({ version: 1, socketPath: socket, token, bootId: randomUUID(), pid: process.pid }), { mode: 0o600 });
    server = createServer(async (req, res) => {
      if (req.headers.authorization !== `Bearer ${token}`) return response(res, 401, { error: 'invalid_token' });
      state.calls.push({ method: req.method, path: req.url, range: req.headers.range, ifNoneMatch: req.headers['if-none-match'] });
      if (req.url === '/api/studio/snapshot') {
        if (state.snapshotDelayMs) await new Promise((resolve) => setTimeout(resolve, state.snapshotDelayMs));
        if (!res.destroyed) return response(res, 200, { online: true, accepting: true, contract: state.v2 ? 2 : 1, projects: [], principles: [], requests: [] });
        return;
      }
      if (!state.v2) return response(res, 404, { error: 'not_found' });
      if (req.url === '/api/studio/catalog') {
        if (state.catalogDelayMs) await new Promise((resolve) => setTimeout(resolve, state.catalogDelayMs));
        if (res.destroyed) return;
        if (state.catalogFault === 'unexpected304') { res.writeHead(304, { etag: state.catalogTag }); return res.end(); }
        const matches = (req.headers['if-none-match'] ?? '').split(',').some((item) => item.trim().replace(/^W\//, '') === state.catalogTag);
        if (matches) { res.writeHead(304, state.catalogFault === 'missingTag' ? {} : { etag: state.catalogTag }); return res.end(); }
        if (state.catalogFault !== 'missingTag') res.setHeader('etag', state.catalogTag);
        return response(res, 200, state.catalog);
      }
      if (req.url === `/api/studio/projects/${projectId}`) {
        if (state.projectDelayMs) await new Promise((resolve) => setTimeout(resolve, state.projectDelayMs));
        if (!res.destroyed) return response(res, 200, state.detail);
        return;
      }
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
        if (review.target.kind === 'version' && review.target.id === state.retiredVersion) {
          return response(res, 404, { error: 'studio_review_target_missing' });
        }
        if (review.revision > project.revision) return response(res, 409, { error: 'studio_revision_unknown' });
        const record = { ...review, createdAt: now };
        state.reviews.set(review.id, record);
        if (state.dropReviewResponse) { state.dropReviewResponse = false; return req.socket.destroy(); }
        return response(res, 201, record);
      }
      const media = /^\/api\/studio\/media\/([\w-]+)\/([a-f0-9]{64})\.(mp4|mp3|pdf|usdz)$/.exec(req.url ?? '');
      if (media) {
        const [, , mediaKey, ext] = media;
        const type = { mp4: 'video/mp4', mp3: 'audio/mpeg', pdf: 'application/pdf', usdz: 'model/vnd.usdz+zip' }[ext];
        if (ext === 'pdf' && mediaKey === state.retiredPdfKey) return response(res, 404, { error: 'not_found' });
        if (ext === 'pdf' && [pdfKey, nextPdfKey].includes(mediaKey)) {
          const range = /^bytes=(\d+)-(\d*)$/.exec(req.headers.range ?? '');
          if (req.headers.range && (!range || Number(range[1]) >= pdf.length || (range[2] && Number(range[2]) < Number(range[1])))) {
            res.writeHead(416, { 'content-range': `bytes */${pdf.length}` }); return res.end();
          }
          if (!range) { res.writeHead(200, { 'content-type': type, 'content-length': pdf.length, 'accept-ranges': 'bytes' }); return res.end(pdf); }
          const start = Number(range[1]), end = Math.min(range[2] ? Number(range[2]) : pdf.length - 1, pdf.length - 1);
          res.writeHead(206, { 'content-type': type, 'content-length': end - start + 1,
            'content-range': `bytes ${start}-${end}/${pdf.length}`, 'accept-ranges': 'bytes' });
          return res.end(pdf.subarray(start, end + 1));
        }
        const limit = (ext === 'mp4' || ext === 'mp3' ? 256 : 128) * mib;
        const total = mediaKey.startsWith('f') ? limit + 1 : limit;
        if (mediaKey.startsWith('e')) {
          res.writeHead(200, { 'content-type': type, 'content-length': 1024 * 1024 });
          res.write(Buffer.alloc(1024));
          res.on('close', () => { state.closedStream = true; });
          return;
        }
        if (req.headers.range === 'bytes=999999999-') { res.writeHead(416, { 'content-range': `bytes */${total}` }); return res.end(); }
        const range = mediaKey.startsWith('d') ? `bytes 0-4/${total}` : `bytes 0-3/${total}`;
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

  it('refreshes eight previously unavailable documents when the catalog validator changes', async () => {
    const documents = Array.from({ length: 8 }, (_, index) => ({
      id: `fixture-${index + 1}`, title: `Fixture ${index + 1}`, category: 'Fixture', detail: 'Synthetic document', format: 'PDF',
      driveUrl: `https://drive.google.com/file/d/fixture-document-${index + 1}/view`,
    }));
    const newTag = `"${'c'.repeat(64)}"`;
    try {
      state.catalog = { ...catalog, documents: documents.map((document) => ({ ...document, unavailable: 'source_unreadable' })) };
      const old = await bridge.request('/v1/studio/catalog', { token: readToken });
      assert.equal(old.status, 200);
      assert.equal(old.headers.get('etag'), tag);
      assert.equal(old.body.data.documents.length, 8);
      assert.ok(old.body.data.documents.every((document) => document.unavailable === 'source_unreadable' && !document.media));

      state.catalogTag = newTag;
      state.catalog = { ...catalog, etag: 'c'.repeat(64), documents: documents.map((document) => ({
        ...document, media: `/api/studio/media/catalog/${pdfKey}.pdf`, bytes: pdf.length,
      })) };
      const updated = await bridge.request('/v1/studio/catalog', { token: readToken, headers: { 'if-none-match': tag } });
      assert.equal(state.calls.at(-1).ifNoneMatch, tag);
      assert.equal(updated.status, 200);
      assert.equal(updated.headers.get('etag'), newTag);
      assert.equal(updated.body.data.etag, 'c'.repeat(64));
      assert.equal(updated.body.data.documents.length, 8);
      assert.ok(updated.body.data.documents.every((document) => document.media && document.bytes === pdf.length && !document.unavailable));

      const unchanged = await bridge.request('/v1/studio/catalog', { token: readToken, headers: { 'if-none-match': newTag } });
      assert.equal(unchanged.status, 304);
      assert.equal(unchanged.body, null);
      assert.equal(unchanged.headers.get('etag'), newTag);
    } finally { state.catalog = catalog; state.catalogTag = tag; }
  });

  it('waits for slow initial catalog and project responses through the Bridge', async () => {
    state.catalogDelayMs = 12_250; // Longer than the former 12-second socket timeout.
    state.projectDelayMs = 12_250;
    try {
      const [result, work] = await Promise.all([
        bridge.request('/v1/studio/catalog', { token: readToken }),
        bridge.request(`/v1/studio/projects/${projectId}`, { token: readToken }),
      ]);
      assert.equal(result.status, 200);
      assert.equal(result.body.data.documents[1].unavailable, 'source_unreadable');
      assert.equal(result.body.data.documents[1].driveUrl, catalog.documents[1].driveUrl);
      assert.equal(work.status, 200);
      assert.deepEqual(work.body.data, detail);
    } finally { state.catalogDelayMs = 0; state.projectDelayMs = 0; }
  });

  it('bounds catalog and project waits independently without extending other requests', async () => {
    const timed = createStudioBackend({ directory: dir, launch: async () => {}, requestTimeoutMs: 100, catalogTimeoutMs: 1000, projectTimeoutMs: 1000 });
    try {
      state.catalogDelayMs = 350;
      state.projectDelayMs = 350;
      const [result, work] = await Promise.all([timed.catalog(), timed.project(projectId)]);
      assert.equal(result.status, 200);
      assert.deepEqual(work, detail);
      assert.equal((await timed.catalog(tag)).status, 304);
      state.snapshotDelayMs = 350;
      await assert.rejects(timed.snapshot(), { code: 'studio_not_connected' });
      state.catalogDelayMs = 1600;
      state.projectDelayMs = 1600;
      await Promise.all([
        assert.rejects(timed.catalog(), { code: 'studio_not_connected' }),
        assert.rejects(timed.project(projectId), { code: 'studio_not_connected' }),
      ]);
    } finally { state.catalogDelayMs = 0; state.projectDelayMs = 0; state.snapshotDelayMs = 0; }
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
    const input = { id: randomUUID(), projectId, revision: 7, target: { kind: 'version', id: versionKey }, comment: 'Fixture review' };
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

  it('treats changed version and media keys as opaque while preserving review outcomes', async () => {
    const nextVersion = '7'.repeat(64);
    const input = { id: randomUUID(), projectId, revision: 7, target: { kind: 'version', id: versionKey }, comment: 'Original version' };
    const post = (body) => bridge.request('/v1/studio/reviews', { method: 'POST', token: allToken, key: randomUUID(), body });
    const headers = { authorization: `Bearer ${readToken}` };
    const oldPath = `/v1/studio/media/catalog/${pdfKey}.pdf`;
    const nextPath = `/v1/studio/media/catalog/${nextPdfKey}.pdf`;
    try {
      const saved = await post(input);
      assert.equal(saved.status, 201);
      const firstMedia = await fetch(bridge.base + oldPath, { headers });
      assert.equal(firstMedia.status, 200);
      assert.deepEqual(Buffer.from(await firstMedia.arrayBuffer()), pdf);

      state.retiredVersion = versionKey;
      state.retiredPdfKey = pdfKey;
      state.detail = { ...detail, versions: [{ ...detail.versions[0], id: nextVersion,
        media: `/api/studio/media/${projectId}/${nextVersion}.mp4` }, ...detail.versions.slice(1)] };
      state.catalogTag = `"${'c'.repeat(64)}"`;
      state.catalog = { ...catalog, etag: 'c'.repeat(64), documents: [{ ...catalog.documents[0], media: `/api/studio/media/catalog/${nextPdfKey}.pdf` }] };

      const refreshed = await bridge.request('/v1/studio/catalog', { token: readToken, headers: { 'if-none-match': tag } });
      assert.equal(refreshed.status, 200);
      assert.equal(refreshed.body.data.documents[0].media, `/api/studio/media/catalog/${nextPdfKey}.pdf`);
      assert.equal((await bridge.request('/v1/studio/catalog', { token: readToken, headers: { 'if-none-match': state.catalogTag } })).status, 304);
      assert.equal((await fetch(bridge.base + oldPath, { headers })).status, 404);
      const nextMedia = await fetch(bridge.base + nextPath, { headers });
      assert.equal(nextMedia.status, 200);
      assert.deepEqual(Buffer.from(await nextMedia.arrayBuffer()), pdf);
      const work = await bridge.request(`/v1/studio/projects/${projectId}`, { token: readToken });
      assert.equal(work.body.data.versions[0].id, nextVersion);
      assert.equal(Object.hasOwn(work.body.data.versions[0], 'width'), false);
      assert.equal(Object.hasOwn(work.body.data.versions[0], 'height'), false);
      assert.equal(Object.hasOwn(work.body.data.versions[0], 'duration'), false);

      const replay = await post(input);
      assert.equal(replay.status, 200);
      assert.deepEqual(replay.body.data, saved.body.data);
      const missing = await post({ ...input, id: randomUUID() });
      assert.equal(missing.status, 404);
      assert.equal(missing.body.error.code, 'studio_review_target_missing');
      const conflict = await post({ ...input, target: { kind: 'version', id: nextVersion } });
      assert.equal(conflict.status, 409);
      assert.equal(conflict.body.error.code, 'studio_review_id_conflict');
      const future = await post({ ...input, id: randomUUID(), revision: 8, target: { kind: 'version', id: nextVersion } });
      assert.equal(future.status, 409);
      assert.equal(future.body.error.code, 'studio_revision_unknown');
      const retargeted = await post({ ...input, id: randomUUID(), target: { kind: 'version', id: nextVersion } });
      assert.equal(retargeted.status, 201);
    } finally {
      state.detail = detail; state.retiredVersion = null; state.retiredPdfKey = null;
      state.catalog = catalog; state.catalogTag = tag;
    }
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
      const path = `/v1/studio/media/${projectId}/${versionKey}.${ext}`;
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

  it('serves catalog PDF bytes with 200, 206, and out-of-range 416', async () => {
    const path = `/v1/studio/media/catalog/${pdfKey}.pdf`;
    const headers = { authorization: `Bearer ${readToken}` };
    const full = await fetch(bridge.base + path, { headers });
    assert.equal(full.status, 200);
    assert.equal(full.headers.get('content-type'), 'application/pdf');
    assert.equal(full.headers.get('content-length'), String(pdf.length));
    assert.equal(full.headers.get('cache-control'), 'no-store');
    assert.deepEqual(Buffer.from(await full.arrayBuffer()), pdf);

    const part = await fetch(bridge.base + path, { headers: { ...headers, range: 'bytes=4-13' } });
    assert.equal(part.status, 206);
    assert.equal(part.headers.get('content-type'), 'application/pdf');
    assert.equal(part.headers.get('content-range'), `bytes 4-13/${pdf.length}`);
    assert.deepEqual(Buffer.from(await part.arrayBuffer()), pdf.subarray(4, 14));
    assert.equal(state.calls.at(-1).range, 'bytes=4-13');

    const outside = await fetch(bridge.base + path, { headers: { ...headers, range: `bytes=${pdf.length}-` } });
    assert.equal(outside.status, 416);
    assert.equal(outside.headers.get('content-range'), `bytes */${pdf.length}`);
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

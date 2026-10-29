// HTTP contract for /v1/drive/files. The Drive adapter is a fake here, so the
// test pins the Bridge behaviour (status codes, headers, range relay,
// cancellation) without the owner's Drive or a Google credential.

import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import { after, before, describe, it } from 'node:test';
import { startBridge } from './helpers.mjs';
import { parseRange } from '../src/routes/drive.mjs';
import { DriveNotConfiguredError } from '../src/drive/google-api.mjs';

const VIDEO = Buffer.from(Array.from({ length: 4096 }, (_, i) => i % 251));

function folder(id, name, parents = []) {
  return { id, name, mimeType: 'application/vnd.google-apps.folder', kind: 'folder', size: null, modifiedAt: null, parents, downloadable: false, webViewLink: `https://drive.google.com/drive/folders/${id}` };
}

function file(id, name, body, mimeType = 'video/mp4') {
  return {
    id,
    name,
    mimeType,
    kind: 'file',
    size: body.length,
    modifiedAt: '2026-10-25T13:00:00.000Z',
    parents: [],
    downloadable: true,
    webViewLink: `https://drive.google.com/file/d/${id}/view`,
    body,
  };
}

const DOC = {
  id: 'doc_workspace_1',
  name: 'Drive運用ルール',
  mimeType: 'application/vnd.google-apps.document',
  kind: 'workspace_document',
  size: null,
  modifiedAt: '2026-10-20T00:00:00.000Z',
  parents: [],
  downloadable: false,
  exportFormats: ['application/pdf'],
  webViewLink: 'https://drive.google.com/file/d/doc_workspace_1/view',
};

// Emulates the two Drive API behaviours the route depends on: page tokens and
// files.get?alt=media answering the forwarded Range with 206/416.
function fakeDrive({ slow = false, unavailable = false } = {}) {
  const items = [
    folder('folder_root_1', 'Studio'),
    folder('folder_video_1', '会社資料', ['folder_root_1']),
    { ...file('file_video_1', 'PR動画.mp4', VIDEO), parents: ['folder_video_1'] },
    file('file_small_1', 'note.pdf', Buffer.from('%PDF-1.7 test')),
    DOC,
  ];
  const state = { opened: 0, destroyed: 0, aborted: 0, ranges: [] };
  return {
    state,
    async list({ query = '', folderId = null, pageSize = 50, pageToken = null }) {
      if (unavailable) throw new DriveNotConfiguredError();
      const offset = pageToken === null ? 0 : Number(pageToken.replace('tok-', ''));
      const filtered = items.filter((item) => {
        if (folderId !== null && (item.parents[0] ?? null) !== folderId) return false;
        return item.name.toLowerCase().includes(query.toLowerCase());
      });
      const page = filtered.slice(offset, offset + pageSize);
      const next = offset + page.length;
      return { items: page, nextPageToken: next < filtered.length ? `tok-${next}` : null };
    },
    async get(id) {
      if (unavailable) throw new DriveNotConfiguredError();
      const item = items.find((candidate) => candidate.id === id);
      if (!item) return null;
      const { body, ...publicItem } = item;
      return { item: publicItem, etag: `"${(item.size ?? 0).toString(16)}"` };
    },
    async open(id, { range = null, signal } = {}) {
      if (unavailable) throw new DriveNotConfiguredError();
      const item = items.find((candidate) => candidate.id === id);
      if (!item || item.kind !== 'file') return null;
      state.opened += 1;
      state.ranges.push(range);
      const size = item.body.length;
      const parsed = parseRange(range, size);
      const headers = new Headers({
        'content-type': item.mimeType,
        'accept-ranges': 'bytes',
        etag: `"${size.toString(16)}"`,
      });
      if (parsed.kind === 'unsatisfiable') {
        headers.set('content-range', `bytes */${size}`);
        return { status: 416, headers, stream: Readable.from([]) };
      }
      const start = parsed.kind === 'range' ? parsed.start : 0;
      const end = parsed.kind === 'range' ? parsed.end : size - 1;
      const body = item.body.subarray(start, end + 1);
      headers.set('content-length', String(body.length));
      if (parsed.kind === 'range') headers.set('content-range', `bytes ${start}-${end}/${size}`);
      signal?.addEventListener('abort', () => {
        state.aborted += 1;
      });
      const stream = slow
        ? new Readable({
            read() {
              setTimeout(() => this.push(body.subarray(0, 16)), 5);
            },
            destroy(error, callback) {
              state.destroyed += 1;
              callback(error);
            },
          })
        : Readable.from(body);
      return { status: parsed.kind === 'range' ? 206 : 200, headers, stream };
    },
  };
}

async function pairDevice(bridge, scopes) {
  const { code } = await bridge.pair(scopes ? { scopes } : {});
  const response = await bridge.enroll(code);
  assert.equal(response.status, 201);
  return response.body.data.token;
}

describe('drive list and metadata', () => {
  let bridge;
  let token;
  let drive;

  before(async () => {
    drive = fakeDrive();
    bridge = await startBridge({ drive });
    token = await pairDevice(bridge);
  });
  after(async () => bridge.close());

  it('requires a device token', async () => {
    const response = await bridge.request('/v1/drive/files');
    assert.equal(response.status, 401);
    assert.equal(response.body.error.code, 'unauthenticated');
  });

  it('requires media:read', async () => {
    const other = await pairDevice(bridge, ['sessions:read']);
    const response = await bridge.request('/v1/drive/files', { token: other });
    assert.equal(response.status, 403);
    assert.equal(response.body.error.code, 'insufficient_scope');
  });

  it('lists items with an opaque next cursor', async () => {
    const first = await bridge.request('/v1/drive/files?pageSize=2', { token });
    assert.equal(first.status, 200);
    assert.equal(first.body.data.items.length, 2);
    assert.equal(first.body.data.items[0].kind, 'folder');
    assert.ok(first.body.data.nextCursor);
    const seen = new Set(first.body.data.items.map((item) => item.id));
    let cursor = first.body.data.nextCursor;
    let pages = 1;
    while (cursor) {
      const page = await bridge.request(`/v1/drive/files?pageSize=2&cursor=${encodeURIComponent(cursor)}`, { token });
      assert.equal(page.status, 200);
      for (const item of page.body.data.items) seen.add(item.id);
      cursor = page.body.data.nextCursor;
      pages += 1;
      assert.ok(pages < 10, 'pagination must terminate');
    }
    assert.equal(seen.size, 5);
    assert.equal(pages, 3);
  });

  it('rejects a cursor that belongs to a different query', async () => {
    const first = await bridge.request('/v1/drive/files?pageSize=1', { token });
    const response = await bridge.request(
      `/v1/drive/files?pageSize=1&query=PR&cursor=${encodeURIComponent(first.body.data.nextCursor)}`,
      { token },
    );
    assert.equal(response.status, 400);
    assert.equal(response.body.error.code, 'cursor_invalid');
  });

  it('rejects a cursor older than 24 hours', async () => {
    const first = await bridge.request('/v1/drive/files?pageSize=1', { token });
    const decoded = JSON.parse(Buffer.from(first.body.data.nextCursor, 'base64url').toString('utf8'));
    const stale = Buffer.from(JSON.stringify({ ...decoded, t: decoded.t - 25 * 60 * 60 * 1000 })).toString('base64url');
    const response = await bridge.request(`/v1/drive/files?pageSize=1&cursor=${encodeURIComponent(stale)}`, { token });
    assert.equal(response.status, 410);
    assert.equal(response.body.error.code, 'cursor_expired');
  });

  it('searches by name and filters by folder', async () => {
    const search = await bridge.request('/v1/drive/files?query=pr%E5%8B%95%E7%94%BB', { token });
    assert.equal(search.status, 200);
    assert.deepEqual(search.body.data.items.map((item) => item.id), ['file_video_1']);
    const inFolder = await bridge.request('/v1/drive/files?folderId=folder_video_1', { token });
    assert.deepEqual(inFolder.body.data.items.map((item) => item.id), ['file_video_1']);
  });

  it('validates paging and ids', async () => {
    assert.equal((await bridge.request('/v1/drive/files?pageSize=0', { token })).status, 400);
    assert.equal((await bridge.request('/v1/drive/files?pageSize=201', { token })).status, 400);
    assert.equal((await bridge.request('/v1/drive/files?folderId=../etc', { token })).status, 400);
  });

  it('returns metadata, 404 outside the index, and distinguishes Workspace documents', async () => {
    const meta = await bridge.request('/v1/drive/files/file_video_1', { token });
    assert.equal(meta.status, 200);
    assert.equal(meta.body.data.mimeType, 'video/mp4');
    assert.equal(meta.body.data.size, VIDEO.length);
    assert.equal(meta.body.data.downloadable, true);

    const missing = await bridge.request('/v1/drive/files/file_unknown_1', { token });
    assert.equal(missing.status, 404);

    const doc = await bridge.request('/v1/drive/files/doc_workspace_1', { token });
    assert.equal(doc.status, 200);
    assert.equal(doc.body.data.kind, 'workspace_document');
    assert.equal(doc.body.data.downloadable, false);
    assert.deepEqual(doc.body.data.exportFormats, ['application/pdf']);
  });
});

describe('drive content and ranges', () => {
  let bridge;
  let token;
  let drive;

  before(async () => {
    drive = fakeDrive();
    bridge = await startBridge({ drive });
    token = await pairDevice(bridge);
  });
  after(async () => bridge.close());

  it('serves the whole file with MIME and length', async () => {
    const response = await fetch(`${bridge.base}/v1/drive/files/file_video_1/content`, {
      headers: { authorization: `Bearer ${token}` },
    });
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('content-type'), 'video/mp4');
    assert.equal(response.headers.get('content-length'), String(VIDEO.length));
    assert.equal(response.headers.get('accept-ranges'), 'bytes');
    const body = Buffer.from(await response.arrayBuffer());
    assert.equal(body.length, VIDEO.length);
    assert.ok(body.equals(VIDEO));
  });

  it('forwards the Range header and relays 206 with Content-Range', async () => {
    const response = await fetch(`${bridge.base}/v1/drive/files/file_video_1/content`, {
      headers: { authorization: `Bearer ${token}`, range: 'bytes=2000-2999' },
    });
    assert.equal(response.status, 206);
    assert.equal(response.headers.get('content-range'), `bytes 2000-2999/${VIDEO.length}`);
    assert.equal(response.headers.get('content-length'), '1000');
    const body = Buffer.from(await response.arrayBuffer());
    assert.ok(body.equals(VIDEO.subarray(2000, 3000)));
    assert.equal(drive.state.ranges.at(-1), 'bytes=2000-2999', 'the client Range reaches the adapter unchanged');
  });

  it('supports open-ended and suffix ranges', async () => {
    const openEnded = await fetch(`${bridge.base}/v1/drive/files/file_video_1/content`, {
      headers: { authorization: `Bearer ${token}`, range: 'bytes=4000-' },
    });
    assert.equal(openEnded.status, 206);
    assert.equal(openEnded.headers.get('content-range'), `bytes 4000-${VIDEO.length - 1}/${VIDEO.length}`);
    assert.equal((await openEnded.arrayBuffer()).byteLength, VIDEO.length - 4000);

    const suffix = await fetch(`${bridge.base}/v1/drive/files/file_video_1/content`, {
      headers: { authorization: `Bearer ${token}`, range: 'bytes=-10' },
    });
    assert.equal(suffix.status, 206);
    assert.equal(suffix.headers.get('content-range'), `bytes ${VIDEO.length - 10}-${VIDEO.length - 1}/${VIDEO.length}`);
    assert.ok(Buffer.from(await suffix.arrayBuffer()).equals(VIDEO.subarray(-10)));
  });

  it('relays a 416 from Drive with its Content-Range', async () => {
    const response = await fetch(`${bridge.base}/v1/drive/files/file_video_1/content`, {
      headers: { authorization: `Bearer ${token}`, range: `bytes=${VIDEO.length + 10}-` },
    });
    assert.equal(response.status, 416);
    assert.equal(response.headers.get('content-range'), `bytes */${VIDEO.length}`);
    const body = await response.text();
    assert.equal(response.headers.get('content-length'), String(Buffer.byteLength(body)));
    assert.equal(JSON.parse(body).error.code, 'range_not_satisfiable');
  });

  it('answers HEAD from metadata without opening the media endpoint', async () => {
    const openedBefore = drive.state.opened;
    const response = await fetch(`${bridge.base}/v1/drive/files/file_video_1/content`, {
      method: 'HEAD',
      headers: { authorization: `Bearer ${token}`, range: 'bytes=0-99' },
    });
    assert.equal(response.status, 206);
    assert.equal(response.headers.get('content-length'), '100');
    assert.equal(response.headers.get('content-range'), `bytes 0-99/${VIDEO.length}`);
    assert.equal((await response.arrayBuffer()).byteLength, 0);
    assert.equal(drive.state.opened, openedBefore, 'HEAD must not open the media stream');

    const headFull = await fetch(`${bridge.base}/v1/drive/files/file_video_1/content`, {
      method: 'HEAD',
      headers: { authorization: `Bearer ${token}` },
    });
    assert.equal(headFull.status, 200);
    assert.equal(headFull.headers.get('content-length'), String(VIDEO.length));
  });

  it('refuses to stream a Workspace document and a folder', async () => {
    const doc = await bridge.request('/v1/drive/files/doc_workspace_1/content', { token });
    assert.equal(doc.status, 409);
    assert.equal(doc.body.error.code, 'export_required');
    assert.match(doc.body.error.message, /application\/pdf/);

    const folderResponse = await bridge.request('/v1/drive/files/folder_root_1/content', { token });
    assert.equal(folderResponse.status, 400);
    assert.equal(folderResponse.body.error.code, 'not_a_file');
  });

  it('aborts the upstream request when the client disconnects', async () => {
    const slow = fakeDrive({ slow: true });
    const slowBridge = await startBridge({ drive: slow });
    const slowToken = await pairDevice(slowBridge);
    const controller = new AbortController();
    const response = await fetch(`${slowBridge.base}/v1/drive/files/file_video_1/content`, {
      headers: { authorization: `Bearer ${slowToken}` },
      signal: controller.signal,
    });
    assert.equal(response.status, 200);
    const reader = response.body.getReader();
    await reader.read();
    controller.abort();
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
    assert.equal(slow.state.destroyed, 1, 'the upstream stream must be destroyed on abort');
    assert.equal(slow.state.aborted, 1, 'the adapter signal must be aborted');
    // The server keeps serving other requests after a cancelled stream.
    const health = await slowBridge.request('/v1/health');
    assert.equal(health.status, 200);
    await slowBridge.close();
  });
});

describe('drive configuration and failures', () => {
  it('reports an unconfigured Drive as 503 drive_not_configured', async () => {
    const bridge = await startBridge({ drive: null });
    const token = await pairDevice(bridge);
    const response = await bridge.request('/v1/drive/files', { token });
    assert.equal(response.status, 503);
    assert.equal(response.body.error.code, 'drive_not_configured');
    await bridge.close();
  });

  it('reports a missing Drive authorization as 503, not an empty list', async () => {
    const bridge = await startBridge({ drive: fakeDrive({ unavailable: true }) });
    const token = await pairDevice(bridge);
    const response = await bridge.request('/v1/drive/files', { token });
    assert.equal(response.status, 503);
    assert.equal(response.body.error.code, 'drive_not_configured');
    await bridge.close();
  });
});

describe('range parsing', () => {
  it('classifies headers', () => {
    assert.deepEqual(parseRange(undefined, 100), { kind: 'full' });
    assert.deepEqual(parseRange('bytes=0-9', 100), { kind: 'range', start: 0, end: 9 });
    assert.deepEqual(parseRange('bytes=90-', 100), { kind: 'range', start: 90, end: 99 });
    assert.deepEqual(parseRange('bytes=-10', 100), { kind: 'range', start: 90, end: 99 });
    assert.deepEqual(parseRange('bytes=0-1000', 100), { kind: 'range', start: 0, end: 99 });
    assert.deepEqual(parseRange('bytes=100-', 100), { kind: 'unsatisfiable' });
    assert.deepEqual(parseRange('bytes=-0', 100), { kind: 'unsatisfiable' });
    assert.deepEqual(parseRange('bytes=0-9,20-29', 100), { kind: 'ignore' });
    assert.deepEqual(parseRange('items=0-9', 100), { kind: 'ignore' });
    assert.deepEqual(parseRange('bytes=abc', 100), { kind: 'ignore' });
  });
});

// Google Drive API adapter tests against a local fake of the Drive v3 API, so
// the request shape (q, fields, page tokens, Range forwarding) and the error
// mapping are pinned without a Google credential.

import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { after, before, describe, it } from 'node:test';
import { startBridge } from './helpers.mjs';
import {
  DriveAuthError,
  DriveNotConfiguredError,
  DriveUpstreamError,
  createGoogleDriveApiAdapter,
  createRefreshTokenProvider,
  driveAdapterFromEnv,
  itemFromDrive,
} from '../src/drive/google-api.mjs';

const VIDEO = Buffer.from(Array.from({ length: 2048 }, (_, i) => i % 251));
const ACCESS_TOKEN = 'test-access-token';

function fileRecord(overrides = {}) {
  return {
    id: 'file_video_1',
    name: 'PR動画.mp4',
    mimeType: 'video/mp4',
    size: String(VIDEO.length),
    modifiedTime: '2026-10-25T13:00:00.000Z',
    parents: ['folder_company_1'],
    webViewLink: 'https://drive.google.com/file/d/file_video_1/view',
    ...overrides,
  };
}

// Minimal Drive v3 surface: files.list, files.get (metadata) and
// files.get?alt=media with Range.
function fakeDriveApi() {
  const requests = [];
  const server = createServer(async (req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1');
    requests.push({
      path: url.pathname,
      query: Object.fromEntries(url.searchParams),
      range: req.headers.range ?? null,
      authorization: req.headers.authorization ?? null,
    });
    if (req.headers.authorization !== `Bearer ${ACCESS_TOKEN}`) {
      res.writeHead(401, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: { message: 'Invalid Credentials' } }));
      return;
    }
    if (url.pathname === '/drive/v3/files') {
      if (url.searchParams.get('pageToken') === 'page-2') {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({
          files: [{
            id: 'doc_1',
            name: 'Drive運用ルール',
            mimeType: 'application/vnd.google-apps.document',
            modifiedTime: '2026-10-20T00:00:00.000Z',
            parents: ['root_1'],
          }],
        }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ nextPageToken: 'page-2', files: [fileRecord()] }));
      return;
    }
    const match = /^\/drive\/v3\/files\/([A-Za-z0-9_-]+)$/.exec(url.pathname);
    if (match) {
      const id = match[1];
      if (id === 'missing_file_1') {
        res.writeHead(404, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: { message: 'File not found' } }));
        return;
      }
      if (id === 'trashed_file_1') {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify(fileRecord({ id, trashed: true })));
        return;
      }
      if (url.searchParams.get('alt') === 'media') {
        const range = req.headers.range;
        if (!range) {
          res.writeHead(200, { 'content-type': 'video/mp4', 'content-length': String(VIDEO.length), 'accept-ranges': 'bytes', etag: '"etag-1"' });
          res.end(VIDEO);
          return;
        }
        const spec = /^bytes=(\d+)-(\d*)$/.exec(range);
        const start = Number(spec[1]);
        const end = spec[2] === '' ? VIDEO.length - 1 : Math.min(Number(spec[2]), VIDEO.length - 1);
        if (start >= VIDEO.length) {
          res.writeHead(416, { 'content-range': `bytes */${VIDEO.length}` });
          res.end();
          return;
        }
        const body = VIDEO.subarray(start, end + 1);
        res.writeHead(206, {
          'content-type': 'video/mp4',
          'content-range': `bytes ${start}-${end}/${VIDEO.length}`,
          'content-length': String(body.length),
          'accept-ranges': 'bytes',
          etag: '"etag-1"',
        });
        res.end(body);
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json', etag: '"etag-1"' });
      res.end(JSON.stringify(fileRecord({ id })));
      return;
    }
    res.writeHead(500, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: { message: 'boom' } }));
  });
  return { server, requests };
}

describe('google drive api adapter', () => {
  let fake;
  let baseUrl;
  let adapter;

  before(async () => {
    fake = fakeDriveApi();
    await new Promise((resolve) => fake.server.listen(0, '127.0.0.1', resolve));
    baseUrl = `http://127.0.0.1:${fake.server.address().port}/drive/v3`;
    adapter = createGoogleDriveApiAdapter({ getAccessToken: async () => ACCESS_TOKEN, baseUrl });
  });
  after(async () => new Promise((resolve) => fake.server.close(resolve)));

  it('lists with the Drive query language and page tokens', async () => {
    const first = await adapter.list({ query: "PR'動画", folderId: 'folder_company_1', pageSize: 25 });
    assert.equal(first.items.length, 1);
    assert.equal(first.items[0].kind, 'file');
    assert.equal(first.items[0].size, VIDEO.length);
    assert.equal(first.nextPageToken, 'page-2');
    const request = fake.requests.at(-1);
    assert.equal(request.query.q, "trashed = false and 'folder_company_1' in parents and name contains 'PR\\'動画'");
    assert.equal(request.query.pageSize, '25');
    assert.equal(request.query.corpora, 'allDrives');
    assert.equal(request.query.includeItemsFromAllDrives, 'true');
    assert.equal(request.query.supportsAllDrives, 'true');
    assert.match(request.query.fields, /nextPageToken,files\(id,name,mimeType,size/);

    const second = await adapter.list({ pageToken: 'page-2' });
    assert.equal(second.items[0].kind, 'workspace_document');
    assert.deepEqual(second.items[0].exportFormats, [
      'application/pdf',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'text/plain',
    ]);
    assert.equal(second.items[0].size, null);
    assert.equal(second.nextPageToken, null);
  });

  it('maps metadata and hides missing or trashed files', async () => {
    const found = await adapter.get('file_video_1');
    assert.equal(found.item.mimeType, 'video/mp4');
    assert.equal(found.etag, '"etag-1"');
    assert.equal(await adapter.get('missing_file_1'), null);
    assert.equal(await adapter.get('trashed_file_1'), null);
    assert.equal(await adapter.get('not a drive id'), null);
  });

  it('forwards the Range header to files.get?alt=media', async () => {
    const opened = await adapter.open('file_video_1', { range: 'bytes=100-199' });
    assert.equal(opened.status, 206);
    assert.equal(opened.headers.get('content-range'), `bytes 100-199/${VIDEO.length}`);
    const chunks = [];
    for await (const chunk of opened.stream) chunks.push(chunk);
    assert.ok(Buffer.concat(chunks).equals(VIDEO.subarray(100, 200)));
    const request = fake.requests.at(-1);
    assert.equal(request.query.alt, 'media');
    assert.equal(request.range, 'bytes=100-199');
  });

  it('relays an unsatisfiable range as 416', async () => {
    const opened = await adapter.open('file_video_1', { range: `bytes=${VIDEO.length + 5}-` });
    assert.equal(opened.status, 416);
    assert.equal(opened.headers.get('content-range'), `bytes */${VIDEO.length}`);
  });

  it('maps a refused credential to DriveAuthError', async () => {
    const wrong = createGoogleDriveApiAdapter({ getAccessToken: async () => 'expired-token', baseUrl });
    await assert.rejects(() => wrong.list({}), DriveAuthError);
  });

  it('maps an upstream failure to DriveUpstreamError', async () => {
    const broken = createGoogleDriveApiAdapter({ getAccessToken: async () => ACCESS_TOKEN, baseUrl: `${baseUrl}/broken` });
    await assert.rejects(() => broken.list({}), DriveUpstreamError);
  });

  it('refuses to call anything without a configured token provider', async () => {
    const unconfigured = createGoogleDriveApiAdapter({});
    assert.equal(unconfigured.configured, false);
    await assert.rejects(() => unconfigured.list({}), DriveNotConfiguredError);
    await assert.rejects(() => unconfigured.get('file_video_1'), DriveNotConfiguredError);
  });

  it('reads credentials only from the environment when all three are present', () => {
    assert.equal(driveAdapterFromEnv({}), null);
    assert.equal(driveAdapterFromEnv({ LAA_DRIVE_CLIENT_ID: 'id', LAA_DRIVE_REFRESH_TOKEN: 'rt' }), null);
    const configured = driveAdapterFromEnv({
      LAA_DRIVE_CLIENT_ID: 'id',
      LAA_DRIVE_CLIENT_SECRET: 'secret',
      LAA_DRIVE_REFRESH_TOKEN: 'rt',
    });
    assert.equal(configured.configured, true);
  });
});

describe('refresh token provider', () => {
  it('exchanges once and reuses the cached token', async () => {
    let calls = 0;
    const fetchImpl = async (url, init) => {
      calls += 1;
      assert.equal(url, 'https://oauth2.googleapis.com/token');
      assert.match(init.body, /grant_type=refresh_token/);
      assert.match(init.body, /refresh_token=rt/);
      return new Response(JSON.stringify({ access_token: 'at-1', expires_in: 3600 }), { status: 200 });
    };
    let clock = 1_000_000;
    const provider = createRefreshTokenProvider({
      clientId: 'id',
      clientSecret: 'secret',
      refreshToken: 'rt',
      fetch: fetchImpl,
      now: () => clock,
    });
    assert.equal(await provider(), 'at-1');
    clock += 60_000;
    assert.equal(await provider(), 'at-1');
    assert.equal(calls, 1);
    clock += 3_600_000;
    assert.equal(await provider(), 'at-1');
    assert.equal(calls, 2, 'the token is refreshed after it expires');
  });

  it('reports a refused refresh token as DriveAuthError', async () => {
    const provider = createRefreshTokenProvider({
      clientId: 'id',
      clientSecret: 'secret',
      refreshToken: 'rt',
      fetch: async () => new Response('{"error":"invalid_grant"}', { status: 400 }),
    });
    await assert.rejects(() => provider(), DriveAuthError);
  });
});

describe('item mapping', () => {
  it('classifies folders, Workspace documents and binaries', () => {
    assert.equal(itemFromDrive({ id: 'a', mimeType: 'application/vnd.google-apps.folder' }).kind, 'folder');
    assert.equal(itemFromDrive({ id: 'a', mimeType: 'application/vnd.google-apps.spreadsheet' }).kind, 'workspace_document');
    assert.equal(itemFromDrive({ id: 'a', mimeType: 'application/pdf', size: '12' }).size, 12);
    assert.equal(itemFromDrive({ id: 'a', mimeType: 'application/pdf' }).size, null);
    assert.equal(itemFromDrive({ id: 'a', mimeType: 'application/pdf' }).downloadable, true);
  });
});

// End-to-end over the real adapter: undici returns a web ReadableStream, and
// the route pipes it to the HTTP response. This pins that the web stream,
// the forwarded Range and the abort signal all survive the whole path.
describe('google drive api adapter through the bridge', () => {
  let fake;
  let bridge;
  let token;

  before(async () => {
    fake = fakeDriveApi();
    await new Promise((resolve) => fake.server.listen(0, '127.0.0.1', resolve));
    const adapter = createGoogleDriveApiAdapter({
      getAccessToken: async () => ACCESS_TOKEN,
      baseUrl: `http://127.0.0.1:${fake.server.address().port}/drive/v3`,
    });
    bridge = await startBridge({ drive: adapter });
    const { code } = await bridge.pair();
    token = (await bridge.enroll(code)).body.data.token;
  });
  after(async () => {
    await bridge.close();
    await new Promise((resolve) => fake.server.close(resolve));
  });

  it('relays a 206 and the bytes from files.get?alt=media', async () => {
    const response = await fetch(`${bridge.base}/v1/drive/files/file_video_1/content`, {
      headers: { authorization: `Bearer ${token}`, range: 'bytes=1000-1099' },
    });
    assert.equal(response.status, 206);
    assert.equal(response.headers.get('content-range'), `bytes 1000-1099/${VIDEO.length}`);
    assert.equal(response.headers.get('content-length'), '100');
    assert.ok(Buffer.from(await response.arrayBuffer()).equals(VIDEO.subarray(1000, 1100)));
  });

  it('serves the whole file when no Range is sent', async () => {
    const response = await fetch(`${bridge.base}/v1/drive/files/file_video_1/content`, {
      headers: { authorization: `Bearer ${token}` },
    });
    assert.equal(response.status, 200);
    assert.equal((await response.arrayBuffer()).byteLength, VIDEO.length);
  });
});

import assert from 'node:assert/strict';
import { chmod, mkdtemp, mkdir, open, readdir, writeFile, symlink, rm, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, describe, it } from 'node:test';
import { createDriveMountAdapter } from '../src/drive/mount.mjs';
import { startBridge } from './helpers.mjs';

const bytes = Buffer.from(Array.from({ length: 2048 }, (_, i) => i % 251));
const png = Buffer.from([137,80,78,71,13,10,26,10,0,0,0,0]);
let directory, mount, my, shared, adapter, bridge, token, entries;

before(async () => {
  directory = await mkdtemp(join(tmpdir(), 'laa-drive-mount-test-'));
  mount = join(directory, 'mount');
  my = join(mount, 'マイドライブ');
  shared = join(mount, '共有ドライブ');
  await mkdir(join(my, '映像'), { recursive: true });
  await mkdir(join(shared, 'チーム'), { recursive: true });
  await writeFile(join(my, '映像', 'sample.mp4'), bytes);
  await writeFile(join(my, 'guide.pdf'), Buffer.from('%PDF-1.7 synthetic'));
  await writeFile(join(my, 'picture.png'), png);
  await writeFile(join(my, 'document.gdoc'), JSON.stringify({ url: 'https://docs.google.com/document/d/example/edit' }));
  await writeFile(join(my, 'invalid.gsheet'), JSON.stringify({ url: 'https://attacker.example/test' }));
  await writeFile(join(shared, 'チーム', 'shared.txt'), 'synthetic');
  await writeFile(join(directory, 'outside.txt'), 'must not be served');
  await symlink(join(directory, 'outside.txt'), join(my, 'outside.pdf'));
  await symlink(directory, join(my, 'outside-folder'));
  adapter = createDriveMountAdapter({ root: mount });
  entries = (await adapter.list({ view: 'my' })).items;
  bridge = await startBridge({ drive: adapter });
  token = await bridge.token();
});
after(async () => { await bridge?.close(); await rm(directory, { recursive: true, force: true }); });
const byName = (name) => entries.find((item) => item.name === name);
const idFor = (key, ...segments) => 'd_' + Buffer.from(JSON.stringify([key, ...segments])).toString('base64url');

it('lists My Drive and shared drives independently with stable path IDs', async () => {
  assert.equal(entries[0].name, '映像');
  assert.equal(entries.some((item) => item.name.startsWith('outside')), false);
  const sharedPage = await adapter.list({ view: 'shared' });
  assert.deepEqual(sharedPage.items.map((item) => item.name), ['チーム']);
  const restarted = createDriveMountAdapter({ root: mount });
  assert.equal((await restarted.get(byName('guide.pdf').id)).item.name, 'guide.pdf');
});

it('paginates folders and recursively searches without crossing roots', async () => {
  const first = await adapter.list({ view: 'my', pageSize: 2 });
  const second = await adapter.list({ view: 'my', pageSize: 2, pageToken: first.nextPageToken });
  assert.equal(first.items.length, 2);
  assert.equal(second.items.length, 2);
  assert.ok(first.items.every((item) => !second.items.some((other) => other.id === item.id)));
  const found = await adapter.list({ view: 'my', query: 'SAMPLE' });
  assert.equal(found.incompleteSearch, false);
  assert.deepEqual(found.items.map((item) => item.name), ['sample.mp4']);
  assert.equal((await adapter.list({ view: 'shared', query: 'sample' })).items.length, 0);
});

it('keeps the next page stable when earlier entries are added or removed', async () => {
  for (const change of ['insert', 'remove']) {
    const folder = join(my, `pages-${change}`);
    await mkdir(folder);
    try {
      for (const name of ['a.txt', 'b.txt', 'c.txt', 'd.txt']) await writeFile(join(folder, name), name);
      const folderId = idFor('my', `pages-${change}`);
      const first = await adapter.list({ folderId, pageSize: 2 });
      assert.deepEqual(first.items.map((item) => item.name), ['a.txt', 'b.txt']);
      if (change === 'insert') await writeFile(join(folder, '0.txt'), 'new');
      else await rm(join(folder, 'a.txt'));
      const second = await adapter.list({ folderId, pageSize: 2, pageToken: first.nextPageToken });
      assert.deepEqual(second.items.map((item) => item.name), ['c.txt', 'd.txt']);
    } finally { await rm(folder, { recursive: true, force: true }); }
  }
});

it('passes mount page cursors through the authenticated Bridge', async () => {
  const first = await bridge.request('/v1/drive/files?view=my&pageSize=2', { token });
  assert.equal(first.status, 200);
  const cursor = first.body.data.nextCursor;
  assert.ok(cursor);
  const second = await bridge.request(`/v1/drive/files?view=my&pageSize=2&cursor=${encodeURIComponent(cursor)}`, { token });
  assert.equal(second.status, 200);
  assert.ok(second.body.data.items.every((item) => !first.body.data.items.some((previous) => previous.id === item.id)));
  await assert.rejects(adapter.list({ view: 'my', pageToken: 'bad-cursor' }), { code: 'cursor_invalid' });
});

it('finds decomposed Japanese filenames using composed search text', async () => {
  const name = 'がっこう.pdf';
  const path = join(my, name.normalize('NFD'));
  await writeFile(path, 'synthetic');
  try {
    const page = await adapter.list({ view: 'my', query: name.normalize('NFC') });
    assert.ok(page.items.some((item) => item.name.normalize('NFC') === name));
  } finally { await rm(path, { force: true }); }
});

it('marks recent and starred unsupported instead of inventing results', async () => {
  for (const view of ['recent', 'starred']) {
    await assert.rejects(adapter.list({ view }), { code: 'drive_view_unavailable' });
  }
});

it('provides validated Google document links, never native document bytes or PDF exports', async () => {
  const doc = byName('document.gdoc');
  assert.equal(doc.kind, 'workspace_document');
  assert.equal(doc.webViewLink, 'https://docs.google.com/document/d/example/edit');
  assert.equal(doc.downloadable, false);
  assert.deepEqual(doc.exportFormats, []);
  assert.equal(byName('invalid.gsheet').webViewLink, null);
  assert.equal(await adapter.open(doc.id), null);
  const response = await bridge.request(`/v1/drive/files/${doc.id}/content`, { token });
  assert.equal(response.status, 409);
});

it('keeps the folder usable when one Google document link is unreadable', { skip: process.getuid?.() === 0 }, async () => {
  const path = join(my, 'unreadable.gdoc');
  await writeFile(path, JSON.stringify({ url: 'https://docs.google.com/document/d/example/edit' }));
  await chmod(path, 0);
  try {
    const page = await adapter.list({ view: 'my' });
    assert.ok(page.items.some((item) => item.name === 'guide.pdf'));
    assert.equal(page.items.find((item) => item.name === 'unreadable.gdoc').webViewLink, null);
  } finally { await chmod(path, 0o600); await rm(path, { force: true }); }
});

it('returns partial search results when a child folder cannot be read', { skip: process.getuid?.() === 0 }, async () => {
  const path = join(my, 'unreadable-folder');
  await mkdir(path);
  await chmod(path, 0);
  try {
    const page = await adapter.list({ view: 'my', query: 'sample' });
    assert.equal(page.incompleteSearch, true);
    assert.ok(page.items.some((item) => item.name === 'sample.mp4'));
  } finally { await chmod(path, 0o700); await rm(path, { recursive: true, force: true }); }
});

it('keeps results when a child folder fails or times out', async () => {
  const path = join(my, 'unavailable-folder');
  await mkdir(path);
  try {
    for (const mode of ['error', 'timeout']) {
      const failing = createDriveMountAdapter({ root: mount, directoryTimeoutMs: 20, readDirectory: async (directory, options) => {
        if (directory === path) {
          if (mode === 'error') throw Object.assign(new Error('provider failed'), { code: 'EIO' });
          return new Promise(() => {});
        }
        return readdir(directory, options);
      } });
      const page = await failing.list({ view: 'my', query: 'guide' });
      assert.equal(page.incompleteSearch, true);
      assert.ok(page.items.some((item) => item.name === 'guide.pdf'));
    }
  } finally { await rm(path, { recursive: true, force: true }); }
});

it('keeps the folder usable when one document link has an I/O error', async () => {
  for (const phase of ['open', 'read']) {
    const failing = createDriveMountAdapter({ root: mount, openFile: async (path, flags) => {
      const target = path === join(my, 'document.gdoc');
      if (target && phase === 'open') throw Object.assign(new Error('provider failed'), { code: 'EIO' });
      const handle = await open(path, flags);
      if (!target || phase !== 'read') return handle;
      return {
        stat: (...args) => handle.stat(...args),
        read: async () => { throw Object.assign(new Error('provider failed'), { code: 'EIO' }); },
        close: () => handle.close(),
      };
    } });
    const page = await failing.list({ view: 'my' });
    assert.ok(page.items.some((item) => item.name === 'guide.pdf'));
    assert.equal(page.items.find((item) => item.name === 'document.gdoc').webViewLink, null);
  }
});

it('identifies PDFs, images, media and bounded image thumbnails', async () => {
  assert.equal(byName('guide.pdf').mimeType, 'application/pdf');
  assert.equal(byName('picture.png').mimeType, 'image/png');
  assert.deepEqual((await adapter.thumbnail(byName('picture.png').id)).body, png);
  assert.equal(await adapter.thumbnail(byName('guide.pdf').id), null);
  const nested = await adapter.list({ folderId: byName('映像').id });
  assert.equal(nested.items[0].mimeType, 'video/mp4');
});

it('serves file bytes and exact ranges via the authenticated Bridge', async () => {
  const id = (await adapter.list({ folderId: byName('映像').id })).items[0].id;
  const response = await fetch(`${bridge.base}/v1/drive/files/${id}/content`, {
    headers: { authorization: `Bearer ${token}`, range: 'bytes=100-399' },
  });
  assert.equal(response.status, 206);
  assert.equal(response.headers.get('content-range'), `bytes 100-399/${bytes.length}`);
  assert.equal(response.headers.get('content-length'), '300');
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), bytes.subarray(100, 400));
  const full = await fetch(`${bridge.base}/v1/drive/files/${id}/content`, { headers: { authorization: `Bearer ${token}` } });
  assert.equal(full.status, 200);
  assert.deepEqual(Buffer.from(await full.arrayBuffer()), bytes);
});

it('returns 416 and HEAD metadata without reading content', async () => {
  const id = byName('guide.pdf').id;
  const head = await fetch(`${bridge.base}/v1/drive/files/${id}/content`, {
    method: 'HEAD', headers: { authorization: `Bearer ${token}`, range: 'bytes=2-4' },
  });
  assert.equal(head.status, 206);
  assert.equal(head.headers.get('content-range'), 'bytes 2-4/18');
  const invalid = await fetch(`${bridge.base}/v1/drive/files/${id}/content`, {
    headers: { authorization: `Bearer ${token}`, range: 'bytes=999-' },
  });
  assert.equal(invalid.status, 416);
  assert.equal(invalid.headers.get('content-range'), 'bytes */18');
});

it('detects a changed file across pinned range requests', async () => {
  const file = join(my, '映像', 'sample.mp4');
  const id = idFor('my', '映像', 'sample.mp4');
  const old = (await adapter.get(id)).item.version;
  await writeFile(file, Buffer.from('replacement'));
  const response = await fetch(`${bridge.base}/v1/drive/files/${id}/content`, {
    headers: { authorization: `Bearer ${token}`, range: 'bytes=0-1', 'x-laa-drive-version': old },
  });
  assert.equal(response.status, 409);
  assert.equal((await response.json()).error.code, 'version_changed');
  await writeFile(file, bytes);
});

it('refuses directory traversal, forged ids and symlink escapes', async () => {
  for (const id of [idFor('my', '..', 'outside.txt'), idFor('my', 'outside.pdf'),
    idFor('my', 'outside-folder', 'outside.txt'), idFor('other', 'outside.txt'), 'd_not-json']) {
    assert.equal(await adapter.get(id), null);
    assert.equal(await adapter.open(id), null);
  }
});

it('supports long Unicode paths and keeps the source mount unchanged on reads', async () => {
  const longName = `${'花'.repeat(70)}.pdf`;
  await writeFile(join(my, longName), 'synthetic long name');
  const found = (await adapter.list({ view: 'my', query: longName })).items[0];
  assert.ok(found.id.length > 200 && found.id.length <= 2048);
  assert.equal((await adapter.get(found.id)).item.name, longName);
  const response = await bridge.request(`/v1/drive/files/${found.id}`, { token });
  assert.equal(response.status, 200);
  assert.equal(response.body.data.name, longName);
  assert.equal((await readFile(join(my, longName), 'utf8')), 'synthetic long name');
});

it('returns a clear error when the mount is absent', async () => {
  const missing = createDriveMountAdapter({ root: join(directory, 'missing') });
  await assert.rejects(missing.list({ view: 'my' }), { code: 'drive_not_configured' });
});

it('returns a permission error without exposing a filesystem path', async () => {
  const denied = createDriveMountAdapter({ root: mount, readDirectory: async () => {
    throw Object.assign(new Error('private path'), { code: 'EPERM' });
  } });
  await assert.rejects(denied.list({ view: 'my' }), (error) =>
    error.code === 'drive_permission_required' && !error.message.includes('private path'));
});

it('bounds repeated stalled directory reads without accumulating worker operations', async () => {
  let calls = 0;
  const stalled = createDriveMountAdapter({ root: mount, directoryTimeoutMs: 15, readDirectory: () => {
    calls++; return new Promise(() => {});
  } });
  await assert.rejects(stalled.list({ view: 'my' }), { code: 'drive_access_timeout' });
  await assert.rejects(stalled.list({ view: 'my' }), { code: 'drive_access_timeout' });
  assert.equal(calls, 1);
});

it('stops waiting on a stalled directory when a list is cancelled', async () => {
  let reportStarted;
  const started = new Promise((resolve) => { reportStarted = resolve; });
  const stalled = createDriveMountAdapter({ root: mount, directoryTimeoutMs: 40, readDirectory: () => {
    reportStarted(); return new Promise(() => {});
  } });
  const abort = new AbortController();
  const listing = stalled.list({ view: 'my', query: 'sample', signal: abort.signal });
  await started;
  abort.abort();
  await assert.rejects(listing, { name: 'AbortError' });
});

it('cancels an in-progress listing when the HTTP client disconnects', async () => {
  let reportStarted, reportAborted, reportLog;
  const started = new Promise((resolve) => { reportStarted = resolve; });
  const aborted = new Promise((resolve) => { reportAborted = resolve; });
  const logged = new Promise((resolve) => { reportLog = resolve; });
  const slow = { async list({ signal }) {
    reportStarted(signal);
    await new Promise((resolve) => {
      const timer = setTimeout(resolve, 300);
      signal?.addEventListener('abort', () => { clearTimeout(timer); reportAborted(); resolve(); }, { once: true });
    });
    signal?.throwIfAborted();
    return { items: [], nextPageToken: null, incompleteSearch: false };
  } };
  const slowBridge = await startBridge({ drive: slow, log: (record) => {
    if (record.path === '/v1/drive/files') reportLog(record);
  } });
  const abort = new AbortController();
  try {
    const ownToken = await slowBridge.token();
    const request = fetch(`${slowBridge.base}/v1/drive/files?query=sample`, {
      headers: { authorization: `Bearer ${ownToken}` }, signal: abort.signal,
    }).catch((error) => error);
    const signal = await started;
    assert.ok(signal);
    abort.abort();
    assert.equal((await request).name, 'AbortError');
    let timer;
    try {
      assert.ok(await Promise.race([aborted.then(() => true), new Promise((resolve) => { timer = setTimeout(() => resolve(false), 1000); })]));
    } finally { clearTimeout(timer); }
    const record = await logged;
    assert.equal(record.status, 499);
  } finally { abort.abort(); await slowBridge.close(); }
});

it('redacts reversible path IDs from HTTP and media logs', async () => {
  const logs = [];
  let reportDriveLog;
  const driveLogged = new Promise((resolve) => { reportDriveLog = resolve; });
  const loggingBridge = await startBridge({ drive: adapter, log: (record) => {
    logs.push(record);
    if (record.area === 'drive') reportDriveLog();
  } });
  try {
    const ownToken = await loggingBridge.token();
    const id = byName('guide.pdf').id;
    const response = await fetch(`${loggingBridge.base}/v1/drive/files/${id}/content`, {
      headers: { authorization: `Bearer ${ownToken}`, range: 'bytes=0-3' },
    });
    assert.equal(response.status, 206);
    await response.arrayBuffer();
    let timeout;
    try {
      assert.ok(await Promise.race([driveLogged.then(() => true), new Promise((resolve) => { timeout = setTimeout(() => resolve(false), 1000); })]));
    } finally { clearTimeout(timeout); }
    assert.equal(JSON.stringify(logs).includes(id), false);
    assert.equal(JSON.stringify(logs).includes('guide.pdf'), false);
  } finally { await loggingBridge.close(); }
});

import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, symlink, rm, readFile } from 'node:fs/promises';
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

it('redacts reversible path IDs from HTTP and media logs', async () => {
  const logs = [];
  const loggingBridge = await startBridge({ drive: adapter, log: (record) => logs.push(record) });
  try {
    const ownToken = await loggingBridge.token();
    const id = byName('guide.pdf').id;
    const response = await fetch(`${loggingBridge.base}/v1/drive/files/${id}/content`, {
      headers: { authorization: `Bearer ${ownToken}`, range: 'bytes=0-3' },
    });
    assert.equal(response.status, 206);
    await response.arrayBuffer();
    assert.equal(JSON.stringify(logs).includes(id), false);
    assert.equal(JSON.stringify(logs).includes('guide.pdf'), false);
  } finally { await loggingBridge.close(); }
});

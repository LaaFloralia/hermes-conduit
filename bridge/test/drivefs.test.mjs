// DriveFS adapter tests. They build a throwaway directory that mimics the
// Google Drive desktop layout (My Drive + per-item id xattrs) so the adapter is
// exercised without the owner's Drive. macOS only: the item id lives in an
// extended attribute that only the Drive client sets, and CI runs on Linux.

import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdir, mkdtemp, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, describe, it } from 'node:test';
import { DRIVE_ITEM_ID_XATTR, DriveUnavailableError, createDriveFsAdapter } from '../src/drive/drivefs.mjs';

const XATTR = '/usr/bin/xattr';
const supported = process.platform === 'darwin' && existsSync(XATTR);

function setId(path, id) {
  execFileSync(XATTR, ['-w', DRIVE_ITEM_ID_XATTR, id, path]);
}

const VIDEO = Buffer.from(Array.from({ length: 2048 }, (_, i) => (i * 7) % 256));

describe('drivefs adapter', { skip: supported ? false : 'needs macOS xattrs' }, () => {
  let root;
  let adapter;

  before(async () => {
    root = await mkdtemp(join(tmpdir(), 'laa-drivefs-'));
    const mine = join(root, 'マイドライブ');
    await mkdir(join(mine, 'Studio', '会社資料'), { recursive: true });
    await mkdir(join(mine, '仕事'), { recursive: true });
    setId(mine, 'root_my_drive');
    setId(join(mine, 'Studio'), 'folder_studio');
    setId(join(mine, 'Studio', '会社資料'), 'folder_company');
    setId(join(mine, '仕事'), 'folder_work');
    const video = join(mine, 'Studio', '会社資料', 'PR動画.mp4');
    await writeFile(video, VIDEO);
    setId(video, 'file_video');
    const doc = join(mine, 'Drive運用ルール.gdoc');
    await writeFile(doc, '{"doc_id":"file_doc"}');
    setId(doc, 'file_doc');
    const note = join(mine, '仕事', 'memo.txt');
    await writeFile(note, 'hello');
    setId(note, 'file_note');
    // A symlink must never be followed into the index.
    await symlink('/etc/hosts', join(mine, '仕事', 'hosts.txt'));
    adapter = createDriveFsAdapter({ root, indexTtlMs: 0 });
  });

  after(async () => {
    if (root) await rm(root, { recursive: true, force: true });
  });

  it('indexes My Drive with ids, kinds and MIME types', async () => {
    const roots = await adapter.list({});
    assert.deepEqual(roots.items.map((item) => item.id), ['root_my_drive']);
    const byId = new Map();
    for (const folderId of [null, 'root_my_drive', 'folder_studio', 'folder_company', 'folder_work']) {
      for (const item of (await adapter.list({ folderId, pageSize: 50 })).items) byId.set(item.id, item);
    }
    assert.equal(byId.get('folder_studio').kind, 'folder');
    assert.equal(byId.get('file_video').mimeType, 'video/mp4');
    assert.equal(byId.get('file_video').size, VIDEO.length);
    assert.equal(byId.get('file_video').downloadable, true);
    assert.deepEqual(byId.get('file_video').parents, ['folder_company']);
    assert.equal(byId.get('file_doc').kind, 'workspace_document');
    assert.deepEqual(byId.get('file_doc').exportFormats, ['application/pdf', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'text/plain']);
    assert.equal(byId.get('file_doc').size, null);
    assert.equal(byId.has('hosts.txt'), false);
  });

  it('filters by folder and by name', async () => {
    const inFolder = await adapter.list({ folderId: 'folder_company' });
    assert.deepEqual(inFolder.items.map((item) => item.id), ['file_video']);
    const search = await adapter.list({ query: 'pr動画' });
    assert.deepEqual(search.items.map((item) => item.id), ['file_video']);
    const noMatch = await adapter.list({ query: 'nothing-here' });
    assert.deepEqual(noMatch.items, []);
  });

  it('sorts folders before files and paginates deterministically', async () => {
    const all = await adapter.list({ folderId: 'root_my_drive', pageSize: 10 });
    assert.deepEqual(all.items.map((item) => item.kind), ['folder', 'folder', 'workspace_document']);
    assert.deepEqual(all.items.map((item) => item.name), ['Studio', '仕事', 'Drive運用ルール.gdoc']);
    const first = await adapter.list({ folderId: 'root_my_drive', pageSize: 2, offset: 0 });
    const second = await adapter.list({ folderId: 'root_my_drive', pageSize: 2, offset: 2 });
    assert.deepEqual(
      [...first.items, ...second.items].map((item) => item.id),
      all.items.map((item) => item.id),
    );
  });

  it('opens a byte range from the local file', async () => {
    const opened = await adapter.open('file_video', { start: 100, end: 199 });
    assert.equal(opened.kind, 'binary');
    const chunks = [];
    for await (const chunk of opened.stream) chunks.push(chunk);
    const body = Buffer.concat(chunks);
    assert.equal(body.length, 100);
    assert.ok(body.equals(VIDEO.subarray(100, 200)));
    assert.match(opened.etag, /^"[0-9a-f]+-[0-9a-f]+"$/);
  });

  it('returns null for unknown ids and refuses folders and documents', async () => {
    assert.equal(await adapter.get('file_missing'), null);
    assert.equal(await adapter.open('file_missing'), null);
    const folder = await adapter.open('folder_studio');
    assert.equal(folder.kind, 'folder');
    const doc = await adapter.open('file_doc');
    assert.equal(doc.kind, 'workspace_document');
    assert.deepEqual(doc.item.exportFormats, ['application/pdf', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'text/plain']);
  });

  it('picks up a file created after the index was built', async () => {
    const path = join(root, 'マイドライブ', '仕事', 'later.pdf');
    await writeFile(path, 'later');
    setId(path, 'file_later');
    const found = await adapter.get('file_later');
    assert.ok(found, 'get() rebuilds once for an unknown id');
    assert.equal(found.item.name, 'later.pdf');
  });

  it('reports a missing Drive client as unavailable', async () => {
    const missing = createDriveFsAdapter({ root: join(root, 'does-not-exist') });
    await assert.rejects(() => missing.list({}), DriveUnavailableError);
    await assert.rejects(() => missing.get('file_video'), DriveUnavailableError);
  });
});

// Read-only adapter for Google Drive for desktop's File Provider mount.
// IDs encode a relative path so they survive a Bridge restart; logs must not
// contain these IDs because they can be decoded to names.
import { constants as FS } from 'node:fs';
import { lstat, open, readdir, realpath } from 'node:fs/promises';
import { homedir } from 'node:os';
import { extname, join, relative, resolve, sep } from 'node:path';
import { createHash } from 'node:crypto';
import { BridgeError } from '../errors.mjs';
import { parseRange } from '../routes/drive.mjs';

const DEFAULT_ROOT = join(homedir(), 'Library/CloudStorage/GoogleDrive-floralia@laa-inc.com');
const ROOTS = { my: 'マイドライブ', shared: '共有ドライブ' };
const MAX_ID = 2048;
const MAX_SEARCH_ENTRIES = 10000;
const MAX_LINK_BYTES = 16384;
const MAX_THUMBNAIL_BYTES = 2 * 1024 * 1024;
const NATIVE_TYPES = {
  '.gdoc': 'application/vnd.google-apps.document',
  '.gsheet': 'application/vnd.google-apps.spreadsheet',
  '.gslides': 'application/vnd.google-apps.presentation',
  '.gdraw': 'application/vnd.google-apps.drawing',
  '.gform': 'application/vnd.google-apps.form',
  '.gsite': 'application/vnd.google-apps.site',
  '.gmap': 'application/vnd.google-apps.map',
  '.gscript': 'application/vnd.google-apps.script',
  '.gtable': 'application/vnd.google-apps.fusiontable',
};
const MIME_TYPES = {
  '.pdf': 'application/pdf', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
  '.png': 'image/png', '.gif': 'image/gif', '.webp': 'image/webp',
  '.heic': 'image/heic', '.heif': 'image/heif', '.tif': 'image/tiff', '.tiff': 'image/tiff',
  '.mp4': 'video/mp4', '.m4v': 'video/x-m4v', '.mov': 'video/quicktime',
  '.mp3': 'audio/mpeg', '.m4a': 'audio/mp4', '.wav': 'audio/wav', '.aac': 'audio/aac',
};

function errorFor(error) {
  if (error instanceof BridgeError) return error;
  if (error?.code === 'EACCES' || error?.code === 'EPERM') {
    return new BridgeError(503, 'drive_permission_required', 'macOS denied the Bridge access to the Drive mount');
  }
  return new BridgeError(503, 'drive_unavailable', 'the Drive mount is unavailable', { retryable: true });
}
function isMissing(error) { return error?.code === 'ENOENT' || error?.code === 'ENOTDIR' || error?.code === 'ELOOP'; }
function itemId(key, segments = []) {
  return 'd_' + Buffer.from(JSON.stringify([key, ...segments])).toString('base64url');
}
function decodeId(id) {
  if (typeof id !== 'string' || !/^d_[A-Za-z0-9_-]+$/.test(id) || id.length > MAX_ID) return null;
  try {
    const encoded = id.slice(2);
    const bytes = Buffer.from(encoded, 'base64url');
    if (bytes.toString('base64url') !== encoded) return null;
    const value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
    if (!Array.isArray(value) || !Object.hasOwn(ROOTS, value[0]) ||
        value.some((segment) => typeof segment !== 'string') ||
        value.slice(1).some((segment) => !segment || segment === '.' || segment === '..' || segment.includes('/') || segment.includes('\0'))) return null;
    return { key: value[0], segments: value.slice(1) };
  } catch { return null; }
}
function versionOf(stat) {
  const digest = createHash('sha256').update([stat.dev, stat.ino, stat.size, stat.mtimeNs, stat.ctimeNs].join(':')).digest('hex');
  return BigInt(`0x${digest.slice(0, 24)}`).toString();
}
function safeWebLink(raw) {
  if (typeof raw !== 'string' || raw.length > 8192) return null;
  try {
    const url = new URL(raw);
    return url.protocol === 'https:' && ['docs.google.com', 'drive.google.com'].includes(url.hostname) &&
      !url.username && !url.password && !url.port ? url.href : null;
  } catch { return null; }
}
function validImage(mime, bytes) {
  if (mime === 'image/jpeg') return bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  if (mime === 'image/png') return bytes.length >= 8 && bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  if (mime === 'image/gif') return bytes.length >= 6 && ['GIF87a', 'GIF89a'].includes(bytes.subarray(0, 6).toString('ascii'));
  if (mime === 'image/webp') return bytes.length >= 12 && bytes.subarray(0, 4).toString('ascii') === 'RIFF' && bytes.subarray(8, 12).toString('ascii') === 'WEBP';
  return false;
}

export function createDriveMountAdapter({ root = DEFAULT_ROOT, directoryTimeoutMs = 5000, readDirectory = readdir } = {}) {
  const base = resolve(root);
  const pendingDirectories = new Map();

  async function guardedDirectory(path) {
    // A macOS permission dialog can leave readdir pending indefinitely. Reuse
    // that call so retries do not exhaust libuv's worker pool.
    let pending = pendingDirectories.get(path);
    if (!pending) {
      pending = readDirectory(path, { withFileTypes: true });
      pendingDirectories.set(path, pending);
      pending.then(() => pendingDirectories.delete(path), () => pendingDirectories.delete(path));
    }
    let timer;
    try {
      return await Promise.race([pending, new Promise((_, reject) => {
        timer = setTimeout(() => reject(new BridgeError(503, 'drive_access_timeout',
          'the Drive mount did not respond; check macOS file access and Drive for desktop', { retryable: true })), directoryTimeoutMs);
        timer.unref?.();
      })]);
    } finally { clearTimeout(timer); }
  }

  async function locate(id) {
    const decoded = decodeId(id);
    if (!decoded) return null;
    const rootPath = join(base, ROOTS[decoded.key]);
    try {
      let path = rootPath;
      const rootStat = await lstat(rootPath, { bigint: true });
      if (rootStat.isSymbolicLink() || !rootStat.isDirectory()) return null;
      const realRoot = await realpath(rootPath);
      for (const segment of decoded.segments) {
        path = join(path, segment);
        const part = await lstat(path, { bigint: true });
        if (part.isSymbolicLink()) return null;
      }
      const real = await realpath(path);
      const rel = relative(realRoot, real);
      if (rel === '..' || rel.startsWith(`..${sep}`) || resolve(realRoot, rel) !== real) return null;
      const stat = await lstat(path, { bigint: true });
      if (stat.isSymbolicLink() || !(stat.isDirectory() || stat.isFile())) return null;
      return { ...decoded, path, stat };
    } catch (error) {
      if (isMissing(error)) return null;
      throw errorFor(error);
    }
  }

  async function openChecked(found, expectedVersion) {
    let handle;
    try {
      handle = await open(found.path, FS.O_RDONLY | (FS.O_NOFOLLOW ?? 0));
      const stat = await handle.stat({ bigint: true });
      const again = await locate(itemId(found.key, found.segments));
      if (!again || !stat.isFile() || stat.dev !== again.stat.dev || stat.ino !== again.stat.ino ||
          versionOf(stat) !== versionOf(again.stat) || (expectedVersion && versionOf(stat) !== expectedVersion)) {
        throw new BridgeError(409, 'version_changed', 'the Drive file changed; reload it before continuing');
      }
      return { handle, stat };
    } catch (error) {
      await handle?.close().catch(() => {});
      if (isMissing(error)) return null;
      throw errorFor(error);
    }
  }

  async function nativeLink(found) {
    if (found.stat.size > BigInt(MAX_LINK_BYTES)) return null;
    const opened = await openChecked(found, versionOf(found.stat));
    if (!opened) return null;
    try {
      const buffer = Buffer.alloc(Number(opened.stat.size));
      const { bytesRead } = await opened.handle.read(buffer, 0, buffer.length, 0);
      try { return safeWebLink(JSON.parse(buffer.subarray(0, bytesRead).toString('utf8')).url); } catch { return null; }
    } finally { await opened.handle.close(); }
  }

  async function metadata(found) {
    const name = found.segments.length ? found.segments.at(-1) : ROOTS[found.key];
    const extension = extname(name).toLowerCase();
    const isFolder = found.stat.isDirectory();
    const nativeMime = !isFolder && NATIVE_TYPES[extension];
    const mimeType = isFolder ? 'application/vnd.google-apps.folder' : nativeMime || MIME_TYPES[extension] || 'application/octet-stream';
    const version = versionOf(found.stat);
    const size = !isFolder && !nativeMime && found.stat.size <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(found.stat.size) : null;
    const hasThumbnail = size !== null && size > 0 && size <= MAX_THUMBNAIL_BYTES &&
      ['image/jpeg', 'image/png', 'image/gif', 'image/webp'].includes(mimeType);
    return {
      id: itemId(found.key, found.segments), name, mimeType,
      kind: isFolder ? 'folder' : nativeMime ? 'workspace_document' : 'file',
      size, modifiedAt: found.stat.mtime.toISOString(), version,
      parents: found.segments.length ? [itemId(found.key, found.segments.slice(0, -1))] : [],
      downloadable: !isFolder && !nativeMime,
      webViewLink: nativeMime ? await nativeLink(found) : null,
      starred: null, viewedAt: null, owners: null, hasThumbnail,
      thumbnailVersion: hasThumbnail ? version : null,
      ...(nativeMime ? { exportFormats: [] } : {}),
    };
  }

  return {
    kind: 'drive-desktop-mount',
    async list({ query = '', folderId = null, pageSize = 50, pageToken = null, view = null } = {}) {
      if (!folderId && ['recent', 'starred'].includes(view)) {
        throw new BridgeError(503, 'drive_view_unavailable', 'this view is not available from the Drive desktop mount');
      }
      const rootId = folderId ?? itemId(view === 'shared' ? 'shared' : 'my');
      const start = await locate(rootId);
      if (!start) {
        if (folderId) throw new BridgeError(404, 'not_found', 'the folder is no longer available');
        throw new BridgeError(503, 'drive_not_configured', 'the Drive desktop mount is unavailable');
      }
      if (!start.stat.isDirectory()) throw new BridgeError(400, 'not_a_folder', 'the selected item is not a folder');
      if (pageToken !== null && !/^(0|[1-9]\d{0,7})$/.test(pageToken)) throw new BridgeError(400, 'cursor_invalid', 'the page cursor is invalid');
      const offset = Number(pageToken ?? 0);
      const stack = [start];
      const matched = [];
      let visited = 0;
      let incomplete = false;
      const needle = query.toLocaleLowerCase();
      while (stack.length) {
        const dir = stack.pop();
        let entries;
        try { entries = await guardedDirectory(dir.path); }
        catch (error) { throw errorFor(error); }
        const candidates = [];
        for (const entry of entries) {
          if (++visited > MAX_SEARCH_ENTRIES) { incomplete = true; break; }
          if (entry.name.startsWith('.') || entry.isSymbolicLink()) continue;
          const id = itemId(dir.key, [...dir.segments, entry.name]);
          if (id.length > MAX_ID) { incomplete = true; continue; }
          candidates.push({ id, name: entry.name });
        }
        for (let i = 0; i < candidates.length; i += 24) {
          const batch = candidates.slice(i, i + 24);
          const children = await Promise.all(batch.map(({ id }) => locate(id)));
          for (let j = 0; j < batch.length; j++) {
            const child = children[j];
            if (!child) continue;
            if (!query || batch[j].name.toLocaleLowerCase().includes(needle)) matched.push(child);
            if (query && child.stat.isDirectory()) stack.push(child);
          }
        }
        if (incomplete) break;
      }
      matched.sort((a, b) => Number(b.stat.isDirectory()) - Number(a.stat.isDirectory()) ||
        a.segments.at(-1).localeCompare(b.segments.at(-1)) || itemId(a.key, a.segments).localeCompare(itemId(b.key, b.segments)));
      const items = await Promise.all(matched.slice(offset, offset + pageSize).map(metadata));
      return { items, nextPageToken: offset + pageSize < matched.length ? String(offset + pageSize) : null,
        incompleteSearch: incomplete };
    },
    async get(id) {
      const found = await locate(id);
      return found ? { item: await metadata(found) } : null;
    },
    async thumbnail(id, { signal } = {}) {
      if (signal?.aborted) throw new DOMException('Aborted', 'AbortError');
      const found = await locate(id);
      if (!found) return null;
      const item = await metadata(found);
      if (!item.hasThumbnail) return null;
      const opened = await openChecked(found, item.version);
      if (!opened) return null;
      try {
        const body = Buffer.alloc(item.size);
        const { bytesRead } = await opened.handle.read(body, 0, body.length, 0);
        if (signal?.aborted) throw new DOMException('Aborted', 'AbortError');
        return bytesRead === body.length && validImage(item.mimeType, body) ? { mimeType: item.mimeType, body } : null;
      } finally { await opened.handle.close(); }
    },
    async open(id, { range = null, signal, expectedVersion = null } = {}) {
      if (signal?.aborted) throw new DOMException('Aborted', 'AbortError');
      const found = await locate(id);
      if (!found || !found.stat.isFile() || NATIVE_TYPES[extname(found.segments.at(-1)).toLowerCase()]) return null;
      const opened = await openChecked(found, expectedVersion);
      if (!opened) return null;
      if (signal?.aborted) { await opened.handle.close(); throw new DOMException('Aborted', 'AbortError'); }
      if (opened.stat.size > BigInt(Number.MAX_SAFE_INTEGER)) { await opened.handle.close(); throw errorFor(new Error()); }
      const size = Number(opened.stat.size);
      const parsed = parseRange(range, size);
      const headers = new Headers({ 'accept-ranges': 'bytes' });
      if (parsed.kind === 'unsatisfiable') {
        await opened.handle.close();
        headers.set('content-range', `bytes */${size}`);
        return { status: 416, headers, stream: null };
      }
      const partial = parsed.kind === 'range';
      const start = partial ? parsed.start : 0;
      const end = partial ? parsed.end : size - 1;
      headers.set('content-length', String(partial ? end - start + 1 : size));
      if (partial) headers.set('content-range', `bytes ${start}-${end}/${size}`);
      const stream = opened.handle.createReadStream({ start, ...(partial ? { end } : {}), autoClose: true, signal });
      return { status: partial ? 206 : 200, headers, stream };
    },
  };
}

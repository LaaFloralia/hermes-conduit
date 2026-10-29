// Drive adapter backed by the signed-in Google Drive desktop client (DriveFS).
//
// The Mac already holds the owner's Google authorization in the Drive desktop
// app (floralia@laa-inc.com). That client mirrors the Drive tree under
// ~/Library/CloudStorage and stamps every item with its Drive file id in the
// com.google.drivefs.item-id#S xattr. Reading those files is the existing,
// read-only route: no OAuth grant, token, API key or new account is added, and
// the client's credentials are never extracted.
//
// Consequences that the API has to state instead of hiding:
//   - The listing covers what Drive desktop exposes (My Drive and shared
//     drives), not "Shared with me" items that were never added, and not trash.
//   - Google Workspace documents are link placeholders on disk (.gdoc/.gsheet/
//     .gslides); their bytes cannot be streamed and must be exported instead.
//   - A file that is not materialized locally is fetched by DriveFS on first
//     read, so the first byte can take seconds; later reads of the same range
//     come from the local cache.

import { execFile } from 'node:child_process';
import { createReadStream } from 'node:fs';
import { readdir, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { extname, join } from 'node:path';
import { createHash } from 'node:crypto';

export const DRIVE_ITEM_ID_XATTR = 'com.google.drivefs.item-id#S';
const XATTR = '/usr/bin/xattr';

const MY_DRIVE_NAMES = ['マイドライブ', 'My Drive'];
const SHARED_DRIVE_NAMES = ['共有ドライブ', 'Shared drives'];

// Drive's own MIME names for the Workspace formats, plus the export formats the
// Drive API offers for them. The Bridge never performs the export itself; it
// only tells the client what the Mac-side route cannot do.
const WORKSPACE_TYPES = {
  '.gdoc': {
    mimeType: 'application/vnd.google-apps.document',
    exportFormats: [
      'application/pdf',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'text/plain',
    ],
  },
  '.gsheet': {
    mimeType: 'application/vnd.google-apps.spreadsheet',
    exportFormats: [
      'application/pdf',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'text/csv',
    ],
  },
  '.gslides': {
    mimeType: 'application/vnd.google-apps.presentation',
    exportFormats: [
      'application/pdf',
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    ],
  },
  '.gdraw': { mimeType: 'application/vnd.google-apps.drawing', exportFormats: ['application/pdf'] },
  '.gform': { mimeType: 'application/vnd.google-apps.form', exportFormats: ['application/pdf'] },
};

const MIME_BY_EXTENSION = {
  '.mp4': 'video/mp4',
  '.m4v': 'video/x-m4v',
  '.mov': 'video/quicktime',
  '.webm': 'video/webm',
  '.mkv': 'video/x-matroska',
  '.mp3': 'audio/mpeg',
  '.m4a': 'audio/mp4',
  '.wav': 'audio/wav',
  '.aac': 'audio/aac',
  '.pdf': 'application/pdf',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.heic': 'image/heic',
  '.svg': 'image/svg+xml',
  '.txt': 'text/plain; charset=utf-8',
  '.md': 'text/markdown; charset=utf-8',
  '.csv': 'text/csv; charset=utf-8',
  '.json': 'application/json',
  '.zip': 'application/zip',
  '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  '.glb': 'model/gltf-binary',
  '.blend': 'application/octet-stream',
};

export class DriveUnavailableError extends Error {
  constructor(message) {
    super(message);
    this.code = 'drive_unavailable';
  }
}

export function mimeTypeForName(name) {
  const ext = extname(name).toLowerCase();
  if (WORKSPACE_TYPES[ext]) return WORKSPACE_TYPES[ext].mimeType;
  return MIME_BY_EXTENSION[ext] ?? 'application/octet-stream';
}

export function kindForName(name) {
  const ext = extname(name).toLowerCase();
  return WORKSPACE_TYPES[ext] ? 'workspace_document' : 'file';
}

export function exportFormatsForName(name) {
  return WORKSPACE_TYPES[extname(name).toLowerCase()]?.exportFormats ?? [];
}

export function defaultDriveRoot(home = homedir()) {
  return join(home, 'Library', 'CloudStorage', 'GoogleDrive-floralia@laa-inc.com');
}

function normalizeName(name) {
  return name.normalize('NFC').toLowerCase();
}

function readItemId(path, exec = execFile) {
  return new Promise((resolvePromise) => {
    exec(XATTR, ['-p', DRIVE_ITEM_ID_XATTR, path], { timeout: 5000, maxBuffer: 4096 }, (error, stdout) => {
      if (error) {
        resolvePromise(null);
        return;
      }
      const id = String(stdout).trim();
      resolvePromise(/^[A-Za-z0-9_-]{5,200}$/.test(id) ? id : null);
    });
  });
}

// Bounded concurrency keeps the index build to a few hundred milliseconds on a
// few thousand items without spawning one xattr per file at once.
async function mapLimit(items, limit, worker) {
  const results = new Array(items.length);
  let next = 0;
  async function run() {
    while (next < items.length) {
      const index = next;
      next += 1;
      results[index] = await worker(items[index], index);
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, run));
  return results;
}

// Folders first, then a case- and width-insensitive name order, then the id so
// pagination is stable across index rebuilds.
function compareEntries(a, b) {
  const af = a.kind === 'folder' ? 0 : 1;
  const bf = b.kind === 'folder' ? 0 : 1;
  if (af !== bf) return af - bf;
  const an = normalizeName(a.name);
  const bn = normalizeName(b.name);
  if (an < bn) return -1;
  if (an > bn) return 1;
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
}

function toItem(entry) {
  const item = {
    id: entry.id,
    name: entry.name,
    mimeType: entry.kind === 'folder' ? 'application/vnd.google-apps.folder' : mimeTypeForName(entry.name),
    kind: entry.kind,
    size: entry.kind === 'file' ? entry.size : null,
    modifiedAt: entry.modifiedAt,
    parents: entry.parentId ? [entry.parentId] : [],
    downloadable: entry.kind === 'file',
    webViewLink: entry.kind === 'folder'
      ? `https://drive.google.com/drive/folders/${entry.id}`
      : `https://drive.google.com/file/d/${entry.id}/view`,
  };
  if (entry.kind === 'workspace_document') item.exportFormats = exportFormatsForName(entry.name);
  return item;
}

/**
 * @param {object} options
 * @param {string} [options.root] Drive desktop account directory.
 * @param {number} [options.indexTtlMs] How long a built index is reused.
 * @param {number} [options.maxEntries] Hard cap on indexed items.
 * @param {number} [options.maxDepth] Directory depth cap from each Drive root.
 * @param {number} [options.concurrency] Parallel xattr reads.
 * @param {Function} [options.exec] child_process.execFile replacement (tests).
 * @param {Function} [options.now] clock (tests).
 */
export function createDriveFsAdapter({
  root = defaultDriveRoot(),
  indexTtlMs = 60_000,
  maxEntries = 20_000,
  maxDepth = 8,
  concurrency = 16,
  exec = execFile,
  now = () => Date.now(),
} = {}) {
  let index = null;
  let builtAt = 0;
  let building = null;

  async function locateRoots() {
    let names;
    try {
      names = await readdir(root);
    } catch {
      throw new DriveUnavailableError('Google Drive desktop folder is not available');
    }
    // macOS stores Japanese names decomposed (NFD); compare and display them
    // composed (NFC) while keeping the on-disk name for path building.
    const mine = names.filter((name) => MY_DRIVE_NAMES.includes(name.normalize('NFC')));
    const shared = names.filter((name) => SHARED_DRIVE_NAMES.includes(name.normalize('NFC')));
    if (mine.length === 0) {
      throw new DriveUnavailableError('Google Drive desktop folder has no My Drive entry');
    }
    return { mine, shared };
  }

  async function walk(startPath, parentId, depth, byId, entries) {
    if (depth > maxDepth || entries.length >= maxEntries) return;
    let dirents;
    try {
      dirents = await readdir(startPath, { withFileTypes: true });
    } catch {
      return; // A folder that vanished mid-walk is skipped, not fatal.
    }
    const pending = [];
    for (const dirent of dirents) {
      if (entries.length + pending.length >= maxEntries) break;
      if (dirent.name.startsWith('.') || dirent.isSymbolicLink()) continue;
      const path = join(startPath, dirent.name);
      if (dirent.isDirectory()) {
        pending.push({ path, name: dirent.name.normalize('NFC'), kind: 'folder', parentId });
      } else if (dirent.isFile()) {
        pending.push({ path, name: dirent.name.normalize('NFC'), kind: kindForName(dirent.name), parentId });
      }
    }
    const resolved = await mapLimit(pending, concurrency, async (entry) => {
      const id = await readItemId(entry.path, exec);
      if (!id) return null;
      let info = null;
      try {
        info = await stat(entry.path);
      } catch {
        return null;
      }
      return {
        ...entry,
        id,
        size: entry.kind === 'file' ? info.size : null,
        modifiedAt: new Date(info.mtimeMs).toISOString(),
        path: entry.path,
        mtimeMs: info.mtimeMs,
      };
    });
    for (const entry of resolved) {
      if (!entry || byId.has(entry.id)) continue;
      entries.push(entry);
      byId.set(entry.id, entry);
    }
    for (const entry of resolved) {
      if (!entry || entry.kind !== 'folder') continue;
      await walk(entry.path, entry.id, depth + 1, byId, entries);
    }
  }

  async function build() {
    const { mine, shared } = await locateRoots();
    const byId = new Map();
    const entries = [];
    for (const diskName of [...mine, ...shared]) {
      const path = join(root, diskName);
      const name = diskName.normalize('NFC');
      const id = await readItemId(path, exec);
      if (!id) {
        // The virtual "Shared drives" container has no id of its own; walk it
        // without registering it so its children stay reachable.
        if (SHARED_DRIVE_NAMES.includes(name)) await walk(path, null, 0, byId, entries);
        continue;
      }
      let info = null;
      try {
        info = await stat(path);
      } catch {
        continue;
      }
      const entry = {
        id,
        name,
        kind: 'folder',
        parentId: null,
        path,
        size: null,
        modifiedAt: new Date(info.mtimeMs).toISOString(),
        mtimeMs: info.mtimeMs,
      };
      if (!byId.has(id)) {
        entries.push(entry);
        byId.set(id, entry);
      }
      await walk(path, id, 0, byId, entries);
    }
    const children = new Map();
    for (const entry of entries) {
      const key = entry.parentId ?? '';
      if (!children.has(key)) children.set(key, []);
      children.get(key).push(entry);
    }
    for (const list of children.values()) list.sort(compareEntries);
    return { entries, byId, children, roots: mine.map((name) => join(root, name)) };
  }

  async function ensureIndex({ force = false } = {}) {
    const fresh = index && !force && now() - builtAt < indexTtlMs;
    if (fresh) return index;
    if (building) return building;
    building = (async () => {
      try {
        const built = await build();
        index = built;
        builtAt = now();
        return built;
      } finally {
        building = null;
      }
    })();
    return building;
  }

  // Without a query or a folder the listing is the browse entry point: the
  // Drive roots. With a query it searches the whole index; with a folderId it
  // lists that folder's children.
  function matches(entry, { query, folderId }) {
    if (query && !normalizeName(entry.name).includes(normalizeName(query))) return false;
    if (folderId !== null) return (entry.parentId ?? null) === folderId;
    if (query) return true;
    return entry.parentId === null;
  }

  return {
    kind: 'drivefs',
    async list({ query = '', folderId = null, pageSize = 50, offset = 0 } = {}) {
      let current = await ensureIndex();
      let all = current.entries.filter((entry) => matches(entry, { query, folderId })).sort(compareEntries);
      if (all.length === 0 && query === '' && folderId !== null) {
        // A folder created after the last index build: rebuild once.
        current = await ensureIndex({ force: true });
        all = current.entries.filter((entry) => matches(entry, { query, folderId })).sort(compareEntries);
      }
      const page = all.slice(offset, offset + pageSize).map(toItem);
      return { items: page, total: all.length };
    },
    async get(id) {
      let current = await ensureIndex();
      let entry = current.byId.get(id);
      if (!entry) {
        current = await ensureIndex({ force: true });
        entry = current.byId.get(id);
      }
      if (!entry) return null;
      return {
        item: toItem(entry),
        etag: `"${(entry.size ?? 0).toString(16)}-${Math.round(entry.mtimeMs).toString(16)}"`,
      };
    },
    async open(id, { start = 0, end = undefined } = {}) {
      const current = await ensureIndex();
      const entry = current.byId.get(id);
      if (!entry) return null;
      const item = toItem(entry);
      if (entry.kind === 'folder') return { kind: 'folder', item };
      if (entry.kind === 'workspace_document') return { kind: 'workspace_document', item };
      return {
        kind: 'binary',
        item,
        etag: `"${entry.size.toString(16)}-${Math.round(entry.mtimeMs).toString(16)}"`,
        stream: createReadStream(entry.path, { start, end }),
      };
    },
  };
}

// The Drive id in a listing is opaque to clients; this keeps it stable for
// pagination fingerprints without exposing the query text.
export function fingerprint(parts) {
  return createHash('sha256').update(parts.join('\u0000')).digest('hex').slice(0, 16);
}

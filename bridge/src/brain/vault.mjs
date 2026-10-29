// Read and create-only access to the Brain vault (ROADMAP 25).
//
// The vault is a plain directory shared with Syncthing, git and Obsidian, so
// every path is validated before it is used: NFC normalised, vault-relative,
// no `.`/`..`, no hidden or Syncthing/git internals, no conflict copies, and a
// realpath that stayed inside the vault (a symlink anywhere on the way is
// refused). Reads are Markdown only.
//
// Creation is the only mutation and it is deliberately narrow: the target must
// be under an allowed create prefix, the parent directory must already exist,
// and the file is opened with O_EXCL so an existing note is never touched. The
// name-conflict policy is explicit: `suffix` (default) picks the next free name
// atomically, `reject` returns 409. There is no rename, overwrite, truncate or
// delete anywhere in this module.

import { createHash } from 'node:crypto';
import {
  closeSync, fsyncSync, lstatSync, openSync, readdirSync, readFileSync, realpathSync, statSync, unlinkSync, writeSync,
} from 'node:fs';
import { join, sep } from 'node:path';
import { badRequest, BridgeError, notFound } from '../errors.mjs';
import { zoneOf } from './policy.mjs';

export const MAX_NOTE_BYTES = 48 * 1024;
export const MAX_READ_BYTES = 256 * 1024;
export const MAX_LIST_ENTRIES = 4000;
export const MAX_WALK_DEPTH = 8;
export const SUFFIX_LIMIT = 20;

const RESERVED_SEGMENTS = new Set([
  '.git', '.obsidian', '.stfolder', '.stversions', '.trash', '.bridge-tmp', 'node_modules',
]);
const RESERVED_BASENAMES = new Set(['AGENTS.md', 'CLAUDE.md']);
const CONFLICT_MARKERS = ['sync-conflict-', '（GitHub競合', '(GitHub競合'];

const utf8 = new TextDecoder('utf-8', { fatal: true });

export function hashBuffer(buffer) {
  return `sha256:${createHash('sha256').update(buffer).digest('hex')}`;
}

export function fileId(relPath) {
  return `bf_${Buffer.from(String(relPath).normalize('NFC'), 'utf8').toString('base64url')}`;
}

export function pathFromId(id) {
  if (typeof id !== 'string' || !id.startsWith('bf_')) throw badRequest('file_id_invalid', 'file id is not recognised');
  return parseVaultPath(Buffer.from(id.slice(3), 'base64url').toString('utf8'));
}

// Returns the NFC-normalised vault-relative path, or throws 400. Shared by
// create and by id decoding, so both go through the same rules.
export function parseVaultPath(raw) {
  if (typeof raw !== 'string') throw badRequest('path_invalid', 'path must be a string');
  if (raw.length === 0 || raw.length > 400) throw badRequest('path_invalid', 'path must be 1-400 characters');
  if (/[\u0000-\u001f\u007f]/.test(raw)) throw badRequest('path_invalid', 'path must not contain control characters');
  if (raw.includes('\\')) throw badRequest('path_invalid', 'path must use forward slashes');
  if (raw.includes(':')) throw badRequest('path_invalid', 'path must not contain a colon');
  if (raw.startsWith('/')) throw badRequest('path_invalid', 'path must be relative to the vault');
  const rel = raw.normalize('NFC');
  const parts = rel.split('/');
  if (parts.some((part) => part === '' || part === '.' || part === '..')) {
    throw badRequest('path_invalid', 'path must not contain empty, "." or ".." segments');
  }
  if (parts.length > MAX_WALK_DEPTH) throw badRequest('path_invalid', 'path is too deep');
  if (!rel.toLowerCase().endsWith('.md')) throw badRequest('path_invalid', 'only Markdown (.md) notes are addressable');
  for (const part of parts) {
    if (part.startsWith('.') || RESERVED_SEGMENTS.has(part)) {
      throw badRequest('path_invalid', `${part} is not addressable`);
    }
  }
  const base = parts[parts.length - 1];
  if (RESERVED_BASENAMES.has(base)) throw badRequest('path_invalid', `${base} is a harness instruction file`);
  for (const marker of CONFLICT_MARKERS) {
    if (base.includes(marker)) throw badRequest('path_invalid', 'conflict copies are not addressable');
  }
  return rel;
}

function toBridgeError(err, what) {
  if (err instanceof BridgeError) return err;
  if (err?.code === 'ENOENT') return notFound(`${what} not found`);
  if (err?.code === 'EACCES' || err?.code === 'EPERM') {
    return new BridgeError(503, 'brain_vault_unreadable', `the Brain vault refused ${what}`, { retryable: true });
  }
  return new BridgeError(503, 'brain_vault_unavailable', `the Brain vault is not usable for ${what}`, { retryable: true });
}

// The same small projection the search CLI reports (状態 / 最終確認), not a
// second parser: a note without these lines has no status, it is not "adopted".
function noteMeta(text, rel) {
  const titleMatch = /^#\s+(.+?)\s*#*\s*$/m.exec(text);
  const statusMatch = /^\s*状態\s*[:：]\s*(未記入|草案|採用済み)/m.exec(text);
  const checkedMatch = /^\s*最終確認\s*[:：]\s*([^\s。、]+)/m.exec(text);
  return {
    title: titleMatch ? titleMatch[1].trim() : rel.split('/').pop().replace(/\.md$/i, ''),
    status: statusMatch ? statusMatch[1] : null,
    checked: checkedMatch ? checkedMatch[1] : null,
  };
}

function fsyncDirectory(dir) {
  let fd;
  try {
    fd = openSync(dir, 'r');
    fsyncSync(fd);
  } catch {
    // Directory fsync is best effort on macOS; the file itself was fsynced.
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
}

export function createBrainVault({ root, policy, createPrefixes }) {
  function rootReal() {
    try {
      const real = realpathSync(root);
      if (!statSync(real).isDirectory()) throw new Error('not a directory');
      return real;
    } catch {
      throw new BridgeError(503, 'brain_vault_unavailable', 'the Brain vault is not available', { retryable: true });
    }
  }

  // Resolves a validated relative path to an existing regular file inside the
  // vault. A symlink on any component (including the file itself) fails the
  // realpath comparison and is reported as 404, not followed.
  function resolveExisting(real, rel) {
    const absolute = join(real, ...rel.split('/'));
    let target;
    try {
      target = realpathSync(absolute);
    } catch (err) {
      throw toBridgeError(err, `note ${rel}`);
    }
    if (target !== absolute) throw notFound(`note ${rel} is not addressable`);
    const info = lstatSync(target);
    if (info.isSymbolicLink() || !info.isFile()) throw notFound(`note ${rel} is not a regular file`);
    return { absolute: target, info };
  }

  function readText(absolute, maxBytes) {
    const info = statSync(absolute);
    if (info.size > maxBytes) throw new BridgeError(413, 'file_too_large', `note is larger than ${maxBytes} bytes`);
    const buffer = readFileSync(absolute);
    try {
      return { buffer, text: utf8.decode(buffer) };
    } catch {
      throw new BridgeError(415, 'file_not_text', 'note is not valid UTF-8 text');
    }
  }

  function entryFor(real, rel, allowedAreas, { withText, tolerant = false }) {
    const area = zoneOf(policy, rel);
    if (!allowedAreas.includes(area.zone)) return null;
    let resolved;
    try {
      resolved = resolveExisting(real, rel);
    } catch (err) {
      if (!tolerant) throw err;
      return null; // vanished or became a link between walk and read
    }
    const { absolute, info } = resolved;
    let buffer;
    let text;
    try {
      ({ buffer, text } = readText(absolute, MAX_READ_BYTES));
    } catch (err) {
      if (!tolerant || !(err instanceof BridgeError)) throw err;
      // List the note with its size but without a hash: a note the Bridge
      // cannot read must still be visible, not silently missing.
      return {
        id: fileId(rel),
        path: rel,
        area: area.zone,
        areaLabel: area.label,
        size: info.size,
        modifiedAt: new Date(info.mtimeMs).toISOString(),
        contentHash: null,
        title: rel.split('/').pop().replace(/\.md$/i, ''),
        status: null,
        checked: null,
        unreadable: err.code,
      };
    }
    return {
      id: fileId(rel),
      path: rel,
      area: area.zone,
      areaLabel: area.label,
      size: info.size,
      modifiedAt: new Date(info.mtimeMs).toISOString(),
      contentHash: hashBuffer(buffer),
      ...noteMeta(text, rel),
      ...(withText ? { text } : {}),
    };
  }

  function walk(dir, depth, out) {
    if (depth > MAX_WALK_DEPTH || out.length >= MAX_LIST_ENTRIES) return;
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return; // an unreadable subdirectory is skipped, not fatal for the listing
    }
    for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
      if (out.length >= MAX_LIST_ENTRIES) return;
      const name = entry.name;
      if (name.startsWith('.') || policy.excludeDirs.includes(name) || RESERVED_SEGMENTS.has(name)) continue;
      const absolute = join(dir, name);
      if (entry.isSymbolicLink()) continue; // never follow: a link could leave the vault or enter `old/`
      if (entry.isDirectory()) {
        walk(absolute, depth + 1, out);
        continue;
      }
      if (!entry.isFile() || !name.toLowerCase().endsWith('.md')) continue;
      out.push(absolute);
    }
  }

  return {
    root,
    policy,
    createPrefixes,

    // Notes the device may see, in a stable path order.
    list({ allowedAreas }) {
      const real = rootReal();
      const files = [];
      walk(real, 0, files);
      const items = [];
      for (const absolute of files) {
        const rel = absolute.slice(real.length + 1).split(sep).join('/');
        let path;
        try {
          path = parseVaultPath(rel);
        } catch {
          continue; // reserved/conflict files are not notes
        }
        const entry = entryFor(real, path, allowedAreas, { withText: false, tolerant: true });
        if (entry) items.push(entry);
      }
      return items.sort((a, b) => a.path.localeCompare(b.path));
    },

    read({ id, path, allowedAreas }) {
      const real = rootReal();
      const rel = path ?? pathFromId(id);
      const entry = entryFor(real, rel, allowedAreas, { withText: true });
      if (!entry) throw notFound(`note ${rel} is not in an allowed area`);
      return entry;
    },

    // Create-only. `onConflict: "suffix"` picks the next free name atomically;
    // `reject` throws 409 without touching the vault.
    create({ path, content, onConflict = 'suffix' }) {
      if (onConflict !== 'suffix' && onConflict !== 'reject') {
        throw badRequest('payload_invalid', 'onConflict must be "suffix" or "reject"');
      }
      const real = rootReal();
      if (!createPrefixes.some((prefix) => path.startsWith(prefix))) {
        throw new BridgeError(403, 'brain_create_area_forbidden',
          `new notes may only be created under ${createPrefixes.join(', ')}`);
      }
      const bytes = Buffer.from(content, 'utf8');
      if (bytes.length > MAX_NOTE_BYTES) {
        throw badRequest('content_too_large', `content must be at most ${MAX_NOTE_BYTES} bytes`);
      }
      const parentParts = path.split('/').slice(0, -1);
      const parentAbsolute = join(real, ...parentParts);
      try {
        const resolved = realpathSync(parentAbsolute);
        if (resolved !== parentAbsolute || !statSync(resolved).isDirectory()) throw new Error('not a plain directory');
      } catch {
        throw badRequest('path_parent_missing', 'the parent folder must already exist inside the vault');
      }

      const candidates = [path];
      const dot = path.lastIndexOf('.md');
      for (let i = 2; i < 2 + SUFFIX_LIMIT && onConflict === 'suffix'; i += 1) {
        candidates.push(`${path.slice(0, dot)} ${i}${path.slice(dot)}`);
      }

      for (const candidate of candidates) {
        const absolute = join(real, ...candidate.split('/'));
        let fd;
        try {
          fd = openSync(absolute, 'wx', 0o644); // O_EXCL: never clobber, even in a race
        } catch (err) {
          if (err.code === 'EEXIST') continue;
          throw toBridgeError(err, `note ${candidate}`);
        }
        let written = 0;
        try {
          written = writeSync(fd, bytes, 0, bytes.length);
          if (written !== bytes.length) throw new Error('short write');
          fsyncSync(fd);
        } catch (err) {
          closeSync(fd);
          try {
            unlinkSync(absolute); // only ever our own exclusive file
          } catch {
            // leave the artefact for a human; the request still fails
          }
          if (err.code === 'ENOSPC') {
            throw new BridgeError(503, 'brain_vault_no_space', 'the Brain vault is out of space', { retryable: true });
          }
          throw toBridgeError(err, `note ${candidate}`);
        }
        closeSync(fd);
        fsyncDirectory(parentAbsolute);
        const info = statSync(absolute);
        const { buffer } = readText(absolute, MAX_READ_BYTES);
        if (buffer.length !== bytes.length || hashBuffer(buffer) !== hashBuffer(bytes)) {
          throw new BridgeError(500, 'brain_create_unverified',
            `note ${candidate} was created but does not read back with the expected content`);
        }
        return {
          id: fileId(candidate),
          path: candidate,
          requestedPath: path,
          area: zoneOf(policy, candidate).zone,
          contentHash: hashBuffer(buffer),
          size: info.size,
          createdAt: new Date(info.mtimeMs).toISOString(),
          suffixApplied: candidate !== path,
        };
      }

      throw new BridgeError(409, 'path_exists', `note ${path} already exists; retry with onConflict "suffix" or another path`);
    },
  };
}

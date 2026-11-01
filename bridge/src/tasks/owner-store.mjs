// Owner tasks: the single durable document that holds the tasks, the operation
// ledger that makes a retry safe, the Linear import mapping, and the tombstones
// of compacted operations.
//
// One file, one write per change: the data and the ledger entry that describes
// the change are committed by the same atomic replace (tmp -> fsync -> rename
// -> directory fsync). A process that dies mid-request therefore leaves either
// the old document or the new one, never a task without its ledger row or a
// ledger row without its task.
//
// Two properties this module refuses to trade away:
//
//   * A missing or corrupt document is never replaced by an empty one. The
//     marker file `owner-tasks.initialized` remembers that the store existed;
//     when the document disappears the store answers 503 and an operator
//     restores a backup.
//   * The lock is never taken from a live writer. A lock whose owner process is
//     still alive is waited on; an unreadable lock stops writes until a human
//     looks. Only a lock whose recorded pid is gone is reclaimed.

import {
  chmodSync,
  closeSync,
  existsSync,
  fsyncSync,
  mkdirSync,
  openSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  statSync,
  writeSync,
} from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { BridgeError } from '../errors.mjs';
import { canonicalJson, sha256Hex } from './stable.mjs';

export const OWNER_TASKS_SCHEMA = 1;
export const OWNER_TASKS_FILE = 'owner-tasks.json';
export const OWNER_TASKS_MARKER = 'owner-tasks.initialized';
export const OWNER_TASKS_BACKUP_DIR = 'owner-tasks-backups';
export const SNAPSHOT_FORMAT = 'laa-owner-tasks-snapshot';
export const SNAPSHOT_VERSION = 1;
export const OPERATION_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;
export const MAX_OPERATIONS = 20_000;
export const DEFAULT_BACKUP_GENERATIONS = 14;

const LOCK_GRACE_MS = 2000;
const SNAPSHOT_NAME = /^owner-tasks-(\d{8}T\d{6}Z)(?:-(\d+))?\.json$/;

export function resolveOwnerTaskPaths({ stateDir }) {
  return {
    dir: stateDir,
    file: join(stateDir, OWNER_TASKS_FILE),
    marker: join(stateDir, OWNER_TASKS_MARKER),
    lock: join(stateDir, `${OWNER_TASKS_FILE}.lock`),
    backupDir: join(stateDir, OWNER_TASKS_BACKUP_DIR),
  };
}

function unavailable(reason, message, { retryable = false } = {}) {
  return new BridgeError(503, 'owner_tasks_store_unavailable', message, {
    details: { reason },
    retryable: retryable || reason === 'locked' || reason === 'io_error',
  });
}

function emptyDocument(iso) {
  return {
    schema: OWNER_TASKS_SCHEMA,
    initialized: true,
    createdAt: iso,
    updatedAt: iso,
    tasks: {},
    operations: {},
    tombstones: {},
    imports: {},
    linearMap: {},
  };
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function checkDocument(doc, file) {
  if (!isPlainObject(doc) || doc.schema !== OWNER_TASKS_SCHEMA || doc.initialized !== true) {
    throw unavailable('corrupt', 'owner-task document has an unsupported shape');
  }
  for (const key of ['tasks', 'operations', 'tombstones', 'imports', 'linearMap']) {
    if (!isPlainObject(doc[key])) {
      throw unavailable('corrupt', `owner-task document is missing "${key}"`);
    }
  }
  return doc;
}

function processAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return true;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code !== 'ESRCH';
  }
}

function sleepMs(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function fsyncDir(dir) {
  let fd;
  try {
    fd = openSync(dir, 'r');
  } catch {
    return;
  }
  try {
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
}

function writeFileAtomic(file, text) {
  const tmp = `${file}.${process.pid}.${Math.random().toString(16).slice(2)}.tmp`;
  const fd = openSync(tmp, 'wx', 0o600);
  try {
    writeSync(fd, text, 0, 'utf8');
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
  renameSync(tmp, file);
  fsyncDir(dirname(file));
}

export function readSnapshot(file) {
  let raw;
  try {
    raw = readFileSync(file, 'utf8');
  } catch (error) {
    throw new BridgeError(400, 'owner_tasks_snapshot_unreadable', `cannot read the snapshot (${error.code ?? 'error'})`);
  }
  let snapshot;
  try {
    snapshot = JSON.parse(raw);
  } catch {
    throw new BridgeError(400, 'owner_tasks_snapshot_invalid', 'the snapshot is not valid JSON');
  }
  if (!isPlainObject(snapshot) || snapshot.format !== SNAPSHOT_FORMAT || snapshot.version !== SNAPSHOT_VERSION) {
    throw new BridgeError(400, 'owner_tasks_snapshot_invalid', 'the file is not an owner-task snapshot');
  }
  if (typeof snapshot.stateSha256 !== 'string' || !/^sha256:[a-f0-9]{64}$/.test(snapshot.stateSha256)) {
    throw new BridgeError(400, 'owner_tasks_snapshot_invalid', 'the snapshot has no valid checksum');
  }
  const actual = `sha256:${sha256Hex(canonicalJson(snapshot.state))}`;
  if (actual !== snapshot.stateSha256) {
    throw new BridgeError(400, 'owner_tasks_snapshot_hash_mismatch', 'the snapshot checksum does not match its contents');
  }
  checkDocument(snapshot.state, file);
  return snapshot;
}

export function createOwnerTaskStore({ dir, now = () => Date.now(), lockTimeoutMs = 5000 } = {}) {
  if (typeof dir !== 'string' || dir === '') throw new Error('owner-task store requires a state directory');
  const paths = resolveOwnerTaskPaths({ stateDir: resolve(dir) });

  function ensureDir(target = paths.dir) {
    mkdirSync(target, { recursive: true, mode: 0o700 });
    try {
      chmodSync(target, 0o700);
    } catch {
      // A directory owned by the user may refuse chmod; reads and writes still work.
    }
  }

  function readDocument() {
    let raw;
    try {
      raw = readFileSync(paths.file, 'utf8');
    } catch (error) {
      if (error.code === 'ENOENT') return null;
      throw unavailable('io_error', `cannot read the owner-task document (${error.code ?? 'error'})`);
    }
    let parsed;
    try {
      parsed = JSON.parse(raw);
    } catch {
      throw unavailable('corrupt', 'owner-task document is not valid JSON');
    }
    return checkDocument(parsed, paths.file);
  }

  function writeDocument(doc) {
    // One line: this document grows with the tombstone ledger, and indentation
    // would multiply that on every write for no operator benefit.
    writeFileAtomic(paths.file, `${JSON.stringify(doc)}\n`);
  }

  function writeMarker() {
    writeFileAtomic(paths.marker, `${JSON.stringify({ initializedAt: new Date(now()).toISOString(), document: OWNER_TASKS_FILE })}\n`);
  }

  function inspectLock() {
    let raw;
    let stat;
    try {
      stat = statSync(paths.lock);
      raw = readFileSync(paths.lock, 'utf8');
    } catch (error) {
      return error.code === 'ENOENT' ? { kind: 'gone' } : { kind: 'unreadable' };
    }
    let info = null;
    try {
      info = JSON.parse(raw);
    } catch {
      info = null;
    }
    if (isPlainObject(info) && Number.isInteger(info.pid) && info.pid > 0) {
      return processAlive(info.pid) ? { kind: 'held', pid: info.pid } : { kind: 'dead', pid: info.pid };
    }
    // Between open() and the pid write a lock is legitimately empty. Only after
    // the grace period is an unparsable lock treated as a crash, and even then
    // it is reported instead of being taken.
    const age = Date.now() - stat.mtimeMs;
    return age < LOCK_GRACE_MS ? { kind: 'held' } : { kind: 'unreadable', age };
  }

  function withLock(fn) {
    ensureDir();
    const deadline = Date.now() + lockTimeoutMs;
    for (;;) {
      let fd = null;
      try {
        fd = openSync(paths.lock, 'wx', 0o600);
      } catch (error) {
        if (error.code !== 'EEXIST') {
          throw unavailable('io_error', `cannot open the owner-task lock (${error.code ?? 'error'})`);
        }
        const state = inspectLock();
        if (state.kind === 'dead') {
          // Re-check under the same reading: only remove the file whose owner is
          // still dead, never a lock a live writer took in between.
          const again = inspectLock();
          if (again.kind === 'dead' && again.pid === state.pid) {
            rmSync(paths.lock, { force: true });
            continue;
          }
          continue;
        }
        if (state.kind === 'unreadable') {
          throw unavailable('locked', 'owner-task lock is unreadable; confirm no writer is running, then remove it');
        }
        if (Date.now() >= deadline) {
          throw unavailable('locked', 'owner-task store is locked by another process');
        }
        sleepMs(5);
        continue;
      }
      try {
        writeSync(fd, JSON.stringify({ pid: process.pid, startedAt: new Date(now()).toISOString() }));
        fsyncSync(fd);
        return fn();
      } finally {
        closeSync(fd);
        rmSync(paths.lock, { force: true });
      }
    }
  }

  // Reads for callers that can answer "nothing yet" honestly. A store that was
  // never initialised has no document and no marker: an empty list is the truth.
  // Once the marker exists, a missing document means data was lost, and every
  // read fails until an operator restores it.
  function readOptional() {
    const doc = readDocument();
    if (doc) return doc;
    if (existsSync(paths.marker)) {
      throw unavailable('missing', 'owner-task document is missing; restore it from a backup');
    }
    return null;
  }

  function read() {
    const doc = readOptional();
    if (!doc) throw unavailable('missing', 'owner-task store has not been initialised');
    return doc;
  }

  function transact(fn, { create = false } = {}) {
    return withLock(() => {
      let doc = readDocument();
      const firstRun = doc === null;
      if (firstRun) {
        if (!create) {
          throw unavailable('missing', 'owner-task document is missing; restore it from a backup');
        }
        if (existsSync(paths.marker)) {
          // The store existed before; an empty file would silently discard every
          // task and every ledger row.
          throw unavailable('missing', 'owner-task document is missing but the store was initialised');
        }
        doc = emptyDocument(new Date(now()).toISOString());
      } else if (!existsSync(paths.marker)) {
        writeMarker();
      }
      const draft = structuredClone(doc);
      const result = fn(draft);
      draft.updatedAt = new Date(now()).toISOString();
      writeDocument(draft);
      if (firstRun) writeMarker();
      return result;
    });
  }

  function countsOf(doc) {
    const tasks = Object.values(doc.tasks);
    const byStatus = { todo: 0, doing: 0, done: 0, canceled: 0 };
    for (const task of tasks) {
      if (Object.hasOwn(byStatus, task.status)) byStatus[task.status] += 1;
    }
    return { tasks: tasks.length, ...byStatus };
  }

  function listSnapshots(dir) {
    let names;
    try {
      names = readdirSync(dir);
    } catch (error) {
      if (error.code === 'ENOENT') return [];
      throw unavailable('io_error', `cannot list snapshots (${error.code ?? 'error'})`);
    }
    return names
      .map((name) => {
        const match = SNAPSHOT_NAME.exec(name);
        return match ? { name, stamp: match[1], sequence: Number(match[2] ?? 0), file: join(dir, name) } : null;
      })
      .filter(Boolean)
      .sort((a, b) => (a.stamp === b.stamp ? a.sequence - b.sequence : a.stamp.localeCompare(b.stamp)));
  }

  function backup({ keep = DEFAULT_BACKUP_GENERATIONS, outDir = paths.backupDir } = {}) {
    if (!Number.isInteger(keep) || keep < 1 || keep > 365) {
      throw new BridgeError(400, 'field_invalid', 'keep must be an integer between 1 and 365', { details: { field: 'keep' } });
    }
    const doc = withLock(() => {
      // `readOptional` distinguishes "nothing has been stored yet" (skip, and
      // say so) from "the document was lost" (fail loudly).
      return readOptional();
    });
    if (!doc) {
      return { skipped: true, reason: 'not_initialized', path: null, counts: null, kept: listSnapshots(outDir).length };
    }
    ensureDir(outDir);
    const createdAt = new Date(now()).toISOString();
    const snapshot = {
      format: SNAPSHOT_FORMAT,
      version: SNAPSHOT_VERSION,
      createdAt,
      counts: countsOf(doc),
      stateSha256: `sha256:${sha256Hex(canonicalJson(doc))}`,
      state: doc,
    };
    const stamp = createdAt.replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z');
    let file = join(outDir, `owner-tasks-${stamp}.json`);
    for (let sequence = 2; existsSync(file); sequence += 1) {
      file = join(outDir, `owner-tasks-${stamp}-${sequence}.json`);
    }
    writeFileAtomic(file, `${JSON.stringify(snapshot)}\n`);

    // Read back what was written: a backup that cannot be restored is not one.
    const written = readSnapshot(file);
    if (written.stateSha256 !== snapshot.stateSha256) {
      throw unavailable('io_error', 'the snapshot did not read back with the same checksum');
    }

    const pruned = [];
    const snapshots = listSnapshots(outDir);
    for (const candidate of snapshots.slice(0, Math.max(0, snapshots.length - keep))) {
      try {
        readSnapshot(candidate.file); // only delete files this CLI wrote
      } catch {
        continue;
      }
      rmSync(candidate.file, { force: true });
      pruned.push(candidate.file);
    }
    return {
      path: file,
      createdAt,
      stateSha256: snapshot.stateSha256,
      counts: snapshot.counts,
      bytes: statSync(file).size,
      pruned,
      kept: listSnapshots(outDir).length,
    };
  }

  function restore({ from, to, allowLive = false, force = false } = {}) {
    if (typeof to !== 'string' || to === '') {
      throw new BridgeError(400, 'field_invalid', 'restore needs an explicit target directory', { details: { field: 'to' } });
    }
    const snapshot = readSnapshot(from);
    const target = resolveOwnerTaskPaths({ stateDir: resolve(to) });
    if (target.dir === paths.dir && !allowLive) {
      throw new BridgeError(400, 'owner_tasks_restore_live_directory',
        'refusing to overwrite the running store without --allow-live');
    }
    if (existsSync(target.file) && !force) {
      throw new BridgeError(409, 'owner_tasks_restore_target_exists',
        'the target directory already holds an owner-task document; pass --force to replace it');
    }
    ensureDir(target.dir);
    writeFileAtomic(target.file, `${JSON.stringify(snapshot.state)}\n`);
    writeFileAtomic(target.marker, `${JSON.stringify({
      initializedAt: new Date(now()).toISOString(),
      document: OWNER_TASKS_FILE,
      restoredFrom: from,
      restoredAt: new Date(now()).toISOString(),
    })}\n`);

    const restored = readDocumentAt(target.file);
    const actual = `sha256:${sha256Hex(canonicalJson(restored))}`;
    if (actual !== snapshot.stateSha256) {
      throw unavailable('io_error', 'the restored document does not match the snapshot checksum');
    }
    const tasks = Object.values(restored.tasks);
    return {
      to: target.dir,
      file: target.file,
      from,
      stateSha256: actual,
      counts: countsOf(restored),
      operations: Object.keys(restored.operations).length,
      tombstones: Object.keys(restored.tombstones).length,
      imports: Object.keys(restored.imports).length,
      newestUpdatedAt: tasks.reduce((max, task) => (task.updatedAt > max ? task.updatedAt : max), ''),
      maxRevision: tasks.reduce((max, task) => Math.max(max, task.revision ?? 0), 0),
    };
  }

  function readDocumentAt(file) {
    const parsed = JSON.parse(readFileSync(file, 'utf8'));
    return checkDocument(parsed, file);
  }

  function status() {
    const out = {
      dir: paths.dir,
      file: paths.file,
      marker: existsSync(paths.marker),
      exists: existsSync(paths.file),
      bytes: null,
      counts: null,
      operations: null,
      tombstones: null,
      imports: null,
      newestUpdatedAt: null,
      lock: inspectLock(),
      backupDir: paths.backupDir,
      lastBackup: null,
      backups: 0,
    };
    if (out.exists) {
      out.bytes = statSync(paths.file).size;
      try {
        const doc = readDocument();
        out.counts = countsOf(doc);
        out.operations = Object.keys(doc.operations).length;
        out.tombstones = Object.keys(doc.tombstones).length;
        out.imports = Object.keys(doc.imports).length;
        const tasks = Object.values(doc.tasks);
        out.newestUpdatedAt = tasks.length === 0
          ? null
          : tasks.reduce((max, task) => (task.updatedAt > max ? task.updatedAt : max), tasks[0].updatedAt);
      } catch (error) {
        out.error = error.code ?? 'unreadable';
        out.errorReason = error.details?.reason ?? null;
      }
    }
    const snapshots = listSnapshots(paths.backupDir);
    out.backups = snapshots.length;
    if (snapshots.length > 0) {
      const newest = snapshots[snapshots.length - 1];
      out.lastBackup = { file: newest.file, bytes: statSync(newest.file).size, modifiedAt: statSync(newest.file).mtime.toISOString() };
    }
    return out;
  }

  return {
    dir: paths.dir,
    file: paths.file,
    paths,
    read,
    readOptional,
    transact,
    backup,
    restore,
    status,
    lockTimeoutMs,
  };
}

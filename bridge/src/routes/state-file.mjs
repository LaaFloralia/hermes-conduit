// Small shared helpers for route modules: request bodies and per-area state
// files. Kept apart from `store.mjs` so a business area never has to touch the
// device/idempotency state to add its own data.

import { chmodSync, closeSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, rmSync, statSync, writeSync } from 'node:fs';
import { dirname } from 'node:path';
import { badRequest } from '../errors.mjs';

export function parseObjectBody(raw) {
  if (raw === undefined || raw.length === 0) return {};
  let parsed;
  try {
    parsed = JSON.parse(raw.toString('utf8'));
  } catch {
    throw badRequest('payload_invalid', 'request body is not valid JSON');
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw badRequest('payload_invalid', 'request body must be a JSON object');
  }
  return parsed;
}

export class StateFileError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'StateFileError';
    this.code = code;
  }
}

// One JSON document per area, re-read per operation and replaced atomically
// with an exclusive lock. Corrupt files are never reset silently: the caller
// surfaces 500 and the operator has to look, because a lost project or
// workspace record is an authorization-relevant loss of identity.
export function createJsonFile({ file, schema = 1, initial = () => ({}) }) {
  const dir = dirname(file);
  const lockFile = `${file}.lock`;

  function ensureDir() {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    try {
      chmodSync(dir, 0o700);
    } catch {
      // Pre-existing directory owned by the user may refuse chmod.
    }
  }

  function read() {
    let raw;
    try {
      raw = readFileSync(file, 'utf8');
    } catch (err) {
      if (err.code === 'ENOENT') return { schema, ...initial() };
      throw new StateFileError('state_unreadable', `cannot read ${file}: ${err.code}`);
    }
    let parsed;
    try {
      parsed = JSON.parse(raw);
    } catch {
      throw new StateFileError('state_corrupt', `state file is not valid JSON: ${file}`);
    }
    if (!parsed || typeof parsed !== 'object' || parsed.schema !== schema) {
      throw new StateFileError('state_corrupt', `unsupported state schema in ${file}`);
    }
    return parsed;
  }

  function write(state) {
    ensureDir();
    const tmp = `${file}.${process.pid}.${Math.random().toString(16).slice(2)}.tmp`;
    const fd = openSync(tmp, 'wx', 0o600);
    try {
      writeSync(fd, `${JSON.stringify(state, null, 2)}\n`, 0, 'utf8');
      fsyncSync(fd);
    } finally {
      closeSync(fd);
    }
    renameSync(tmp, file);
  }

  function withLock(fn) {
    ensureDir();
    const deadline = Date.now() + 2000;
    for (;;) {
      try {
        const fd = openSync(lockFile, 'wx', 0o600);
        try {
          return fn();
        } finally {
          closeSync(fd);
          rmSync(lockFile, { force: true });
        }
      } catch (err) {
        if (err.code !== 'EEXIST') throw err;
        try {
          if (Date.now() - statSync(lockFile).mtimeMs > 10_000) {
            rmSync(lockFile, { force: true });
            continue;
          }
        } catch {
          continue;
        }
        if (Date.now() > deadline) {
          throw new StateFileError('state_locked', `state lock is held: ${lockFile}`);
        }
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
      }
    }
  }

  return {
    file,
    read,
    mutate(fn) {
      return withLock(() => {
        const state = read();
        const result = fn(state);
        write(state);
        return result;
      });
    },
  };
}

// Persistent state for the Bridge: devices, one-time pairing codes and the
// idempotency ledger.
//
// Everything lives in one JSON file that is re-read on every operation and
// replaced atomically. The file stays small (a handful of devices, a week of
// idempotency keys), so per-request reads buy a property worth more than the
// syscalls: a state change made by the CLI (`laa-bridge revoke`) takes effect
// on the next request of an already running server, with no restart and no
// second code path for reloading.
//
// Corrupt state is never reset silently: the caller must stop serving, because
// a lost device or ledger row is an authorization and replay-tracking loss.

import { chmodSync, closeSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, rmSync, statSync, writeSync } from 'node:fs';
import { join } from 'node:path';

export const STATE_SCHEMA = 1;

export class StateError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'StateError';
    this.code = code;
  }
}

function emptyState() {
  return { schema: STATE_SCHEMA, devices: {}, pairings: {}, idempotency: {} };
}

export function createStore({ dir, idempotencyRetentionMs, now = () => Date.now() }) {
  const file = join(dir, 'state.json');
  const lockFile = join(dir, 'state.lock');

  function ensureDir() {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    // mkdir's mode is filtered by umask; the state holds only token hashes, but
    // keep it owner-only anyway.
    try {
      chmodSync(dir, 0o700);
    } catch {
      // A pre-existing directory owned by the user may refuse chmod; reading
      // and writing still work, so this is not fatal.
    }
  }

  function read() {
    let raw;
    try {
      raw = readFileSync(file, 'utf8');
    } catch (err) {
      if (err.code === 'ENOENT') return emptyState();
      throw new StateError('state_unreadable', `cannot read ${file}: ${err.code}`);
    }
    let parsed;
    try {
      parsed = JSON.parse(raw);
    } catch {
      throw new StateError('state_corrupt', `state file is not valid JSON: ${file}`);
    }
    if (!parsed || typeof parsed !== 'object' || parsed.schema !== STATE_SCHEMA) {
      throw new StateError('state_corrupt', `unsupported state schema in ${file}`);
    }
    return {
      schema: STATE_SCHEMA,
      devices: parsed.devices ?? {},
      pairings: parsed.pairings ?? {},
      idempotency: parsed.idempotency ?? {},
    };
  }

  function write(state) {
    ensureDir();
    const tmp = join(dir, `.state.${process.pid}.${Math.random().toString(16).slice(2)}.tmp`);
    const fd = openSync(tmp, 'wx', 0o600);
    try {
      const data = `${JSON.stringify(state, null, 2)}\n`;
      writeSync(fd, data, 0, 'utf8');
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
        // A lock left behind by a killed process must not block pairing or
        // revocation forever.
        try {
          if (Date.now() - statSync(lockFile).mtimeMs > 10_000) {
            rmSync(lockFile, { force: true });
            continue;
          }
        } catch {
          continue;
        }
        if (Date.now() > deadline) {
          throw new StateError('state_locked', `state lock is held: ${lockFile}`);
        }
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
      }
    }
  }

  function prune(state) {
    const t = now();
    for (const [hash, pairing] of Object.entries(state.pairings)) {
      // Keep expired codes for an hour after expiry so a late attempt is told
      // "expired" instead of "unknown".
      if (pairing.expiresAt + 60 * 60 * 1000 < t) delete state.pairings[hash];
    }
    for (const [key, entry] of Object.entries(state.idempotency)) {
      if (entry.createdAt + idempotencyRetentionMs < t) delete state.idempotency[key];
    }
    return state;
  }

  return {
    dir,
    file,
    read,
    mutate(fn) {
      return withLock(() => {
        const state = prune(read());
        const result = fn(state);
        write(state);
        return result;
      });
    },
    // Test/operator helper: read, prune, persist only when something changed.
    compact() {
      const before = read();
      const compacted = prune(structuredClone(before));
      if (JSON.stringify(before) !== JSON.stringify(compacted)) write(compacted);
      return compacted;
    },
  };
}

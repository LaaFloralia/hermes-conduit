// Out-of-vault journal for Bridge-created Brain notes (BRAIN-WRITE §4 step 5,
// §7 "brain:create … journal付き").
//
// The vault is the shared copy; the journal is the Bridge's own record of what
// it put there and why, kept outside the vault so Syncthing cannot rewrite it.
// It holds metadata only (path, hash, size, request/device id) — the content is
// already in the vault and must not be duplicated into a second store.
//
// Two records per create: `intent` is fsynced before the vault is touched, so a
// crash in the middle leaves a trace of what may exist; `committed` (or
// `aborted`) closes it. A journal that cannot be written refuses the create
// before any vault change.

import { chmodSync, closeSync, fsyncSync, mkdirSync, openSync, writeSync } from 'node:fs';
import { dirname } from 'node:path';
import { BridgeError } from '../errors.mjs';

export function createJournal({ file, now = () => Date.now() }) {
  function ensureDir() {
    mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
    try {
      chmodSync(dirname(file), 0o700);
    } catch {
      // An existing directory may refuse chmod; appending still works.
    }
  }

  function append(record) {
    ensureDir();
    const line = `${JSON.stringify({ at: new Date(now()).toISOString(), ...record })}\n`;
    const fd = openSync(file, 'a', 0o600);
    try {
      writeSync(fd, line);
      fsyncSync(fd);
    } finally {
      closeSync(fd);
    }
  }

  return {
    file,
    // Throws 503 when nothing can be recorded: the caller must not touch the
    // vault in that case.
    intent(record) {
      try {
        append({ phase: 'intent', ...record });
      } catch {
        throw new BridgeError(503, 'brain_journal_unavailable',
          'the Brain create journal cannot be written; nothing was created', { retryable: true });
      }
    },
    close(record) {
      try {
        append(record);
        return true;
      } catch {
        // The note exists; the caller reports the incomplete audit instead of
        // pretending the create did not happen.
        return false;
      }
    },
    append,
  };
}

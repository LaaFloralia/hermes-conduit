// Isolated instrumentation for the ledger I/O characterization fixture.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { syncBuiltinESMExports } from 'node:module';

const counts = { reads: 0, replacements: 0, fsyncs: 0 };
const read = fs.readFileSync, rename = fs.renameSync, fsync = fs.fsyncSync;
fs.readFileSync = function (...args) {
  if (String(args[0]).endsWith('/task-operations.json')) counts.reads++;
  return read.apply(this, args);
};
fs.renameSync = function (...args) {
  if (String(args[1]).endsWith('/task-operations.json')) counts.replacements++;
  return rename.apply(this, args);
};
fs.fsyncSync = function (...args) { counts.fsyncs++; return fsync.apply(this, args); };
syncBuiltinESMExports();
const { createStore } = await import('../../src/store.mjs');
const { createTaskOperationLedger } = await import('../../src/tasks/operation-ledger.mjs');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ledger-io-fixture-'));
try {
  const store = createStore({ dir, idempotencyRetentionMs: 7 * 24 * 60 * 60 * 1000 });
  const ledger = createTaskOperationLedger({ store });
  const base = { deviceId: 'device', viewerId: 'viewer', method: 'POST', path: '/fixture',
    rawBody: Buffer.from('{}'), kind: 'create', targetId: 'target' };
  ledger.reserve({ ...base, key: 'initialize' });
  counts.reads = counts.replacements = counts.fsyncs = 0;
  ledger.reserve({ ...base, key: 'measure' });
  ledger.finish({ ...base, key: 'measure', status: 'succeeded', result: { id: 'target', identifier: 'F-1' } });
  process.stdout.write(JSON.stringify(counts));
} finally { fs.rmSync(dir, { recursive: true, force: true }); }

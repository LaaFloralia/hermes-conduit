import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { createStore } from '../src/store.mjs';
import { createTaskOperationLedger } from '../src/tasks/operation-ledger.mjs';

const deviceId = 'fixture-device', viewerId = 'fixture-owner';
const hash = (key) => createHash('sha256').update(JSON.stringify([deviceId, key])).digest('hex');
test('old terminal records compact to hashes while unknown and resolved remain replay-safe', (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'laa-compact-test-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
  let time = Date.UTC(2026, 0, 1); const now = () => time;
  const store = createStore({ dir, idempotencyRetentionMs: 86400000, now });
  let ledger = createTaskOperationLedger({ store, now });
  const reserve = (key) => ledger.reserve({ deviceId, viewerId, key, method: 'POST', path: '/fixture',
    rawBody: Buffer.from('private fixture body'), kind: 'create', targetId: `target-${key}` });
  for (const [key, status] of [['success-key', 'succeeded'], ['reject-key', 'rejected'], ['unknown-key', 'outcome_unknown'], ['resolved-key', 'outcome_unknown']]) {
    assert.equal(reserve(key).action, 'execute');
    ledger.finish({ deviceId, viewerId, key, status, result: { id: `target-${key}` }, rejection: 'linear_rejected' });
  }
  const resolved = ledger.byKey({ deviceId, viewerId, key: 'resolved-key' });
  ledger.resolve({ deviceId, viewerId, operationId: resolved.operationId, resolution: 'not_applied', key: 'resolve-key', fingerprint: 'resolve-fingerprint' });
  time += 8 * 86400000;
  assert.equal(reserve('fresh-key').action, 'execute');
  const doc = JSON.parse(readFileSync(ledger.file));
  assert.deepEqual(new Set(Object.keys(doc.tombstones)), new Set([hash('success-key'), hash('reject-key')]));
  assert.ok(Object.entries(doc.tombstones).every(([h, at]) => /^[a-f0-9]{64}$/.test(h) && at === time));
  assert.equal(doc.entries[hash('success-key')], undefined);
  assert.equal(doc.entries[hash('reject-key')], undefined);
  assert.equal(doc.entries[hash('unknown-key')].status, 'outcome_unknown');
  assert.equal(doc.entries[hash('resolved-key')].status, 'resolved');
  assert.doesNotMatch(JSON.stringify(doc.tombstones), /fixture|owner|target|body/);
  ledger = createTaskOperationLedger({ store, now });
  for (const key of ['success-key', 'reject-key']) {
    assert.equal(reserve(key).action, 'expired');
    assert.throws(() => ledger.byKey({ deviceId, viewerId, key }), { status: 410, code: 'task_operation_compacted', details: { tombstone: true } });
    assert.throws(() => ledger.abandonUnsent({ deviceId, viewerId, key }), { status: 410, code: 'task_operation_compacted', details: { tombstone: true } });
  }
  assert.equal(reserve('unknown-key').entry.status, 'outcome_unknown');
  assert.equal(reserve('resolved-key').entry.status, 'resolved');
  assert.throws(() => ledger.resolve({ deviceId, viewerId, operationId: resolved.operationId,
    resolution: 'not_applied', key: 'success-key', fingerprint: 'other' }), { code: 'idempotency_key_conflict' });
  time += 30 * 86400000 - 1;
  assert.equal(reserve('before-expiry').action, 'execute');
  assert.equal(reserve('success-key').action, 'expired');
  time += 1;
  assert.equal(reserve('after-expiry').action, 'execute');
  assert.equal(ledger.byKey({ deviceId, viewerId, key: 'success-key' }), null);
  assert.equal(ledger.byKey({ deviceId, viewerId, key: 'unknown-key' }).status, 'outcome_unknown');
  assert.equal(ledger.byKey({ deviceId, viewerId, key: 'resolved-key' }).status, 'resolved');
});

test('legacy tombstone arrays get a full 30-day retention period on migration', (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'laa-compact-legacy-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
  let time = Date.UTC(2026, 0, 1); const now = () => time;
  const store = createStore({ dir, idempotencyRetentionMs: 86400000, now });
  const ledger = createTaskOperationLedger({ store, now });
  const reserve = (key) => ledger.reserve({ deviceId, viewerId, key, method: 'POST', path: '/fixture',
    rawBody: Buffer.alloc(0), kind: 'create', targetId: 'target' });
  assert.equal(reserve('seed').action, 'execute');
  const doc = JSON.parse(readFileSync(ledger.file));
  doc.tombstones = [hash('legacy')];
  writeFileSync(ledger.file, JSON.stringify(doc));
  assert.throws(() => ledger.byKey({ deviceId, viewerId, key: 'legacy' }), { code: 'task_operation_compacted' });
  assert.equal(reserve('trigger').action, 'execute');
  assert.equal(JSON.parse(readFileSync(ledger.file)).tombstones[hash('legacy')], time);
  time += 30 * 86400000 - 1;
  assert.equal(reserve('legacy').action, 'expired');
  time += 1;
  assert.equal(reserve('trigger-after').action, 'execute');
  assert.equal(ledger.byKey({ deviceId, viewerId, key: 'legacy' }), null);
  const malformed = JSON.parse(readFileSync(ledger.file));
  malformed.tombstones = { [hash('invalid')]: 'not a timestamp' };
  writeFileSync(ledger.file, JSON.stringify(malformed));
  assert.throws(() => reserve('must-fail-closed'), { code: 'task_ledger_unavailable' });
});

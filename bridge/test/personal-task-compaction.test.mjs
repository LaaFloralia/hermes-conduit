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
const ownerHash = createHash('sha256').update(JSON.stringify([deviceId, viewerId])).digest('hex');

test('terminal tombstones retain their result and permanently prevent duplicate creation', (t) => {
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
  // Abandon itself compacts the old rejection; it must still reveal the result.
  assert.throws(() => ledger.abandonUnsent({ deviceId, viewerId, key: 'reject-key' }),
    { status: 410, code: 'task_operation_compacted', details: { tombstone: true, result: 'rejected' } });
  const doc = JSON.parse(readFileSync(ledger.file));
  assert.deepEqual(new Set(Object.keys(doc.tombstones)), new Set([hash('success-key'), hash('reject-key')]));
  assert.deepEqual(doc.tombstones[hash('success-key')], { compactedAt: time, status: 'succeeded', ownerHash });
  assert.deepEqual(doc.tombstones[hash('reject-key')], { compactedAt: time, status: 'rejected', ownerHash });
  assert.equal(doc.entries[hash('success-key')], undefined);
  assert.equal(doc.entries[hash('reject-key')], undefined);
  assert.equal(doc.entries[hash('unknown-key')].status, 'outcome_unknown');
  assert.equal(doc.entries[hash('resolved-key')].status, 'resolved');
  assert.doesNotMatch(JSON.stringify(doc.tombstones), /fixture|target|body/);
  ledger = createTaskOperationLedger({ store, now });
  for (const [key, result] of [['success-key', 'succeeded'], ['reject-key', 'rejected']]) {
    assert.equal(reserve(key).action, 'expired');
    assert.throws(() => ledger.byKey({ deviceId, viewerId, key }), { status: 410, details: { tombstone: true, result } });
    assert.throws(() => ledger.abandonUnsent({ deviceId, viewerId, key }), { status: 410, details: { tombstone: true, result } });
    assert.throws(() => ledger.byKey({ deviceId, viewerId: 'another-viewer', key }),
      { status: 410, details: { tombstone: true, result: 'unknown' } });
  }
  assert.equal(reserve('unknown-key').entry.status, 'outcome_unknown');
  assert.equal(reserve('resolved-key').entry.status, 'resolved');
  assert.throws(() => ledger.resolve({ deviceId, viewerId, operationId: resolved.operationId,
    resolution: 'not_applied', key: 'success-key', fingerprint: 'other' }), { code: 'idempotency_key_conflict' });
  // Over 37 days since success, including the former 30-day expiry boundary.
  time += 30 * 86400000 + 1;
  assert.equal(reserve('after-former-expiry').action, 'execute');
  assert.throws(() => ledger.abandonUnsent({ deviceId, viewerId, key: 'success-key' }),
    { status: 410, details: { tombstone: true, result: 'succeeded' } });
  assert.throws(() => ledger.abandonUnsent({ deviceId, viewerId, key: 'reject-key' }),
    { status: 410, details: { tombstone: true, result: 'rejected' } });
  assert.equal(reserve('success-key').action, 'expired');
  assert.equal(ledger.byKey({ deviceId, viewerId, key: 'unknown-key' }).status, 'outcome_unknown');
  assert.equal(ledger.byKey({ deviceId, viewerId, key: 'resolved-key' }).status, 'resolved');
});

test('legacy tombstones stay indefinitely and cannot be mistaken for rejection', (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'laa-compact-legacy-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
  let time = Date.UTC(2026, 0, 1); const now = () => time;
  const store = createStore({ dir, idempotencyRetentionMs: 86400000, now });
  const ledger = createTaskOperationLedger({ store, now });
  const reserve = (key) => ledger.reserve({ deviceId, viewerId, key, method: 'POST', path: '/fixture',
    rawBody: Buffer.alloc(0), kind: 'create', targetId: 'target' });
  assert.equal(reserve('seed').action, 'execute');
  const doc = JSON.parse(readFileSync(ledger.file));
  doc.tombstones = [hash('legacy-array')];
  writeFileSync(ledger.file, JSON.stringify(doc));
  assert.equal(reserve('trigger').action, 'execute');
  const migrated = JSON.parse(readFileSync(ledger.file));
  assert.deepEqual(migrated.tombstones[hash('legacy-array')], { compactedAt: time, status: 'unknown' });
  migrated.tombstones[hash('legacy-timestamp')] = time;
  writeFileSync(ledger.file, JSON.stringify(migrated));
  time += 100 * 86400000;
  assert.equal(reserve('trigger-later').action, 'execute');
  for (const key of ['legacy-array', 'legacy-timestamp']) {
    assert.throws(() => ledger.abandonUnsent({ deviceId, viewerId, key }),
      { status: 410, details: { tombstone: true, result: 'unknown' } });
    assert.equal(reserve(key).action, 'expired');
  }
  const malformed = JSON.parse(readFileSync(ledger.file));
  malformed.tombstones = { [hash('invalid')]: 'not a timestamp' };
  writeFileSync(ledger.file, JSON.stringify(malformed));
  assert.throws(() => reserve('must-fail-closed'), { code: 'task_ledger_unavailable' });
});

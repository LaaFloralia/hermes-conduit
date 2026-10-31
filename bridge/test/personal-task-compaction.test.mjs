import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
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
  assert.deepEqual(new Set(doc.tombstones), new Set([hash('success-key'), hash('reject-key')]));
  assert.ok(doc.tombstones.every((h) => /^[a-f0-9]{64}$/.test(h)));
  assert.equal(doc.entries[hash('success-key')], undefined);
  assert.equal(doc.entries[hash('reject-key')], undefined);
  assert.equal(doc.entries[hash('unknown-key')].status, 'outcome_unknown');
  assert.equal(doc.entries[hash('resolved-key')].status, 'resolved');
  assert.doesNotMatch(JSON.stringify(doc.tombstones), /fixture|owner|target|body/);
  ledger = createTaskOperationLedger({ store, now });
  for (const key of ['success-key', 'reject-key']) {
    assert.equal(reserve(key).action, 'expired');
    assert.throws(() => ledger.byKey({ deviceId, viewerId, key }), { code: 'idempotency_outcome_unknown' });
    assert.throws(() => ledger.abandonUnsent({ deviceId, viewerId, key }), { code: 'idempotency_outcome_unknown' });
  }
  assert.equal(reserve('unknown-key').entry.status, 'outcome_unknown');
  assert.equal(reserve('resolved-key').entry.status, 'resolved');
  assert.throws(() => ledger.resolve({ deviceId, viewerId, operationId: resolved.operationId,
    resolution: 'not_applied', key: 'success-key', fingerprint: 'other' }), { code: 'idempotency_key_conflict' });
});

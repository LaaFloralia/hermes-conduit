// Content-free durable record for owner-initiated Linear writes. Linear does
// not accept the Bridge's idempotency key, so an ambiguous downstream result
// stays unresolved until the owner reconciles it.
import { createHash, randomUUID } from 'node:crypto';
import { closeSync, existsSync, fsyncSync, openSync } from 'node:fs';
import { join } from 'node:path';
import { BridgeError } from '../errors.mjs';
import { createJsonFile } from '../routes/state-file.mjs';

const MAX_RECORDS = 20_000;
const RECENT_MS = 7 * 24 * 60 * 60 * 1000;
const INFLIGHT_MS = 90 * 1000;
const digest = (data) => createHash('sha256').update(data).digest('hex');
const keyHash = (deviceId, key) => digest(JSON.stringify([deviceId, key]));
const ownerHash = (deviceId, viewerId) => digest(JSON.stringify([deviceId, viewerId]));
function processStillExists(pid) {
  // A live but suspended Bridge must not be mistaken for a crashed writer.
  // A reused PID can delay recovery, but cannot allow a second write.
  if (!Number.isInteger(pid) || pid <= 0) return true;
  try { process.kill(pid, 0); return true; } catch (error) { return error.code !== 'ESRCH'; }
}

export function operationFingerprint({ method, path, viewerId, ifMatch, rawBody }) {
  return createHash('sha256').update(JSON.stringify([method, path, viewerId, ifMatch ?? null]))
    .update('\n').update(rawBody ?? Buffer.alloc(0)).digest('hex');
}

export function createTaskOperationLedger({ store, now = () => Date.now() }) {
  if (!store?.dir) throw new Error('task operation ledger requires a Bridge store');
  const file = join(store.dir, 'task-operations.json');
  const data = createJsonFile({ file, initial: () => ({ entries: {}, tombstones: {} }) });
  const unavailable = () => new BridgeError(503, 'task_ledger_unavailable', 'the task operation ledger requires operator recovery');
  const compacted = (record, deviceId, viewerId) => new BridgeError(410, 'task_operation_compacted',
    'the completed operation was compacted', { details: { tombstone: true,
      result: record.ownerHash === ownerHash(deviceId, viewerId) ? record.status : 'unknown' } });
  function syncDirectory() {
    const fd = openSync(store.dir, 'r');
    try { fsyncSync(fd); } finally { closeSync(fd); }
  }

  function checked(doc) {
    if (!doc.entries || typeof doc.entries !== 'object' || Array.isArray(doc.entries)) throw unavailable();
    if (doc.tombstones === undefined) doc.tombstones = {};
    // Older formats cannot prove the result or owner. Preserve their keys
    // indefinitely without ever treating them as a confirmed rejection.
    if (Array.isArray(doc.tombstones)) {
      if (new Set(doc.tombstones).size !== doc.tombstones.length ||
          doc.tombstones.some((hash) => typeof hash !== 'string' || !/^[a-f0-9]{64}$/.test(hash))) throw unavailable();
      doc.tombstones = Object.fromEntries(doc.tombstones.map((hash) => [hash, { compactedAt: now(), status: 'unknown' }]));
    }
    if (!doc.tombstones || typeof doc.tombstones !== 'object') throw unavailable();
    for (const [hash, value] of Object.entries(doc.tombstones)) {
      if (!/^[a-f0-9]{64}$/.test(hash)) throw unavailable();
      const record = typeof value === 'number' ? { compactedAt: value, status: 'unknown' } : value;
      if (!record || typeof record !== 'object' || Array.isArray(record) ||
          !Number.isSafeInteger(record.compactedAt) || record.compactedAt < 0 ||
          !['succeeded', 'rejected', 'unknown'].includes(record.status) ||
          (record.status === 'unknown' ? record.ownerHash !== undefined : !/^[a-f0-9]{64}$/.test(record.ownerHash ?? ''))) throw unavailable();
      doc.tombstones[hash] = record;
    }
    return doc.entries;
  }
  function compact(all, tombstones) {
    const timestamp = now();
    for (const [hash, entry] of Object.entries(all)) {
      if (['succeeded', 'rejected'].includes(entry.status) && Number.isFinite(entry.updatedAt)
          && timestamp - entry.updatedAt >= RECENT_MS) {
        if (!Object.hasOwn(tombstones, hash)) tombstones[hash] = {
          compactedAt: timestamp, status: entry.status, ownerHash: ownerHash(entry.deviceId, entry.viewerId),
        };
        delete all[hash];
      }
    }
  }
  function ready({ create = false } = {}) {
    try {
      const initialized = store.read().taskOperationsInitialized === true;
      if (initialized && !existsSync(file)) throw unavailable();
      if (initialized) { checked(data.read()); return true; }
      if (!create && !existsSync(file)) return false;
      if (!create) throw unavailable();
      // Create the empty file before setting the durable marker. No mutation is
      // sent until both exist; a crash during initialization fails closed.
      data.mutate((doc) => {
        if (Object.keys(checked(doc)).length && !store.read().taskOperationsInitialized) throw unavailable();
      });
      store.mutate((state) => { state.taskOperationsInitialized = true; });
      syncDirectory();
      return true;
    } catch (error) {
      if (error instanceof BridgeError) throw error;
      throw unavailable();
    }
  }
  function edit(fn) {
    ready({ create: true });
    try {
      const result = data.mutate((doc) => {
        if (!existsSync(file) || store.read().taskOperationsInitialized !== true) throw unavailable();
        return fn(checked(doc), doc.tombstones);
      });
      // The file helper fsyncs its temporary file before rename. Persist the
      // directory entry too before any Linear mutation is sent.
      syncDirectory();
      return result;
    } catch (error) {
      if (error instanceof BridgeError) throw error;
      throw unavailable();
    }
  }
  function snapshot() {
    if (!ready()) return { entries: {}, tombstones: {} };
    try {
      if (!existsSync(file)) throw unavailable();
      const doc = data.read(); checked(doc);
      return doc;
    } catch (error) {
      if (error instanceof BridgeError) throw error;
      throw unavailable();
    }
  }
  function entries() { return snapshot().entries; }
  function visible(entry) {
    const age = Math.max(0, now() - entry.createdAt);
    const status = entry.status === 'in_progress' && age >= INFLIGHT_MS && !processStillExists(entry.processId)
      ? 'outcome_unknown' : entry.status;
    return {
      operationId: entry.operationId, kind: entry.kind, targetId: entry.targetId,
      ...(entry.contextId ? { contextId: entry.contextId } : {}),
      status, createdAt: new Date(entry.createdAt).toISOString(), updatedAt: new Date(entry.updatedAt).toISOString(),
      ...(entry.resultId ? { resultId: entry.resultId, identifier: entry.identifier } : {}),
      ...(entry.status === 'rejected' ? { rejection: entry.rejection ?? 'preflight_failed' } : {}),
      ...(entry.resolution ? { resolution: entry.resolution } : {}),
      ...(entry.status === 'succeeded' && age >= RECENT_MS ? { replayExpired: true } : {}),
    };
  }
  function owned(entry, deviceId, viewerId) {
    return entry && entry.deviceId === deviceId && entry.viewerId === viewerId;
  }
  return {
    file,
    reserve({ deviceId, viewerId, key, method, path, ifMatch, rawBody, kind, targetId, contextId }) {
      const hash = keyHash(deviceId, key);
      const fingerprint = operationFingerprint({ method, path, viewerId, ifMatch, rawBody });
      return edit((all, tombstones) => {
        compact(all, tombstones);
        if (Object.hasOwn(tombstones, hash)) return { action: 'expired' };
        const previous = all[hash];
        if (!previous && Object.values(all).some((entry) => entry.resolutionKeyHash === hash)) return { action: 'conflict' };
        if (previous) {
          if (previous.viewerId !== viewerId || previous.fingerprint !== fingerprint) return { action: 'conflict' };
          const value = visible(previous);
          if (previous.status === 'succeeded' && value.replayExpired) return { action: 'expired', entry: value };
          if (previous.status === 'preflight_retryable') {
            if (now() - previous.createdAt >= RECENT_MS) {
              previous.status = 'rejected';
              previous.rejection = 'preflight_retry_expired';
              previous.updatedAt = now();
              return { action: 'existing', entry: visible(previous), rejection: previous.rejection };
            }
            previous.status = 'in_progress';
            previous.processId = process.pid;
            previous.updatedAt = now();
            return { action: 'execute', entry: visible(previous) };
          }
          return { action: 'existing', entry: value, rejection: previous.rejection ?? null };
        }
        if (Object.keys(all).length >= MAX_RECORDS) throw new BridgeError(503, 'task_ledger_full', 'the task operation ledger needs operator maintenance');
        const timestamp = now();
        const entry = {
          operationId: randomUUID(), deviceId, viewerId, fingerprint, kind, targetId, ...(contextId ? { contextId } : {}),
          status: 'in_progress', processId: process.pid, createdAt: timestamp, updatedAt: timestamp,
        };
        all[hash] = entry;
        return { action: 'execute', entry: visible(entry) };
      });
    },
    finish({ deviceId, viewerId, key, status, result, rejection, cleanupAssetHash }) {
      return edit((all) => {
        const entry = all[keyHash(deviceId, key)];
        if (!owned(entry, deviceId, viewerId) || entry.status !== 'in_progress') throw unavailable();
        if (!['succeeded', 'rejected', 'outcome_unknown', 'preflight_retryable'].includes(status)) throw unavailable();
        entry.status = status;
        entry.updatedAt = now();
        if (status === 'succeeded') { entry.resultId = result.id; entry.identifier = result.identifier; }
        if (status === 'rejected') {
          entry.rejection = rejection;
          if (cleanupAssetHash !== undefined) {
            if (typeof cleanupAssetHash !== 'string' || !/^[a-f0-9]{64}$/.test(cleanupAssetHash)) throw unavailable();
            entry.cleanupAssetHash = cleanupAssetHash;
          }
        }
        return visible(entry);
      });
    },
    byKey({ deviceId, viewerId, key }) {
      const { entries: all, tombstones } = snapshot();
      const hash = keyHash(deviceId, key);
      if (Object.hasOwn(tombstones, hash)) throw compacted(tombstones[hash], deviceId, viewerId);
      let entry = all[hash] ?? Object.values(all).find((item) => item.resolutionKeyHash === hash);
      // Atomically close an expired no-write preflight before advertising it
      // as rejected. A concurrent retry can never be mistaken for a no-op.
      if (owned(entry, deviceId, viewerId) && entry.status === 'preflight_retryable' && now() - entry.createdAt >= RECENT_MS) {
        return edit((current) => {
          const latest = current[hash];
          if (!owned(latest, deviceId, viewerId)) return null;
          if (latest.status === 'preflight_retryable' && now() - latest.createdAt >= RECENT_MS) {
            latest.status = 'rejected'; latest.rejection = 'preflight_retry_expired'; latest.updatedAt = now();
          }
          return visible(latest);
        });
      }
      return owned(entry, deviceId, viewerId) ? visible(entry) : null;
    },
    abandonUnsent({ deviceId, viewerId, key }) {
      const hash = keyHash(deviceId, key);
      const result = edit((all, tombstones) => {
        compact(all, tombstones);
        if (Object.hasOwn(tombstones, hash)) return { compacted: tombstones[hash] };
        const previous = all[hash];
        if (previous) {
          if (!owned(previous, deviceId, viewerId)) throw new BridgeError(409, 'idempotency_key_conflict', 'the key belongs to another viewer');
          // A retry can only start by changing this state under the same lock.
          if (previous.status === 'preflight_retryable') {
            previous.status = 'rejected'; previous.rejection = 'preflight_abandoned'; previous.updatedAt = now();
          }
          return { entry: visible(previous) };
        }
        if (Object.values(all).some((entry) => entry.resolutionKeyHash === hash)) {
          throw new BridgeError(409, 'idempotency_key_conflict', 'the key belongs to a reconciliation');
        }
        if (Object.keys(all).length >= MAX_RECORDS) throw new BridgeError(503, 'task_ledger_full', 'the task operation ledger needs operator maintenance');
        // No request reached reservation. A tombstone prevents a delayed
        // request with this key from starting after the draft is restored.
        const timestamp = now();
        const entry = { operationId: randomUUID(), deviceId, viewerId, fingerprint: null,
          kind: 'abandoned', targetId: 'not_sent', status: 'rejected', rejection: 'abandoned_before_reservation',
          createdAt: timestamp, updatedAt: timestamp };
        all[hash] = entry;
        return { entry: visible(entry) };
      });
      if (result.compacted) throw compacted(result.compacted, deviceId, viewerId);
      return result.entry;
    },
    get({ deviceId, viewerId, operationId }) {
      const entry = Object.values(entries()).find((item) => item.operationId === operationId && owned(item, deviceId, viewerId));
      return entry ? visible(entry) : null;
    },
    list({ deviceId, viewerId }) {
      return Object.values(entries()).filter((entry) => owned(entry, deviceId, viewerId))
        .map(visible).filter((entry) => entry.status === 'in_progress' || entry.status === 'outcome_unknown')
        .sort((a, b) => b.createdAt.localeCompare(a.createdAt));
    },
    resolve({ deviceId, viewerId, operationId, resolution, key, fingerprint }) {
      return edit((all, tombstones) => {
        const hash = keyHash(deviceId, key);
        if (all[hash] || Object.hasOwn(tombstones, hash)) {
          throw new BridgeError(409, 'idempotency_key_conflict', 'the key belongs to a different request');
        }
        const prior = Object.values(all).find((item) => item.resolutionKeyHash === hash);
        if (prior && (prior.operationId !== operationId || prior.viewerId !== viewerId || prior.resolutionFingerprint !== fingerprint)) {
          throw new BridgeError(409, 'idempotency_key_conflict', 'the key belongs to a different request');
        }
        const entry = Object.values(all).find((item) => item.operationId === operationId && owned(item, deviceId, viewerId));
        if (!entry) throw new BridgeError(404, 'operation_not_found', 'the task operation was not found');
        if (entry.status === 'resolved') {
          if (entry.resolution !== resolution) throw new BridgeError(409, 'operation_resolution_conflict', 'the operation was resolved differently');
          if (!prior) throw new BridgeError(409, 'operation_already_resolved', 'the operation has already been resolved');
        } else {
          if (visible(entry).status !== 'outcome_unknown') throw new BridgeError(409, 'operation_not_unresolved', 'only an unresolved operation can be confirmed');
          entry.status = 'resolved';
          entry.resolution = resolution;
          entry.resolutionKeyHash = hash;
          entry.resolutionFingerprint = fingerprint;
          entry.updatedAt = now();
        }
        return visible(entry);
      });
    },
  };
}

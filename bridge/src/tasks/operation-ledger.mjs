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
  const data = createJsonFile({ file, initial: () => ({ entries: {} }) });
  const unavailable = () => new BridgeError(503, 'task_ledger_unavailable', 'the task operation ledger requires operator recovery');
  function syncDirectory() {
    const fd = openSync(store.dir, 'r');
    try { fsyncSync(fd); } finally { closeSync(fd); }
  }

  function checked(doc) {
    if (!doc.entries || typeof doc.entries !== 'object' || Array.isArray(doc.entries)) throw unavailable();
    return doc.entries;
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
        return fn(checked(doc));
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
  function entries() {
    if (!ready()) return {};
    try {
      if (!existsSync(file)) throw unavailable();
      return checked(data.read());
    } catch (error) {
      if (error instanceof BridgeError) throw error;
      throw unavailable();
    }
  }
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
      return edit((all) => {
        const previous = all[hash];
        if (!previous && Object.values(all).some((entry) => entry.resolutionKeyHash === hash)) return { action: 'conflict' };
        if (previous) {
          if (previous.viewerId !== viewerId || previous.fingerprint !== fingerprint) return { action: 'conflict' };
          const value = visible(previous);
          if (previous.status === 'succeeded' && value.replayExpired) return { action: 'expired', entry: value };
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
    finish({ deviceId, viewerId, key, status, result, rejection }) {
      return edit((all) => {
        const entry = all[keyHash(deviceId, key)];
        if (!owned(entry, deviceId, viewerId) || entry.status !== 'in_progress') throw unavailable();
        if (!['succeeded', 'rejected', 'outcome_unknown'].includes(status)) throw unavailable();
        entry.status = status;
        entry.updatedAt = now();
        if (status === 'succeeded') { entry.resultId = result.id; entry.identifier = result.identifier; }
        if (status === 'rejected') entry.rejection = rejection;
        return visible(entry);
      });
    },
    byKey({ deviceId, viewerId, key }) {
      const all = entries();
      const hash = keyHash(deviceId, key);
      const entry = all[hash] ?? Object.values(all).find((item) => item.resolutionKeyHash === hash);
      return owned(entry, deviceId, viewerId) ? visible(entry) : null;
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
      return edit((all) => {
        const hash = keyHash(deviceId, key);
        if (all[hash]) {
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

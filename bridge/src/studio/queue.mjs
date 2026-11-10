import { isDeepStrictEqual } from 'node:util';
import { BridgeError } from '../errors.mjs';

const DAY_MS = 24 * 60 * 60 * 1000;
const KEEP_TERMINAL_MS = 7 * DAY_MS;
const RETRYABLE = new Set(['studio_not_connected', 'studio_not_accepting']);

export function createStudioQueue({ store, backend, now, intervalMs, registerCleanup }) {
  let dispatching = null;

  const key = (id) => id.toLowerCase();
  const record = (entry) => ({
    request: entry.request, status: entry.status, bootId: null,
    updatedAt: new Date(entry.updatedAt).toISOString(), report: null,
  });
  const entryFor = (id) => store.read().studioQueue[key(id)];
  const all = (deviceId) => Object.values(store.read().studioQueue)
    .filter((entry) => entry.deviceId === deviceId)
    .sort((a, b) => b.createdAt - a.createdAt)
    .slice(0, 60)
    .map(record);
  const get = (id, deviceId) => {
    const entry = entryFor(id);
    return entry?.deviceId === deviceId ? record(entry) : undefined;
  };

  function replay(request, deviceId, entry = entryFor(request.id)) {
    if (!entry) return undefined;
    if (entry.deviceId !== deviceId || !isDeepStrictEqual(entry.request, request)) {
      throw new BridgeError(409, 'studio_request_id_conflict', 'The request ID belongs to different content');
    }
    return record(entry);
  }

  function enqueue(request, deviceId) {
    return store.mutate((state) => {
      const existing = replay(request, deviceId, state.studioQueue[key(request.id)] ?? null);
      if (existing) return existing;
      if (Object.values(state.studioQueue).filter((entry) => entry.status === 'bridge_waiting').length >= 60) {
        throw new BridgeError(429, 'studio_queue_full', 'The Studio queue is full', { retryable: true });
      }
      const t = now();
      const entry = { request, deviceId, createdAt: t, updatedAt: t, status: 'bridge_waiting' };
      state.studioQueue[key(request.id)] = entry;
      return record(entry);
    });
  }

  function stop(id, deviceId) {
    if (!get(id, deviceId)) return undefined;
    return store.mutate((state) => {
      const entry = state.studioQueue[key(id)];
      if (entry?.deviceId !== deviceId) return undefined;
      if (dispatching === key(id) || (entry.status === 'bridge_waiting' && entry.deliveryUncertain)) {
        throw new BridgeError(409, 'studio_queue_dispatching', 'The request is being handed to Studio', { retryable: true });
      }
      if (entry.status === 'bridge_waiting') {
        entry.status = 'stopped';
        entry.updatedAt = now();
      }
      return record(entry);
    });
  }

  async function tick() {
    if (dispatching !== null) return;
    const entries = Object.entries(store.read().studioQueue);
    const t = now();
    const expired = entries.filter(([, entry]) => entry.status === 'bridge_waiting' && t - entry.createdAt >= DAY_MS);
    const old = entries.filter(([, entry]) => entry.status !== 'bridge_waiting' && t - entry.updatedAt >= KEEP_TERMINAL_MS);
    if (expired.length || old.length) {
      store.mutate((state) => {
        for (const [id] of expired) {
          const entry = state.studioQueue[id];
          if (entry?.status === 'bridge_waiting') { entry.status = 'expired'; entry.updatedAt = t; }
        }
        for (const [id] of old) delete state.studioQueue[id];
      });
    }
    const next = entries.filter(([, entry]) => entry.status === 'bridge_waiting' && t - entry.createdAt < DAY_MS)
      .sort(([, a], [, b]) => a.createdAt - b.createdAt)[0];
    if (!next) return;
    const [id, { request }] = next;
    dispatching = id;
    try {
      // Studio serializes creation by UUID and rejects changes to its body.
      // A lost reply or Bridge restart therefore cannot run the work twice.
      store.mutate((state) => { state.studioQueue[id].deliveryUncertain = true; });
      await backend.createRequest(request);
      store.mutate((state) => { delete state.studioQueue[id]; });
    } catch (error) {
      if (!(error instanceof BridgeError)) return;
      if (error.code === 'studio_work_busy') {
        store.mutate((state) => { delete state.studioQueue[id].deliveryUncertain; });
        return;
      }
      if (RETRYABLE.has(error.code) || error.status >= 500) return;
      store.mutate((state) => {
        const entry = state.studioQueue[id];
        if (entry?.status === 'bridge_waiting') { entry.status = 'failed'; entry.updatedAt = now(); }
      });
    } finally {
      dispatching = null;
    }
  }

  const run = () => tick().catch(() => {});
  const timer = setInterval(run, intervalMs);
  timer.unref();
  registerCleanup?.(() => clearInterval(timer));
  run();
  return { all, get, replay, enqueue, stop };
}

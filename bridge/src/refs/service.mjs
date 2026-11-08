// Reconcile loop and decoration helpers.
//
// The service never lets the registry break a list response: decoration falls
// back to `ref: null` and a registry write failure is logged without titles,
// bodies or paths. Reconcile runs only in the live server; read-only callers
// (CLI, tests) observe explicitly.

import { KINDS, createRefRegistry } from './registry.mjs';

const LOCAL_KINDS = Object.freeze(['session', 'project', 'skill', 'decision']);
const LOCAL_INTERVAL_MS = 60_000;
const TASK_INTERVAL_MS = 300_000;

export function createRefService({
  file,
  now = () => Date.now(),
  live = false,
  log = null,
  localIntervalMs = LOCAL_INTERVAL_MS,
  taskIntervalMs = TASK_INTERVAL_MS,
} = {}) {
  const registry = createRefRegistry({ file, now });
  const sources = new Map();
  const timers = [];
  let started = false;
  let lastReport = null;

  function report(error) {
    // One line per distinct failure kind: a corrupt registry would otherwise
    // log on every decorated row.
    const key = `${error?.name ?? 'Error'}:${error?.code ?? ''}`;
    if (key === lastReport) return;
    lastReport = key;
    try {
      log?.({ level: 'error', event: 'refs_error', error: error?.name ?? 'Error', code: error?.code ?? null });
    } catch {
      // A logger must never break a response.
    }
  }

  function observe(kind, items) {
    try {
      const result = registry.observeComplete(kind, items);
      lastReport = null;
      return result;
    } catch (error) {
      report(error);
      return null;
    }
  }

  function refFor(kind, key) {
    try {
      return registry.refFor(kind, key);
    } catch (error) {
      report(error);
      return null;
    }
  }

  async function observeSource(kind) {
    const read = sources.get(kind);
    if (!read) return null;
    try {
      const items = await read();
      // `null` means "the source has no complete value right now" (a cold
      // routines cache); it is not an empty list and releases nothing.
      if (items === null || items === undefined) return null;
      return observe(kind, items);
    } catch (error) {
      report(error);
      return null;
    }
  }

  function decorate(kind, item, key) {
    return { ...item, ref: refFor(kind, key) };
  }

  function decorateAll(kind, items, keyOf) {
    return items.map((item) => decorate(kind, item, keyOf(item)));
  }

  return {
    registry,
    file,
    registerSource(kind, read) {
      if (!KINDS.includes(kind)) throw new TypeError(`unknown ref kind: ${kind}`);
      sources.set(kind, read);
    },
    observe,
    observeSource,
    decorate,
    decorateAll,
    assign(kind, key, title, external = {}) {
      if (typeof key !== 'string' || key === '') return null;
      try {
        const record = registry.assign({ kind, key, title, external });
        return record.ref;
      } catch (error) {
        report(error);
        return null;
      }
    },
    release(kind, key) {
      try {
        registry.release(kind, key);
      } catch (error) {
        report(error);
      }
    },
    refFor,
    resolve(input) {
      return registry.resolve(input);
    },
    list(kinds = KINDS) {
      return registry.held(kinds);
    },
    observedAt(kinds = KINDS) {
      return registry.observedAt(kinds);
    },
    start() {
      if (started) return;
      started = true;
      // Live mode only: the reconcile is part of the server, and tests must not
      // read the developer's real skill folders just by opening a Bridge.
      if (!live) return;
      for (const kind of LOCAL_KINDS) void observeSource(kind);
      const local = setInterval(() => {
        for (const kind of [...LOCAL_KINDS, 'routine']) void observeSource(kind);
      }, localIntervalMs);
      local.unref?.();
      timers.push(local);
      const tasks = setInterval(() => { void observeSource('task'); }, taskIntervalMs);
      tasks.unref?.();
      timers.push(tasks);
    },
    stop() {
      for (const timer of timers.splice(0)) clearInterval(timer);
      started = false;
    },
  };
}

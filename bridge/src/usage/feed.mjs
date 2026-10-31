// Background collection keeps requests nonblocking. A failed latest read clears
// the cache; a previous process's snapshot is never treated as a fresh read.

import { readUsageFeed } from './proxy.mjs';

export function createUsageFeedSource({
  url,
  fetcher,
  refreshTimeoutMs = 30000,
  refreshIntervalMs = 120000,
  now = () => Date.now(),
} = {}) {
  // A persisted last-good sample cannot establish whether the last attempt
  // failed before a restart. Start empty and only trust this process's reads.
  let cached = null;
  let receivedAt = null;
  const observationAnchors = new Map();
  let inflight = null;
  let closed = false;
  const controller = new AbortController();

  function startRefresh() {
    if (inflight !== null) return inflight;
    if (closed) return Promise.resolve(null);
    const run = readUsageFeed({ url, fetcher, timeoutMs: refreshTimeoutMs, signal: controller.signal })
      .then((feed) => {
        if (closed) return null;
        cached = feed;
        receivedAt = now();
        for (const [id, anchor] of observationAnchors) {
          if (receivedAt - anchor.receivedAt >= 720_000) observationAnchors.delete(id);
        }
        for (const row of Array.isArray(feed.providers) ? feed.providers : []) {
          if (!row || typeof row.id !== 'string' || typeof row.updatedAt !== 'string') continue;
          const observedAt = Date.parse(row.updatedAt);
          if (!Number.isFinite(observedAt)) continue;
          const prior = observationAnchors.get(row.id);
          if (!prior || prior.observedAt !== observedAt) {
            observationAnchors.set(row.id, { observedAt, receivedAt });
          }
        }
        return feed;
      })
      .catch(() => {
        if (closed) return null;
        // A failed latest attempt invalidates the old value immediately.
        cached = null;
        receivedAt = null;
        return null;
      })
      .finally(() => { if (inflight === run) inflight = null; });
    inflight = run;
    return run;
  }

  // Scheduled collection never holds up an app request.
  startRefresh();
  const timer = setInterval(startRefresh, refreshIntervalMs);
  timer.unref?.();
  return {
    read: async () => ({ feed: cached, receivedAt, observationAnchors: new Map(observationAnchors) }),
    refresh: startRefresh,
    close: () => { closed = true; controller.abort(); clearInterval(timer); },
    snapshot: () => cached,
    get inflight() { return inflight !== null; },
  };
}

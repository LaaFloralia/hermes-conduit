// Background collection keeps requests nonblocking. A failed latest read clears
// the cache; a previous process's snapshot is never treated as a fresh read.

import {
  closeSync,
  fsyncSync,
  mkdirSync,
  openSync,
  renameSync,
  unlinkSync,
  writeSync,
} from 'node:fs';
import { dirname } from 'node:path';
import { readUsageFeed } from './proxy.mjs';

export const USAGE_SNAPSHOT_SCHEMA = 1;
const MAX_SNAPSHOT_BYTES = 512 * 1024;

// Exported for tests: the on-disk format in one place.
export function writeUsageSnapshot(file, feed, { now = () => Date.now() } = {}) {
  const body = `${JSON.stringify({ schema: USAGE_SNAPSHOT_SCHEMA, capturedAt: new Date(now()).toISOString(), feed }, null, 2)}\n`;
  if (Buffer.byteLength(body, 'utf8') > MAX_SNAPSHOT_BYTES) return false;
  mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
  const tmp = `${file}.${process.pid}.${Math.random().toString(16).slice(2)}.tmp`;
  const fd = openSync(tmp, 'wx', 0o600);
  try {
    writeSync(fd, body, 0, 'utf8');
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
  renameSync(tmp, file);
  return true;
}

export function createUsageFeedSource({
  file,
  url,
  fetcher,
  refreshTimeoutMs = 30000,
  refreshIntervalMs = 120000,
  now = () => Date.now(),
} = {}) {
  // A persisted last-good sample cannot establish whether the last attempt
  // failed before a restart. Start empty and only trust this process's reads.
  let cached = null;
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
        if (file !== undefined) {
          try { writeUsageSnapshot(file, feed, { now }); } catch { /* memory remains usable */ }
        }
        return feed;
      })
      .catch(() => {
        if (closed) return null;
        // A failed latest attempt invalidates the old value immediately.
        cached = null;
        if (file !== undefined) {
          try { unlinkSync(file); } catch { /* absent or unwritable */ }
        }
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
    file,
    read: async () => ({ feed: cached, lastGood: false }),
    refresh: startRefresh,
    close: () => { closed = true; controller.abort(); clearInterval(timer); },
    snapshot: () => cached,
    get inflight() { return inflight !== null; },
  };
}

// Last-good usage feed: a bounded read, one in-flight refresh, a snapshot on disk.
//
// The proxy answers from its own 20 s upstream budget, so under Mac load a
// `/widget` read can take 19–25 s. Waiting that long is not an option for the
// app (the Bridge caps the request at 5 s), and neither is showing 「未取得」
// while a usable reading exists. The rules here are therefore:
//
//   * one request owns the wait: it waits at most `timeoutMs` for a fresh read;
//   * the read itself keeps running in the background (bounded by
//     `refreshTimeoutMs`, 30 s) so the next request gets the fresh value;
//   * at most one refresh is in flight — a second request never starts another
//     and never queues behind a slow one when a snapshot exists;
//   * when the wait ends without a fresh read, the last successful payload is
//     returned unchanged, so its own `fetchedAt`/`updatedAt` still decide
//     `observedAt`, `stale` and `expired`. Old data is never relabelled fresh;
//   * with no snapshot the caller falls back to `unavailable`, as before.
//
// The snapshot file holds the proxy's display payload only (the same JSON the
// loopback endpoint serves: code-owned quotas, balances and credits, no
// credential of any kind). It is read once at startup, replaced atomically and
// re-validated on load; a corrupt or foreign file is ignored, never repaired
// into an invented reading.

import {
  closeSync,
  fsyncSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  statSync,
  writeSync,
} from 'node:fs';
import { dirname } from 'node:path';
import { USAGE_FEED_VERSION, readUsageFeed } from './proxy.mjs';

export const USAGE_SNAPSHOT_SCHEMA = 1;
const MAX_SNAPSHOT_BYTES = 512 * 1024;

function validSnapshot(doc) {
  if (!doc || typeof doc !== 'object' || Array.isArray(doc)) return null;
  if (doc.schema !== USAGE_SNAPSHOT_SCHEMA) return null;
  const feed = doc.feed;
  if (!feed || typeof feed !== 'object' || Array.isArray(feed)) return null;
  if (feed.version !== USAGE_FEED_VERSION) return null;
  if (typeof feed.fetchedAt !== 'string' || !Array.isArray(feed.providers)) return null;
  return feed;
}

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

function loadUsageSnapshot(file) {
  let raw;
  try {
    if (statSync(file).size > MAX_SNAPSHOT_BYTES) return null;
    raw = readFileSync(file, 'utf8');
  } catch {
    return null;
  }
  try {
    return validSnapshot(JSON.parse(raw));
  } catch {
    return null;
  }
}

function withDeadline(promise, ms) {
  let timer;
  const deadline = new Promise((resolve) => {
    timer = setTimeout(() => resolve(null), ms);
    // A pending refresh must not keep the process (or a test run) alive.
    timer.unref?.();
  });
  return Promise.race([promise, deadline]).finally(() => clearTimeout(timer));
}

export function createUsageFeedSource({
  file,
  url,
  fetcher,
  timeoutMs = 5000,
  refreshTimeoutMs = 30000,
  now = () => Date.now(),
} = {}) {
  let cached = file === undefined ? null : loadUsageSnapshot(file);
  let inflight = null;

  function remember(feed) {
    cached = feed;
    if (file === undefined) return;
    try {
      writeUsageSnapshot(file, feed, { now });
    } catch {
      // A snapshot that cannot be written costs a restart reload, not the
      // reading this request already has.
    }
  }

  function startRefresh() {
    const run = readUsageFeed({ url, fetcher, timeoutMs: refreshTimeoutMs })
      .then((feed) => {
        remember(feed);
        return feed;
      })
      .catch(() => null)
      .finally(() => {
        if (inflight === run) inflight = null;
      });
    inflight = run;
    return run;
  }

  // `lastGood` is only a diagnostic: the items are built from the payload's own
  // timestamps either way.
  async function read() {
    // A slow refresh is already running and a snapshot can answer now: do not
    // make this request pay the timeout again.
    if (inflight !== null && cached !== null) return { feed: cached, lastGood: true };
    const refresh = inflight ?? startRefresh();
    const fresh = await withDeadline(refresh, timeoutMs);
    if (fresh !== null) return { feed: fresh, lastGood: false };
    return cached === null ? { feed: null, lastGood: false } : { feed: cached, lastGood: true };
  }

  return {
    file,
    read,
    snapshot: () => cached,
    get inflight() {
      return inflight !== null;
    },
  };
}

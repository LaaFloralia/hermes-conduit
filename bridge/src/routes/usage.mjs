// /v1/usage and /v1/mac/status (ROADMAP task 09, docs/laa/USAGE.md).
//
// Both endpoints are read-only and need `usage:read` (BRIDGE §3, §9). They
// return the item shape from USAGE.md §4 with `{items, nextCursor}`; the list is
// a fixed small set, so the cursor is always null.
//
// A source being down is not a Bridge failure: the proxy unreachable, the feed
// malformed or the storage-guard file absent all produce 200 with `unavailable`
// items. That keeps the app's "no data" state separate from "Bridge is broken",
// and no missing reading is ever reported as 0.
//
// The feed is refreshed in the background; requests never wait for upstream.
// Measured on the production Bridge (2026-11-02): p50 9 ms, and the 1-5 s tail
// coincides with heavy child processes on the Mac (routines, Linear owner tasks,
// Studio), not with the proxy read, which this handler never waits for. `fetchedAt`
// reports when the served snapshot was received, not when it was asked for.

import {
  resolveStorageStatusFile,
  resolveUsageAutoStaleMs,
  resolveUsageFeedUrl,
  resolveUsageRefreshTimeoutMs,
} from '../config.mjs';
import { createUsageFeedSource } from '../usage/feed.mjs';
import { createCapacitySource } from '../usage/capacity.mjs';
import { createRoutineUsage, isRoutineUsage } from '../usage/routine.mjs';
import {
  createHostSampler,
  readDiskStatus,
  unavailableCpu,
  unavailableMemory,
} from '../usage/host.mjs';
import { unavailableUsageItems, usageItemsFromFeed } from '../usage/proxy.mjs';

export function usageRoutes({
  feedUrl,
  fetcher,
  refreshTimeoutMs,
  autoStaleMs,
  sampler,
  capacitySource,
  collectMacBook = capacitySource != null,
  storageStatusFile,
  routineFile,
  registerCleanup,
  now = () => Date.now(),
} = {}) {
  const url = feedUrl ?? resolveUsageFeedUrl();
  const staleMs = autoStaleMs ?? resolveUsageAutoStaleMs();
  const host = sampler ?? createHostSampler({ now });
  const statusFile = storageStatusFile ?? resolveStorageStatusFile();
  const feedSource = createUsageFeedSource({
    url,
    fetcher,
    refreshTimeoutMs: refreshTimeoutMs ?? resolveUsageRefreshTimeoutMs(),
    now,
  });
  registerCleanup?.(feedSource.close);
  const capacity = capacitySource ?? createCapacitySource({ host, now });
  registerCleanup?.(capacity.close);

  async function projection() {
    let items;
    const { feed, receivedAt, observationAnchors } = await feedSource.read();
    if (feed === null) {
      // The reason the feed was unusable stays internal: the app only needs to
      // know that these readings are not available.
      items = unavailableUsageItems('fetch_failed');
    } else {
      try {
        items = usageItemsFromFeed(feed, { now: now(), receivedAt, observationAnchors, autoStaleMs: staleMs });
      } catch {
        // A malformed or future-dated payload is discarded whole (USAGE.md §4),
        // including a snapshot that only passed the lighter reload check.
        items = unavailableUsageItems('fetch_failed');
      }
    }
    return { items, receivedAt };
  }

  const routine = createRoutineUsage({ file: routineFile, now, async collect(publish) {
    // This GET reads the existing local proxy cache, never a paid provider or
    // billing page. The in-flight startup/periodic fetch is shared if present.
    const balances = feedSource.refresh().then(async () => publish((await projection()).items));
    const macbook = collectMacBook && capacity.refreshMacBook
      ? capacity.refreshMacBook().then(() => publish(capacity.read({ sample: false }))) : null;
    await Promise.allSettled([balances, macbook]);
  } });
  registerCleanup?.(routine.close);

  async function usage({ req } = {}) {
    const force = req && new URL(req.url, 'http://localhost').searchParams.get('refresh') === '1';
    // Local measurements can sample immediately; the proxy keeps its
    // existing cadence, so user input cannot trigger a provider call.
    if (force) await capacity.refreshInstant?.();
    const { items, receivedAt } = await projection();
    const scheduled = new Map(routine.read().map(item => [item.id, item]));
    const placeholders = new Map(unavailableUsageItems('fetch_failed').map(item => [item.id, item]));
    const rows = items.map(item => isRoutineUsage(item) ? scheduled.get(item.id) ?? placeholders.get(item.id) : item);
    rows.push(...capacity.read().map(item => isRoutineUsage(item) && capacity.refreshMacBook
      ? scheduled.get(item.id) ?? item : item));
    return { status: 200, data: { items: rows, nextCursor: null, fetchedAt: receivedAt === null ? null : new Date(receivedAt).toISOString() } };
  }

  async function macStatus() {
    let cpu;
    let memory;
    try {
      ({ cpu, memory } = await host.read());
    } catch {
      cpu = unavailableCpu();
      memory = unavailableMemory();
    }
    const disk = await readDiskStatus({ file: statusFile, now });
    return { status: 200, data: { items: [cpu, memory, disk], nextCursor: null } };
  }

  return [
    { method: 'GET', path: '/v1/usage', auth: true, scope: 'usage:read', handler: usage },
    { method: 'GET', path: '/v1/mac/status', auth: true, scope: 'usage:read', handler: macStatus },
  ];
}

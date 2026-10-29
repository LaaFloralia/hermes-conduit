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

import {
  resolveStorageStatusFile,
  resolveUsageAutoStaleMs,
  resolveUsageFeedTimeoutMs,
  resolveUsageFeedUrl,
} from '../config.mjs';
import {
  createHostSampler,
  readDiskStatus,
  unavailableCpu,
  unavailableMemory,
} from '../usage/host.mjs';
import { readUsageFeed, unavailableUsageItems, usageItemsFromFeed } from '../usage/proxy.mjs';

export function usageRoutes({
  feedUrl,
  fetcher,
  feedTimeoutMs,
  autoStaleMs,
  sampler,
  storageStatusFile,
  now = () => Date.now(),
} = {}) {
  const url = feedUrl ?? resolveUsageFeedUrl();
  const timeoutMs = feedTimeoutMs ?? resolveUsageFeedTimeoutMs();
  const staleMs = autoStaleMs ?? resolveUsageAutoStaleMs();
  const host = sampler ?? createHostSampler({ now });
  const statusFile = storageStatusFile ?? resolveStorageStatusFile();

  async function usage() {
    let items;
    try {
      const feed = await readUsageFeed({ url, fetcher, timeoutMs });
      items = usageItemsFromFeed(feed, { now: now(), autoStaleMs: staleMs });
    } catch {
      // The reason the feed was unusable stays internal: the app only needs to
      // know that these readings are not available.
      items = unavailableUsageItems('fetch_failed');
    }
    return { status: 200, data: { items, nextCursor: null } };
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

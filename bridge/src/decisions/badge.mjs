import { randomUUID } from 'node:crypto';
import { watch } from 'node:fs';
import { basename, dirname } from 'node:path';
import { deliverWithPlugin } from '../notify/index.mjs';

export const ownerBadgeCount = (records) => records.filter((r) => r.category === 'owner' && r.status === 'open').length;

// Only the live Bridge sends. The CLI and task completion write the same
// atomic file; a directory watch sees their renames, with polling to recover
// missed events and close expired decisions without an app on screen.
export function createDecisionBadgePublisher({ store, deliver = deliverWithPlugin, now = Date.now }) {
  let sent, pending, inFlight, retryAt = 0;
  async function drain() {
    while (true) {
      const count = ownerBadgeCount(store.expireAndReadOpen());
      if (count === sent && !pending) return;
      if (pending?.badge !== count) {
        pending = { type: 'decision.badge', event_id: `laa-decision-badge:${randomUUID()}`, badge: count };
        retryAt = 0;
      }
      if (now() < retryAt) return;
      try {
        if (!(await deliver(pending))?.delivered) throw new Error('badge not delivered');
      } catch {
        retryAt = now() + 30_000;
        return;
      }
      sent = pending.badge;
      pending = undefined;
    }
  }
  function refresh() {
    return inFlight ??= drain().catch(() => {}).finally(() => { inFlight = undefined; });
  }
  function start() {
    let watcher;
    try {
      watcher = watch(dirname(store.file), { persistent: false }, (_, name) => {
        if (!name || name === basename(store.file)) void refresh();
      });
      watcher.on('error', () => watcher.close());
    } catch { /* Polling also works when the directory is not ready. */ }
    const timer = setInterval(refresh, 1000);
    timer.unref();
    void refresh();
    return () => { clearInterval(timer); watcher?.close(); };
  }
  return { refresh, start };
}

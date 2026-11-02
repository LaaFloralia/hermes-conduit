import { notifyOwner } from '../notify/index.mjs';

// Only an explicitly owner-authorized source may supply this stream. An agent's
// own notifications must never be presented as the owner's inbox.
export function createOwnerTaskNotificationPoller({ source, notify = notifyOwner, intervalMs = 60_000,
  schedule = setInterval, cancel = clearInterval } = {}) {
  const seen = new Set();
  const startedAt = Date.now();
  let running = false;
  async function poll() {
    if (running || source?.ownerInboxAvailable !== true) return { available: false };
    running = true;
    try {
      let cursor, pages = 0, delivered = 0;
      do {
        const page = await source.listCollection('inbox', { limit: 100, cursor });
        for (const item of page.items) {
          if (item.readAt || item.archivedAt || !item.issue?.id || !/assign|mention|comment|updated|subtask/i.test(item.type ?? '')) continue;
          // Historical items remain in the inbox, without a startup push burst.
          if (Date.parse(item.updatedAt) < startedAt) continue;
          const key = `linear:${item.id}:${item.updatedAt}`;
          if (seen.has(key)) continue;
          const result = await notify({ kind: 'task', title: item.title || 'Linearの通知',
            body: item.issue.title, deepLink: `laa://work/tasks/${encodeURIComponent(item.issue.id)}`, dedupeKey: key });
          if (result?.delivered === true) { seen.add(key); delivered++; }
        }
        cursor = page.nextCursor;
        pages++;
      } while (cursor && pages < 5);
      // Delivery has its own persistent dedupe; this is only a bounded hot cache.
      while (seen.size > 2000) seen.delete(seen.values().next().value);
      return { available: true, delivered, incomplete: Boolean(cursor) };
    } catch { return { available: false }; }
    finally { running = false; }
  }
  let timer;
  return {
    poll,
    start() {
      if (!timer && source?.ownerInboxAvailable === true) {
        timer = schedule(() => { void poll(); }, intervalMs); timer?.unref?.();

      }
    },
    stop() { if (timer) cancel(timer); timer = undefined; },
  };
}

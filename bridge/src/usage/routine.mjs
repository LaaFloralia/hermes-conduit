// Usage readings that change on the daily Bridge schedule, not on a client poll.
import { createJsonFile } from '../routes/state-file.mjs';

const DAY = 86_400_000;
// 05:00 JST is 20:00 UTC the day before; Japan does not use DST.
const JST_RESET_OFFSET = (9 - 5) * 3_600_000;
export const usageDay = (at) => Math.floor((at + JST_RESET_OFFSET) / DAY);
export const nextUsageRefresh = (at) => (usageDay(at) + 1) * DAY - JST_RESET_OFFSET;

export function isRoutineUsage(item) {
  return item.id.startsWith('capacity.macbook.') || (item.kind === 'balance' && item.id.endsWith('.balance'));
}

export function createRoutineUsage({ file, now = Date.now, collect, schedule = setTimeout, cancel = clearTimeout } = {}) {
  const disk = file ? createJsonFile({ file }) : null;
  let snapshot;
  try { snapshot = disk?.read(); } catch { /* Leave unreadable state untouched. */ }
  let day = Number.isSafeInteger(snapshot?.day) ? snapshot.day : null;
  let items = Array.isArray(snapshot?.items) ? snapshot.items.filter(item => item && typeof item.id === 'string' && isRoutineUsage(item)) : [];
  let timer, inflight, closed = false;

  function runDue() {
    if (closed || inflight) return inflight;
    const slot = usageDay(now());
    if (day !== null && day >= slot) return;
    day = slot;
    // Persist the attempt before any work; a restart cannot re-run the same
    // scheduled batch. Keep a previous observation if today's read fails.
    save();
    inflight = Promise.resolve().then(() => collect(publish)).catch(() => {}).finally(() => { inflight = null; });
    return inflight;
  }

  function publish(readings) {
    if (closed) return;
    const next = new Map(items.map(item => [item.id, item]));
    for (const item of readings.filter(isRoutineUsage)) {
      const previous = next.get(item.id);
      next.set(item.id, item.availability === 'available' || previous?.availability !== 'available'
        ? item : { ...previous, stale: true });
    }
    items = [...next.values()];
    save();
  }

  function save() {
    try { disk?.mutate(state => { state.day = day; state.items = items; }); } catch { /* A journal failure doesn't hide live readings. */ }
  }
  function arm() {
    if (closed) return;
    runDue();
    const at = now();
    timer = schedule(arm, Math.max(1, nextUsageRefresh(at) - at));
    timer?.unref?.();
  }
  arm();
  return {
    read: () => items,
    runDue,
    close() { closed = true; cancel(timer); },
  };
}

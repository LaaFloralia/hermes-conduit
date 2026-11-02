// Short lived snapshots. Any Linear write fences every in-flight list read,
// including writes through the full client rather than the owner endpoint.
let generation = 0;
export function invalidateLinearLists() { generation++; }

export function createLinearListCache({ now = Date.now, ttlMs = 45_000 } = {}) {
  const entries = new Map();
  return async function cached(key, load) {
    let entry = entries.get(key);
    if (!entry || entry.generation !== generation) {
      entry = { generation, value: undefined, at: 0, pending: null };
      entries.set(key, entry);
    }
    const refresh = () => {
      if (!entry.pending) {
        entry.pending = Promise.resolve().then(load).then((value) => {
          if (entry.generation === generation) { entry.value = structuredClone(value); entry.at = now(); }
          return value;
        }).finally(() => { entry.pending = null; });
      }
      return entry.pending;
    };
    if (entry.value === undefined) return structuredClone(await refresh());
    if (now() - entry.at >= ttlMs) void refresh().catch(() => {});
    return structuredClone(entry.value);
  };
}

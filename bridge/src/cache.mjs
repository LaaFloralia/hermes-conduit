// Stale-while-revalidate for read-only sources (BRIDGE §9).
//
// The app must never wait for a slow or missing source. A request is served
// from the last good value, one refresh runs at a time, and `fetchedAt` says
// how old the answer is. Only a source that has never produced a value can fail
// the request, and a protocol error (a malformed upstream response) is still
// reported instead of being hidden behind the cache.
//
// `waitMs` is the budget a revalidation may take before the cached value is
// served; a source whose last read already took longer than that is served from
// the cache until it recovers. `firstWaitMs` bounds the wait for the very first
// value (0 waits for the whole read).

const TIMED_OUT = Symbol('timed out');

export function createReadCache({
  read,
  freshMs = 0,
  waitMs = 0,
  firstWaitMs = 0,
  cooldownMs = 0,
  fallbackOn = (error) => error?.status === 503 || error?.retryable === true,
  now = () => Date.now(),
} = {}) {
  if (typeof read !== 'function') throw new TypeError('read must be a function');
  let value;
  let fetchedAt = null;
  let durationMs = null;
  let failedAt = null;
  let lastError = null;
  let inflight = null;

  function timed(promise, ms) {
    if (!(ms > 0)) return Promise.resolve(TIMED_OUT);
    return new Promise((resolve) => {
      const timer = setTimeout(() => resolve(TIMED_OUT), ms);
      timer.unref?.();
      promise.then((outcome) => { clearTimeout(timer); resolve(outcome); });
    });
  }

  function refresh() {
    if (inflight) return inflight;
    const startedAt = now();
    const run = Promise.resolve().then(read).then((next) => {
      value = next;
      fetchedAt = now();
      durationMs = fetchedAt - startedAt;
      failedAt = null;
      lastError = null;
      return next;
    }, (error) => {
      durationMs = now() - startedAt;
      failedAt = now();
      lastError = error;
      throw error;
    }).finally(() => { if (inflight === run) inflight = null; });
    inflight = run;
    return run;
  }

  // Always resolves, so a background refresh never becomes an unhandled rejection.
  const outcomeOf = (run) => run.then((next) => ({ next }), (error) => ({ error }));
  const warm = () => { void outcomeOf(refresh()); };
  const entry = (stale, error = null) => ({ value, fetchedAt, stale, error });
  const empty = () => ({ value: undefined, fetchedAt: null, stale: true, error: lastError });
  const backoff = () => (failedAt !== null && now() - failedAt < cooldownMs) ||
    (waitMs > 0 && durationMs !== null && durationMs >= waitMs);

  async function get() {
    if (fetchedAt === null) {
      // Nothing to serve: this is the only case where a request waits for the read.
      const outcome = firstWaitMs > 0 ? await timed(outcomeOf(refresh()), firstWaitMs) : await outcomeOf(refresh());
      if (outcome === TIMED_OUT) { warm(); return empty(); }
      if (outcome.error) throw outcome.error;
      return entry(false);
    }
    if (freshMs > 0 && now() - fetchedAt < freshMs) return entry(false);
    if (backoff()) { warm(); return entry(true, lastError); }
    const outcome = await timed(outcomeOf(refresh()), waitMs);
    if (outcome === TIMED_OUT) { warm(); return entry(true, lastError); }
    if (outcome.error) {
      // A malformed or rejected upstream answer stays an error: the cache only
      // covers "the source could not be read", never "the source answered badly".
      if (!fallbackOn(outcome.error)) throw outcome.error;
      return entry(true, outcome.error);
    }
    return entry(false);
  }

  return { get, warm, peek: () => (fetchedAt === null ? null : entry(false)) };
}

// For a read that already carries the caller's own validators (a conditional
// catalog GET), the route keeps the last good value itself: `accept` records a
// successful answer and `fallback` returns it when a later read cannot reach the
// source. Protocol errors are still reported, exactly as in `createReadCache`.
export function createLastGood({ fallbackOn = (error) => error?.status === 503 || error?.retryable === true, now = () => Date.now() } = {}) {
  let value;
  let fetchedAt = null;
  let lastError = null;

  return {
    accept(next) { value = next; fetchedAt = now(); lastError = null; },
    fallback(error) {
      if (value === undefined || !fallbackOn(error)) throw error;
      lastError = error;
      return { value, fetchedAt, stale: true, error };
    },
    peek: () => (fetchedAt === null ? null : { value, fetchedAt, stale: false, error: lastError }),
  };
}

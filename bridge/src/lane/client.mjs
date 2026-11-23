import { LANE_HEADER, PRODUCTION_PORTS } from './guard.mjs';

const HEALTH = '/v1/health';
const LIVE_ORIGIN = 'http://127.0.0.1:9137';

export class LaneMismatch extends Error {
  constructor(status = null) {
    super('Bridge did not confirm the requested lab lane');
    this.code = 'lane_mismatch';
    this.status = status;
  }
}

async function stampedFetch(url, id, init = {}) {
  if (!/^[A-Za-z0-9_-]{1,96}$/.test(id ?? '')) throw new LaneMismatch();
  const headers = new Headers(init.headers);
  headers.set(LANE_HEADER, id);
  const response = await fetch(url, { ...init, headers, redirect: 'error', signal: init.signal ?? AbortSignal.timeout(5000) });
  if (response.status === 421 || response.headers.get(LANE_HEADER) !== id) {
    await response.body?.cancel().catch(() => {});
    throw new LaneMismatch(response.status);
  }
  return response;
}

export function laneClient(origin, id) {
  const base = new URL(origin);
  if (base.protocol !== 'http:' || base.hostname !== '127.0.0.1' || !base.port || PRODUCTION_PORTS.includes(Number(base.port))
      || base.username || base.password || base.pathname !== '/' || base.search || base.hash) throw new LaneMismatch();
  return async (path, init = {}) => {
    const url = new URL(path, base);
    if (url.origin !== base.origin || !path.startsWith('/') || path.startsWith('//')) throw new LaneMismatch();
    if (path !== HEALTH || (init.method ?? 'GET').toUpperCase() !== 'GET' || init.body !== undefined) {
      // Prove the peer understands the lane before sending even a read with
      // credentials, let alone a write, to a legacy or misconfigured server.
      const proof = await stampedFetch(new URL(HEALTH, base), id);
      await proof.body?.cancel();
      if (!proof.ok) throw new LaneMismatch(proof.status);
    }
    return stampedFetch(url, id, init);
  };
}

// Explicit verification escape hatch: fixed destination, GET and path only;
// no authorization, user-provided body, redirects or other live access.
export async function probeLiveHealth(id) {
  return stampedFetch(new URL(HEALTH, LIVE_ORIGIN), id, { method: 'GET' });
}

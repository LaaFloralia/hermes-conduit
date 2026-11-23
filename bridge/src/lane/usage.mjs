import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { BridgeError } from '../errors.mjs';
import { unavailableUsageItems } from '../usage/proxy.mjs';
import { lanePath } from './guard.mjs';

const samples = new URL('../../../docs/laa/fixtures/usage/', import.meta.url);
export const usageModePath = (state) => join(state, 'usage-ui-mode');
export const usageCountPath = (state) => join(state, 'usage-ui-count');
export const usageModes = ['normal', 'degraded', 'error', 'offline', 'empty', 'slow', 'stale', 'revoked'];

// The lane's authenticated routes sample only checked-in synthetic readings.
// Two small private files connect the fixture controls to the real Bridge.
export function laneUsageRoutes(lane, state, now) {
  const modeFile = lanePath(lane.root, usageModePath(state), 'usage mode');
  if (!existsSync(modeFile)) return [];
  const countFile = lanePath(lane.root, usageCountPath(state), 'usage request count');
  let count = 0;
  return ['/v1/usage', '/v1/mac/status'].map((path) => ({
    method: 'GET', path, auth: true, scope: 'usage:read', laneOnly: true, async handler({ res }) {
      const usage = path === '/v1/usage';
      if (usage) writeFileSync(countFile, String(++count), { mode: 0o600 });
      const mode = readFileSync(modeFile, 'utf8');
      if (mode === 'offline') { res.destroy(); return; }
      if (mode === 'error') throw new BridgeError(503, 'unavailable', 'synthetic outage', { retryable: true });
      if (mode === 'revoked') throw new BridgeError(401, 'token_revoked', 'synthetic revocation');
      if (mode === 'slow') await sleep(3000);
      const sample = usage ? 'usage-normal.json' : 'mac-status-normal.json';
      const { data } = JSON.parse(readFileSync(new URL(sample, samples), 'utf8'));
      if (usage) {
        const observed = now() - (mode === 'stale' ? 30 * 60_000 : 60_000);
        const at = (ms) => new Date(ms).toISOString();
        const gib = 1024 ** 3;
        data.items.push({ id: 'capacity.mac-mini.ssd', kind: 'capacity', label: 'Mac mini SSD',
          value: 400 * gib, unit: 'bytes', source: 'filesystem', observedAt: at(observed), availability: 'available',
          stale: mode === 'stale', expired: false, estimated: false,
          detail: { totalBytes: 500 * gib, availableBytes: 100 * gib, status: 'normal', warningFreeBytes: 80 * gib,
            criticalFreeBytes: 40 * gib, freshUntil: at(observed + 10 * 60_000) } });
        for (const quota of data.items.filter((item) => item.kind === 'quota' && item.detail?.windows)) {
          quota.observedAt = at(observed);
          quota.stale = mode === 'stale';
          quota.detail.freshUntil = at(observed + 20 * 60_000);
          for (const window of quota.detail.windows) window.resetsAt = at(now() + 3_600_000);
          quota.expired = false;
        }
        if (mode === 'empty') data.items = unavailableUsageItems('fetch_failed');
        if (mode === 'degraded') {
          const first = data.items[0];
          Object.assign(first, { availability: 'unavailable', nullReason: 'fetch_failed', value: null, observedAt: null });
          delete first.detail;
        }
      }
      return { status: 200, data };
    },
  }));
}

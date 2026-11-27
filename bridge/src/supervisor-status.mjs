import { constants } from 'node:fs';
import { open } from 'node:fs/promises';

const MAX_BYTES = 256 * 1024;
const counts = ['runningAll', 'readyPending', 'stalled', 'needsJudgement', 'reportedUnverified',
  'memoryPending', 'boardDelegable', 'boardOwnerOnly'];
const metrics = ['tickDurationMs', 'inspectP95Ms'];
const timestamp = /^(\d{4}-\d{2}-\d{2})T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.(\d+))?(?:Z|[+-]\d{2}:\d{2})$/;
function parseTime(value) {
  const match = typeof value === 'string' && timestamp.exec(value);
  if (!match) return null;
  const [, date, fraction = ''] = match;
  const midnight = Date.parse(`${date}T00:00:00Z`), ms = Date.parse(value);
  // Date.parse can normalize an invalid calendar date (e.g. February 30).
  if (!Number.isFinite(midnight) || !Number.isFinite(ms) || new Date(midnight).toISOString().slice(0, 10) !== date) return null;
  return { ms, fraction: fraction.replace(/0+$/, '') };
}
const count = (value) => Number.isSafeInteger(value) && value >= 0;
const metric = (value) => Number.isFinite(value) && value >= 0 && value <= Number.MAX_SAFE_INTEGER;

export async function readSupervisorStatus(file, now) {
  const missing = { status: 'missing' };
  if (!file) return missing;
  let handle;
  try {
    handle = await open(file, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    const stat = await handle.stat();
    if (!stat.isFile() || stat.size > MAX_BYTES) return missing;
    const bytes = Buffer.alloc(MAX_BYTES + 1);
    let size = 0;
    while (size < bytes.length) {
      const { bytesRead } = await handle.read(bytes, size, bytes.length - size);
      if (!bytesRead) break;
      size += bytesRead;
    }
    if (size > MAX_BYTES) return missing;
    const raw = JSON.parse(bytes.toString('utf8', 0, size));
    if (raw?.schema !== 'laa.supervisor-status.v1' || !['ok', 'stalled'].includes(raw.status)) return missing;
    const checked = parseTime(raw.checkedAt), deadline = parseTime(raw.nextCheckBy);
    if (!checked || !deadline || deadline.ms < checked.ms
      || (deadline.ms === checked.ms && deadline.fraction < checked.fraction)) return missing;
    return {
      status: now() > deadline.ms ? 'stale' : raw.status,
      checkedAt: new Date(checked.ms).toISOString(),
      nextCheckBy: new Date(deadline.ms).toISOString(),
      ...Object.fromEntries(metrics.filter((key) => metric(raw[key])).map((key) => [key, raw[key]])),
      ...(count(raw.vmPressureLevel) ? { vmPressureLevel: raw.vmPressureLevel } : {}),
      counts: Object.fromEntries(counts.filter((key) => count(raw.counts?.[key])).map((key) => [key, raw.counts[key]])),
      ...(Array.isArray(raw.sla?.breaches) ? { slaBreachCount: raw.sla.breaches.length } : {}),
      ...(Array.isArray(raw.cronLintWarnings) ? { cronLintWarningCount: raw.cronLintWarnings.length } : {}),
    };
  } catch {
    return missing;
  } finally {
    await handle?.close().catch(() => {});
  }
}

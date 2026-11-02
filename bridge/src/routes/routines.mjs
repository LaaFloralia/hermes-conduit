// Read only: project the Console's inventory-backed job observations.
//
// `laa-console jobs` can take from tens of milliseconds to minutes, so the
// projection is cached: a request is answered from the last successful read,
// one read runs at a time, and the cache refreshes in the background once the
// value is older than `freshMs`. Only a source that has never answered is a 503.
import { execFile } from 'node:child_process';
import { dirname } from 'node:path';
import { promisify } from 'node:util';
import { createReadCache } from '../cache.mjs';
import { BridgeError } from '../errors.mjs';
const exec = promisify(execFile);

const ROLE_NAMES = Object.freeze({ ciel: 'Ciel', cos: 'Merlin', cto: 'Ada', cfo: 'Morgan',
  cio: 'Sherlock', cmo: 'Monet', cso: 'Talos', argus: 'Argus' });
const boundedString = (value) => typeof value === 'string' && value.length <= 500 ? value : null;

export function routineState(job, reading) {
  if (reading.running === true) return 'running';
  if (reading.enabled === false || job.expected === 'stopped') return 'paused';
  if (reading.schedulerResult === 'error' || ['failed', 'partial'].includes(reading.businessStatus)) return 'error';
  if (reading.enabled === true) return 'scheduled';
  return 'unknown';
}

export function routineDestination(job) {
  if (job.notificationMode !== 'chat') return null;
  const rawRole = job.receiverRole ?? job.ownerRole;
  const role = typeof rawRole === 'string' ? rawRole.toLowerCase() : null;
  const name = Object.hasOwn(ROLE_NAMES, role) ? ROLE_NAMES[role] : null;
  return name ? `${name}の定期実行チャット` : null;
}

export function routineKind(job) {
  if (['scheduled', 'service', 'manual', 'unknown'].includes(job.triggerKind)) return job.triggerKind;
  if (job.reading?.source === 'launchd') return 'unknown';
  if (['hermes', 'hermes-shared', 'paseo'].includes(job.reading?.source)) return 'scheduled';
  return 'unknown';
}

export function projectRoutines(document) {
  if (!Array.isArray(document?.data)) throw new Error('invalid jobs response');
  return document.data.map((job) => {
    if (typeof job?.id !== 'string' || typeof job?.name !== 'string') throw new Error('invalid job');
    const reading = job.reading && typeof job.reading === 'object' ? job.reading : {};
    return { id: job.id, name: job.name, schedule: boundedString(job.schedule),
      triggerKind: routineKind(job), destination: routineDestination(job), state: routineState(job, reading),
      nextRunAt: boundedString(reading.nextRunAt), lastRunAt: boundedString(reading.lastRunAt),
      businessStatus: boundedString(reading.businessStatus), notificationStatus: boundedString(reading.notificationStatus),
      result: boundedString(reading.result) };
  });
}

// launchd starts the Bridge with a PATH that has no node; laa-console's tsx needs one, so lend it the Bridge runtime.
export function consoleEnv(env = process.env, execPath = process.execPath) {
  return { ...env, PATH: [dirname(execPath), env.PATH].filter(Boolean).join(':') };
}

export function routineRoutes({
  read = async () => {
    const { stdout } = await exec('/Users/laa/.local/bin/laa-console', ['jobs'], { timeout: 60000, maxBuffer: 4 * 1024 * 1024, env: consoleEnv() });
    return JSON.parse(stdout);
  },
  freshMs = 60000, firstWaitMs = 250, now = () => Date.now(),
} = {}) {
  const cache = createReadCache({ read: async () => projectRoutines(await read()), freshMs, waitMs: 0, firstWaitMs, now });
  // Warm at startup so the app does not pay for the first Console run.
  cache.warm();
  return [{ method: 'GET', path: '/v1/routines', auth: true, scope: 'sessions:read', handler: async () => {
    let entry = null;
    try { entry = await cache.get(); } catch { /* nothing has ever been read */ }
    if (entry === null || entry.fetchedAt === null) {
      throw new BridgeError(503, 'routines_unavailable', 'routine observations unavailable', { retryable: true });
    }
    return { status: 200, data: { items: entry.value, nextCursor: null, fetchedAt: new Date(entry.fetchedAt).toISOString() } };
  } }];
}

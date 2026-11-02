// Read only: project the Console's inventory-backed job observations.
import { execFile } from 'node:child_process';
import { dirname } from 'node:path';
import { promisify } from 'node:util';
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

export function projectRoutines(document) {
  if (!Array.isArray(document?.data)) throw new Error('invalid jobs response');
  return document.data.map((job) => {
    if (typeof job?.id !== 'string' || typeof job?.name !== 'string') throw new Error('invalid job');
    const reading = job.reading && typeof job.reading === 'object' ? job.reading : {};
    return { id: job.id, name: job.name, schedule: boundedString(job.schedule),
      destination: routineDestination(job), state: routineState(job, reading),
      nextRunAt: boundedString(reading.nextRunAt), lastRunAt: boundedString(reading.lastRunAt),
      businessStatus: boundedString(reading.businessStatus), notificationStatus: boundedString(reading.notificationStatus),
      result: boundedString(reading.result) };
  });
}

// launchd starts the Bridge with a PATH that has no node; laa-console's tsx needs one, so lend it the Bridge runtime.
export function consoleEnv(env = process.env, execPath = process.execPath) {
  return { ...env, PATH: [dirname(execPath), env.PATH].filter(Boolean).join(':') };
}

export function routineRoutes({ read = async () => {
  const { stdout } = await exec('/Users/laa/.local/bin/laa-console', ['jobs'], { timeout: 20000, maxBuffer: 4 * 1024 * 1024, env: consoleEnv() });
  return JSON.parse(stdout);
} } = {}) {
  return [{ method: 'GET', path: '/v1/routines', auth: true, scope: 'sessions:read', handler: async () => {
    try { return { status: 200, data: { items: projectRoutines(await read()), nextCursor: null } }; }
    catch { throw new BridgeError(503, 'routines_unavailable', 'routine observations unavailable', { retryable: true }); }
  } }];
}

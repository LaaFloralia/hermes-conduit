// Read only: project the Console's inventory-backed job observations.
//
// `laa-console jobs` can take from tens of milliseconds to minutes, so the
// projection is cached: a request is answered from the last successful read,
// one read runs at a time, and the cache refreshes in the background once the
// value is older than `freshMs`. Only a source that has never answered is a 503.
//
// A cold cache keeps retrying on its own: the startup warm can fail once (a
// busy Mac, a Console run that outlived the exec timeout) and otherwise leave
// the app showing "could not load the list" until someone tapped refresh hours
// later. One unusable row is skipped instead of voiding every routine.
import { execFile } from 'node:child_process';
import { dirname } from 'node:path';
import { promisify } from 'node:util';
import { createReadCache } from '../cache.mjs';
import { BridgeError } from '../errors.mjs';
import { routineRefItem } from '../refs/items.mjs';
const exec = promisify(execFile);

const ROLE_NAMES = Object.freeze({ monet: 'Monet', cos: 'Merlin', cto: 'Ada', cfo: 'Morgan',
  cio: 'Sherlock', cso: 'Talos', argus: 'Argus' });
const boundedString = (value) => typeof value === 'string' && value.length <= 500 ? value : null;

export function routineState(job, reading) {
  if (reading.running === true || reading.schedulerState === 'running') return 'running';
  if (reading.enabled === false || job.expected === 'stopped') return 'paused';
  if (['read_unavailable', 'schedule_overdue'].includes(reading.reasonCode)) return 'error';
  if (reading.schedulerResult === 'error' || ['failed', 'partial'].includes(reading.businessStatus)) return 'error';
  if (reading.enabled === true) return 'scheduled';
  return 'unknown';
}

export function routineDestination(job) {
  if (job.notificationMode !== 'chat') return null;
  const rawRole = job.receiverRole ?? job.ownerRole;
  const role = typeof rawRole === 'string' ? rawRole.toLowerCase() : null;
  const name = Object.hasOwn(ROLE_NAMES, role) ? ROLE_NAMES[role] : null;
  return name ? `${name}のチャット` : null;
}

export function routineKind(job) {
  if (['scheduled', 'service', 'manual', 'unknown'].includes(job.triggerKind)) return job.triggerKind;
  if (job.reading?.source === 'launchd') return 'unknown';
  if (['hermes', 'hermes-shared', 'paseo', 'work'].includes(job.reading?.source)) return 'scheduled';
  return 'unknown';
}

export function projectRoutines(document) {
  return projectRoutineRows(document).items;
}

// Splits "the Console answered with an unusable document" from "this row is
// unusable". A document whose every row is unusable is a shape change, not an
// empty schedule list, so it still fails the read instead of showing none.
export function projectRoutineRows(document) {
  if (!Array.isArray(document?.data)) throw new Error('invalid jobs response');
  const items = [];
  let skipped = 0;
  for (const job of document.data) {
    if (typeof job?.id !== 'string' || typeof job?.name !== 'string') { skipped += 1; continue; }
    const reading = job.reading && typeof job.reading === 'object' ? job.reading : {};
    items.push({ id: job.id, name: job.name, schedule: boundedString(job.schedule),
      triggerKind: routineKind(job), destination: routineDestination(job), state: routineState(job, reading),
      nextRunAt: boundedString(reading.nextRunAt), lastRunAt: boundedString(reading.lastRunAt),
      businessStatus: boundedString(reading.businessStatus), notificationStatus: boundedString(reading.notificationStatus),
      result: boundedString(reading.result),
      ...Object.fromEntries(['runId', 'reasonCode', 'observationStatus', 'scheduledAt', 'expectedRunAt', 'startedAt', 'finishedAt', 'notificationAcceptedAt', 'notificationSentAt', 'notificationReceivedAt'].map((key) => [key, boundedString(reading[key])])) });
  }
  if (document.data.length > 0 && items.length === 0) throw new Error('invalid jobs response');
  return { items, skipped };
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
  freshMs = 60000, firstWaitMs = 3000, retryMs = 15000, now = () => Date.now(), refs = null,
} = {}) {
  const cache = createReadCache({ read: async () => projectRoutineRows(await read()), freshMs, waitMs: 0, firstWaitMs, now });
  if (refs) {
    // A skipped row means the Console answer was partly unusable, so it is not
    // a complete set and must not release a number.
    refs.registerSource('routine', () => {
      const entry = cache.peek();
      if (entry === null || entry.value.skipped > 0) return null;
      return entry.value.items.map(routineRefItem);
    });
  }
  // A cold cache retries until the first read lands, so a warm that failed at
  // startup does not leave the app with a 503 until its next manual refresh.
  let retryTimer = null;
  const keepWarm = () => {
    if (cache.peek() !== null) return;
    cache.warm();
    if (retryTimer !== null) return;
    retryTimer = setInterval(() => {
      if (cache.peek() !== null) { clearInterval(retryTimer); retryTimer = null; return; }
      cache.warm();
    }, retryMs);
    retryTimer.unref?.();
  };
  // Warm at startup so the app does not pay for the first Console run.
  keepWarm();
  return [{ method: 'GET', path: '/v1/routines', auth: true, scope: 'sessions:read', handler: async () => {
    let entry = null;
    try { entry = await cache.get(); } catch { /* nothing has ever been read */ }
    if (entry === null || entry.fetchedAt === null) {
      keepWarm();
      throw new BridgeError(503, 'routines_unavailable', 'routine observations unavailable', { retryable: true });
    }
    if (refs && entry.value.skipped === 0) refs.observe('routine', entry.value.items.map(routineRefItem));
    const items = refs
      ? entry.value.items.map((item) => ({ ...item, ref: refs.refFor('routine', item.id) }))
      : entry.value.items;
    return { status: 200, data: { items, skipped: entry.value.skipped, nextCursor: null, fetchedAt: new Date(entry.fetchedAt).toISOString() } };
  } }];
}

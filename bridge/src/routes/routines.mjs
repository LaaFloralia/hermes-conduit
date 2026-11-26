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

const STAFF_NAMES = Object.freeze({ monet: 'Monet', cos: 'Merlin', cto: 'Ada', cfo: 'Morgan',
  cio: 'Sherlock', cso: 'Talos', argus: 'Argus' });
const ROLE_NAMES = Object.freeze({ ...STAFF_NAMES, soap: '薬用石鹸' });
const boundedString = (value, limit = 500) => typeof value === 'string' && value.length <= limit ? value : null;
const modelSetting = (value) => typeof value === 'string' && /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,119}$/.test(value) ? value : null;
const deliveryMode = (value) => ['chat', 'local', 'none'].includes(value) ? value : null;
const routineStaff = (value) => typeof value?.id === 'string' && Object.hasOwn(STAFF_NAMES, value.id) && value.name === STAFF_NAMES[value.id]
  ? { id: value.id, name: value.name } : null;

function plannedRun(value) {
  const by = modelSetting(value?.by);
  const why = boundedString(value?.why, 120);
  const label = boundedString(value?.label, 100);
  const effort = value?.effort ?? null;
  if (!by || by !== by.toLowerCase() || !why || !label ||
      (by === 'code' ? effort !== null : !['low', 'medium', 'high', 'xhigh', 'max'].includes(effort))) return null;
  const via = by !== 'code' && value.via === 'work' ? { via: 'work' } : {};
  return { by, effort, ...via, why, label };
}

function runTime(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d(?:\.\d{1,9})?)?(?:Z|[+-]\d{2}:\d{2})$/.test(value) ||
      !Number.isFinite(Date.parse(value))) return null;
  const day = value.slice(0, 10);
  const midnight = Date.parse(`${day}T00:00:00Z`);
  return Number.isFinite(midnight) && new Date(midnight).toISOString().slice(0, 10) === day ? value : null;
}

function recentRuns(value) {
  if (!Array.isArray(value)) return null;
  return value.slice(0, 20).flatMap((run) => {
    const startedAt = runTime(run?.startedAt);
    const { runId, result } = run ?? {};
    if (!startedAt || typeof runId !== 'string' || !/^[a-zA-Z0-9-]{8,80}$/.test(runId) ||
        !['ok', 'failed', 'running', 'silent', 'unknown'].includes(result)) return [];
    return [{ runId, startedAt, finishedAt: runTime(run.finishedAt), result,
      model: modelSetting(run.model), provider: modelSetting(run.provider), effort: modelSetting(run.effort) }];
  });
}

export function routineState(job, reading) {
  // A disabled output never runs just because its sibling owns the shared slot.
  if (reading.outputEnabled === false) return 'paused';
  if (reading.running === true || reading.schedulerState === 'running') return 'running';
  if (reading.enabled === false || reading.schedulerState === 'paused' || job.expected === 'stopped' ||
      (reading.source === 'launchd' && reading.loaded === false)) return 'paused';
  if (['read_unavailable', 'schedule_overdue', 'launchd_failed'].includes(reading.reasonCode)) return 'error';
  if (reading.schedulerResult === 'error' || ['failed', 'partial', 'needs_attention'].includes(reading.businessStatus)) return 'error';
  if (reading.enabled === true) return 'scheduled';
  return 'unknown';
}

export function routineDestination(job) {
  const delivery = deliveryMode(job.delivery);
  if (delivery) {
    if (delivery !== 'chat') return null;
    const staff = routineStaff(job.staff);
    if (staff) return `${staff.name}のチャット`;
    // Accept a Console still using legacy receiver roles during the migration.
    if (job.staff != null) return null;
  } else {
    if (job.delivery != null || job.notificationMode !== 'chat') return null;
    if (job.triggerKind === 'scheduled' || ['hermes', 'hermes-shared', 'work', 'paseo'].includes(job.reading?.source)) return '定期実行';
  }
  const rawRole = job.receiverRole ?? (delivery ? null : job.ownerRole);
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
      staff: routineStaff(job.staff), run: plannedRun(job.run), delivery: deliveryMode(job.delivery),
      recentRuns: recentRuns(reading.recentRuns),
      ...(reading.modelSettings?.author ? { authorModel: modelSetting(reading.modelSettings.author.model),
        authorEffort: modelSetting(reading.modelSettings.author.effort) } : {}),
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

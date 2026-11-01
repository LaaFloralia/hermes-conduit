// Read only: project the Console's inventory-backed job observations.
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { BridgeError } from '../errors.mjs';
const exec = promisify(execFile);

export function projectRoutines(document) {
  if (!Array.isArray(document?.data)) throw new Error('invalid jobs response');
  return document.data.map((job) => {
    if (typeof job?.id !== 'string' || typeof job?.name !== 'string') throw new Error('invalid job');
    const reading = job.reading && typeof job.reading === 'object' ? job.reading : {};
    const string = (value) => typeof value === 'string' && value.length <= 500 ? value : null;
    return { id: job.id, name: job.name, schedule: string(job.schedule),
      nextRunAt: string(reading.nextRunAt), lastRunAt: string(reading.lastRunAt),
      result: string(reading.result) };
  });
}

export function routineRoutes({ read = async () => {
  const { stdout } = await exec('/Users/laa/.local/bin/laa-console', ['jobs'], { timeout: 20000, maxBuffer: 4 * 1024 * 1024 });
  return JSON.parse(stdout);
} } = {}) {
  return [{ method: 'GET', path: '/v1/routines', auth: true, scope: 'sessions:read', handler: async () => {
    try { return { status: 200, data: { items: projectRoutines(await read()), nextCursor: null } }; }
    catch { throw new BridgeError(503, 'routines_unavailable', 'routine observations unavailable', { retryable: true }); }
  } }];
}

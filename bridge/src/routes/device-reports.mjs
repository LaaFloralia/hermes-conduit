// MetricKit diagnostics a device hands the Mac: crash, hang, launch and
// resource-exception reports with their call stacks, as iOS wrote them.
//
// TestFlight's crash feed needs the tester to tap "Share", and often stays
// empty; MetricKit hands the app its own crash report on the next launch.
// The app sends each stored diagnostic once; the Bridge keeps it beside its
// state (0600, per device, newest few dozen) so a crash can be read from the
// Mac with its stack. Nothing leaves the Mac from here.
//
// The body is `{kind: "diagnostics", name, appVersion, payload}`. The file
// is named by the payload's content hash, so sending the same report twice
// stores it once and reports `stored: false`.
import { createHash } from 'node:crypto';
import { chmodSync, closeSync, existsSync, fsyncSync, mkdirSync, openSync, readdirSync, renameSync, rmSync, statSync, writeSync } from 'node:fs';
import { join } from 'node:path';
import { badRequest } from '../errors.mjs';
import { parseObjectBody } from './state-file.mjs';

export const DEVICE_REPORT_MAX_BYTES = 4 * 1024 * 1024;
export const DEVICE_REPORTS_KEPT = 60;
const NAME = /^[A-Za-z0-9._-]{1,120}$/;
const VERSION = /^[0-9A-Za-z .()_-]{1,40}$/;

export function deviceReportRoutes({ dir, now = () => Date.now(), kept = DEVICE_REPORTS_KEPT }) {
  const root = join(dir, 'device-reports');

  function folderFor(deviceId) {
    // Device ids are `dev_` and hex; anything else never reaches a path.
    if (!/^dev_[0-9a-f]{8,64}$/.test(deviceId ?? '')) throw badRequest('device_invalid', 'device id is not usable');
    return join(root, deviceId);
  }

  function prune(folder) {
    const files = readdirSync(folder).filter((name) => name.endsWith('.json'))
      .map((name) => ({ name, at: statSync(join(folder, name)).mtimeMs }))
      .sort((a, b) => a.at - b.at || a.name.localeCompare(b.name));
    for (const file of files.slice(0, Math.max(0, files.length - kept))) rmSync(join(folder, file.name), { force: true });
  }

  function post({ device, rawBody }) {
    const body = parseObjectBody(rawBody);
    if (body.kind !== 'diagnostics') throw badRequest('kind_invalid', 'only diagnostics are accepted');
    if (typeof body.name !== 'string' || !NAME.test(body.name)) throw badRequest('name_invalid', 'name is not a report file name');
    if (body.appVersion !== undefined && (typeof body.appVersion !== 'string' || !VERSION.test(body.appVersion))) {
      throw badRequest('app_version_invalid', 'appVersion is not a version');
    }
    if (body.payload === null || typeof body.payload !== 'object' || Array.isArray(body.payload)) {
      throw badRequest('payload_invalid', 'payload must be a JSON object');
    }
    const payload = JSON.stringify(body.payload);
    const id = createHash('sha256').update(payload).digest('hex').slice(0, 24);
    const folder = folderFor(device.id);
    const file = join(folder, `${id}.json`);
    if (existsSync(file)) return { status: 200, data: { id, stored: false } };

    mkdirSync(folder, { recursive: true, mode: 0o700 });
    const record = JSON.stringify({
      receivedAt: new Date(now()).toISOString(),
      deviceId: device.id,
      platform: device.platform ?? null,
      appVersion: body.appVersion ?? null,
      name: body.name,
      payload: body.payload,
    });
    const temporary = `${file}.${process.pid}.tmp`;
    const fd = openSync(temporary, 'w', 0o600);
    try {
      writeSync(fd, record);
      fsyncSync(fd);
    } finally {
      closeSync(fd);
    }
    chmodSync(temporary, 0o600);
    renameSync(temporary, file);
    prune(folder);
    return { status: 201, data: { id, stored: true } };
  }

  return [
    { method: 'POST', path: '/v1/device-reports', auth: true, scope: 'sessions:write', idempotent: false,
      bodyLimit: DEVICE_REPORT_MAX_BYTES, handler: post },
  ];
}

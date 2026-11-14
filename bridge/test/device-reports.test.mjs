import test from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { startBridge } from './helpers.mjs';

const crash = (n) => ({ timeStampBegin: '2026-11-15 07:59:00', crashDiagnostics: [{ callStackTree: { n }, diagnosticMetaData: { exceptionType: 1 } }] });
const report = (n, extra = {}) => ({ kind: 'diagnostics', name: `diagnostics-1-2-${n}.json`, appVersion: '1.0 (2611150800)', payload: crash(n), ...extra });

test('device reports: a diagnostic is kept once per device, 0600, newest kept', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const token = await api.token(['sessions:read', 'sessions:write']);

  const first = await api.request('/v1/device-reports', { method: 'POST', token, body: report(1) });
  assert.equal(first.status, 201);
  assert.equal(first.body.data.stored, true);
  const again = await api.request('/v1/device-reports', { method: 'POST', token, body: report(1) });
  assert.deepEqual([again.status, again.body.data.stored, again.body.data.id], [200, false, first.body.data.id]);

  const root = join(api.stateDir, 'device-reports');
  const [deviceDir] = readdirSync(root);
  assert.match(deviceDir, /^dev_[0-9a-f]+$/);
  const files = readdirSync(join(root, deviceDir));
  assert.deepEqual(files, [`${first.body.data.id}.json`]);
  const file = join(root, deviceDir, files[0]);
  assert.equal(statSync(file).mode & 0o777, 0o600);
  const saved = JSON.parse(readFileSync(file, 'utf8'));
  assert.equal(saved.deviceId, deviceDir);
  assert.equal(saved.appVersion, '1.0 (2611150800)');
  assert.deepEqual(saved.payload, crash(1));
  assert.equal(saved.kind, 'diagnostics');
  const metrics = await api.request('/v1/device-reports', { method: 'POST', token, body: report(9, { kind: 'metrics', name: 'metrics-1-2-9.json' }) });
  assert.equal(metrics.status, 201);
});

test('device reports: bad bodies, scope and authentication', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const token = await api.token(['sessions:read', 'sessions:write']);
  const readOnly = await api.token(['sessions:read']);
  for (const [body, code] of [
    [report(2, { kind: 'logs' }), 'kind_invalid'],
    [report(2, { name: '../x.json' }), 'name_invalid'],
    [report(2, { appVersion: 'a/b' }), 'app_version_invalid'],
    [report(2, { payload: [1] }), 'payload_invalid'],
  ]) {
    const response = await api.request('/v1/device-reports', { method: 'POST', token, body });
    assert.deepEqual([response.status, response.body.error.code], [400, code]);
  }
  assert.equal((await api.request('/v1/device-reports', { method: 'POST', token: readOnly, body: report(3) })).status, 403);
  assert.equal((await api.request('/v1/device-reports', { method: 'POST', body: report(3) })).status, 401);
});

#!/usr/bin/env node
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { access, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { laneClient } from '../../../bridge/src/lane/client.mjs';

const exec = promisify(execFile);
const launcher = fileURLToPath(new URL('./lane.mjs', import.meta.url));
const timeoutMs = 90_000;
const run = (...args) => exec(process.execPath, [launcher, ...args], { timeout: 240_000 });
const client = (origin, id) => laneClient(origin, id, { timeoutMs });
const lanes = [];
async function up() {
  const { stdout } = await run('up', '--json', '--fixture', 'work', '--fixture', 'phone-use', '--fixture', 'usage');
  const manifest = JSON.parse(stdout);
  lanes.push(manifest);
  return JSON.parse(await readFile(join(manifest.root, 'lane.json'), 'utf8'));
}

async function workflow(lane, index, other) {
  const base = `http://127.0.0.1:${lane.ports.bridge}`;
  const fixture = `http://127.0.0.1:${lane.ports.work}`;
  await run('status', lane.root);
  await assert.rejects(client(base, other.id)('/v1/health'), { code: 'lane_mismatch', status: 421 });
  const synthetic = client(fixture, lane.id);
  const enroll = await (await synthetic('/v1/devices/enroll', { method: 'POST', body: '{}' })).json();
  const fixtureResponse = await synthetic('/v1/sessions', { headers: { authorization: `Bearer ${enroll.data.token}` } });
  assert.ok(fixtureResponse.ok);
  assert.ok((await fixtureResponse.json()).data.items.length > 0);

  const phone = client(`http://127.0.0.1:${lane.ports['phone-use']}`, lane.id);
  const phoneControl = client(`http://127.0.0.1:${lane.ports['phone-use-control']}`, lane.id);
  const { code } = await (await phoneControl('/code')).json();
  const { data: phoneAuth } = await (await phone('/v1/devices/enroll', { method: 'POST',
    body: JSON.stringify({ code, name: 'Synthetic phone', platform: 'ios' }) })).json();
  const registered = await phone('/v1/phone-use/start-token', { method: 'PUT', headers: { authorization: `Bearer ${phoneAuth.token}` },
    body: JSON.stringify({ token: 'ab'.repeat(32), environment: 'sandbox' }) });
  assert.equal(registered.status, 200);
  const asked = await (await phoneControl('/ask?timeout=10')).json();
  assert.equal(asked.ok, true);
  const pushSink = JSON.parse((await readFile(join(lane.root, 'sink/apns.jsonl'), 'utf8')).trim());
  assert.deepEqual(Object.keys(pushSink).sort(), ['at', 'kind']);
  assert.equal(pushSink.kind, 'start');

  const api = client(base, lane.id);
  const usage = client(`http://127.0.0.1:${lane.ports['usage-control']}`, lane.id);
  assert.equal((await api('/v1/usage')).status, 401);
  const usageHeaders = { authorization: `Bearer ${lane.token}` };
  const capacity = async () => {
    const response = await api('/v1/usage', { headers: usageHeaders });
    assert.equal(response.status, 200);
    return (await response.json()).data.items.find(({ id }) => id === 'capacity.mac-mini.ssd');
  };
  assert.equal((await capacity()).detail.availableBytes, 100 * 1024 ** 3);
  assert.equal((await usage('/mode/stale')).status, 200);
  await assert.rejects(client(`http://127.0.0.1:${lane.ports['usage-control']}`, other.id)('/mode/empty'), { code: 'lane_mismatch' });
  assert.equal((await capacity()).stale, true);
  assert.equal(await (await usage('/counts')).text(), '2');

  const request = async (path, method = 'GET', value, key = '') => {
    const response = await api(path, { method, headers: { authorization: `Bearer ${lane.token}`,
      ...(value === undefined ? {} : { 'content-type': 'application/json', 'idempotency-key': key }) },
    ...(value === undefined ? {} : { body: JSON.stringify(value) }) });
    const body = await response.json();
    assert.ok(response.ok, `${method} ${path}: ${response.status} (${body.error?.code ?? 'no code'})`);
    return body.data;
  };
  // Same choices → create → send → conversation → archive shape as Work UI.
  assert.equal((await request('/v1/sessions')).items.length, 0);
  const { defaultProfile } = await request('/v1/session-options?catalogOnly=true');
  assert.equal(defaultProfile, 'lab-echo');
  const prompt = `Lane ${index} original`;
  const created = await request('/v1/sessions', 'POST', { profile: defaultProfile, requestId: 'same-run-id', prompt }, 'create');
  const id = created.id ?? created.session?.id;
  assert.match(id, /^ses_[a-f0-9]{16}$/);
  assert.equal((await request('/v1/sessions')).items.length, 1);
  const followUp = `Lane ${index} follow-up`;
  await request(`/v1/sessions/${id}/messages`, 'POST', { text: followUp }, 'send');
  let echoed = [];
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const { items } = await request(`/v1/sessions/${id}/conversation`);
    echoed = items.filter(({ role }) => role === 'assistant').map(({ text }) => text);
    if (echoed.includes(`Lab Echo: ${followUp}`)) break;
    await sleep(100);
  }
  assert.deepEqual(echoed, [`Lab Echo: ${prompt}`, `Lab Echo: ${followUp}`]);
  await request(`/v1/sessions/${id}`, 'PATCH', { archived: true }, 'archive');
  assert.equal((await request('/v1/sessions')).items.length, 0);
  const archived = (await request('/v1/sessions?archived=only')).items;
  assert.equal(archived.length, 1);
  assert.equal(archived[0].id, id);
  console.log(`lane ${index}: bridge :${lane.ports.bridge}, work fixture :${lane.ports.work}; handshake/cross-lane refusal/create/send/list/archive/synthetic usage/APNs sink OK`);
}

try {
  const started = await Promise.allSettled([up(), up()]);
  for (const result of started) if (result.status === 'rejected') throw result.reason;
  const [first, second] = started.map((result) => result.value);
  assert.notEqual(first.root, second.root);
  assert.notEqual(first.id, second.id);
  const ports = [...Object.values(first.ports), ...Object.values(second.ports)];
  assert.equal(new Set(ports).size, ports.length);
  const finished = await Promise.allSettled([workflow(first, 1, second), workflow(second, 2, first)]);
  for (const result of finished) if (result.status === 'rejected') throw result.reason;
} finally {
  const stopped = await Promise.allSettled(lanes.map(async ({ root }) => {
    await run('down', root);
    await assert.rejects(access(root), { code: 'ENOENT' });
    console.log(`down and root removed: ${root}`);
  }));
  for (const result of stopped) if (result.status === 'rejected') throw result.reason;
}

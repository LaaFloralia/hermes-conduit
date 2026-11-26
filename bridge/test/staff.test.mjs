import { test } from 'node:test';
import assert from 'node:assert/strict';
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startBridge } from './helpers.mjs';

const fixture = new URL('./fixtures/staff-roster.yaml', import.meta.url);
const endpoint = '/v1/staff';
const rosterFile = (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'laa-staff-test-'));
  const path = join(dir, 'roster.yaml');
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  copyFileSync(fixture, path);
  return path;
};

test('staff requires device auth and sessions:read; projects roster order and only public valid fields', async (t) => {
  const bridge = await startBridge({ staff: { path: rosterFile(t) } });
  t.after(() => bridge.close());
  assert.equal((await bridge.request(endpoint)).status, 401);
  assert.equal((await bridge.request(endpoint, { token: await bridge.token(['brain:read']) })).status, 403);
  const response = await bridge.request(endpoint, { token: await bridge.token(['sessions:read']) });
  assert.equal(response.status, 200);
  assert.deepEqual(response.body.data, { staff: [
    { id: 'zebra', profile: 'laa-zebra', name: 'Zebra', thinking: { base: 'Ready… ⚙️', alt: ['Waiting… 🐣'] } },
    { id: 'ant', profile: 'laa-ant', name: 'Ant' },
    { id: 'bad_json', profile: 'laa-bad_json', name: 'Bad JSON' },
    { id: 'blank_base', profile: 'laa-blank_base', name: 'Blank Base' },
    { id: 'bad_alt_type', profile: 'laa-bad_alt_type', name: 'Bad Alt Type' },
    { id: 'bad_alt_item', profile: 'laa-bad_alt_item', name: 'Bad Alt Item' },
    { id: 'blank_alt', profile: 'laa-blank_alt', name: 'Blank Alt' },
    { id: 'only_base', profile: 'laa-only_base', name: 'Only Base', thinking: { base: 'Valid', alt: [] } },
  ] });
});

test('staff falls back to an empty list and warns when the file cannot be read, even with a warmed cache', async (t) => {
  const path = rosterFile(t);
  const events = [];
  const bridge = await startBridge({ staff: { path }, log: (entry) => events.push(entry) });
  t.after(() => bridge.close());
  const token = await bridge.token();
  const expectUnreadable = async () => {
    const response = await bridge.request(endpoint, { token });
    assert.equal(response.status, 200);
    assert.deepEqual(response.body.data, { staff: [] });
  };
  assert.ok((await bridge.request(endpoint, { token })).body.data.staff.length > 0);
  const canDenyRead = process.getuid() !== 0;
  if (canDenyRead) {
    chmodSync(path, 0o000);
    await expectUnreadable();
    chmodSync(path, 0o600);
    assert.ok((await bridge.request(endpoint, { token })).body.data.staff.length > 0);
  }
  renameSync(path, `${path}.bak`);
  await expectUnreadable();
  mkdirSync(path);
  await expectUnreadable();
  assert.deepEqual(events.filter((entry) => entry.level === 'warn'), Array.from({ length: canDenyRead ? 3 : 2 }, () => ({
    level: 'warn', event: 'staff_roster_unreadable',
  })));
});

test('staff reuses the projection at the same mtime and reloads when it changes', async (t) => {
  const path = rosterFile(t);
  const initial = 1700000000;
  utimesSync(path, initial, initial);
  const bridge = await startBridge({ staff: { path } });
  t.after(() => bridge.close());
  const token = await bridge.token();
  const get = async () => (await bridge.request(endpoint, { token })).body.data.staff[0].name;
  assert.equal(await get(), 'Zebra');
  writeFileSync(path, readFileSync(path, 'utf8').replace('name: Zebra', 'name: Bison'));
  utimesSync(path, initial, initial);
  assert.equal(await get(), 'Zebra');
  utimesSync(path, initial + 1, initial + 1);
  assert.deepEqual(await Promise.all([get(), get()]), ['Bison', 'Bison']);
});

import assert from 'node:assert/strict';
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { startBridge } from './helpers.mjs';
import { createHabitService } from '../src/habits/service.mjs';
import { createHabitStore } from '../src/habits/store.mjs';

const NOW = Date.parse('2026-11-14T10:00:00Z');
async function boot(t, options = {}) {
  const api = await startBridge({ now: () => NOW, ...options });
  t.after(() => api.close());
  return { api, token: await api.token() };
}
const body = { kind: 'do', title: '走る', weeklyTarget: 2 };
const add = (api, token, value = body, key = 'k1') => api.request('/v1/habits', { token, method: 'POST', body: value, key });
const patch = (api, token, id, value, revision = '1') => api.request(`/v1/habits/${id}`, { token, method: 'PATCH', body: value, headers: revision === null ? {} : { 'if-match': revision } });
const check = (api, token, id, done, date = '2026-11-14') => api.request(`/v1/habits/${id}/checkins/${date}`, { token, method: 'PUT', body: { done } });

test('device token completes create/read/check/update/archive/restore and survives a restart', async (t) => {
  const { api, token } = await boot(t);
  assert.deepEqual((await api.request('/v1/habits', { token })).body.data.items, []);
  const created = await add(api, token, { ...body, note: 'memo', minutes: 20, minimum: '5分' });
  assert.equal(created.status, 201); assert.equal(created.headers.get('etag'), '"1"');
  const h = created.body.data;
  assert.equal(h.targets, undefined);
  const replayed = await add(api, token, { ...body, note: 'memo', minutes: 20, minimum: '5分' });
  assert.equal(replayed.status, 200); assert.equal(replayed.headers.get('idempotency-replayed'), 'true'); assert.equal(replayed.body.data.id, h.id);
  const checked = await check(api, token, h.id, true);
  assert.equal(checked.status, 200); assert.deepEqual(checked.body.data, { habitId: h.id, date: '2026-11-14', done: true, week: { start: '2026-11-09', count: 1, target: 2, met: false } });
  assert.equal((await check(api, token, h.id, true)).status, 200);
  assert.equal((await api.request('/v1/habits/events', { token })).body.data.items.length, 2);
  assert.equal((await check(api, token, h.id, false)).body.data.week.count, 0);
  const updated = await patch(api, token, h.id, { title: '歩く', weeklyTarget: 1 }, '"1"');
  assert.equal(updated.status, 200); assert.equal(updated.headers.get('etag'), '"2"');
  assert.equal((await patch(api, token, h.id, { title: '歩く' }, '2')).headers.get('etag'), '"2"');
  assert.equal((await patch(api, token, h.id, { archived: true }, '2')).status, 200);
  assert.equal((await api.request('/v1/habits/archived', { token })).body.data.items[0].id, h.id);
  assert.equal((await check(api, token, h.id, true)).body.error.code, 'habit_archived');
  assert.equal((await patch(api, token, h.id, { title: 'x' }, '3')).status, 409);
  assert.equal((await patch(api, token, h.id, { archived: false }, '3')).headers.get('etag'), '"4"');
  await api.restart();
  const week = (await api.request('/v1/habits', { token })).body.data;
  assert.equal(week.items.length, 1); assert.equal(week.items[0].title, '歩く'); assert.equal(week.items[0].revision, 4);
  assert.deepEqual((await api.request('/v1/habits/history?weeks=8', { token })).body.data.weeks, []);
  const events = (await api.request('/v1/habits/events?limit=2', { token })).body.data;
  assert.equal(events.items.length, 2); assert.ok(events.nextCursor);
  assert.equal(events.items[0].type, 'habit.restored');
  assert.equal((await api.request(`/v1/habits/events?limit=2&cursor=${events.nextCursor}`, { token })).body.data.items.length, 2);
});

test('every endpoint requires authentication and enforces read/write scopes before service calls', async (t) => {
  const { api, token } = await boot(t); const h = (await add(api, token)).body.data;
  const readOnly = await api.token(['tasks:read']);
  const other = await api.token(['calendar:read']);
  const reads = ['/v1/habits', '/v1/habits/history', '/v1/habits/archived', '/v1/habits/events'];
  const writes = [
    ['/v1/habits', 'POST', body],
    [`/v1/habits/${h.id}`, 'PATCH', { title: 'x' }],
    [`/v1/habits/${h.id}/checkins/2026-11-14`, 'PUT', { done: true }],
  ];
  for (const path of reads) {
    assert.equal((await api.request(path)).status, 401);
    assert.equal((await api.request(path, { token: other })).status, 403);
    assert.equal((await api.request(path, { token: readOnly })).status, 200);
  }
  for (const [path, method, value] of writes) {
    assert.equal((await api.request(path, { method, body: value })).status, 401);
    assert.equal((await api.request(path, { method, token: readOnly, body: value })).status, 403);
  }
  // Write responses carry the habit or its week, so write-only access is refused
  // and nothing about the habit leaks through the refusal.
  const writeOnly = await api.token(['tasks:write']);
  for (const [path, method, value] of writes) {
    const refused = await api.request(path, { method, token: writeOnly, body: value,
      headers: { 'idempotency-key': 'write-only-1', 'if-match': `"${h.revision}"` } });
    assert.equal(refused.status, 403);
    assert.equal(refused.body.error.code, 'insufficient_scope');
    assert.equal(JSON.stringify(refused.body).includes(h.title), false);
  }
  assert.equal((await api.request('/v1/habits', { token })).body.data.items.length, 1);
});

test('HTTP rejects keys, unknown fields, invalid dates and stale/missing If-Match with contract codes', async (t) => {
  const { api, token } = await boot(t);
  assert.equal((await api.request('/v1/habits', { token, method: 'POST', body })).body.error.code, 'idempotency_key_required');
  assert.equal((await add(api, token, body, 'bad key')).body.error.code, 'idempotency_key_invalid');
  const h = (await add(api, token)).body.data;
  const missing = await patch(api, token, h.id, { title: 'x' }, null);
  assert.equal(missing.status, 428); assert.equal(missing.body.error.code, 'habit_if_match_required');
  const stale = await patch(api, token, h.id, { title: 'x' }, '2');
  assert.equal(stale.status, 412); assert.equal(stale.body.error.code, 'habit_revision_mismatch'); assert.equal(stale.body.error.details.revision, 1);
  for (const value of [{ kind: 'avoid' }, { unknown: 'x' }, { weeklyTarget: 0 }, { support: 'x' }]) {
    const response = await patch(api, token, h.id, value);
    assert.equal(response.status, 400); assert.equal(response.body.error.code, 'habit_invalid'); assert.equal(response.body.error.details.field, Object.keys(value)[0]);
  }
  assert.equal((await patch(api, token, 'missing', {})).status, 404);
  for (const [date, expected] of [['2026-11-15', 'habit_date_future'], ['2026-11-08', 'habit_date_before_start'], ['2026-02-30', 'habit_date_invalid']]) {
    assert.equal((await check(api, token, h.id, true, date)).body.error.code, expected);
  }
  assert.equal((await api.request('/v1/habits?week=bad', { token })).body.error.code, 'habit_week_invalid');
  assert.equal((await api.request('/v1/habits/history?weeks=27', { token })).status, 400);
  assert.equal((await api.request('/v1/habits/events?limit=101', { token })).status, 400);
});

test('concurrent retried creates are atomic, scoped to a device, and return exactly one habit', async (t) => {
  const { api, token } = await boot(t);
  const responses = await Promise.all(Array.from({ length: 8 }, () => add(api, token)));
  assert.equal(responses.filter((r) => r.status === 201).length, 1);
  assert.equal(responses.filter((r) => r.status === 200).length, 7);
  assert.equal(new Set(responses.map((r) => r.body.data.id)).size, 1);
  const secondToken = await api.token();
  assert.equal((await add(api, secondToken)).status, 201);
  assert.equal((await api.request('/v1/habits', { token })).body.data.items.length, 2);
});

test('HTTP is always owner, may change support, and never takes actor metadata from the body', async (t) => {
  const { api, token } = await boot(t);
  const h = (await add(api, token, { ...body, support: 'off' })).body.data;
  assert.equal((await api.request('/v1/habits', { token })).body.data.items[0].title, body.title);
  assert.equal((await patch(api, token, h.id, { support: 'plan' })).status, 200);
  const forged = await add(api, token, { ...body, actor: 'agent' }, 'forged');
  assert.equal(forged.body.error.code, 'habit_invalid');
  const events = (await api.request('/v1/habits/events', { token })).body.data.items;
  assert.equal(events.every((e) => e.actor === 'owner' && e.agent === null && e.reason === null), true);
});

for (const configured of [false, true]) test(`habits remain independent with Google Calendar ${configured ? 'throwing' : 'unconfigured'}`, async (t) => {
  let calls = 0;
  const service = new Proxy({}, { get() { return () => { calls++; throw new Error('calendar unavailable'); }; } });
  const { api, token } = await boot(t, configured ? { calendar: { service } } : {});
  const h = (await add(api, token)).body.data;
  assert.equal((await check(api, token, h.id, true)).status, 200);
  assert.equal((await patch(api, token, h.id, { archived: true })).status, 200);
  for (const path of ['/v1/habits', '/v1/habits/history', '/v1/habits/archived', '/v1/habits/events']) assert.equal((await api.request(path, { token })).status, 200);
  assert.equal((await patch(api, token, h.id, { archived: false }, '2')).status, 200);
  assert.equal(calls, 0, 'no habits operation may touch Calendar');
});

test('habit source imports no Google/Calendar/Linear/Brain module', () => {
  const root = new URL('../src/habits/', import.meta.url);
  const sources = readdirSync(root).filter((name) => name.endsWith('.mjs')).map((name) => new URL(name, root));
  sources.push(new URL('../src/routes/habits.mjs', import.meta.url));
  for (const file of sources) {
    const source = readFileSync(file, 'utf8');
    const imports = [...source.matchAll(/(?:from\s*|import\s*\(\s*|import\s*)['"]([^'"]+)['"]/g)].map((m) => m[1]);
    assert.equal(imports.some((path) => /(?:calendar\/|google\/|tasks\/linear|brain\/)/.test(path)), false, file.pathname);
  }
});

test('HTTP preserves corrupt habits data and reports state_corrupt', async (t) => {
  const { api, token } = await boot(t);
  const path = join(api.stateDir, 'habits.json'); writeFileSync(path, '{broken');
  assert.equal((await api.request('/v1/habits', { token })).body.error.code, 'state_corrupt');
  const refused = await add(api, token);
  assert.equal(refused.status, 500); assert.equal(refused.body.error.code, 'state_corrupt');
  assert.equal(readFileSync(path, 'utf8'), '{broken');
});

test('route options accept service and store injection', async (t) => {
  const injected = { week: () => ({ items: [], marker: 'injected' }) };
  const { api, token } = await boot(t, { habits: { service: injected } });
  assert.equal((await api.request('/v1/habits', { token })).body.data.marker, 'injected');
  const state = { schema: 1, habits: [], events: [], checkins: {}, ops: {} };
  const store = { read: () => state, mutate: (fn) => fn(state) };
  const second = await boot(t, { habits: { store } });
  await add(second.api, second.token);
  assert.equal(state.habits.length, 1);
  assert.equal(createHabitService({ store: createHabitStore({ dir: second.api.stateDir }) }).week().items.length, 0);
});

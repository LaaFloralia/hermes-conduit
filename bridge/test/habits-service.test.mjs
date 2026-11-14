import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { createHabitStore } from '../src/habits/store.mjs';
import { createHabitService } from '../src/habits/service.mjs';
import { addDays } from '../src/habits/dates.mjs';

function fixture(t, start = '2026-11-14T10:00:00Z') {
  const dir = mkdtempSync(join(tmpdir(), 'laa-habits-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  let time = Date.parse(start);
  const now = () => time;
  const store = createHabitStore({ dir, now });
  const service = createHabitService({ store, now });
  let key = 0;
  const add = (body = {}, context = {}) => service.create({ key: `k${++key}`, body: { kind: 'do', title: '走る', weeklyTarget: 3, ...body }, ...context }).habit;
  const update = (habit, body, context = {}) => service.update({ id: habit.id, ifMatch: habit.revision, body, ...context });
  const check = (habit, date = service.today(), done = true, context = {}) => service.check({ id: habit.id, date, body: { done }, ...context });
  return { dir, now, store, service, add, update, check, at: (iso) => { time = Date.parse(iso); } };
}
const code = (expected, field) => (error) => {
  assert.equal(error.code, expected);
  if (field) assert.equal(error.details?.field, field);
  return true;
};
const agent = { actor: 'agent', agent: 'Monet', reason: '社長の依頼' };

test('empty state creates nothing; defaults and persisted reread have no internal targets', (t) => {
  const f = fixture(t);
  assert.deepEqual(f.service.week().items, []);
  assert.deepEqual(readdirSync(f.dir), []);
  const h = f.add({ title: '  走る  ' });
  assert.equal(h.title, '走る');
  assert.equal(h.note, ''); assert.equal(h.minutes, null); assert.equal(h.minimum, null); assert.equal(h.support, 'ask');
  assert.equal(h.revision, 1); assert.equal(h.createdOn, '2026-11-14');
  assert.equal(h.archivedAt, null); assert.equal(h.targets, undefined);
  assert.equal(statSync(f.dir).mode & 0o777, 0o700);
  assert.equal(statSync(f.store.file).mode & 0o777, 0o600);
  const reread = createHabitService({ store: createHabitStore({ dir: f.dir, now: f.now }), now: f.now });
  assert.deepEqual(reread.week().items[0], f.service.week().items[0]);
  assert.deepEqual(f.store.read().habits[0].targets, [{ from: '2026-11-09', weeklyTarget: 3 }]);
});

test('updates, archive, restore and no-op updates preserve the documented revisions', (t) => {
  const f = fixture(t); let h = f.add();
  const before = readFileSync(f.store.file, 'utf8');
  assert.equal(f.update(h, { title: h.title }).revision, 1);
  assert.equal(readFileSync(f.store.file, 'utf8'), before);
  h = f.update(h, { title: '新しい名前', note: '非公開のメモ', minutes: 20, minimum: '5分', support: 'plan' });
  assert.equal(h.revision, 2);
  h = f.update(h, { archived: true });
  assert.equal(h.revision, 3); assert.equal(h.archivedOn, '2026-11-14');
  const archivedState = readFileSync(f.store.file, 'utf8');
  assert.equal(f.update(h, { archived: true }).revision, 3);
  assert.equal(readFileSync(f.store.file, 'utf8'), archivedState);
  assert.deepEqual(f.service.week().items, []); assert.equal(f.service.week().archivedCount, 1);
  assert.equal(f.service.archived().items[0].id, h.id);
  assert.throws(() => f.update(h, { title: '不可' }), code('habit_archived'));
  assert.throws(() => f.check(h), code('habit_archived'));
  h = f.update(h, { archived: false });
  assert.equal(h.revision, 4); assert.equal(h.archivedOn, null);
  assert.equal(f.service.week().items[0].id, h.id);
  assert.deepEqual(f.service.archived().items, []);
  h = f.update(h, { minutes: null, minimum: null });
  assert.equal(h.minutes, null); assert.equal(h.minimum, null);
});

test('If-Match is required, validated, and checked inside the storage lock', (t) => {
  const f = fixture(t); const h = f.add();
  assert.throws(() => f.service.update({ id: h.id, body: {} }), code('habit_if_match_required'));
  for (const value of ['W/"1"', '1x', '0', '01']) assert.throws(() => f.service.update({ id: h.id, ifMatch: value, body: {} }), code('habit_invalid', 'ifMatch'));
  assert.equal(f.service.update({ id: h.id, ifMatch: '"1"', body: { title: 'new' } }).revision, 2);
  assert.throws(() => f.update(h, { note: 'stale' }), (error) => {
    assert.equal(error.status, 412); assert.equal(error.code, 'habit_revision_mismatch'); assert.equal(error.details.revision, 2); return true;
  });
  assert.throws(() => f.service.update({ id: 'missing', ifMatch: '1', body: {} }), code('habit_not_found'));
});

const invalidBodies = [
  [{ kind: 'other' }, 'kind'], [{ title: '' }, 'title'], [{ title: '   ' }, 'title'], [{ title: 'x'.repeat(81) }, 'title'],
  [{ title: 'a\nb' }, 'title'], [{ title: 'a\u0000b' }, 'title'], [{ title: 2 }, 'title'],
  [{ weeklyTarget: 0 }, 'weeklyTarget'], [{ weeklyTarget: 8 }, 'weeklyTarget'], [{ weeklyTarget: 1.5 }, 'weeklyTarget'], [{ weeklyTarget: '3' }, 'weeklyTarget'],
  [{ note: 'x'.repeat(501) }, 'note'], [{ note: null }, 'note'], [{ minutes: 0 }, 'minutes'], [{ minutes: 601 }, 'minutes'], [{ minutes: 1.1 }, 'minutes'],
  [{ minimum: '' }, 'minimum'], [{ minimum: 'x'.repeat(81) }, 'minimum'], [{ minimum: 1 }, 'minimum'], [{ support: 'yes' }, 'support'],
  [{ unknown: true }, 'unknown'], [{ id: 'reserved' }, 'id'], [{ revision: 3 }, 'revision'], [{ archived: true }, 'archived'],
];
for (const [body, field] of invalidBodies) test(`creation rejects invalid ${JSON.stringify(body).slice(0, 65)}`, (t) => {
  const f = fixture(t);
  assert.throws(() => f.add(body), code('habit_invalid', field));
  assert.deepEqual(f.service.week().items, []);
});

test('field boundaries, Unicode character counts, unknown patch/check fields and immutable kind', (t) => {
  const f = fixture(t);
  const h = f.add({ title: '🌷'.repeat(80), note: 'a'.repeat(500), minutes: 600, minimum: 'a'.repeat(80), weeklyTarget: 7 });
  assert.equal([...h.title].length, 80);
  assert.equal(f.add({ kind: 'avoid', weeklyTarget: 0 }).weeklyTarget, 0);
  for (const field of ['kind', 'id', 'createdAt', 'targets', 'bogus']) assert.throws(() => f.update(h, { [field]: 'x' }), code('habit_invalid', field));
  assert.throws(() => f.update(h, { archived: 'yes' }), code('habit_invalid', 'archived'));
  assert.throws(() => f.service.check({ id: h.id, date: '2026-11-14', body: { done: 1 } }), code('habit_invalid', 'done'));
  assert.throws(() => f.service.check({ id: h.id, date: '2026-11-14', body: { done: true, note: 'x' } }), code('habit_invalid', 'note'));
});

test('create replays per principal without duplicate habits or events and expires after seven days', (t) => {
  const f = fixture(t);
  const request = { principal: 'phone1', key: 'same', body: { kind: 'do', title: 'A', weeklyTarget: 1 } };
  const first = f.service.create(request);
  const original = readFileSync(f.store.file, 'utf8');
  const replay = f.service.create(request);
  assert.equal(replay.status, 200); assert.equal(replay.replayed, true); assert.equal(replay.habit.id, first.habit.id);
  assert.equal(readFileSync(f.store.file, 'utf8'), original);
  assert.equal(f.service.create({ ...request, principal: 'phone2' }).status, 201);
  assert.equal(f.store.read().habits.length, 2);
  f.at('2026-11-21T10:00:00Z');
  assert.equal(f.service.create(request).status, 201);
  assert.equal(Object.keys(f.store.read().ops).length, 1);
  for (const key of [undefined, '']) assert.throws(() => f.service.create({ ...request, key }), code('idempotency_key_required'));
  for (const key of ['bad space', 'a'.repeat(201), 'x/y']) assert.throws(() => f.service.create({ ...request, key }), code('idempotency_key_invalid'));
});

test('Tokyo Sunday-to-Monday boundary uses a UTC date that is still Sunday', (t) => {
  const f = fixture(t, '2026-11-15T14:59:59Z'); f.add();
  assert.equal(f.service.today(), '2026-11-15');
  assert.equal(f.service.week().week.start, '2026-11-09');
  f.at('2026-11-15T15:00:00Z');
  const week = f.service.week();
  assert.equal(week.today, '2026-11-16'); assert.equal(week.week.start, '2026-11-16'); assert.equal(week.week.end, '2026-11-22');
  assert.equal(week.week.current, true); assert.equal(week.timeZone, 'Asia/Tokyo');
  assert.equal(f.service.week({ week: '2026-11-15' }).week.current, false);
});

test('the year-crossing week contains exactly 2026-12-28 through 2027-01-03', (t) => {
  const f = fixture(t, '2027-01-01T00:00:00Z');
  const h = f.add({ weeklyTarget: 1 }); f.check(h, '2026-12-28');
  const week = f.service.week();
  assert.deepEqual(week.week.days, ['2026-12-28', '2026-12-29', '2026-12-30', '2026-12-31', '2027-01-01', '2027-01-02', '2027-01-03']);
  assert.equal(week.items[0].count, 1); assert.equal(week.items[0].met, true);
});

test('week/date bounds and malformed dates never roll into another month', (t) => {
  const f = fixture(t); const h = f.add();
  for (const date of ['2019-12-31', '2026-02-30', '2026-2-03', '', 'bad', '2027-11-16']) assert.throws(() => f.service.week({ week: date }), code('habit_week_invalid'));
  assert.equal(f.service.week({ week: '2020-01-01' }).week.start, '2019-12-30');
  assert.equal(f.service.week({ week: '2027-11-15' }).week.start, '2027-11-15');
  for (const date of ['2026-02-30', '2026-11-1', 'bad']) assert.throws(() => f.check(h, date), code('habit_date_invalid'));
  assert.throws(() => f.check(h, '2026-11-15'), code('habit_date_future'));
  assert.throws(() => f.check(h, '2026-11-08'), code('habit_date_before_start'));
  assert.equal(f.check(h, '2026-11-09').done, true);
});

test('check/uncheck are idempotent, sorted and leave the habit revision unchanged', (t) => {
  const f = fixture(t); const h = f.add({ weeklyTarget: 2 });
  assert.equal(f.check(h, '2026-11-14').week.met, false);
  assert.equal(f.check(h, '2026-11-10').week.met, true);
  assert.deepEqual(f.store.read().checkins[h.id], ['2026-11-10', '2026-11-14']);
  const original = readFileSync(f.store.file, 'utf8');
  f.check(h, '2026-11-10'); assert.equal(readFileSync(f.store.file, 'utf8'), original);
  assert.equal(f.check(h, '2026-11-10', false).week.count, 1);
  const after = readFileSync(f.store.file, 'utf8');
  f.check(h, '2026-11-10', false); assert.equal(readFileSync(f.store.file, 'utf8'), after);
  assert.equal(f.service.week().items[0].revision, 1);
  assert.deepEqual(f.service.events().items.map((e) => e.type), ['checkin.cleared', 'checkin.set', 'checkin.set', 'habit.created']);
});

test('avoid counts days of doing the prohibited habit and compares against a maximum', (t) => {
  const f = fixture(t); const h = f.add({ kind: 'avoid', weeklyTarget: 0 });
  assert.equal(f.service.week().items[0].met, true);
  assert.equal(f.check(h).week.met, false);
  assert.equal(f.check(h, undefined, false).week.met, true);
});

test('targets apply from the edited week while historical target and met stay unchanged', (t) => {
  const f = fixture(t, '2026-11-11T00:00:00Z'); let h = f.add({ weeklyTarget: 3 });
  f.check(h, '2026-11-09'); f.check(h, '2026-11-10');
  f.at('2026-11-16T00:00:00Z'); h = f.update(h, { weeklyTarget: 2 });
  let history = f.service.history();
  assert.equal(history.weeks.length, 1); assert.equal(history.weeks[0].items[0].target, 3); assert.equal(history.weeks[0].items[0].met, false);
  f.check(h, '2026-11-16'); f.check(h, '2026-11-15');
  assert.equal(f.service.week({ week: '2026-11-15' }).items[0].met, true);
  h = f.update(h, { weeklyTarget: 1 });
  assert.equal(f.service.week().items[0].target, 1);
  assert.equal(f.store.read().habits[0].targets.length, 2);
  f.at('2026-11-23T00:00:00Z');
  history = f.service.history({ weeks: 26 });
  assert.deepEqual(history.weeks.map((w) => [w.start, w.items[0].target, w.items[0].met]), [['2026-11-16', 1, true], ['2026-11-09', 3, true]]);
  assert.equal(f.service.week({ week: '2026-11-02' }).items.length, 0);
});

test('ordering, archive week exclusion and restoration are consistent across week/history', (t) => {
  const f = fixture(t, '2026-11-02T00:00:00Z');
  f.add({ title: 'avoid', kind: 'avoid', weeklyTarget: 1 });
  const a = f.add({ title: 'first' });
  f.at('2026-11-03T00:00:00Z'); f.add({ title: 'second' });
  assert.deepEqual(f.service.week().items.map((h) => h.title), ['first', 'second', 'avoid']);
  f.at('2026-11-11T00:00:00Z'); let h = f.update(a, { archived: true });
  assert.equal(f.service.week().items.some((h) => h.id === a.id), false);
  assert.equal(f.service.history().weeks[0].items.some((h) => h.id === a.id), true);
  f.at('2026-11-16T00:00:00Z');
  assert.equal(f.service.history().weeks[0].items.some((h) => h.id === a.id), false);
  h = f.update(h, { archived: false });
  assert.equal(f.service.history().weeks[0].items.some((h) => h.id === a.id), true);
  assert.equal(f.service.week().items.some((h) => h.id === a.id), true);
});

test('events retain actor, agent, reason and historical title, redact note contents and paginate', (t) => {
  const f = fixture(t); let h = f.add({ note: 'secret original' });
  h = f.update(h, { title: '新名', note: 'secret changed' }, agent);
  f.check(h, undefined, true, agent);
  const first = f.service.events({ limit: 2 });
  assert.equal(first.items.length, 2); assert.ok(first.nextCursor);
  assert.equal(first.items[0].date, '2026-11-14');
  assert.equal(first.items[1].actor, 'agent'); assert.equal(first.items[1].agent, 'Monet'); assert.equal(first.items[1].reason, '社長の依頼');
  assert.deepEqual(first.items[1].changes.note, { fromLength: 15, toLength: 14 });
  assert.equal(JSON.stringify(f.service.events()).includes('secret'), false);
  const last = f.service.events({ cursor: first.nextCursor, limit: 2 });
  assert.equal(last.items[0].title, '走る'); assert.equal(last.items[0].actor, 'owner'); assert.equal(last.items[0].agent, null); assert.equal(last.items[0].reason, null);
  assert.equal(last.nextCursor, null);
  assert.throws(() => f.service.events({ cursor: 'bogus' }), code('habit_invalid', 'cursor'));
  for (const value of [0, 101, 1.2, '', 'x']) assert.throws(() => f.service.events({ limit: value }), code('habit_invalid', 'limit'));
  for (const value of [0, 27, 1.2, '', 'x']) assert.throws(() => f.service.history({ weeks: value }), code('habit_invalid', 'weeks'));
});

test('agent paths withhold off content in week/history/events and reject all off writes', (t) => {
  const f = fixture(t, '2026-11-02T00:00:00Z');
  const hidden = f.add({ title: 'PRIVATE', note: 'SECRET', support: 'off' });
  const shown = f.add({ title: 'public', support: 'plan' });
  f.at('2026-11-16T00:00:00Z');
  for (const method of ['week', 'history', 'events']) {
    const result = f.service[method]({ actor: 'agent' });
    assert.equal(result.withheld, 1); assert.equal(JSON.stringify(result).includes('PRIVATE'), false); assert.equal(JSON.stringify(result).includes(hidden.id), false);
  }
  assert.throws(() => f.update(hidden, { title: 'x' }, agent), code('habit_support_off'));
  assert.throws(() => f.update(hidden, { archived: true }, agent), code('habit_support_off'));
  assert.throws(() => f.check(hidden, undefined, true, agent), code('habit_support_off'));
  assert.throws(() => f.update(shown, { support: 'off' }, agent), code('habit_support_owner_only'));
  assert.throws(() => f.add({ support: 'ask' }, agent), code('habit_support_owner_only'));
  assert.equal(f.add({}, agent).support, 'ask');
  for (const context of [{ actor: 'agent' }, { ...agent, agent: '' }, { ...agent, reason: '' }, { ...agent, reason: 'x'.repeat(201) }]) {
    assert.throws(() => f.update(shown, { title: 'x' }, context), code('habit_invalid'));
  }
  const result = f.service.create({ key: 'hidden-replay', principal: 'cli:Monet', body: { kind: 'do', title: 'created', weeklyTarget: 1 }, ...agent });
  f.update(result.habit, { support: 'off' });
  assert.throws(() => f.service.create({ key: 'hidden-replay', principal: 'cli:Monet', body: {}, ...agent }), code('habit_support_off'));
});

test('backup takes the previous contents on first changed write of a Tokyo day and retains thirty', (t) => {
  const f = fixture(t, '2026-10-01T00:00:00Z'); let h = f.add();
  let prior = readFileSync(f.store.file, 'utf8');
  for (let i = 1; i <= 32; i++) {
    const day = addDays('2026-10-01', i); f.at(`${day}T00:00:00Z`);
    h = f.update(h, { title: `day ${i}` });
    const path = join(f.dir, 'habits-backups', `habits-${day}.json`);
    assert.equal(readFileSync(path, 'utf8'), prior);
    assert.equal(statSync(path).mode & 0o777, 0o600);
    const snapshot = readFileSync(path, 'utf8');
    h = f.update(h, { note: `note ${i}` });
    assert.equal(readFileSync(path, 'utf8'), snapshot);
    prior = readFileSync(f.store.file, 'utf8');
  }
  const names = readdirSync(join(f.dir, 'habits-backups')).sort();
  assert.equal(names.length, 30); assert.equal(names[0], 'habits-2026-10-04.json');
  assert.equal(statSync(join(f.dir, 'habits-backups')).mode & 0o777, 0o700);
  f.at('2026-11-02T15:00:00Z');
  f.update(h, { title: h.title });
  assert.equal(readdirSync(join(f.dir, 'habits-backups')).includes('habits-2026-11-03.json'), false);
  f.update(h, { title: 'next Tokyo day' });
  assert.equal(readFileSync(join(f.dir, 'habits-backups/habits-2026-11-03.json'), 'utf8'), prior);
});

test('corrupt JSON and invalid state shapes fail closed without overwriting or backing up', (t) => {
  const f = fixture(t);
  for (const raw of ['{broken', '{"schema":2}', '{"schema":1,"habits":{},"events":[],"checkins":{},"ops":{}}', '{"schema":1,"habits":[{}],"events":[],"checkins":{},"ops":{}}']) {
    writeFileSync(f.store.file, raw);
    assert.throws(() => f.service.week(), code('state_corrupt'));
    assert.throws(() => f.add(), code('state_corrupt'));
    assert.equal(readFileSync(f.store.file, 'utf8'), raw);
  }
  assert.deepEqual(readdirSync(f.dir), ['habits.json']);
});

test('event storage retains the newest 2000 entries', (t) => {
  const f = fixture(t); const h = f.add();
  f.store.mutate((state) => {
    state.events = Array.from({ length: 2000 }, (_, i) => ({ id: `event${i}`, habitId: h.id }));
  });
  f.check(h);
  assert.equal(f.store.read().events.length, 2000);
  assert.equal(f.store.read().events[0].type, 'checkin.set');
  assert.equal(f.store.read().events.at(-1).id, 'event1998');
});

test('a successful update prunes expired creation operations without creating another habit', (t) => {
  const f = fixture(t); const h = f.add();
  f.at('2026-11-21T10:00:00Z');
  f.update(h, { title: 'updated' });
  assert.equal(Object.keys(f.store.read().ops).length, 0);
  assert.equal(f.store.read().habits.length, 1);
});

test('invalid persisted habit fields and duplicate dates are corruption, never silently repaired', (t) => {
  const f = fixture(t); const h = f.add();
  const original = readFileSync(f.store.file, 'utf8');
  for (const mutate of [
    (state) => { delete state.habits[0].title; },
    (state) => { state.habits[0].targets = [{ from: '2026-11-10', weeklyTarget: 3 }]; },
    (state) => { state.checkins[h.id] = ['2026-11-14', '2026-11-14']; },
  ]) {
    const state = JSON.parse(original); mutate(state); const raw = JSON.stringify(state); writeFileSync(f.store.file, raw);
    assert.throws(() => f.update(h, { note: 'refused' }), code('state_corrupt'));
    assert.equal(readFileSync(f.store.file, 'utf8'), raw);
  }
});

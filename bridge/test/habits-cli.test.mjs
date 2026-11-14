import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { habitsCommand } from '../src/cli-habits.mjs';
import { createHabitStore } from '../src/habits/store.mjs';
import { createHabitService } from '../src/habits/service.mjs';

const CLI = new URL('../src/cli.mjs', import.meta.url).pathname;
function fixture(t) {
  const dir = mkdtempSync(join(tmpdir(), 'laa-habits-cli-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const run = (...args) => {
    const result = spawnSync(process.execPath, [CLI, 'habits', ...args, '--json'], { env: { ...process.env, LAA_BRIDGE_STATE_DIR: dir }, encoding: 'utf8', timeout: 10000 });
    assert.equal(result.error, undefined);
    return { ...result, data: result.stdout ? JSON.parse(result.stdout) : null };
  };
  const store = createHabitStore({ dir }); const service = createHabitService({ store });
  const add = (...args) => run('add', '--by', 'Monet', '--reason', '社長の依頼', '--request-id', 'k1', '--kind', 'do', '--title', '走る', '--target', '3', ...args);
  const by = ['--by', 'Monet', '--reason', '社長の依頼'];
  return { dir, run, store, service, add, by };
}

test('CLI add/replay/week/check/uncheck/update/archive/restore use the shared persisted service', (t) => {
  const f = fixture(t);
  const added = f.add('--minutes', '20', '--minimum', '5分', '--note', 'メモ');
  assert.equal(added.status, 0, added.stderr); assert.equal(added.data.ok, true); assert.equal(added.data.habit.support, 'ask');
  const h = added.data.habit; assert.equal(f.add().data.habit.id, h.id); assert.equal(f.store.read().habits.length, 1);
  assert.equal(f.run('week').data.items[0].id, h.id);
  assert.equal(f.run('check', '--id', h.id, '--date', 'today', ...f.by).data.done, true);
  const before = f.store.read().events.length;
  assert.equal(f.run('check', '--id', h.id, '--date', 'today', ...f.by).status, 0);
  assert.equal(f.store.read().events.length, before);
  assert.equal(f.run('uncheck', '--id', h.id, '--date', 'today', ...f.by).data.done, false);
  const edited = f.run('update', '--id', h.id, '--if-match', '1', ...f.by, '--title', '歩く', '--target', '2', '--clear-minutes', '--clear-minimum');
  assert.equal(edited.status, 0, edited.stderr); assert.equal(edited.data.habit.revision, 2); assert.equal(edited.data.habit.minutes, null); assert.equal(edited.data.habit.minimum, null);
  const archived = f.run('archive', '--id', h.id, '--if-match', '2', ...f.by);
  assert.equal(archived.status, 0); assert.equal(f.run('week').data.items.length, 0);
  assert.equal(f.run('check', '--id', h.id, '--date', 'today', ...f.by).status, 4);
  assert.equal(f.run('restore', '--id', h.id, '--if-match', '3', ...f.by).data.habit.revision, 4);
  assert.equal(f.run('history', '--weeks', '8').status, 0);
  const events = f.run('events', '--limit', '100').data.items;
  assert.equal(events.every((e) => e.actor === 'agent' && e.agent === 'Monet' && e.reason === '社長の依頼'), true);
  assert.equal(JSON.stringify(events).includes('メモ'), false);
});

test('CLI excludes off habits in all reads and rejects off writes and --support', (t) => {
  const f = fixture(t);
  const h = f.service.create({ key: 'owner', body: { kind: 'avoid', title: 'PRIVATE', weeklyTarget: 0, support: 'off' } }).habit;
  for (const sub of ['week', 'history', 'events']) {
    const result = f.run(sub); assert.equal(result.status, 0); assert.equal(result.data.withheld, 1); assert.equal(result.stdout.includes('PRIVATE'), false); assert.equal(result.stdout.includes(h.id), false);
  }
  for (const args of [
    ['update', '--id', h.id, '--if-match', '1', '--title', 'x'],
    ['archive', '--id', h.id, '--if-match', '1'],
    ['restore', '--id', h.id, '--if-match', '1'],
    ['check', '--id', h.id, '--date', 'today'],
    ['uncheck', '--id', h.id, '--date', 'today'],
  ]) {
    const result = f.run(...args, ...f.by); assert.equal(result.status, 4); assert.equal(result.data.error.code, 'habit_support_off'); assert.equal(result.stdout.includes('PRIVATE'), false);
  }
  assert.equal(f.add('--support', 'plan').status, 2);
  assert.equal(f.run('update', '--id', h.id, '--if-match', '1', ...f.by, '--support', 'ask').status, 2);
});

test('CLI requires --by/--reason on every write, validates usage, and has the documented exit codes', (t) => {
  const f = fixture(t); const h = f.add().data.habit;
  const writes = [
    ['add', '--kind', 'do', '--title', 'A', '--target', '1', '--request-id', 'new'],
    ['update', '--id', h.id, '--if-match', '1', '--title', 'B'],
    ['archive', '--id', h.id, '--if-match', '1'], ['restore', '--id', h.id, '--if-match', '1'],
    ['check', '--id', h.id, '--date', 'today'], ['uncheck', '--id', h.id, '--date', 'today'],
  ];
  for (const args of writes) {
    assert.equal(f.run(...args, '--by', 'Monet').status, 2);
    assert.equal(f.run(...args, '--reason', '依頼').status, 2);
  }
  assert.equal(f.run('nonsense').status, 2);
  assert.equal(f.run('week', 'unexpected').status, 2);
  assert.equal(f.run('update', '--id', h.id, ...f.by, '--title', 'B').status, 2);
  assert.equal(f.run('update', '--id', h.id, '--if-match', '1', ...f.by, '--minutes', '10', '--clear-minutes').status, 2);
  assert.equal(f.run('update', '--id', 'missing', '--if-match', '1', ...f.by, '--title', 'B').status, 3);
  assert.equal(f.run('update', '--id', h.id, '--if-match', '2', ...f.by, '--title', 'B').status, 4);
  assert.equal(f.add('--request-id', 'invalid-target', '--target', '0').status, 5);
  assert.equal(f.add('--request-id', 'invalid-minutes', '--minutes', 'NaN').status, 5);
  assert.equal(f.add('--reason', 'x'.repeat(201)).status, 5);
  assert.equal(f.run('history', '--weeks', '27').status, 5);
  const missingValue = f.run('add', '--by');
  assert.equal(missingValue.status, 2); assert.equal(missingValue.data.error.code, 'usage_error');
  writeFileSync(join(f.dir, 'habits.json'), '{broken');
  assert.equal(f.run('week').status, 6); assert.equal(f.add().status, 6);
  assert.equal(readFileSync(join(f.dir, 'habits.json'), 'utf8'), '{broken');
});

test('CLI handles unavailable storage and unexpected failures without exposing internals', (t) => {
  const f = fixture(t);
  writeFileSync(join(f.dir, 'not-a-dir'), 'file');
  const result = spawnSync(process.execPath, [CLI, 'habits', 'week', '--json'], { env: { ...process.env, LAA_BRIDGE_STATE_DIR: join(f.dir, 'not-a-dir') }, encoding: 'utf8' });
  assert.equal(result.status, 6);
  let output = '';
  const status = habitsCommand(['week'], { json: true }, { service: { week: () => { throw new Error('SECRET'); } }, write: (s) => { output += s; }, writeErr() {} });
  assert.equal(status, 1); assert.equal(JSON.parse(output).error.code, 'internal_error'); assert.equal(output.includes('SECRET'), false);
});

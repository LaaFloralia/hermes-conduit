import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { createOwnerTaskStore } from '../src/tasks/owner-store.mjs';
import { createOwnerTaskService } from '../src/tasks/owner-service.mjs';

function tempDir(t) {
  const dir = mkdtempSync(join(tmpdir(), 'laa-owner-backup-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function clockAt(start = Date.parse('2026-11-01T00:00:00.000Z')) {
  let value = start;
  const now = () => value;
  now.advance = (ms) => { value += ms; };
  return now;
}

function boot(dir, now) {
  const store = createOwnerTaskStore({ dir, now });
  return { store, service: createOwnerTaskService({ store, now }) };
}

function seed(service, count = 5) {
  const ids = [];
  for (let i = 0; i < count; i += 1) {
    const result = service.create({
      principal: 'dev_a',
      key: `k${i}`,
      body: { title: `task ${i}`, memo: i % 2 === 0 ? `memo ${i}` : '', dueDate: i % 2 === 0 ? '2026-11-0' + ((i % 9) + 1) : null },
    });
    ids.push(result.task.id);
  }
  service.update({
    principal: 'dev_a', key: 'u1', method: 'PATCH', path: 'p', id: ids[0], ifMatch: 1, body: { status: 'doing' },
  });
  if (ids[1]) {
    service.update({
      principal: 'dev_a', key: 'u2', method: 'PATCH', path: 'p', id: ids[1], ifMatch: 1, body: { status: 'done', dueDate: null },
    });
  }
  return ids;
}

test('backup writes a checksummed 0600 snapshot outside the document directory', (t) => {
  const dir = tempDir(t);
  const now = clockAt();
  const { service } = boot(dir, now);
  seed(service);

  const result = service.backup();
  assert.equal(result.skipped, undefined);
  assert.equal(result.counts.tasks, 5);
  assert.equal(statSync(result.path).mode & 0o777, 0o600);
  assert.equal(statSync(join(dir, 'owner-tasks-backups')).mode & 0o777, 0o700);
  assert.match(result.stateSha256, /^sha256:[a-f0-9]{64}$/);
  assert.ok(result.bytes > 0);

  const snapshot = JSON.parse(readFileSync(result.path, 'utf8'));
  assert.equal(snapshot.format, 'laa-owner-tasks-snapshot');
  assert.equal(snapshot.version, 1);
  assert.equal(snapshot.state.tasks[Object.keys(snapshot.state.tasks)[0]].title.startsWith('task'), true);

  const status = service.status();
  assert.equal(status.backups, 1);
  assert.equal(status.lastBackup.file, result.path);
});

test('retention keeps the newest generations and leaves unrelated files alone', (t) => {
  const dir = tempDir(t);
  const now = clockAt();
  const { service } = boot(dir, now);
  seed(service, 1);

  const outDir = join(dir, 'backups');
  const paths = [];
  for (let day = 0; day < 5; day += 1) {
    paths.push(service.backup({ keep: 3, outDir }).path);
    now.advance(24 * 60 * 60 * 1000);
  }
  const kept = readdirSync(outDir).filter((name) => name.endsWith('.json')).sort();
  assert.equal(kept.length, 3);
  assert.deepEqual(kept, paths.slice(-3).map((path) => path.split('/').pop()).sort());

  writeFileSync(join(outDir, 'notes.txt'), 'keep me');
  const after = service.backup({ keep: 3, outDir });
  assert.equal(after.pruned.length, 1);
  assert.equal(readdirSync(outDir).includes('notes.txt'), true);
});

test('restore into another directory reproduces every task exactly', (t) => {
  const sourceDir = tempDir(t);
  const targetDir = tempDir(t);
  const now = clockAt();
  const source = boot(sourceDir, now);
  seed(source.service);

  const backup = source.service.backup();
  const restored = source.service.restore({ from: backup.path, to: targetDir });
  assert.equal(restored.counts.tasks, 5);
  assert.equal(restored.stateSha256, backup.stateSha256);
  assert.equal(restored.maxRevision, 2);

  const copy = boot(targetDir, now);
  const original = source.store.read();
  const replica = copy.store.read();
  assert.deepEqual(replica.tasks, original.tasks);
  assert.deepEqual(replica.operations, original.operations);

  // The restored store is writable and the copied ledger replays the same keys.
  const replay = copy.service.create({ principal: 'dev_a', key: 'k0', body: { title: 'task 0', memo: 'memo 0', dueDate: '2026-11-01' } });
  assert.equal(replay.replayed, true);
  assert.equal(replay.task.id, Object.keys(original.tasks)[0]);
});

test('a tampered or unreadable snapshot is refused', (t) => {
  const dir = tempDir(t);
  const now = clockAt();
  const { service } = boot(dir, now);
  seed(service, 1);
  const backup = service.backup();

  const snapshot = JSON.parse(readFileSync(backup.path, 'utf8'));
  snapshot.state.tasks[Object.keys(snapshot.state.tasks)[0]].title = 'tampered';
  writeFileSync(backup.path, `${JSON.stringify(snapshot)}\n`);
  assert.throws(() => service.restore({ from: backup.path, to: tempDir(t) }), (error) => (
    error.status === 400 && error.code === 'owner_tasks_snapshot_hash_mismatch'
  ));

  writeFileSync(backup.path, 'not json');
  assert.throws(() => service.restore({ from: backup.path, to: tempDir(t) }), (error) => (
    error.code === 'owner_tasks_snapshot_invalid'
  ));
});

test('restore refuses the live directory without --allow-live and an occupied target without --force', (t) => {
  const dir = tempDir(t);
  const target = tempDir(t);
  const now = clockAt();
  const { service } = boot(dir, now);
  seed(service, 2);
  const backup = service.backup();

  assert.throws(() => service.restore({ from: backup.path, to: dir }), (error) => (
    error.code === 'owner_tasks_restore_live_directory'
  ));
  assert.equal(service.restore({ from: backup.path, to: target }).counts.tasks, 2);
  assert.throws(() => service.restore({ from: backup.path, to: target }), (error) => (
    error.code === 'owner_tasks_restore_target_exists'
  ));
  assert.equal(service.restore({ from: backup.path, to: target, force: true }).counts.tasks, 2);
  // Restoring onto the live directory is possible only when asked for.
  assert.equal(service.restore({ from: backup.path, to: dir, allowLive: true, force: true }).counts.tasks, 2);
});

test('backup of a store that was never initialised is skipped, and a lost document still fails', (t) => {
  const dir = tempDir(t);
  const now = clockAt();
  const { service } = boot(dir, now);

  const skipped = service.backup();
  assert.equal(skipped.skipped, true);
  assert.equal(skipped.reason, 'not_initialized');

  seed(service, 1);
  service.backup();
  rmSync(join(dir, 'owner-tasks.json'));
  assert.throws(() => service.backup(), (error) => error.details.reason === 'missing');
});

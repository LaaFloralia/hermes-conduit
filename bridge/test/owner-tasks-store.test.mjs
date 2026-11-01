import assert from 'node:assert/strict';
import {
  mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, utimesSync, writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import {
  MAX_OPERATIONS,
  OPERATION_RETENTION_MS,
  OWNER_TASKS_FILE,
  OWNER_TASKS_MARKER,
  createOwnerTaskStore,
} from '../src/tasks/owner-store.mjs';
import { createOwnerTaskService } from '../src/tasks/owner-service.mjs';

function tempDir(t) {
  const dir = mkdtempSync(join(tmpdir(), 'laa-owner-store-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function clockAt(start = Date.parse('2026-11-01T00:00:00.000Z')) {
  let value = start;
  const now = () => value;
  now.advance = (ms) => { value += ms; };
  return now;
}

function boot(t, { dir = tempDir(t), now = clockAt(), lockTimeoutMs } = {}) {
  const store = createOwnerTaskStore({ dir, now, lockTimeoutMs });
  const service = createOwnerTaskService({ store, now });
  return { dir, store, service, now };
}

function seedDocument(dir, doc) {
  writeFileSync(join(dir, OWNER_TASKS_FILE), `${JSON.stringify(doc)}\n`, { mode: 0o600 });
  writeFileSync(join(dir, OWNER_TASKS_MARKER), `${JSON.stringify({ initializedAt: doc.createdAt })}\n`, { mode: 0o600 });
}

function emptyDoc(iso = '2026-11-01T00:00:00.000Z') {
  return {
    schema: 1,
    initialized: true,
    createdAt: iso,
    updatedAt: iso,
    tasks: {},
    operations: {},
    tombstones: {},
    imports: {},
    linearMap: {},
  };
}

const BODY = { title: '契約内容を確認する', dueDate: '2026-11-05' };

test('the first write initialises the document and the marker with owner-only permissions', (t) => {
  const { dir, service } = boot(t);
  assert.deepEqual(service.list().items, []);

  const result = service.create({ principal: 'dev_a', key: 'k1', body: BODY });
  assert.equal(result.status, 201);
  assert.equal(result.task.revision, 1);
  assert.deepEqual(readdirSync(dir).sort(), [OWNER_TASKS_MARKER, OWNER_TASKS_FILE].sort());
  assert.equal(statSync(join(dir, OWNER_TASKS_FILE)).mode & 0o777, 0o600);
  assert.equal(statSync(join(dir, OWNER_TASKS_MARKER)).mode & 0o777, 0o600);
  assert.equal(statSync(dir).mode & 0o777, 0o700);

  const doc = JSON.parse(readFileSync(join(dir, OWNER_TASKS_FILE), 'utf8'));
  assert.equal(Object.keys(doc.tasks).length, 1);
  assert.equal(Object.keys(doc.operations).length, 1);
  // The ledger keeps hashes, never the key or the task text.
  const entry = Object.values(doc.operations)[0];
  assert.equal(Object.hasOwn(entry, 'key'), false);
  assert.equal(JSON.stringify(entry).includes('契約内容'), false);
  assert.match(entry.principalHash, /^[a-f0-9]{64}$/);
});

test('an uninitialised store reads as empty and is not created by a read', (t) => {
  const { dir, store, service } = boot(t);
  const list = service.list();
  assert.deepEqual(list.items, []);
  assert.equal(list.total, 0);
  assert.deepEqual(list.counts, { open: 0, done: 0, canceled: 0 });
  assert.throws(() => service.get('11111111-1111-4111-8111-111111111111'), (error) => error.status === 404);
  assert.equal(readdirSync(dir).length, 0, 'a read must not create the store');
  assert.throws(() => store.read(), (error) => error.details.reason === 'missing');
});

test('a missing document after initialisation is never recreated as empty', (t) => {
  const { dir, service } = boot(t);
  service.create({ principal: 'dev_a', key: 'k1', body: BODY });
  rmSync(join(dir, OWNER_TASKS_FILE));

  assert.throws(() => service.list(), (error) => (
    error.status === 503 && error.code === 'owner_tasks_store_unavailable' && error.details.reason === 'missing'
  ));
  assert.throws(() => service.create({ principal: 'dev_a', key: 'k2', body: { title: 'x' } }), (error) => (
    error.details?.reason === 'missing'
  ));
  assert.equal(readdirSync(dir).includes(OWNER_TASKS_FILE), false, 'the empty document must not be written');
});

test('a corrupt document stops reads and writes and is left on disk', (t) => {
  const { dir, service } = boot(t);
  service.create({ principal: 'dev_a', key: 'k1', body: BODY });
  const broken = '{"schema":1,"initialized":true,"tasks":';
  writeFileSync(join(dir, OWNER_TASKS_FILE), broken);

  assert.throws(() => service.list(), (error) => error.details?.reason === 'corrupt');
  assert.throws(() => service.create({ principal: 'dev_a', key: 'k2', body: { title: 'x' } }), (error) => (
    error.details?.reason === 'corrupt'
  ));
  assert.equal(readFileSync(join(dir, OWNER_TASKS_FILE), 'utf8'), broken);
});

test('a document without the initialisation flag is refused', (t) => {
  const { dir, service } = boot(t);
  seedDocument(dir, { ...emptyDoc(), initialized: false });
  assert.throws(() => service.list(), (error) => error.details?.reason === 'corrupt');
  assert.throws(() => service.create({ principal: 'dev_a', key: 'k1', body: BODY }), (error) => (
    error.details?.reason === 'corrupt'
  ));
});

test('a lock held by a live process is waited on and then reported, never stolen', (t) => {
  const { dir, service } = boot(t, { lockTimeoutMs: 60 });
  const lock = join(dir, `${OWNER_TASKS_FILE}.lock`);
  writeFileSync(lock, JSON.stringify({ pid: process.pid, startedAt: new Date().toISOString() }), { mode: 0o600 });

  assert.throws(
    () => service.create({ principal: 'dev_a', key: 'k1', body: BODY }),
    (error) => error.details?.reason === 'locked' && error.retryable === true,
  );
  assert.equal(readdirSync(dir).includes(`${OWNER_TASKS_FILE}.lock`), true, 'the live lock stays');
});

test('a lock whose owner is gone is reclaimed', (t) => {
  const { dir, service } = boot(t, { lockTimeoutMs: 500 });
  writeFileSync(join(dir, `${OWNER_TASKS_FILE}.lock`), JSON.stringify({ pid: 999999, startedAt: '2026-10-01T00:00:00.000Z' }), { mode: 0o600 });

  const result = service.create({ principal: 'dev_a', key: 'k1', body: BODY });
  assert.equal(result.status, 201);
  assert.equal(readdirSync(dir).includes(`${OWNER_TASKS_FILE}.lock`), false);
});

test('an unreadable lock stops writes instead of being taken', (t) => {
  const { dir, service } = boot(t, { lockTimeoutMs: 100 });
  const lock = join(dir, `${OWNER_TASKS_FILE}.lock`);
  writeFileSync(lock, 'not json', { mode: 0o600 });
  const past = (Date.now() - 60_000) / 1000;
  utimesSync(lock, past, past);

  assert.throws(() => service.create({ principal: 'dev_a', key: 'k1', body: BODY }), (error) => (
    error.details?.reason === 'locked' && /unreadable/.test(error.message)
  ));
  assert.equal(readFileSync(lock, 'utf8'), 'not json');
});

test('two store instances see each other through the file', (t) => {
  const dir = tempDir(t);
  const now = clockAt();
  const first = createOwnerTaskService({ store: createOwnerTaskStore({ dir, now }), now });
  const second = createOwnerTaskService({ store: createOwnerTaskStore({ dir, now }), now });

  const created = first.create({ principal: 'dev_a', key: 'k1', body: BODY });
  assert.equal(second.get(created.task.id).title, BODY.title);
  const updated = second.update({
    principal: 'cli',
    key: 'k2',
    method: 'PATCH',
    path: 'cli:tasks.update',
    id: created.task.id,
    ifMatch: 1,
    body: { status: 'doing' },
  });
  assert.equal(updated.task.revision, 2);
  assert.equal(first.get(created.task.id).status, 'doing');
});

test('a successful operation is compacted to a tombstone after seven days and never replays as unsent', (t) => {
  const now = clockAt();
  const { service } = boot(t, { now });
  const created = service.create({ principal: 'dev_a', key: 'k1', body: BODY });

  now.advance(OPERATION_RETENTION_MS + 24 * 60 * 60 * 1000);
  // Any write runs compaction first.
  service.update({
    principal: 'dev_a',
    key: 'k2',
    method: 'PATCH',
    path: 'cli:tasks.update',
    id: created.task.id,
    ifMatch: 1,
    body: { status: 'doing' },
  });

  const doc = JSON.parse(readFileSync(join(service.store.dir, OWNER_TASKS_FILE), 'utf8'));
  assert.equal(Object.keys(doc.operations).length, 1, 'only the newer operation stays');
  assert.equal(Object.keys(doc.tombstones).length, 1);
  const tombstone = Object.values(doc.tombstones)[0];
  assert.equal(tombstone.status, 'succeeded');
  assert.equal(tombstone.targetId, created.task.id);
  assert.equal(JSON.stringify(tombstone).includes('契約内容'), false);

  assert.throws(
    () => service.create({ principal: 'dev_a', key: 'k1', body: BODY }),
    (error) => error.status === 410 && error.code === 'owner_task_operation_compacted'
      && error.details.targetId === created.task.id,
  );

  // 37 days later the same request is still not treated as never sent.
  now.advance(30 * 24 * 60 * 60 * 1000);
  assert.throws(
    () => service.create({ principal: 'dev_a', key: 'k1', body: BODY }),
    (error) => error.status === 410,
  );
  assert.equal(Object.keys(service.store.read().tasks).length, 1, 'no second task was created');
});

test('a full ledger stops new writes with a store reason', (t) => {
  const { dir, service, now } = boot(t);
  const doc = emptyDoc();
  for (let i = 0; i < MAX_OPERATIONS; i += 1) {
    doc.operations[`h${i}`] = {
      principalHash: 'a'.repeat(64),
      fingerprint: 'f'.repeat(64),
      method: 'POST',
      path: 'p',
      status: 'succeeded',
      httpStatus: 201,
      targetId: null,
      revision: 1,
      createdAt: now(),
      updatedAt: now(),
    };
  }
  seedDocument(dir, doc);

  assert.throws(
    () => service.create({ principal: 'dev_a', key: 'k1', body: BODY }),
    (error) => error.code === 'owner_tasks_store_unavailable' && error.details.reason === 'ledger_full',
  );
});

test('twenty thousand tombstones stay small enough for a single-document store', (t) => {
  const { dir, service, now } = boot(t);
  const doc = emptyDoc();
  for (let i = 0; i < 20_000; i += 1) {
    doc.tombstones[`${i.toString(16).padStart(8, '0')}${'a'.repeat(56)}`] = {
      compactedAt: now(),
      status: 'succeeded',
      principalHash: 'b'.repeat(64),
      targetId: '11111111-1111-4111-8111-111111111111',
      revision: 3,
    };
  }
  seedDocument(dir, doc);

  const bytes = statSync(join(dir, OWNER_TASKS_FILE)).size;
  t.diagnostic(`20,000 tombstones = ${bytes} bytes (${(bytes / 1024 / 1024).toFixed(2)} MiB)`);
  assert.ok(bytes < 8 * 1024 * 1024, `tombstones must stay under 8 MiB, saw ${bytes}`);
  // The document still reads and a new write still works.
  assert.equal(service.list().total, 0);
  assert.equal(service.create({ principal: 'dev_a', key: 'k1', body: BODY }).status, 201);
});

test('a transaction that throws writes nothing', (t) => {
  const { dir, service } = boot(t);
  const created = service.create({ principal: 'dev_a', key: 'k1', body: BODY });
  const before = readFileSync(join(dir, OWNER_TASKS_FILE), 'utf8');

  assert.throws(() => service.update({
    principal: 'dev_a',
    key: 'k2',
    method: 'PATCH',
    path: 'cli:tasks.update',
    id: created.task.id,
    ifMatch: 99,
    body: { status: 'doing' },
  }), (error) => error.status === 412);

  assert.equal(readFileSync(join(dir, OWNER_TASKS_FILE), 'utf8'), before);
});

test('a completed document leaves no temporary files behind', (t) => {
  const { dir, service } = boot(t);
  const created = service.create({ principal: 'dev_a', key: 'k1', body: BODY });
  service.update({
    principal: 'dev_a',
    key: 'k2',
    method: 'PATCH',
    path: 'cli:tasks.update',
    id: created.task.id,
    ifMatch: 1,
    body: { status: 'done' },
  });
  const names = readdirSync(dir).sort();
  assert.deepEqual(names, [OWNER_TASKS_MARKER, OWNER_TASKS_FILE].sort());
});

test('a write that cannot open the lock reports an io error instead of proceeding', (t) => {
  const { dir, service } = boot(t);
  // A directory where the lock file should be: open(..., 'wx') fails with EISDIR.
  mkdirSync(join(dir, `${OWNER_TASKS_FILE}.lock`));
  assert.throws(() => service.create({ principal: 'dev_a', key: 'k1', body: BODY }), (error) => (
    error.code === 'owner_tasks_store_unavailable' && ['io_error', 'locked'].includes(error.details.reason)
  ));
});

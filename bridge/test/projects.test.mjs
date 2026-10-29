import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { createProjectStore } from '../src/routes/projects.mjs';
import { startBridge } from './helpers.mjs';

const BODY = 'Always answer in Japanese.\nKeep it under five lines.';
const sha = (text) => `sha256:${createHash('sha256').update(text, 'utf8').digest('hex')}`;

async function boot(t) {
  const api = await startBridge();
  t.after(() => api.close());
  const token = await api.token();
  return { api, token };
}

async function createProject(api, token, body = { name: 'Trading｜環境認識', instructions: BODY }, key = 'k-create-1') {
  return api.request('/v1/projects', { method: 'POST', token, key, body });
}

// A record written before instructionRef was refused: it keeps the ref as
// metadata only. The file it names does not exist, which proves nothing reads it.
function legacyRecord(overrides = {}) {
  const iso = '2026-10-01T00:00:00.000Z';
  return {
    id: 'prj_bbbbbbbbbbbb',
    name: 'Trading｜旧ref',
    nameSource: 'owner',
    instructionRef: 'Context/aesthetic.md',
    instructions: null,
    instructionHash: null,
    instructionVersion: 0,
    instructionHistory: [],
    version: 1,
    createdAt: iso,
    updatedAt: iso,
    createdBy: null,
    ...overrides,
  };
}

function writeProjects(api, projects) {
  writeFileSync(join(api.stateDir, 'projects.json'), `${JSON.stringify({ schema: 2, projects }, null, 2)}\n`, { mode: 0o600 });
}

test('a project stores its instruction body, version and hash', async (t) => {
  const { api, token } = await boot(t);

  const created = await createProject(api, token);
  assert.equal(created.status, 201);
  const project = created.body.data;
  assert.match(project.id, /^prj_[0-9a-f]{12}$/);
  assert.equal(project.name, 'Trading｜環境認識');
  assert.equal(project.nameSource, 'owner');
  assert.equal(project.instructions, BODY);
  assert.equal(project.instructionRef, null);
  assert.equal(project.instructionHash, sha(BODY), 'the hash is the sha256 of the body itself');
  assert.equal(project.instructionVersion, 1);
  assert.equal(project.version, 1);
  assert.equal(project.etag, '"1"');
  assert.equal(created.headers.get('etag'), '"1"');
  assert.equal('path' in project, false, 'a project must not carry a workspace path');

  const fetched = await api.request(`/v1/projects/${project.id}`, { token });
  assert.equal(fetched.status, 200);
  assert.deepEqual(fetched.body.data, project);
  assert.equal(fetched.headers.get('etag'), '"1"');

  const listed = await api.request('/v1/projects', { token });
  assert.equal(listed.status, 200);
  assert.equal(listed.body.data.items.length, 1);
  assert.equal(listed.body.data.items[0].id, project.id);
  assert.equal('instructions' in listed.body.data.items[0], false, 'the list must not ship every body');
  assert.equal(listed.body.data.items[0].instructionHash, sha(BODY));
  assert.equal(listed.body.data.nextCursor, null);
});

test('an empty body means no instructions, and the version stays at zero', async (t) => {
  const { api, token } = await boot(t);
  const created = await createProject(api, token, { name: 'LAA｜空' }, 'k-empty');
  assert.equal(created.status, 201);
  assert.equal(created.body.data.instructions, null);
  assert.equal(created.body.data.instructionHash, null);
  assert.equal(created.body.data.instructionVersion, 0);

  const versions = await api.request(`/v1/projects/${created.body.data.id}/instructions/versions`, { token });
  assert.deepEqual(versions.body.data.items, []);
});

test('instructionRef is refused on write instead of being stored', async (t) => {
  const { api, token } = await boot(t);

  const created = await createProject(api, token, { name: 'x', instructionRef: 'Context/aesthetic.md' }, 'k-ref');
  assert.equal(created.status, 400);
  assert.equal(created.body.error.code, 'instruction_ref_unsupported');

  const withBody = await createProject(api, token, { name: 'x', instructions: BODY, instructionRef: 'a.md' }, 'k-ref-2');
  assert.equal(withBody.status, 400);
  assert.equal(withBody.body.error.code, 'instruction_ref_unsupported');

  const project = (await createProject(api, token, { name: 'x', instructions: BODY }, 'k-base')).body.data;
  for (const [key, ref] of [
    ['k-ref-patch', 'Context/aesthetic.md'],
    ['k-ref-absolute', '/etc/passwd'],
    ['k-ref-traversal', '../etc/passwd'],
    ['k-ref-empty', ''],
  ]) {
    const response = await api.request(`/v1/projects/${project.id}`, {
      method: 'PATCH',
      token,
      key,
      headers: { 'if-match': '"1"' },
      body: { instructionRef: ref },
    });
    assert.equal(response.status, 400, `${ref} must be refused`);
    assert.equal(response.body.error.code, 'instruction_ref_unsupported');
  }

  // `null` is not a ref: it is the explicit "clear legacy metadata" value.
  const nullRef = await api.request(`/v1/projects/${project.id}`, {
    method: 'PATCH',
    token,
    key: 'k-ref-null',
    headers: { 'if-match': '"1"' },
    body: { instructionRef: null },
  });
  assert.equal(nullRef.status, 200);
  assert.equal(nullRef.body.data.instructionRef, null);
  assert.equal(nullRef.body.data.version, 1, 'a no-op must not bump the version');
});

test('a legacy instructionRef record is metadata only and can be cleared', async (t) => {
  const { api, token } = await boot(t);
  writeProjects(api, { prj_bbbbbbbbbbbb: legacyRecord() });

  const fetched = await api.request('/v1/projects/prj_bbbbbbbbbbbb', { token });
  assert.equal(fetched.status, 200);
  assert.equal(fetched.body.data.instructionRef, 'Context/aesthetic.md', 'the ref stays visible as metadata');
  assert.equal(fetched.body.data.instructions, null, 'the Bridge never reads the referenced file');
  assert.equal(fetched.body.data.instructionVersion, 0);

  const cleared = await api.request('/v1/projects/prj_bbbbbbbbbbbb', {
    method: 'PATCH',
    token,
    key: 'k-legacy-clear',
    headers: { 'if-match': '"1"' },
    body: { instructionRef: null },
  });
  assert.equal(cleared.status, 200);
  assert.equal(cleared.body.data.instructionRef, null);
  assert.equal(cleared.body.data.version, 2);
  assert.equal(cleared.body.data.instructionVersion, 0, 'clearing metadata is not a new instruction version');

  // A legacy record with a ref still accepts an inline body; saving the body
  // also drops the ref so the record never shows both sources.
  writeProjects(api, { prj_bbbbbbbbbbbb: legacyRecord({ version: 1 }) });
  const replaced = await api.request('/v1/projects/prj_bbbbbbbbbbbb', {
    method: 'PATCH',
    token,
    key: 'k-legacy-body',
    headers: { 'if-match': '"1"' },
    body: { instructions: 'Only answer in Japanese.' },
  });
  assert.equal(replaced.status, 200);
  assert.equal(replaced.body.data.instructionRef, null);
  assert.equal(replaced.body.data.instructions, 'Only answer in Japanese.');
  assert.equal(replaced.body.data.instructionVersion, 1);
});

test('updates require If-Match and a stale version returns the current side', async (t) => {
  const { api, token } = await boot(t);
  const project = (await createProject(api, token)).body.data;

  const noPrecondition = await api.request(`/v1/projects/${project.id}`, {
    method: 'PATCH',
    token,
    key: 'k-2',
    body: { instructions: 'changed' },
  });
  assert.equal(noPrecondition.status, 428);
  assert.equal(noPrecondition.body.error.code, 'precondition_required');

  const staleBeforeAnyChange = await api.request(`/v1/projects/${project.id}`, {
    method: 'PATCH',
    token,
    key: 'k-3',
    headers: { 'if-match': '"9"' },
    body: { instructions: 'changed' },
  });
  assert.equal(staleBeforeAnyChange.status, 412);
  assert.equal(staleBeforeAnyChange.body.error.code, 'version_mismatch');

  const updated = await api.request(`/v1/projects/${project.id}`, {
    method: 'PATCH',
    token,
    key: 'k-4',
    headers: { 'if-match': '"1"' },
    body: { instructions: 'Answer in Japanese only.' },
  });
  assert.equal(updated.status, 200);
  assert.equal(updated.body.data.instructionVersion, 2);
  assert.equal(updated.body.data.etag, '"2"');

  // A second device still holding version 1 must see both sides, never merge.
  const stale = await api.request(`/v1/projects/${project.id}`, {
    method: 'PATCH',
    token,
    key: 'k-5',
    headers: { 'if-match': '"1"' },
    body: { instructions: 'Answer in English only.' },
  });
  assert.equal(stale.status, 412);
  assert.equal(stale.body.error.code, 'version_mismatch');
  assert.deepEqual(stale.body.error.details.current, {
    id: project.id,
    version: 2,
    etag: '"2"',
    instructionVersion: 2,
    instructionHash: sha('Answer in Japanese only.'),
    instructionRef: null,
    instructions: 'Answer in Japanese only.',
  });

  const replay = await api.request(`/v1/projects/${project.id}`, {
    method: 'PATCH',
    token,
    key: 'k-4',
    headers: { 'if-match': '"1"' },
    body: { instructions: 'Answer in Japanese only.' },
  });
  assert.equal(replay.status, 200);
  assert.equal(replay.headers.get('idempotency-replayed'), 'true');
  assert.equal(replay.body.data.version, 2, 'a replayed update must not apply twice');
});

test('identical instructions are not a new version', async (t) => {
  const { api, token } = await boot(t);
  const project = (await createProject(api, token)).body.data;

  const same = await api.request(`/v1/projects/${project.id}`, {
    method: 'PATCH',
    token,
    key: 'k-same',
    headers: { 'if-match': '"1"' },
    body: { instructions: BODY },
  });
  assert.equal(same.status, 200);
  assert.equal(same.body.data.instructionVersion, 1);
  assert.equal(same.body.data.version, 1, 'a no-op must not bump the project version');

  const renamed = await api.request(`/v1/projects/${project.id}`, {
    method: 'PATCH',
    token,
    key: 'k-rename',
    headers: { 'if-match': '"1"' },
    body: { name: 'Trading｜環境認識 v2' },
  });
  assert.equal(renamed.status, 200);
  assert.equal(renamed.body.data.name, 'Trading｜環境認識 v2');
  assert.equal(renamed.body.data.version, 2);
  assert.equal(renamed.body.data.instructionVersion, 1, 'a rename must not bump the instruction version');
});

test('the version history keeps the last ten bodies, newest first', async (t) => {
  const { api, token } = await boot(t);
  const project = (await createProject(api, token, { name: 'x', instructions: 'v1' }, 'k-h0')).body.data;

  for (let version = 2; version <= 12; version += 1) {
    const response = await api.request(`/v1/projects/${project.id}`, {
      method: 'PATCH',
      token,
      key: `k-h${version}`,
      headers: { 'if-match': `"${version - 1}"` },
      body: { instructions: `v${version}` },
    });
    assert.equal(response.status, 200);
    assert.equal(response.body.data.instructionVersion, version);
  }

  const history = await api.request(`/v1/projects/${project.id}/instructions/versions`, { token });
  assert.equal(history.status, 200);
  const items = history.body.data.items;
  assert.equal(items.length, 10, 'only the last ten revisions are kept');
  assert.equal(items[0].version, 12);
  assert.equal(items.at(-1).version, 3);
  assert.deepEqual(items.map((item) => item.body), [12, 11, 10, 9, 8, 7, 6, 5, 4, 3].map((n) => `v${n}`));
  for (const item of items) {
    assert.equal(item.hash, sha(item.body));
    assert.ok(item.updatedAt);
  }

  const current = await api.request(`/v1/projects/${project.id}`, { token });
  assert.equal(current.body.data.instructions, 'v12');
  assert.equal(current.body.data.instructionVersion, 12);
});

test('an idempotent retry replays the stored project instead of creating another', async (t) => {
  const { api, token } = await boot(t);
  const body = { name: 'x', instructions: BODY };

  const first = await createProject(api, token, body, 'k-replay');
  const second = await createProject(api, token, body, 'k-replay');
  assert.equal(second.status, 201);
  assert.equal(second.headers.get('idempotency-replayed'), 'true');
  assert.equal(second.body.data.id, first.body.data.id);
  assert.equal((await api.request('/v1/projects', { token })).body.data.items.length, 1);

  const conflicting = await createProject(api, token, { ...body, name: 'Something else' }, 'k-replay');
  assert.equal(conflicting.status, 409);
  assert.equal(conflicting.body.error.code, 'idempotency_key_conflict');
});

test('reading needs sessions:read and writing needs sessions:write', async (t) => {
  const { api, token } = await boot(t);
  const reader = await api.token(['sessions:read']);

  const created = await createProject(api, token, undefined, 'k-scope');
  assert.equal(created.status, 201);

  const list = await api.request('/v1/projects', { token: reader });
  assert.equal(list.status, 200);
  const versions = await api.request(`/v1/projects/${created.body.data.id}/instructions/versions`, { token: reader });
  assert.equal(versions.status, 200);

  const deniedWrite = await api.request('/v1/projects', {
    method: 'POST',
    token: reader,
    key: 'k-scope-2',
    body: { name: 'Nope' },
  });
  assert.equal(deniedWrite.status, 403);
  assert.equal(deniedWrite.body.error.code, 'insufficient_scope');

  const deniedPatch = await api.request(`/v1/projects/${created.body.data.id}`, {
    method: 'PATCH',
    token: reader,
    key: 'k-scope-3',
    headers: { 'if-match': '"1"' },
    body: { name: 'Nope' },
  });
  assert.equal(deniedPatch.status, 403);

  const anonymous = await api.request('/v1/projects');
  assert.equal(anonymous.status, 401);
  assert.equal(anonymous.body.error.code, 'unauthenticated');
});

test('an owner-given name cannot be replaced by an automatic name', async (t) => {
  const { api, token } = await boot(t);
  const project = (await createProject(api, token, { name: 'Trading｜環境認識', instructions: BODY }, 'k-owner')).body.data;

  const auto = await api.request(`/v1/projects/${project.id}`, {
    method: 'PATCH',
    token,
    key: 'k-owner-auto',
    headers: { 'if-match': '"1"' },
    body: { name: 'LAA｜自動命名', nameSource: 'auto' },
  });
  assert.equal(auto.status, 409);
  assert.equal(auto.body.error.code, 'name_source_locked');

  const afterRefusal = await api.request(`/v1/projects/${project.id}`, { token });
  assert.equal(afterRefusal.body.data.name, project.name);
  assert.equal(afterRefusal.body.data.version, 1, 'a refused rename must not change the version');

  const autoProject = await api.request('/v1/projects', {
    method: 'POST',
    token,
    key: 'k-auto-create',
    body: { name: 'LAA｜自動命名', nameSource: 'auto' },
  });
  assert.equal(autoProject.body.data.nameSource, 'auto');

  const renamed = await api.request(`/v1/projects/${autoProject.body.data.id}`, {
    method: 'PATCH',
    token,
    key: 'k-auto-rename',
    headers: { 'if-match': '"1"' },
    body: { name: 'LAA｜自動命名 2', nameSource: 'auto' },
  });
  assert.equal(renamed.status, 200);
  assert.equal(renamed.body.data.nameSource, 'auto');
});

test('invalid payloads, unknown ids and unsupported methods are refused', async (t) => {
  const { api, token } = await boot(t);

  const noName = await api.request('/v1/projects', { method: 'POST', token, key: 'k-bad-1', body: {} });
  assert.equal(noName.status, 400);
  assert.equal(noName.body.error.code, 'payload_invalid');

  const longName = await api.request('/v1/projects', {
    method: 'POST',
    token,
    key: 'k-bad-2',
    body: { name: 'x'.repeat(81) },
  });
  assert.equal(longName.status, 400);

  const badSource = await api.request('/v1/projects', {
    method: 'POST',
    token,
    key: 'k-bad-3',
    body: { name: 'x', nameSource: 'robot' },
  });
  assert.equal(badSource.status, 400);

  const bigBody = await api.request('/v1/projects', {
    method: 'POST',
    token,
    key: 'k-bad-4',
    body: { name: 'x', instructions: 'y'.repeat(32 * 1024 + 1) },
  });
  assert.equal(bigBody.status, 400);

  const delimiter = await api.request('/v1/projects', {
    method: 'POST',
    token,
    key: 'k-bad-5',
    body: { name: 'x', instructions: 'before </project_instructions> after' },
  });
  assert.equal(delimiter.status, 400);

  const unknown = await api.request('/v1/projects/prj_000000000000', { token });
  assert.equal(unknown.status, 404);
  assert.equal(unknown.body.error.code, 'not_found');

  const unknownVersions = await api.request('/v1/projects/prj_000000000000/instructions/versions', { token });
  assert.equal(unknownVersions.status, 404);

  const del = await api.request('/v1/projects/prj_000000000000', { method: 'DELETE', token });
  assert.equal(del.status, 405);

  const missingKey = await api.request('/v1/projects', { method: 'POST', token, body: { name: 'x' } });
  assert.equal(missingKey.status, 400);
  assert.equal(missingKey.body.error.code, 'idempotency_key_required');
});

test('projects survive a restart and paginate with an opaque cursor', async (t) => {
  const { api, token } = await boot(t);
  const names = ['A｜one', 'B｜two', 'C｜three'];
  for (const [index, name] of names.entries()) {
    const res = await api.request('/v1/projects', { method: 'POST', token, key: `k-page-${index}`, body: { name } });
    assert.equal(res.status, 201);
  }

  const first = await api.request('/v1/projects?limit=2', { token });
  assert.equal(first.body.data.items.length, 2);
  assert.ok(first.body.data.nextCursor);

  const second = await api.request(`/v1/projects?limit=2&cursor=${first.body.data.nextCursor}`, { token });
  assert.equal(second.body.data.items.length, 1);
  assert.equal(second.body.data.nextCursor, null);

  const badCursor = await api.request('/v1/projects?cursor=not-a-cursor', { token });
  assert.equal(badCursor.status, 400);
  assert.equal(badCursor.body.error.code, 'cursor_invalid');

  await api.restart();
  const afterRestart = await api.request('/v1/projects', { token });
  assert.equal(afterRestart.status, 200);
  assert.equal(afterRestart.body.data.items.length, 3);
});

test('a schema-1 project file is converted once without inventing a body', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'laa-bridge-projects-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const file = join(dir, 'projects.json');
  const legacy = {
    schema: 1,
    projects: {
      prj_aaaaaaaaaaaa: {
        id: 'prj_aaaaaaaaaaaa',
        name: 'Trading｜旧',
        nameSource: 'owner',
        instructionRef: 'Context/aesthetic.md',
        instructionTextHash: 'deadbeef',
        instructionHash: 'sha256:legacy',
        instructionVersion: 4,
        instructionHistory: [{ version: 4, hash: 'sha256:legacy', at: '2026-10-01T00:00:00.000Z' }],
        version: 2,
        createdAt: '2026-10-01T00:00:00.000Z',
        updatedAt: '2026-10-01T00:00:00.000Z',
      },
    },
  };
  writeFileSync(file, JSON.stringify(legacy), { mode: 0o600 });

  const store = createProjectStore({ file });
  const project = store.get('prj_aaaaaaaaaaaa');
  assert.equal(project.name, 'Trading｜旧');
  assert.equal(project.instructionVersion, 4, 'the version number survives');
  assert.equal(project.instructionRef, 'Context/aesthetic.md', 'the ref survives as legacy metadata');
  assert.equal(project.instructions, null);
  assert.equal(project.instructionHash, null, 'the old hash covered text the Bridge never kept');
  assert.deepEqual(project.instructionHistory, []);
  assert.equal(store.instructionsFor(project), null, 'a ref is never read');
  assert.equal(JSON.parse(readFileSync(file, 'utf8')).schema, 2);
});

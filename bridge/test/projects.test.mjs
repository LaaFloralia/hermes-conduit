import assert from 'node:assert/strict';
import test from 'node:test';
import { startBridge } from './helpers.mjs';

const PROJECT = {
  name: 'Trading｜環境認識',
  instructionRef: 'Brain/Context/aesthetic.md',
  instructions: 'Always answer in Japanese.',
};

async function createProject(api, token, body = PROJECT, key = 'k-create-1') {
  return api.request('/v1/projects', { method: 'POST', token, key, body });
}

test('a project is created, listed and fetched with an instruction version hash', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const token = await api.token();

  const created = await createProject(api, token);
  assert.equal(created.status, 201);
  const project = created.body.data;
  assert.match(project.id, /^prj_[0-9a-f]{12}$/);
  assert.equal(project.name, PROJECT.name);
  assert.equal(project.nameSource, 'owner');
  assert.equal(project.instructionRef, PROJECT.instructionRef);
  assert.match(project.instructionHash, /^sha256:[0-9a-f]{64}$/);
  assert.equal(project.instructionVersion, 1);
  assert.equal(project.version, 1);
  assert.equal(project.etag, '"1"');
  assert.equal(created.headers.get('etag'), '"1"');
  assert.equal('path' in project, false, 'a project must not carry a workspace path');

  const listed = await api.request('/v1/projects', { token });
  assert.equal(listed.status, 200);
  assert.equal(listed.body.data.items.length, 1);
  assert.equal(listed.body.data.items[0].id, project.id);
  assert.equal(listed.body.data.nextCursor, null);

  const fetched = await api.request(`/v1/projects/${project.id}`, { token });
  assert.equal(fetched.status, 200);
  assert.deepEqual(fetched.body.data, project);
  assert.equal(fetched.headers.get('etag'), '"1"');
});

test('the instruction hash covers the reference and the text', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const token = await api.token();

  const a = await createProject(api, token, { name: 'A', instructionRef: 'ref/a' }, 'k-a');
  const b = await createProject(api, token, { name: 'B', instructionRef: 'ref/b' }, 'k-b');
  const c = await createProject(api, token, { name: 'C', instructionRef: 'ref/a', instructions: 'x' }, 'k-c');
  const hashes = [a, b, c].map((res) => res.body.data.instructionHash);
  assert.equal(new Set(hashes).size, 3, 'different refs or texts must produce different hashes');
});

test('an idempotent retry replays the stored project instead of creating another', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const token = await api.token();

  const first = await createProject(api, token, PROJECT, 'k-replay');
  const second = await createProject(api, token, PROJECT, 'k-replay');
  assert.equal(second.status, 201);
  assert.equal(second.headers.get('idempotency-replayed'), 'true');
  assert.equal(second.body.data.id, first.body.data.id);
  assert.equal((await api.request('/v1/projects', { token })).body.data.items.length, 1);

  const conflicting = await api.request('/v1/projects', {
    method: 'POST',
    token,
    key: 'k-replay',
    body: { ...PROJECT, name: 'Something else' },
  });
  assert.equal(conflicting.status, 409);
  assert.equal(conflicting.body.error.code, 'idempotency_key_conflict');
});

test('reading needs sessions:read and writing needs sessions:write', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const reader = await api.token(['sessions:read']);
  const writer = await api.token();

  const created = await createProject(api, writer, PROJECT, 'k-scope');
  assert.equal(created.status, 201);

  const list = await api.request('/v1/projects', { token: reader });
  assert.equal(list.status, 200);

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

test('updates require If-Match and reject a stale version', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const token = await api.token();
  const project = (await createProject(api, token, PROJECT, 'k-1')).body.data;

  const noPrecondition = await api.request(`/v1/projects/${project.id}`, {
    method: 'PATCH',
    token,
    key: 'k-2',
    body: { name: 'Renamed' },
  });
  assert.equal(noPrecondition.status, 428);
  assert.equal(noPrecondition.body.error.code, 'precondition_required');

  const stale = await api.request(`/v1/projects/${project.id}`, {
    method: 'PATCH',
    token,
    key: 'k-3',
    headers: { 'if-match': '"9"' },
    body: { name: 'Renamed' },
  });
  assert.equal(stale.status, 412);
  assert.equal(stale.body.error.code, 'version_mismatch');

  const updated = await api.request(`/v1/projects/${project.id}`, {
    method: 'PATCH',
    token,
    key: 'k-4',
    headers: { 'if-match': '"1"' },
    body: { name: 'Trading｜環境認識 v2' },
  });
  assert.equal(updated.status, 200);
  assert.equal(updated.body.data.name, 'Trading｜環境認識 v2');
  assert.equal(updated.body.data.version, 2);
  assert.equal(updated.body.data.etag, '"2"');
  assert.equal(updated.headers.get('etag'), '"2"');
  assert.equal(updated.body.data.instructionVersion, 1, 'a rename must not bump the instruction version');

  const replay = await api.request(`/v1/projects/${project.id}`, {
    method: 'PATCH',
    token,
    key: 'k-4',
    headers: { 'if-match': '"1"' },
    body: { name: 'Trading｜環境認識 v2' },
  });
  assert.equal(replay.status, 200);
  assert.equal(replay.headers.get('idempotency-replayed'), 'true');
  assert.equal(replay.body.data.version, 2, 'a replayed update must not apply twice');
});

test('an owner-given name cannot be replaced by an automatic name', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const token = await api.token();
  const project = (await createProject(api, token, PROJECT, 'k-owner')).body.data;

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
  assert.equal(afterRefusal.body.data.name, PROJECT.name);
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

test('changing instructions bumps the instruction version and keeps the hash history', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const token = await api.token();
  const project = (await createProject(api, token, PROJECT, 'k-instr')).body.data;

  const changed = await api.request(`/v1/projects/${project.id}`, {
    method: 'PATCH',
    token,
    key: 'k-instr-2',
    headers: { 'if-match': '"1"' },
    body: { instructions: 'Always answer in Japanese, briefly.' },
  });
  assert.equal(changed.status, 200);
  assert.equal(changed.body.data.instructionVersion, 2);
  assert.notEqual(changed.body.data.instructionHash, project.instructionHash);

  const refOnly = await api.request(`/v1/projects/${project.id}`, {
    method: 'PATCH',
    token,
    key: 'k-instr-3',
    headers: { 'if-match': '"2"' },
    body: { instructionRef: 'Brain/Context/other.md' },
  });
  assert.equal(refOnly.body.data.instructionVersion, 3);
  assert.notEqual(refOnly.body.data.instructionHash, changed.body.data.instructionHash);

  const same = await api.request(`/v1/projects/${project.id}`, {
    method: 'PATCH',
    token,
    key: 'k-instr-4',
    headers: { 'if-match': '"3"' },
    body: { instructionRef: 'Brain/Context/other.md', instructions: 'Always answer in Japanese, briefly.' },
  });
  assert.equal(same.status, 200);
  assert.equal(same.body.data.instructionVersion, 3, 'an identical instruction set is not a new version');
  assert.equal(same.body.data.instructionHash, refOnly.body.data.instructionHash);
});

test('invalid payloads, unknown ids and unsupported methods are refused', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const token = await api.token();

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

  const unknown = await api.request('/v1/projects/prj_000000000000', { token });
  assert.equal(unknown.status, 404);
  assert.equal(unknown.body.error.code, 'not_found');

  const del = await api.request('/v1/projects/prj_000000000000', { method: 'DELETE', token });
  assert.equal(del.status, 405);

  const missingKey = await api.request('/v1/projects', { method: 'POST', token, body: { name: 'x' } });
  assert.equal(missingKey.status, 400);
  assert.equal(missingKey.body.error.code, 'idempotency_key_required');
});

test('projects survive a restart and paginate with an opaque cursor', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const token = await api.token();
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

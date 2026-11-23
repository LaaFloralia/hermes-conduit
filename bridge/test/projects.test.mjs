import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { createProjectStore, DEFAULT_PROJECT_ID, storedFileName } from '../src/routes/projects.mjs';
import { createSessionStore } from '../src/sessions/store.mjs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
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
  assert.match(fetched.headers.get('etag'), /^W\/"1-[0-9a-f]{24}"$/);

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
    defaultProfile: null,
    progressNote: null,
    requirements: [],
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

test('a long Japanese file name is shortened on disk but kept as the display name', async (t) => {
  const { api, token } = await boot(t);
  const project = (await createProject(api, token, { name: '資料つき' }, 'k-long-project')).body.data;
  const name = `${'資'.repeat(117)}.md`; // 120 code points, 354 UTF-8 bytes
  const body = { name, contentBase64: Buffer.from('# 参考').toString('base64'), mimeType: 'text/markdown' };

  const added = await api.request(`/v1/projects/${project.id}/files`, { method: 'POST', token, key: 'k-long-file', body });
  assert.equal(added.status, 201, JSON.stringify(added.body));
  assert.equal(added.body.data.files[0].name, name, 'the API keeps the display name');
  assert.equal(added.body.data.files[0].path, undefined, 'the Mac path stays private');

  const stored = readdirSync(join(api.stateDir, 'project-files', project.id));
  assert.equal(stored.length, 1);
  assert.ok(Buffer.byteLength(stored[0], 'utf8') <= 255, `${Buffer.byteLength(stored[0], 'utf8')} bytes`);
  assert.ok(stored[0].endsWith('.md'), 'the extension survives the shortening');
  assert.equal(stored[0], stored[0].normalize('NFC'));

  const replay = await api.request(`/v1/projects/${project.id}/files`, { method: 'POST', token, key: 'k-long-file', body });
  assert.equal(replay.status, 201);
  assert.equal(replay.headers.get('idempotency-replayed'), 'true');
  assert.equal(replay.body.data.files.length, 1);
  assert.equal(readdirSync(join(api.stateDir, 'project-files', project.id)).length, 1);
});

test('storedFileName normalises and cuts on code-point boundaries', () => {
  const id = 'file_0123456789ab';
  for (const name of [
    `${'が'.repeat(120)}.txt`,
    `${'📄'.repeat(60)}.pdf`,
    `${'か\u3099'.repeat(60)}.md`,
  ]) {
    const stored = storedFileName(id, name);
    assert.ok(Buffer.byteLength(stored, 'utf8') <= 255, `${Buffer.byteLength(stored, 'utf8')} bytes`);
    assert.equal(stored, stored.normalize('NFC'));
    assert.equal(Buffer.from(stored, 'utf8').toString('utf8'), stored, 'no broken code point');
  }
  assert.ok(storedFileName(id, `${'が'.repeat(120)}.txt`).endsWith('.txt'));
  assert.ok(storedFileName(id, `${'📄'.repeat(60)}.pdf`).endsWith('.pdf'));
});

test('a rejected file name releases its key so the corrected retry can run', async (t) => {
  const { api, token } = await boot(t);
  const project = (await createProject(api, token, { name: '資料つき' }, 'k-retry-project')).body.data;
  const invalid = await api.request(`/v1/projects/${project.id}/files`, {
    method: 'POST',
    token,
    key: 'k-file-retry',
    body: { name: 'x'.repeat(121), contentBase64: Buffer.from('a').toString('base64') },
  });
  assert.equal(invalid.status, 400);
  assert.equal(invalid.body.error.code, 'payload_invalid');

  const corrected = await api.request(`/v1/projects/${project.id}/files`, {
    method: 'POST',
    token,
    key: 'k-file-retry',
    body: { name: '短い名前.md', contentBase64: Buffer.from('a').toString('base64') },
  });
  assert.equal(corrected.status, 201, JSON.stringify(corrected.body));
  assert.equal(corrected.body.data.files[0].name, '短い名前.md');
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
  assert.equal(JSON.parse(readFileSync(file, 'utf8')).schema, 3);
});

test('archiving a project moves it out of the list, keeps it readable and restores it', async (t) => {
  const { api, token } = await boot(t);
  const project = (await createProject(api, token)).body.data;
  const names = async (query = '') => (await api.request(`/v1/projects${query}`, { token })).body.data.items.map((item) => item.id);

  const patch = (body, etag, key) => api.request(`/v1/projects/${project.id}`, { method: 'PATCH', token, key, headers: { 'if-match': etag }, body });
  assert.equal((await patch({ archived: 'yes' }, project.etag, 'k-bad')).status, 400);
  const archived = await patch({ archived: true }, project.etag, 'k-archive');
  assert.equal(archived.status, 200);
  assert.ok(archived.body.data.archivedAt);
  assert.equal(archived.body.data.instructions, BODY);
  assert.deepEqual(await names(), []);
  assert.deepEqual(await names('?archived=only'), [project.id]);
  assert.equal((await api.request(`/v1/projects/${project.id}`, { token })).status, 200);

  const restored = await patch({ archived: false }, archived.body.data.etag, 'k-restore');
  assert.equal(restored.body.data.archivedAt, null);
  assert.deepEqual(await names(), [project.id]);
  assert.deepEqual(await names('?archived=only'), []);
});

test('versioned requirements preserve the owner title on edits and withdrawal across a restart', async t => {
  const { api, token } = await boot(t);
  const p = (await createProject(api, token, { name: 'Example', progressNote: 'Next: check the result', instructions: BODY })).body.data;
  const path = `/v1/projects/${p.id}`;
  const req = (suffix, method, key, etag, body, otherToken = token) => api.request(path + suffix, {
    method, key, token: otherToken, headers: etag ? { 'if-match': etag } : {}, body,
  });
  const owner = { title: '  Preserve my exact words.  ', source: 'owner' };
  assert.equal((await req('/requirements', 'POST', 'missing-version', null, owner)).status, 428);
  const readOnly = await api.token(['sessions:read']);
  assert.equal((await req('/requirements', 'POST', 'read-only', p.etag, owner, readOnly)).status, 403);
  const a = await req('/requirements', 'POST', 'requirement-a', p.etag, owner);
  assert.equal(a.status, 201);
  assert.deepEqual((await req('/requirements', 'POST', 'requirement-a', p.etag, owner)).body.data, a.body.data);
  const aId = a.body.data.requirements[0].id;
  const b = await req('/requirements', 'POST', 'requirement-b', a.body.data.etag, { title: 'AI check', source: 'ai' });
  const bId = b.body.data.requirements[1].id;
  assert.equal((await req(`/requirements/${aId}`, 'PATCH', 'stale', a.body.data.etag, { status: 'completed' })).status, 412);
  assert.equal((await req(`/requirements/${aId}`, 'PATCH', 'locked', b.body.data.etag, { title: 'Different words' })).status, 409);
  assert.equal((await req('/requirements/order', 'PUT', 'duplicate-order', b.body.data.etag, { ids: [aId, aId] })).status, 400);
  const ordered = await req('/requirements/order', 'PUT', 'order', b.body.data.etag, { ids: [bId, aId] });
  assert.equal(ordered.status, 200);
  assert.deepEqual(ordered.body.data.requirements.map(r => [r.id, r.order]), [[bId, 0], [aId, 1]]);
  const done = await req(`/requirements/${aId}`, 'PATCH', 'complete', ordered.body.data.etag, { status: 'completed', details: 'Verified' });
  assert.equal(done.body.data.requirements[1].title, owner.title);
  assert.deepEqual(done.body.data.requirementSummary, { completed: 1, total: 2 });
  const removed = await req(`/requirements/${aId}`, 'DELETE', 'withdraw', done.body.data.etag);
  assert.equal(removed.status, 200);
  assert.deepEqual(removed.body.data.requirementSummary, { completed: 0, total: 1 });
  const file = join(api.stateDir, 'projects.json');
  const stored = JSON.parse(readFileSync(file, 'utf8')).projects[p.id];
  assert.equal(statSync(file).mode & 0o777, 0o600);
  assert.equal(stored.requirements.find(r => r.id === aId).title, owner.title);
  assert.ok(stored.requirements.find(r => r.id === aId).withdrawnAt);
  await api.restart();
  const fetched = (await api.request(path, { token })).body.data;
  assert.equal(fetched.requirements.length, 1);
  assert.equal(fetched.requirements[0].id, bId);
  assert.equal(fetched.progressNote, 'Next: check the result');
  assert.deepEqual(fetched.sessions, []);
});

test('project detail bounds active sessions, pages the archive, and revalidates without a body', async t => {
  const api = await startBridge();
  t.after(() => api.close());
  const token = await api.token();
  const p = (await createProject(api, token, { name: 'Project pages' })).body.data;
  const path = `/v1/projects/${p.id}`;
  const sessions = createSessionStore({ file: join(api.stateDir, 'sessions.json') });
  const ids = Array.from({ length: 207 }, (_, i) => `ses_${(i + 1).toString(16).padStart(16, '0')}`);
  const rows = ids.map((id, i) => ({ id, name: `Row ${i}`, phase: 'running', projectId: p.id,
    updatedAt: new Date(1_790_000_000_000 + (i === 204 ? 205 : i) * 1000).toISOString(),
    ...(i >= 205 ? { archivedAt: '2026-11-04T00:00:00.000Z' } : {}) }));
  sessions.importDirectory(rows);
  const request = (query = '', headers = {}) => api.request(`${path}${query}`, { token, headers });
  const first = await request();
  const etag = first.headers.get('etag');
  assert.match(etag, /^W\/"1-[0-9a-f]{24}"$/);
  assert.equal(first.body.data.etag, p.etag);
  assert.deepEqual(first.body.data.sessionCounts, { active: 205, archived: 2, running: 205, awaitingDecision: 0, waiting: 0 });
  assert.equal(first.body.data.sessions.length, 200);
  assert.equal(first.body.data.sessions[0].id, ids[204]);
  const next = await request(`?sessionsCursor=${first.body.data.nextSessionsCursor}`);
  assert.deepEqual(next.body.data.sessions.map(x => x.id), ids.slice(0, 5).reverse());
  assert.equal(next.body.data.nextSessionsCursor, null);
  const query = '?sessions=all&sessionsLimit=2';
  const archived = await request(query, { 'if-none-match': etag });
  assert.deepEqual(archived.body.data.sessions.map(x => x.id), [ids[206], ids[204]], 'same timestamp ties break by ID');
  const rest = await request(`${query}&sessionsCursor=${archived.body.data.nextSessionsCursor}`);
  assert.deepEqual(rest.body.data.sessions.map(x => x.id), [ids[205], ids[203]]);
  const unchanged = await request('', { 'if-none-match': `"irrelevant", ${etag}` });
  assert.equal(unchanged.status, 304);
  assert.equal(unchanged.body, null);
  assert.equal(unchanged.headers.get('content-length'), null);
  assert.equal(unchanged.headers.get('etag'), etag);
  assert.equal((await api.request(path, { headers: { 'if-none-match': etag } })).status, 401);
  assert.equal((await request('?sessionsLimit=201')).status, 400);
  assert.equal((await request(`?sessionsCursor=${archived.body.data.nextSessionsCursor}`)).status, 400);
  sessions.update(ids[204], row => { row.phase = 'awaiting_decision'; return []; });
  const changed = await request('', { 'if-none-match': etag });
  assert.equal(changed.status, 200);
  assert.equal(changed.body.data.sessions[0].status, 'awaiting_decision');
  assert.equal(changed.body.data.etag, p.etag, 'Session observations do not change the project write version');
  const patch = await api.request(path, { method: 'PATCH', token, key: 'representation-can-write', headers: { 'if-match': changed.headers.get('etag') }, body: { progressNote: 'Verified' } });
  assert.equal(patch.status, 200);
  assert.equal((await request('', { 'if-none-match': changed.headers.get('etag') })).status, 200);
});

test('legacy session creation and retry keep one project; the local CLI can attach Work and its children', async t => {
  let launches = 0;
  const api = await startBridge({ sessions: { adapter: {
    create: async () => ({ sessionId: `delegate-${++launches}`, requested: { model: 'test-model' } }), status: async () => ({}),
  } } });
  t.after(() => api.close());
  const token = await api.token();
  const p = (await createProject(api, token, { name: 'Release' })).body.data;
  const path = `/v1/projects/${p.id}`;
  const requirement = (await api.request(`${path}/requirements`, {
    method: 'POST', token, key: 'add', headers: { 'if-match': p.etag }, body: { title: 'Check', source: 'owner' },
  })).body.data;
  const reqId = requirement.requirements[0].id;
  const body = { requestId: 'app-v1-fallback', profile: 'opus-high', prompt: 'legacy no project' };
  const legacy = await api.request('/v1/sessions', { method: 'POST', token, key: 'legacy', body });
  assert.equal(legacy.status, 201);
  assert.equal(legacy.body.data.projectId, DEFAULT_PROJECT_ID);
  const id = legacy.body.data.id;
  const patch = (key, dest) => api.request(`/v1/sessions/${id}`, { method: 'PATCH', token, key, body: { projectId: dest } });
  assert.equal((await patch('move', p.id)).body.data.projectId, p.id);
  const replay = await api.request('/v1/sessions', { method: 'POST', token, key: 'legacy-new-key', body });
  assert.equal(replay.status, 200);
  assert.equal(replay.body.data.projectId, p.id);
  assert.equal(launches, 1);

  const sessionStore = createSessionStore({ file: join(api.stateDir, 'sessions.json') });
  const uuid = '00000000-0000-4000-8000-000000000123';
  const parent = 'ses_1111111111111111';
  const child = 'ses_2222222222222222';
  const at = '2026-10-01T00:00:00.000Z';
  const row = { phase: 'running', requested: { model: 'test' }, updatedAt: at };
  sessionStore.importDirectory([
    { ...row, id: child, parentId: parent, phase: 'awaiting_decision', name: 'Child', projectId: DEFAULT_PROJECT_ID },
    { ...row, id: parent, name: 'Work parent', projectId: DEFAULT_PROJECT_ID, delegate: { sessionId: uuid } },
  ]);
  const cli = (args, input) => {
    const result = spawnSync(process.execPath, [fileURLToPath(new URL('../src/cli.mjs', import.meta.url)), 'projects', ...args], {
      env: { ...process.env, LAA_BRIDGE_STATE_DIR: api.stateDir }, input: input && JSON.stringify(input), encoding: 'utf8',
    });
    assert.equal(result.status, 0, result.stdout);
    return JSON.parse(result.stdout).data;
  };
  assert.equal(cli(['assign', 'Release', uuid]).sessionId, parent);
  cli(['rpc'], { op: 'assign', project: p.id, sessionId: uuid, requirementId: reqId });
  const read = async () => (await api.request(path, { token })).body.data;
  let detail = await read();
  assert.deepEqual(detail.requirements[0].sessionIds, [parent]);
  assert.equal(detail.requirements[0].status, 'in_progress');
  assert.equal(detail.sessions.find(s => s.id === parent).status, 'running');
  assert.equal(detail.sessions.find(s => s.id === child).status, 'awaiting_decision');
  assert.equal(detail.sessions.find(s => s.id === child).parentId, parent);
  const blocked = await api.request(`/v1/sessions/${parent}`, { method: 'PATCH', token, key: 'reject-linked', body: { projectId: DEFAULT_PROJECT_ID } });
  assert.equal(blocked.status, 409);
  // A new directory snapshot cannot overwrite an explicit move.
  sessionStore.importDirectory([{ ...row, id: parent, name: 'Work parent', projectId: DEFAULT_PROJECT_ID, delegate: { sessionId: uuid } }]);
  await api.restart();
  detail = await read();
  assert.equal(detail.sessions.some(s => s.id === parent), true);
  assert.equal(detail.sessions.some(s => s.id === child), true);
  const unclassified = (await api.request(`/v1/projects/${DEFAULT_PROJECT_ID}`, { token })).body.data;
  assert.equal(unclassified.name, '未分類');
  assert.equal(unclassified.sessions.some(s => [id, parent, child].includes(s.id)), false);
});

test('project session counts keep running, awaiting the owner and waiting apart (BUS-508)', async t => {
  const api = await startBridge();
  t.after(() => api.close());
  const token = await api.token();
  const p = (await createProject(api, token, { name: 'Project states' })).body.data;
  const sessions = createSessionStore({ file: join(api.stateDir, 'sessions.json') });
  const phases = ['running', 'created', 'awaiting_review', 'awaiting_review', 'idle', 'awaiting_decision', 'closed', 'running'];
  sessions.importDirectory(phases.map((phase, i) => ({ id: `ses_${(i + 1).toString(16).padStart(16, '0')}`, name: `Row ${i}`, phase,
    projectId: p.id, updatedAt: new Date(1_790_000_000_000 + i * 1000).toISOString(),
    ...(i === 7 ? { archivedAt: '2026-11-04T00:00:00.000Z' } : {}) })));
  const body = (await api.request(`/v1/projects/${p.id}`, { token })).body.data;
  // Seven unarchived: two at work, one asking, three waiting, one closed.
  assert.deepEqual(body.sessionCounts, { active: 7, archived: 1, running: 2, awaitingDecision: 1, waiting: 3 });
  assert.deepEqual(body.sessions.map(x => x.status).sort(),
    ['awaiting_decision', 'completed', 'running', 'running', 'waiting', 'waiting', 'waiting']);
});

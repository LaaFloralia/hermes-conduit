// Brain read / search / create-only contract (ROADMAP 25, docs/laa/BRAIN-WRITE.md).
//
// Everything runs against a throwaway vault that mirrors the real policy shape:
// the default areas, the restricted ones, a conflict copy, a symlink and a
// nested memo. The search adapter is a fake (the real one is `laa-brain`), and
// the git/Syncthing/disk preconditions are injectable so every refusal is
// exercised without touching the real vault or the running sync.

import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import {
  existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { DEFAULT_SCOPES } from '../src/config.mjs';
import { BridgeError } from '../src/errors.mjs';
import { createDiskGate, createGitGate, createSyncthingGate } from '../src/brain/gates.mjs';
import { createJournal } from '../src/brain/journal.mjs';
import { fileId, hashBuffer, parseVaultPath } from '../src/brain/vault.mjs';
import { startBridge } from './helpers.mjs';

const POLICY = {
  version: 1,
  root: 'PLACEHOLDER',
  exclude_dirs: ['.git', '.obsidian', '.trash', 'node_modules'],
  zones: [
    { prefix: 'old/', zone: 'old', label: '旧資料', default: false, jev: false, guide: false },
    { prefix: 'Inbox/', zone: 'inbox', label: '確認前の入力', default: false, jev: false, guide: true },
    { prefix: 'Sources/', zone: 'sources', label: '原資料', default: false, jev: false },
    { prefix: 'Journal/', zone: 'journal', label: '日記', default: false, jev: false },
    { prefix: 'Trading/研究資料/', zone: 'trading-research', label: '研究資料', default: false, jev: false },
    { prefix: 'Attachments/', zone: 'attachments', label: '添付', default: false, jev: false },
    { prefix: 'Context/', zone: 'context', label: '判断軸', default: true, jev: false },
    { prefix: 'Company/', zone: 'company', label: '会社', default: true, jev: true },
    { prefix: 'Trading/', zone: 'trading', label: '手引き', default: true, jev: true },
  ],
  root_zone: { zone: 'root', label: '入口', default: true, jev: true },
  guide_zone: { zone: 'guide', label: '運用案内', default: true, jev: true },
  unclassified_zone: { zone: 'unclassified', label: '未分類', default: false, jev: false },
};

const AESTHETICS = '# Aesthetics\n\n状態: 採用済み\n最終確認: 2026-10-01\n\n色は静かに。\n';
const DRAFT = '# Draft\n\n状態: 草案\n\nあとで確認。\n';

function makeVault() {
  const root = mkdtempSync(join(tmpdir(), 'laa-brain-vault-'));
  const files = {
    'README.md': '# Brain\n\n入口。\n',
    'Company/Aesthetics.md': AESTHETICS,
    'Company/README.md': '# 会社の運用\n',
    'Company/note.sync-conflict-20261020-201228-ABCD.md': '# 競合コピー\n',
    'Company/（GitHub競合 2026-10-20 1030）.md': '# GitHub競合\n',
    'Context/aesthetic.md': '# 判断軸\n\n道具の選び方。\n',
    'Trading/Methods/ICT.md': '# ICT\n',
    'Trading/研究資料/raw.md': '# 研究\n',
    'Inbox/Draft.md': DRAFT,
    'Inbox/README.md': '# Inboxの運用\n',
    'old/Legacy.md': '# Legacy\n',
    'Sources/raw.md': '# 原資料\n',
    'Journal/2026-10-29.md': '# 日記\n',
    'Attachments/reference.md': '# 参考\n',
    'Loose.md': '# 直下のメモ\n',
    'Unclassified/odd.md': '# 未分類\n',
  };
  for (const [rel, body] of Object.entries(files)) {
    const absolute = join(root, rel);
    mkdirSync(dirname(absolute), { recursive: true });
    writeFileSync(absolute, body, 'utf8');
  }
  symlinkSync('/etc/hosts', join(root, 'Company/link.md'));
  const policyFile = join(root, '..', `${root.split('/').pop()}-policy.json`);
  writeFileSync(policyFile, JSON.stringify({ ...POLICY, root }, null, 2), 'utf8');
  return { root, policyFile };
}

function sha(text) {
  return `sha256:${createHash('sha256').update(text, 'utf8').digest('hex')}`;
}

async function startBrain(t, overrides = {}) {
  const { root, policyFile } = makeVault();
  const calls = [];
  const search = async (request) => {
    calls.push(request);
    return {
      query: request.query,
      found: true,
      match_basis: 'lexical_only',
      results: [
        {
          path: 'Company/Aesthetics.md', section: 'Aesthetics', lines: [1, 5], zone: 'company',
          status: '採用済み', checked: '2026-10-01', p: null, lexical: 12.5, text: '色は静かに。',
          relevance_status: 'unjudged',
        },
        {
          path: 'old/Legacy.md', section: 'Legacy', lines: [1, 1], zone: 'old',
          status: null, checked: null, p: null, lexical: 9, text: 'legacy', relevance_status: 'unjudged',
        },
      ],
    };
  };
  const gates = {
    git: () => ({ branch: 'master', head: 'ref: refs/heads/master' }),
    disk: () => ({ freeBytes: 1024 * 1024 * 1024 }),
    sync: async () => ({ state: 'idle', errors: 0, pullErrors: 0 }),
    ...(overrides.gates ?? {}),
  };
  const api = await startBridge({
    brain: {
      vaultRoot: root,
      policyFile,
      journalFile: join(root, '..', `${root.split('/').pop()}-journal.jsonl`),
      createPrefixes: ['Inbox/'],
      search: overrides.search ?? search,
      gates,
      ...(overrides.brain ?? {}),
    },
  });
  t.after(async () => {
    await api.close();
    rmSync(root, { recursive: true, force: true });
    rmSync(policyFile, { force: true });
  });
  return {
    api,
    root,
    policyFile,
    calls,
    token: () => api.token(),
    createToken: () => api.token([...DEFAULT_SCOPES, 'brain:create']),
  };
}

test('the listing covers the default areas only and never shows conflict copies or symlinks', async (t) => {
  const { api, root } = await startBrain(t);
  const token = await api.token();
  const res = await api.request('/v1/brain/files', { token });
  assert.equal(res.status, 200);
  const paths = res.body.data.items.map((item) => item.path);
  for (const expected of ['README.md', 'Company/Aesthetics.md', 'Company/README.md', 'Context/aesthetic.md', 'Trading/Methods/ICT.md']) {
    assert.ok(paths.includes(expected), `${expected} should be listed`);
  }
  for (const hidden of [
    'Inbox/Draft.md', 'old/Legacy.md', 'Sources/raw.md', 'Journal/2026-10-29.md',
    'Trading/研究資料/raw.md', 'Attachments/reference.md', 'Unclassified/odd.md',
  ]) {
    assert.equal(paths.includes(hidden), false, `${hidden} must not be listed by default`);
  }
  assert.equal(paths.some((path) => path.includes('sync-conflict-')), false);
  assert.equal(paths.some((path) => path.includes('GitHub競合')), false);
  assert.equal(paths.includes('Company/link.md'), false);

  const aesthetics = res.body.data.items.find((item) => item.path === 'Company/Aesthetics.md');
  assert.equal(aesthetics.id, fileId('Company/Aesthetics.md'));
  assert.equal(aesthetics.area, 'company');
  assert.equal(aesthetics.status, '採用済み');
  assert.equal(aesthetics.checked, '2026-10-01');
  assert.equal(aesthetics.title, 'Aesthetics');
  assert.equal(aesthetics.contentHash, sha(readFileSync(join(root, 'Company/Aesthetics.md'), 'utf8')));
  assert.equal('text' in aesthetics, false, 'a listing must not carry note bodies');
  assert.deepEqual(res.body.data.optionalAreas,
    ['attachments', 'inbox', 'journal', 'old', 'sources', 'trading-research', 'unclassified']);
});

test('naming a restricted area adds it without widening anything else', async (t) => {
  const { api } = await startBrain(t);
  const token = await api.token();
  const res = await api.request('/v1/brain/files?area=inbox', { token });
  assert.equal(res.status, 200);
  const paths = res.body.data.items.map((item) => item.path);
  assert.ok(paths.includes('Inbox/Draft.md'));
  assert.ok(paths.includes('Company/Aesthetics.md'));
  assert.equal(paths.includes('old/Legacy.md'), false);
  assert.ok(res.body.data.areas.includes('inbox'));

  const unknown = await api.request('/v1/brain/files?area=secrets', { token });
  assert.equal(unknown.status, 400);
  assert.equal(unknown.body.error.code, 'area_unknown');
});

test('the listing paginates with an opaque cursor', async (t) => {
  const { api } = await startBrain(t);
  const token = await api.token();
  const first = await api.request('/v1/brain/files?limit=2', { token });
  assert.equal(first.status, 200);
  assert.equal(first.body.data.items.length, 2);
  assert.equal(first.body.data.total > 2, true);
  assert.ok(first.body.data.nextCursor);
  const second = await api.request(`/v1/brain/files?limit=2&cursor=${first.body.data.nextCursor}`, { token });
  assert.equal(second.status, 200);
  assert.notEqual(second.body.data.items[0].path, first.body.data.items[0].path);
  const bad = await api.request('/v1/brain/files?cursor=not-a-cursor', { token });
  assert.equal(bad.status, 400);
  assert.equal(bad.body.error.code, 'cursor_invalid');
});

test('a note is returned with its body, hash and etag; a restricted note needs its area', async (t) => {
  const { api } = await startBrain(t);
  const token = await api.token();
  const res = await api.request(`/v1/brain/files/${fileId('Company/Aesthetics.md')}`, { token });
  assert.equal(res.status, 200);
  assert.equal(res.body.data.path, 'Company/Aesthetics.md');
  assert.equal(res.body.data.text, AESTHETICS);
  assert.equal(res.body.data.contentHash, sha(AESTHETICS));
  assert.equal(res.headers.get('etag'), `"${res.body.data.contentHash}"`);

  const draftId = fileId('Inbox/Draft.md');
  const hidden = await api.request(`/v1/brain/files/${draftId}`, { token });
  assert.equal(hidden.status, 404);
  assert.equal(hidden.body.error.code, 'not_found');

  const allowed = await api.request(`/v1/brain/files/${draftId}?area=inbox`, { token });
  assert.equal(allowed.status, 200);
  assert.equal(allowed.body.data.text, DRAFT);
  assert.equal(allowed.body.data.status, '草案');
});

test('ids that leave the vault, point at a symlink or are not notes are refused', async (t) => {
  const { api } = await startBrain(t);
  const token = await api.token();
  const cases = [
    [fileId('Company/../etc/passwd.md'), 400],
    [fileId('/etc/hosts'), 400],
    [fileId('Company/link.md'), 404],
    [fileId('Company/missing.md'), 404],
    [fileId('Company/Aesthetics.txt'), 400],
    [fileId('Company/.hidden.md'), 400],
    [fileId('Company/note.sync-conflict-1.md'), 400],
    [fileId('AGENTS.md'), 400],
  ];
  for (const [id, status] of cases) {
    const res = await api.request(`/v1/brain/files/${id}`, { token });
    assert.equal(res.status, status, `${id} should be ${status}: ${res.body?.error?.code}`);
  }
  const malformed = await api.request('/v1/brain/files/bf_%%%', { token });
  assert.equal(malformed.status, 404);
});

test('search reuses the CLI shape, is local-only by default and filters restricted hits', async (t) => {
  const { api, calls } = await startBrain(t);
  const token = await api.token();
  const res = await api.request('/v1/brain/search?q=色&k=3', { token });
  assert.equal(res.status, 200);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].rerank, false, 'the Bridge must not send Brain text to the re-ranker by default');
  assert.deepEqual(calls[0].areas, []);
  assert.equal(res.body.data.results.length, 1);
  assert.equal(res.body.data.results[0].path, 'Company/Aesthetics.md');
  assert.equal(res.body.data.results[0].relevanceStatus, 'unjudged');
  assert.equal(res.body.data.matchBasis, 'lexical_only');

  const rerank = await api.request('/v1/brain/search?q=色&rerank=1&area=old', { token });
  assert.equal(rerank.status, 200);
  assert.equal(calls[1].rerank, true);
  assert.deepEqual(calls[1].areas, ['old']);
  assert.equal(rerank.body.data.results.length, 2, 'the requested area is allowed for this request');

  const missing = await api.request('/v1/brain/search', { token });
  assert.equal(missing.status, 400);
  assert.equal(missing.body.error.code, 'query_invalid');

  const bigK = await api.request('/v1/brain/search?q=x&k=11', { token });
  assert.equal(bigK.status, 400);
});

test('a failing search adapter becomes 503, not an empty result', async (t) => {
  const { api } = await startBrain(t, {
    search: async () => {
      throw new BridgeError(503, 'brain_search_failed', 'the Brain search failed', { retryable: true });
    },
  });
  const res = await api.request('/v1/brain/search?q=色', { token: await api.token() });
  assert.equal(res.status, 503);
  assert.equal(res.body.error.code, 'brain_search_failed');
  assert.equal(res.body.error.retryable, true);
});

test('a note is created exactly as sent, with a hash from the written bytes', async (t) => {
  const { api, root } = await startBrain(t);
  const auth = await api.token([...DEFAULT_SCOPES, 'brain:create']);
  const content = '# 買い物\n\n- 牛乳\n- 醤油\n';
  const res = await api.request('/v1/brain/files', {
    method: 'POST', token: auth, key: 'brain-create-1',
    body: { path: 'Inbox/買い物.md', content },
  });
  assert.equal(res.status, 201);
  assert.equal(res.body.data.path, 'Inbox/買い物.md');
  assert.equal(res.body.data.area, 'inbox');
  assert.equal(res.body.data.size, Buffer.byteLength(content, 'utf8'));
  assert.equal(res.body.data.contentHash, sha(content));
  assert.equal(res.body.data.suffixApplied, false);
  assert.equal(readFileSync(join(root, 'Inbox/買い物.md'), 'utf8'), content);

  const read = await api.request(`/v1/brain/files/${res.body.data.id}?area=inbox`, { token: auth });
  assert.equal(read.status, 200);
  assert.equal(read.body.data.text, content);

  const defaultList = await api.request('/v1/brain/files', { token: auth });
  assert.equal(defaultList.body.data.items.some((item) => item.path === 'Inbox/買い物.md'), false);
});

test('creation needs brain:create, which the default device scopes do not include', async (t) => {
  const { api } = await startBrain(t);
  const auth = await api.token();
  const me = await api.request('/v1/me', { token: auth });
  assert.equal(me.body.data.scopes.includes('brain:create'), false);
  const res = await api.request('/v1/brain/files', {
    method: 'POST', token: auth, key: 'brain-create-scope', body: { path: 'Inbox/x.md', content: 'x' },
  });
  assert.equal(res.status, 403);
  assert.equal(res.body.error.code, 'insufficient_scope');
});

test('a create is idempotent and never touches an existing note', async (t) => {
  const { api, root } = await startBrain(t);
  const auth = await api.token([...DEFAULT_SCOPES, 'brain:create']);
  const body = { path: 'Inbox/Note.md', content: 'first' };
  const first = await api.request('/v1/brain/files', { method: 'POST', token: auth, key: 'k1', body });
  assert.equal(first.status, 201);
  const replay = await api.request('/v1/brain/files', { method: 'POST', token: auth, key: 'k1', body });
  assert.equal(replay.status, 201);
  assert.equal(replay.headers.get('idempotency-replayed'), 'true');
  assert.deepEqual(replay.body.data, first.body.data);
  assert.equal(readFileSync(join(root, 'Inbox/Note.md'), 'utf8'), 'first');

  const different = await api.request('/v1/brain/files', {
    method: 'POST', token: auth, key: 'k1', body: { path: 'Inbox/Note.md', content: 'second' },
  });
  assert.equal(different.status, 409);
  assert.equal(different.body.error.code, 'idempotency_key_conflict');

  const noKey = await api.request('/v1/brain/files', { method: 'POST', token: auth, body });
  assert.equal(noKey.status, 400);
  assert.equal(noKey.body.error.code, 'idempotency_key_required');
});

test('a name conflict is resolved by a suffix by default and by refusal on request', async (t) => {
  const { api, root } = await startBrain(t);
  const auth = await api.token([...DEFAULT_SCOPES, 'brain:create']);
  const created = await api.request('/v1/brain/files', {
    method: 'POST', token: auth, key: 's1', body: { path: 'Inbox/Note.md', content: 'first' },
  });
  assert.equal(created.status, 201);

  const suffixed = await api.request('/v1/brain/files', {
    method: 'POST', token: auth, key: 's2', body: { path: 'Inbox/Note.md', content: 'second' },
  });
  assert.equal(suffixed.status, 201);
  assert.equal(suffixed.body.data.path, 'Inbox/Note 2.md');
  assert.equal(suffixed.body.data.requestedPath, 'Inbox/Note.md');
  assert.equal(suffixed.body.data.suffixApplied, true);
  assert.equal(readFileSync(join(root, 'Inbox/Note.md'), 'utf8'), 'first');
  assert.equal(readFileSync(join(root, 'Inbox/Note 2.md'), 'utf8'), 'second');

  const rejected = await api.request('/v1/brain/files', {
    method: 'POST', token: auth, key: 's3', body: { path: 'Inbox/Note.md', content: 'third', onConflict: 'reject' },
  });
  assert.equal(rejected.status, 409);
  assert.equal(rejected.body.error.code, 'path_exists');
  assert.equal(existsSync(join(root, 'Inbox/Note 3.md')), false);
});

test('two concurrent creates of one name both land, on different paths', async (t) => {
  const { api } = await startBrain(t);
  const auth = await api.token([...DEFAULT_SCOPES, 'brain:create']);
  const [a, b] = await Promise.all([
    api.request('/v1/brain/files', { method: 'POST', token: auth, key: 'c1', body: { path: 'Inbox/Race.md', content: 'a' } }),
    api.request('/v1/brain/files', { method: 'POST', token: auth, key: 'c2', body: { path: 'Inbox/Race.md', content: 'b' } }),
  ]);
  assert.equal(a.status, 201);
  assert.equal(b.status, 201);
  assert.notEqual(a.body.data.path, b.body.data.path);
});

test('a create outside the allowed prefix, or with an invalid path, is refused', async (t) => {
  const { api } = await startBrain(t);
  const auth = await api.token([...DEFAULT_SCOPES, 'brain:create']);
  const cases = [
    ['Company/Aesthetics.md', 403, 'brain_create_area_forbidden'],
    ['Inbox/../Company/x.md', 400, 'path_invalid'],
    ['/Inbox/x.md', 400, 'path_invalid'],
    ['Inbox/x.txt', 400, 'path_invalid'],
    ['Inbox/.hidden.md', 400, 'path_invalid'],
    ['Inbox/note.sync-conflict-1.md', 400, 'path_invalid'],
    ['Inbox/AGENTS.md', 400, 'path_invalid'],
    ['Inbox/a:b.md', 400, 'path_invalid'],
    ['Inbox/missing/x.md', 400, 'path_parent_missing'],
  ];
  let key = 0;
  for (const [path, status, code] of cases) {
    key += 1;
    const res = await api.request('/v1/brain/files', {
      method: 'POST', token: auth, key: `bad-${key}`, body: { path, content: 'x' },
    });
    assert.equal(res.status, status, `${path}: ${res.body?.error?.code}`);
    assert.equal(res.body.error.code, code);
  }
  const tooBig = await api.request('/v1/brain/files', {
    method: 'POST', token: auth, key: 'bad-big', body: { path: 'Inbox/big.md', content: 'x'.repeat(49 * 1024) },
  });
  assert.equal(tooBig.status, 400);
  assert.equal(tooBig.body.error.code, 'content_too_large');
});

test('a failing precondition refuses the create before anything is written', async (t) => {
  const cases = [
    [{ sync: async () => { throw new BridgeError(503, 'brain_sync_paused', 'paused', { retryable: true }); } }, 503, 'brain_sync_paused'],
    [{ git: () => { throw new BridgeError(423, 'brain_git_busy', 'lock', { retryable: true }); } }, 423, 'brain_git_busy'],
    [{ disk: () => { throw new BridgeError(503, 'brain_vault_no_space', 'space', { retryable: true }); } }, 503, 'brain_vault_no_space'],
  ];
  for (const [gates, status, code] of cases) {
    const { api, root } = await startBrain(t, { gates });
    const res = await api.request('/v1/brain/files', {
      method: 'POST', token: await api.token([...DEFAULT_SCOPES, 'brain:create']),
      key: `gate-${code}`, body: { path: 'Inbox/g.md', content: 'x' },
    });
    assert.equal(res.status, status);
    assert.equal(res.body.error.code, code);
    assert.equal(existsSync(join(root, 'Inbox/g.md')), false);
  }
});

test('an unwritable journal refuses the create before the vault is touched', async (t) => {
  const journalFile = mkdtempSync(join(tmpdir(), 'laa-brain-journal-'));
  t.after(() => rmSync(journalFile, { recursive: true, force: true }));
  const { api, root } = await startBrain(t, { brain: { journalFile } });
  const res = await api.request('/v1/brain/files', {
    method: 'POST', token: await api.token([...DEFAULT_SCOPES, 'brain:create']), key: 'j1',
    body: { path: 'Inbox/j.md', content: 'x' },
  });
  assert.equal(res.status, 503);
  assert.equal(res.body.error.code, 'brain_journal_unavailable');
  assert.equal(existsSync(join(root, 'Inbox/j.md')), false);
});

test('the journal records the intent and the commit with hashes, never the body', async (t) => {
  const { api, root } = await startBrain(t);
  const content = '# 本文は残さない\n';
  const res = await api.request('/v1/brain/files', {
    method: 'POST', token: await api.token([...DEFAULT_SCOPES, 'brain:create']), key: 'jr1',
    body: { path: 'Inbox/J.md', content },
  });
  assert.equal(res.status, 201);
  const journalFile = join(root, '..', `${root.split('/').pop()}-journal.jsonl`);
  const raw = readFileSync(journalFile, 'utf8');
  const lines = raw.trim().split('\n').map((line) => JSON.parse(line));
  assert.equal(lines.length, 2);
  assert.equal(lines[0].phase, 'intent');
  assert.equal(lines[1].phase, 'committed');
  assert.equal(lines[1].path, 'Inbox/J.md');
  assert.equal(lines[1].contentHash, sha(content));
  assert.equal(lines[1].size, Buffer.byteLength(content, 'utf8'));
  assert.equal(raw.includes('本文は残さない'), false);
  assert.equal(lines[1].requestId.startsWith('req_'), true);
  assert.match(lines[1].deviceId, /^dev_/);
});

test('the gate report names each dependency instead of hiding a failure', async (t) => {
  const { api } = await startBrain(t, {
    gates: { sync: async () => { throw new BridgeError(503, 'brain_sync_paused', 'paused', { retryable: true }); } },
  });
  const res = await api.request('/v1/brain/gates', { token: await api.token() });
  assert.equal(res.status, 200);
  assert.equal(res.body.data.vault.available, true);
  assert.equal(res.body.data.git.ok, true);
  assert.equal(res.body.data.sync.ok, false);
  assert.equal(res.body.data.sync.code, 'brain_sync_paused');
  assert.equal(res.body.data.disk.ok, true);
});

// --- the real gate adapters ------------------------------------------------

test('the git gate refuses a lock, a rebase and a non-master checkout', (t) => {
  const root = mkdtempSync(join(tmpdir(), 'laa-brain-git-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const gitDir = join(root, '.git');
  mkdirSync(gitDir, { recursive: true });
  writeFileSync(join(gitDir, 'HEAD'), 'ref: refs/heads/master\n');

  const check = createGitGate({ vaultRoot: root });
  assert.deepEqual(check().branch, 'master');

  writeFileSync(join(gitDir, 'index.lock'), '');
  assert.throws(check, (err) => err.status === 423 && err.code === 'brain_git_busy');
  rmSync(join(gitDir, 'index.lock'));

  mkdirSync(join(gitDir, 'rebase-merge'));
  assert.throws(check, (err) => err.status === 423);
  rmSync(join(gitDir, 'rebase-merge'), { recursive: true });

  writeFileSync(join(gitDir, 'HEAD'), 'ref: refs/heads/topic\n');
  assert.throws(check, (err) => err.status === 423 && err.code === 'brain_git_branch');

  rmSync(join(gitDir, 'HEAD'));
  assert.throws(check, (err) => err.code === 'brain_git_unavailable');
});

test('the disk gate refuses a vault with too little free space', (t) => {
  const root = mkdtempSync(join(tmpdir(), 'laa-brain-disk-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  assert.equal(typeof createDiskGate({ vaultRoot: root })().freeBytes, 'number');
  assert.throws(createDiskGate({ vaultRoot: root, minFreeBytes: Number.MAX_SAFE_INTEGER }),
    (err) => err.status === 503 && err.code === 'brain_vault_no_space');
});

test('the Syncthing gate maps paused, errored, unreachable and missing-key states', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'laa-brain-sync-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const configPath = join(dir, 'config.xml');
  writeFileSync(configPath, '<configuration><apikey>abc123</apikey></configuration>');

  const ok = createSyncthingGate({
    configPath, baseUrl: 'http://127.0.0.1:8384', folder: 'brain',
    fetchImpl: async (url, init) => {
      assert.equal(init.headers['x-api-key'], 'abc123');
      assert.equal(url.endsWith('/rest/db/status?folder=brain'), true);
      return { ok: true, status: 200, json: async () => ({ state: 'idle', errors: 0, pullErrors: 0 }) };
    },
  });
  assert.equal((await ok()).state, 'idle');

  const paused = createSyncthingGate({
    configPath, baseUrl: 'http://x', folder: 'brain',
    fetchImpl: async () => ({ ok: true, status: 200, json: async () => ({ paused: true }) }),
  });
  await assert.rejects(paused, (err) => err.status === 503 && err.code === 'brain_sync_paused');

  const errored = createSyncthingGate({
    configPath, baseUrl: 'http://x', folder: 'brain',
    fetchImpl: async () => ({ ok: true, status: 200, json: async () => ({ errors: 1 }) }),
  });
  await assert.rejects(errored, (err) => err.code === 'brain_sync_error');

  const down = createSyncthingGate({
    configPath, baseUrl: 'http://x', folder: 'brain',
    fetchImpl: async () => { throw new Error('ECONNREFUSED'); },
  });
  await assert.rejects(down, (err) => err.code === 'brain_sync_unavailable');

  const noKey = createSyncthingGate({
    configPath: join(dir, 'absent.xml'), baseUrl: 'http://x', folder: 'brain',
    fetchImpl: async () => ({ ok: true, status: 200, json: async () => ({}) }),
  });
  await assert.rejects(noKey, (err) => err.code === 'brain_sync_unavailable');
});

test('the journal keeps 0600 and refuses a path it cannot append to', (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'laa-brain-journal-unit-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const file = join(dir, 'nested', 'journal.jsonl');
  const journal = createJournal({ file });
  journal.intent({ phase: 'intent', path: 'Inbox/a.md' });
  journal.close({ phase: 'committed', path: 'Inbox/a.md' });
  assert.equal(readFileSync(file, 'utf8').trim().split('\n').length, 2);

  const blocked = createJournal({ file: dir });
  assert.throws(() => blocked.intent({ phase: 'intent' }),
    (err) => err.status === 503 && err.code === 'brain_journal_unavailable');
});

test('a policy file that is missing is a 503, not an empty vault', async (t) => {
  const { api, policyFile } = await startBrain(t);
  rmSync(policyFile);
  const res = await api.request('/v1/brain/files', { token: await api.token() });
  assert.equal(res.status, 503);
  assert.equal(res.body.error.code, 'brain_policy_unavailable');
});

test('parseVaultPath and hashBuffer keep the documented shapes', () => {
  assert.equal(parseVaultPath('Inbox/買い物.md'), 'Inbox/買い物.md');
  assert.equal(parseVaultPath('Inbox/e\u0301.md'), 'Inbox/é.md');
  assert.equal(hashBuffer(Buffer.from('x')), sha('x'));
  assert.throws(() => parseVaultPath('Inbox/a.md/'), (err) => err.code === 'path_invalid');
});

test('a note the Bridge cannot read stays visible instead of hiding the listing', async (t) => {
  const { api, root } = await startBrain(t);
  const token = await api.token();
  writeFileSync(join(root, 'Company/huge.md'), `# huge\n${'x'.repeat(300 * 1024)}`, 'utf8');
  const res = await api.request('/v1/brain/files', { token });
  assert.equal(res.status, 200);
  const huge = res.body.data.items.find((item) => item.path === 'Company/huge.md');
  assert.ok(huge, 'an oversized note must still be listed');
  assert.equal(huge.contentHash, null);
  assert.equal(huge.unreadable, 'file_too_large');
  const single = await api.request(`/v1/brain/files/${fileId('Company/huge.md')}`, { token });
  assert.equal(single.status, 413);
  assert.equal(single.body.error.code, 'file_too_large');
});

test('a replacement-shaped create body is refused instead of ignored', async (t) => {
  const { api } = await startBrain(t);
  const auth = await api.token([...DEFAULT_SCOPES, 'brain:create']);
  for (const extra of [{ baseHash: 'sha256:x' }, { overwrite: true }]) {
    const res = await api.request('/v1/brain/files', {
      method: 'POST', token: auth, key: `extra-${Object.keys(extra)[0]}`,
      body: { path: 'Inbox/x.md', content: 'x', ...extra },
    });
    assert.equal(res.status, 400);
    assert.equal(res.body.error.code, 'unsupported_field');
  }
});

test('the vault does not create parent folders', async (t) => {
  const { api, root } = await startBrain(t);
  const res = await api.request('/v1/brain/files', {
    method: 'POST', token: await api.token([...DEFAULT_SCOPES, 'brain:create']), key: 'parent-1',
    body: { path: 'Inbox/new/deep.md', content: 'x' },
  });
  assert.equal(res.status, 400);
  assert.equal(res.body.error.code, 'path_parent_missing');
  assert.equal(existsSync(join(root, 'Inbox/new')), false);
});

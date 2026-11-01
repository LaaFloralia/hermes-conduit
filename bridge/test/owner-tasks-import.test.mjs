import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { buildManifest, candidateOf, computeManifestHash } from '../src/tasks/owner-import.mjs';

const CLI = new URL('../src/cli.mjs', import.meta.url).pathname;
const ASSIGNEE = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';

function tempDir(t, prefix = 'laa-owner-import-') {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function makeIssue(index, overrides = {}) {
  return {
    id: `00000000-0000-4000-8000-${String(index).padStart(12, '0')}`,
    identifier: `BUS-${index}`,
    title: `task ${index}`,
    description: `memo ${index}`,
    url: `https://linear.app/laa/issue/BUS-${index}`,
    updatedAt: `2026-10-${String((index % 28) + 1).padStart(2, '0')}T00:00:00.000Z`,
    dueDate: null,
    state: { name: 'Todo', type: 'unstarted' },
    assignee: { id: ASSIGNEE, name: 'LAA' },
    team: { id: 'team-1', key: 'BUS', name: 'BUS' },
    project: null,
    labels: { nodes: [] },
    comments: { nodes: [] },
    attachments: { nodes: [] },
    ...overrides,
  };
}

// A loopback GraphQL responder. It records every request so a test can prove no
// mutation was ever sent, and it never talks to Linear.
async function fakeLinear(t, { issues, pageSize = 50, failPage = null, loopPage = null, malformedPage = null } = {}) {
  // Pages are computed per request so a test can change the source between the
  // dry-run and the import.
  const pagesOf = () => {
    const pages = [];
    for (let i = 0; i < issues.length; i += pageSize) pages.push(issues.slice(i, i + pageSize));
    if (pages.length === 0) pages.push([]);
    return pages;
  };
  const requests = [];
  const server = createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    let body;
    try {
      body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    } catch {
      res.writeHead(400).end('{}');
      return;
    }
    requests.push({ headers: req.headers, body });
    const index = body.variables?.after ? Number(String(body.variables.after).slice(1)) : 0;
    if (failPage !== null && index === failPage) {
      res.writeHead(500, { 'content-type': 'application/json' }).end('{"errors":[{"message":"boom"}]}');
      return;
    }
    const pages = pagesOf();
    const page = pages[index] ?? [];
    if (malformedPage !== null && index === malformedPage) {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ data: { issues: { nodes: page } } }));
      return;
    }
    const hasNextPage = index < pages.length - 1;
    const endCursor = hasNextPage ? `p${loopPage === index ? index : index + 1}` : null;
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ data: { issues: { nodes: page, pageInfo: { hasNextPage, endCursor } } } }));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const { port } = server.address();
  return { endpoint: `http://127.0.0.1:${port}/graphql`, requests };
}

function tokenHelper(t) {
  const dir = tempDir(t, 'laa-owner-token-');
  const file = join(dir, 'token.sh');
  writeFileSync(file, '#!/bin/sh\nprintf "lin_api_test_token"\n', { mode: 0o700 });
  return file;
}

function run(args, { env }) {
  return new Promise((resolve) => {
    const child = execFile(process.execPath, [CLI, ...args], {
      env: { ...process.env, LAA_BRIDGE_QUIET: '1', ...env },
      maxBuffer: 8 * 1024 * 1024,
    }, (error, stdout, stderr) => {
      resolve({ code: typeof error?.code === 'number' ? error.code : error ? 1 : 0, stdout, stderr });
    });
    child.stdin.end();
  });
}

function envFor(t, linear) {
  return {
    LAA_BRIDGE_STATE_DIR: tempDir(t),
    LAA_BRIDGE_LINEAR_ENDPOINT: linear.endpoint,
    LAA_BRIDGE_LINEAR_TOKEN_HELPER: tokenHelper(t),
  };
}

async function dryRun(t, linear, extra = []) {
  const out = join(tempDir(t), 'manifest.json');
  const result = await run(['tasks', 'import-linear', '--dry-run', '--assignee', ASSIGNEE, '--out', out, '--json', ...extra], { env: envFor(t, linear) });
  return { ...result, out, manifest: result.code === 0 ? JSON.parse(readFileSync(out, 'utf8')) : null };
}

test('a dry-run writes a manifest and changes nothing else', async (t) => {
  const linear = await fakeLinear(t, {
    issues: [
      makeIssue(1),
      makeIssue(2, { dueDate: '2026-11-05', project: { id: 'p1', name: 'P' }, comments: { nodes: [{ id: 'c1' }] } }),
      makeIssue(3, { state: { name: 'Triage', type: 'triage' } }),
    ],
  });
  const env = envFor(t, linear);
  const out = join(tempDir(t), 'manifest.json');
  const result = await run(['tasks', 'import-linear', '--dry-run', '--assignee', ASSIGNEE, '--out', out, '--json'], { env });

  assert.equal(result.code, 0, result.stderr);
  const body = JSON.parse(result.stdout);
  assert.equal(body.dryRun, true);
  assert.deepEqual(body.counts, { fetched: 3, selected: 2, excluded: 1, undecided: 1 });
  assert.equal(body.contentHash, `sha256:${body.contentHash.slice(7)}`);
  assert.equal(statSync(out).mode & 0o777, 0o600);
  assert.deepEqual(readdirSync(env.LAA_BRIDGE_STATE_DIR), [], 'a dry-run must not create the store');

  const manifest = JSON.parse(readFileSync(out, 'utf8'));
  assert.equal(manifest.format, 'laa-owner-tasks-import');
  assert.equal(manifest.version, 1);
  assert.equal(manifest.assigneeId, ASSIGNEE);
  assert.equal(manifest.contentHash, computeManifestHash(manifest));
  const third = manifest.candidates.find((candidate) => candidate.identifier === 'BUS-3');
  assert.equal(third.excluded, 'state_undecided');
  const second = manifest.candidates.find((candidate) => candidate.identifier === 'BUS-2');
  assert.deepEqual(second.notes.sort(), ['comments_not_migrated', 'project_not_migrated']);
  assert.equal(second.dueDate, '2026-11-05');
  assert.match(second.taskId, /^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);

  // Only queries, and the token came from the helper.
  assert.ok(linear.requests.length > 0);
  for (const request of linear.requests) {
    assert.match(request.body.query, /^\s*query\s/);
    assert.doesNotMatch(request.body.query, /mutation|subscription/i);
    assert.equal(request.headers.authorization, 'lin_api_test_token');
  }
});

test('two dry-runs over unchanged data produce the same content hash', async (t) => {
  const linear = await fakeLinear(t, { issues: [makeIssue(1), makeIssue(2)] });
  const env = envFor(t, linear);
  const first = await run(['tasks', 'import-linear', '--dry-run', '--assignee', ASSIGNEE, '--out', join(tempDir(t), 'a.json'), '--json'], { env });
  const second = await run(['tasks', 'import-linear', '--dry-run', '--assignee', ASSIGNEE, '--out', join(tempDir(t), 'b.json'), '--json'], { env });
  assert.equal(first.code, 0, first.stderr);
  assert.equal(second.code, 0, second.stderr);
  assert.equal(JSON.parse(first.stdout).contentHash, JSON.parse(second.stdout).contentHash);
});

test('the approved manifest becomes tasks in one go and is idempotent', async (t) => {
  const linear = await fakeLinear(t, {
    issues: [
      makeIssue(1),
      makeIssue(2, { dueDate: '2026-11-05', description: '# 見出し\n本文' }),
      makeIssue(3, { state: { name: 'Doing', type: 'started' } }),
    ],
  });
  const env = envFor(t, linear);
  const out = join(tempDir(t), 'manifest.json');
  const dry = await run(['tasks', 'import-linear', '--dry-run', '--assignee', ASSIGNEE, '--out', out, '--json'], { env });
  assert.equal(dry.code, 0, dry.stderr);
  const { contentHash } = JSON.parse(dry.stdout);

  const applied = await run(['tasks', 'import-linear', '--manifest', out, '--approve', contentHash, '--json'], { env });
  assert.equal(applied.code, 0, applied.stderr);
  const body = JSON.parse(applied.stdout);
  assert.equal(body.replayed, false);
  assert.equal(body.import.count, 3);

  const listed = JSON.parse((await run(['tasks', 'list', '--json'], { env })).stdout);
  assert.equal(listed.total, 3);
  const row = listed.items.find((task) => task.title === 'task 2');
  assert.equal(row.source, 'linear_import');
  assert.equal(row.memo, undefined, 'the list carries no body');
  assert.equal(row.dueDate, '2026-11-05');
  assert.equal(row.updatedAt, '2026-10-03T00:00:00.000Z');
  assert.equal(listed.items.find((task) => task.title === 'task 3').status, 'doing');
  const detail = JSON.parse((await run(['tasks', 'get', '--id', row.id, '--json'], { env })).stdout).task;
  assert.equal(detail.memo, '# 見出し\n本文');
  assert.deepEqual(detail.links, ['https://linear.app/laa/issue/BUS-2']);

  const again = await run(['tasks', 'import-linear', '--manifest', out, '--approve', contentHash, '--json'], { env });
  assert.equal(again.code, 0, again.stderr);
  assert.equal(JSON.parse(again.stdout).replayed, true);
  assert.equal(JSON.parse((await run(['tasks', 'list', '--json'], { env })).stdout).total, 3);

  // A later dry-run sees them as already imported and selects nothing.
  const later = await run(['tasks', 'import-linear', '--dry-run', '--assignee', ASSIGNEE, '--out', join(tempDir(t), 'c.json'), '--json'], { env });
  assert.deepEqual(JSON.parse(later.stdout).counts, { fetched: 3, selected: 0, excluded: 3, undecided: 0 });
});

test('an unapproved or edited manifest is refused before anything is written', async (t) => {
  const linear = await fakeLinear(t, { issues: [makeIssue(1)] });
  const env = envFor(t, linear);
  const out = join(tempDir(t), 'manifest.json');
  const dry = await run(['tasks', 'import-linear', '--dry-run', '--assignee', ASSIGNEE, '--out', out, '--json'], { env });
  const { contentHash } = JSON.parse(dry.stdout);

  const wrong = await run(['tasks', 'import-linear', '--manifest', out, '--approve', 'sha256:' + '0'.repeat(64), '--json'], { env });
  assert.equal(wrong.code, 4);
  assert.equal(JSON.parse(wrong.stdout).error.code, 'owner_tasks_import_approval_mismatch');

  const withoutApproval = await run(['tasks', 'import-linear', '--manifest', out], { env });
  assert.equal(withoutApproval.code, 2);

  const manifest = JSON.parse(readFileSync(out, 'utf8'));
  manifest.candidates[0].title = 'edited after approval';
  writeFileSync(out, JSON.stringify(manifest));
  const edited = await run(['tasks', 'import-linear', '--manifest', out, '--approve', contentHash, '--json'], { env });
  assert.equal(edited.code, 4);
  assert.equal(JSON.parse(edited.stdout).error.code, 'owner_tasks_import_manifest_invalid');
  assert.equal(JSON.parse((await run(['tasks', 'list', '--json'], { env })).stdout).total, 0);
});

test('Linear changing after the dry-run blocks the import', async (t) => {
  const issues = [makeIssue(1), makeIssue(2)];
  const linear = await fakeLinear(t, { issues });
  const env = envFor(t, linear);
  const out = join(tempDir(t), 'manifest.json');
  const dry = await run(['tasks', 'import-linear', '--dry-run', '--assignee', ASSIGNEE, '--out', out, '--json'], { env });
  const { contentHash } = JSON.parse(dry.stdout);

  issues[0].updatedAt = '2026-10-20T00:00:00.000Z';
  const stale = await run(['tasks', 'import-linear', '--manifest', out, '--approve', contentHash, '--json'], { env });
  assert.equal(stale.code, 4);
  assert.equal(JSON.parse(stale.stdout).error.code, 'owner_tasks_import_stale');
  assert.equal(JSON.parse((await run(['tasks', 'list', '--json'], { env })).stdout).total, 0);
});

test('a new Linear issue after the dry-run also blocks the import', async (t) => {
  const issues = [makeIssue(1)];
  const linear = await fakeLinear(t, { issues });
  const env = envFor(t, linear);
  const out = join(tempDir(t), 'manifest.json');
  const dry = await run(['tasks', 'import-linear', '--dry-run', '--assignee', ASSIGNEE, '--out', out, '--json'], { env });
  const { contentHash } = JSON.parse(dry.stdout);

  issues.push(makeIssue(2));
  const stale = await run(['tasks', 'import-linear', '--manifest', out, '--approve', contentHash, '--json'], { env });
  assert.equal(stale.code, 4);
  assert.equal(JSON.parse(stale.stdout).error.details.added, 1);
});

test('the import is all or nothing', async (t) => {
  const linear = await fakeLinear(t, { issues: [makeIssue(1), makeIssue(2)] });
  const env = envFor(t, linear);
  const out = join(tempDir(t), 'manifest.json');
  const dry = await run(['tasks', 'import-linear', '--dry-run', '--assignee', ASSIGNEE, '--out', out, '--json'], { env });
  const { contentHash } = JSON.parse(dry.stdout);
  const manifest = JSON.parse(readFileSync(out, 'utf8'));
  const reserved = manifest.candidates[0].taskId;

  const preexisting = await run(['tasks', 'add', '--id', reserved, '--request-id', 'pre', '--title', 'already here', '--json'], { env });
  assert.equal(preexisting.code, 0, preexisting.stderr);

  const applied = await run(['tasks', 'import-linear', '--manifest', out, '--approve', contentHash, '--json'], { env });
  assert.equal(applied.code, 4);
  const listed = JSON.parse((await run(['tasks', 'list', '--json'], { env })).stdout);
  assert.equal(listed.total, 1, 'the other candidate must not have been created');
});

test('a failed page stops the dry-run and writes no manifest', async (t) => {
  const linear = await fakeLinear(t, { issues: [makeIssue(1), makeIssue(2), makeIssue(3)], pageSize: 1, failPage: 1 });
  const env = envFor(t, linear);
  const out = join(tempDir(t), 'manifest.json');
  const result = await run(['tasks', 'import-linear', '--dry-run', '--assignee', ASSIGNEE, '--out', out, '--json'], { env });
  assert.equal(result.code, 7);
  assert.equal(JSON.parse(result.stdout).error.code, 'linear_unavailable');
  assert.deepEqual(readdirSync(env.LAA_BRIDGE_STATE_DIR), []);
});

test('an incomplete page stops the dry-run instead of importing part of it', async (t) => {
  const linear = await fakeLinear(t, { issues: [makeIssue(1), makeIssue(2)], pageSize: 1, malformedPage: 0 });
  const env = envFor(t, linear);
  const result = await run(['tasks', 'import-linear', '--dry-run', '--assignee', ASSIGNEE, '--out', join(tempDir(t), 'm.json'), '--json'], { env });
  assert.equal(result.code, 7);
  assert.equal(JSON.parse(result.stdout).error.code, 'linear_response_invalid');
  assert.deepEqual(readdirSync(env.LAA_BRIDGE_STATE_DIR), []);
});

test('a pagination loop stops the dry-run', async (t) => {
  const linear = await fakeLinear(t, { issues: [makeIssue(1), makeIssue(2)], pageSize: 1, loopPage: 0 });
  const env = envFor(t, linear);
  const result = await run(['tasks', 'import-linear', '--dry-run', '--assignee', ASSIGNEE, '--out', join(tempDir(t), 'm.json'), '--json'], { env });
  assert.equal(result.code, 7);
  assert.equal(JSON.parse(result.stdout).error.code, 'linear_pagination_loop');
});

test('more than five hundred issues are read page by page', async (t) => {
  const issues = Array.from({ length: 520 }, (_, i) => makeIssue(i + 1));
  const linear = await fakeLinear(t, { issues, pageSize: 50 });
  const env = envFor(t, linear);
  const out = join(tempDir(t), 'manifest.json');
  const result = await run(['tasks', 'import-linear', '--dry-run', '--assignee', ASSIGNEE, '--out', out, '--json'], { env });
  assert.equal(result.code, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).counts.fetched, 520);
  assert.equal(linear.requests.length, 11);
});

test('a missing credential exits 7 without writing a manifest', async (t) => {
  const linear = await fakeLinear(t, { issues: [makeIssue(1)] });
  const env = {
    LAA_BRIDGE_STATE_DIR: tempDir(t),
    LAA_BRIDGE_LINEAR_ENDPOINT: linear.endpoint,
    LAA_BRIDGE_LINEAR_TOKEN_HELPER: join(tempDir(t), 'missing.sh'),
  };
  const out = join(tempDir(t), 'manifest.json');
  const result = await run(['tasks', 'import-linear', '--dry-run', '--assignee', ASSIGNEE, '--out', out, '--json'], { env });
  assert.equal(result.code, 7);
  assert.equal(JSON.parse(result.stdout).error.code, 'linear_credential_unavailable');
  assert.deepEqual(readdirSync(env.LAA_BRIDGE_STATE_DIR), []);
});

test('candidate mapping names every exclusion reason', () => {
  const base = { assigneeId: ASSIGNEE };
  assert.equal(candidateOf(makeIssue(1), base).excluded, null);
  assert.equal(candidateOf(makeIssue(1, { assignee: { id: 'other' } }), base).excluded, 'assignee_mismatch');
  assert.equal(candidateOf(makeIssue(1, { title: '   ' }), base).excluded, 'missing_title');
  assert.equal(candidateOf(makeIssue(1, { state: { name: 'Triage', type: 'triage' } }), base).excluded, 'state_undecided');
  assert.equal(candidateOf(makeIssue(1, { description: 'x'.repeat(20_001) }), base).excluded, 'memo_too_large');
  assert.equal(candidateOf(makeIssue(1, { title: 'x'.repeat(501) }), base).excluded, 'title_too_large');
  assert.equal(candidateOf(makeIssue(1, { dueDate: '2026-02-30' }), base).excluded, 'due_date_invalid');
  assert.equal(candidateOf(makeIssue(1, { url: 'http://insecure.example/x' }), base).excluded, 'url_invalid');
  assert.equal(candidateOf(makeIssue(1), { ...base, isImported: () => ({ taskId: 'x' }) }).excluded, 'already_imported');
  assert.equal(candidateOf(makeIssue(1), { ...base, taskIdExists: () => true }).excluded, 'task_id_conflict');
});

test('the manifest hash ignores generatedAt but covers the candidates', () => {
  const manifest = buildManifest({
    issues: [makeIssue(1)], assigneeId: ASSIGNEE, includeClosed: false, now: () => Date.parse('2026-11-01T00:00:00Z'),
  });
  const later = { ...manifest, generatedAt: '2027-01-01T00:00:00.000Z' };
  assert.equal(computeManifestHash(later), computeManifestHash(manifest));
  const changed = { ...manifest, candidates: [{ ...manifest.candidates[0], title: 'other' }] };
  assert.notEqual(computeManifestHash(changed), computeManifestHash(manifest));
});

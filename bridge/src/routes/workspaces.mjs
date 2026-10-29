// /v1/workspaces — repos and worktrees that already exist under an allowlisted
// set of roots, plus creation through the existing Paseo worktree convention.
//
// Design decisions:
//   * Projects and workspaces are separate identities (see projects.mjs). A
//     workspace record never carries a project's instructions, and a project
//     never carries a path.
//   * Listing is read-only and works even when the Paseo daemon is down: the
//     filesystem plus `git status` are the source of truth for what exists.
//     `GIT_OPTIONAL_LOCKS=0` keeps `git status` from refreshing the index.
//   * Creation goes through `paseo worktree create` so Paseo's own bookkeeping
//     (worktree root, branch, workspace visibility) stays consistent. The
//     Bridge never runs `git worktree remove`, `git reset`, `--force` or any
//     archive: an existing worktree can only be listed, never destroyed.
//   * Every path returned is realpath-checked against the allowlist, and
//     symlinks are not followed while walking, so a link inside `~/dev` cannot
//     pull a directory from outside into the inventory.

import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, readdirSync, realpathSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, dirname, isAbsolute, join, resolve, sep } from 'node:path';
import { promisify } from 'node:util';
import { resolvePaseoBin, resolveWorkspaceRoots } from '../config.mjs';
import { badRequest, conflict, dependencyUnavailable, notFound } from '../errors.mjs';
import { createJsonFile, parseObjectBody } from './state-file.mjs';

const WORKSPACE_SCHEMA = 1;
const WORKSPACE_ID_PATTERN = /^ws_[0-9a-f]{16}$/;
const WORKTREE_NAME_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const BRANCH_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._/-]{0,119}$/;
const SKIP_DIRS = new Set([
  '.git', 'node_modules', '.build', 'DerivedData', '.venv', 'venv', 'build', 'dist', '.next', '.cache', 'Pods',
]);
const WORKTREE_CONCURRENCY = 5;

export function createWorkspaceStore({ file, now = () => Date.now() }) {
  const state = createJsonFile({ file, schema: WORKSPACE_SCHEMA, initial: () => ({ workspaces: {} }) });
  return {
    file,
    get(id) {
      return state.read().workspaces?.[id] ?? null;
    },
    all() {
      return Object.values(state.read().workspaces ?? {});
    },
    findExisting(repoPath, branch) {
      return Object.values(state.read().workspaces ?? {}).find(
        (record) => record.repoPath === repoPath && record.branch === branch,
      ) ?? null;
    },
    put(record) {
      return state.mutate((doc) => {
        doc.workspaces ??= {};
        doc.workspaces[record.id] = record;
        return record;
      });
    },
    now,
  };
}

export function createWorkspaceRoutes({
  workspaceStore,
  findProject = () => null,
  now = () => Date.now(),
  roots = resolveWorkspaceRoots(),
  gitRun = defaultGitRun,
  createWorktree = defaultCreateWorktree,
  statusTtlMs = 5000,
  maxDepth = 3,
} = {}) {
  const service = createWorkspaceService({ roots, gitRun, createWorktree, statusTtlMs, maxDepth, now });

  async function list({ req }) {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    const limit = parseLimit(url.searchParams.get('limit'));
    const offset = parseCursor(url.searchParams.get('cursor'));
    const projectId = url.searchParams.get('projectId');
    if (projectId && !findProject(projectId)) throw notFound('project not found');

    const items = await service.inventory();
    const records = new Map(workspaceStore.all().map((record) => [record.path, record]));
    const filtered = items
      .map((item) => withRegistry(item, records.get(item.path)))
      .filter((item) => (projectId ? item.projectId === projectId : true));
    const page = filtered.slice(offset, offset + limit);
    return {
      status: 200,
      data: {
        items: page,
        nextCursor: offset + limit < filtered.length ? encodeCursor(offset + limit) : null,
      },
    };
  }

  async function get({ params }) {
    const item = await service.find(params[0]);
    if (!item) throw notFound('workspace not found under an allowlisted root');
    return {
      status: 200,
      data: withRegistry(item, workspaceStore.get(item.id)),
      headers: { etag: etagFor(item) },
    };
  }

  async function create({ device, rawBody }) {
    const body = parseObjectBody(rawBody);
    const repoId = requireId(body.repoId, 'repoId');
    const projectId = body.projectId === undefined || body.projectId === null
      ? null
      : requireId(body.projectId, 'projectId');
    if (projectId && !findProject(projectId)) throw notFound('project not found');
    const worktreeName = parseWorktreeName(body.worktreeName);
    const branch = body.branch === undefined || body.branch === null
      ? worktreeName
      : parseBranch(body.branch);
    const base = body.base === undefined || body.base === null ? null : parseBranch(body.base);

    const repo = await service.find(repoId);
    if (!repo) throw notFound('repo not found under an allowlisted root');
    if (repo.kind !== 'repo') {
      throw conflict('repo_is_worktree', 'create a worktree from a repository, not from another worktree');
    }

    // `rev-parse --verify --quiet` exits non-zero when the ref is absent; that
    // is the normal case here, so an exit code is not a failure by itself.
    let existingBranch = '';
    try {
      existingBranch = (await gitRun(['rev-parse', '--verify', '--quiet', `refs/heads/${branch}`], { cwd: repo.path })).trim();
    } catch {
      existingBranch = '';
    }
    if (existingBranch !== '') {
      throw conflict('worktree_exists', `branch ${branch} already exists in ${displayPath(repo.path)}`);
    }
    const recorded = workspaceStore.findExisting(repo.path, branch);
    if (recorded) throw conflict('worktree_exists', `branch ${branch} is already recorded for ${displayPath(repo.path)}`);

    let created;
    try {
      created = await createWorktree({ repoPath: repo.path, branch, base });
    } catch (err) {
      if (err?.code === 'branch_exists') {
        throw conflict('worktree_exists', `branch ${branch} already exists in ${displayPath(repo.path)}`);
      }
      throw dependencyUnavailable(`paseo worktree create failed: ${safeMessage(err)}`);
    }

    const createdPath = service.verifyCreatedPath(created?.worktreePath);
    const status = await service.status(createdPath);
    const record = {
      id: workspaceId(createdPath),
      path: createdPath,
      repoPath: repo.path,
      branch: created?.branchName ?? branch,
      projectId,
      createdBy: device?.id ?? null,
      createdAt: new Date(now()).toISOString(),
    };
    workspaceStore.put(record);
    return {
      status: 201,
      data: { ...view({ path: createdPath, kind: 'worktree', status }), repoId: repo.id, projectId, etag: null },
    };
  }

  return [
    { method: 'GET', path: '/v1/workspaces', auth: true, scope: 'sessions:read', handler: list },
    { method: 'POST', path: '/v1/workspaces', auth: true, scope: 'sessions:write', idempotent: true, handler: create },
    { method: 'GET', pattern: /^\/v1\/workspaces\/(ws_[0-9a-f]{16})$/, auth: true, scope: 'sessions:read', handler: get },
  ];
}

// --- inventory -------------------------------------------------------------

export function createWorkspaceService({ roots, gitRun, createWorktree, statusTtlMs, maxDepth, now }) {
  const rootPaths = [...new Set(roots.map((root) => resolve(root)))];
  const cache = new Map();

  function realRoots() {
    return rootPaths.map((root) => {
      try {
        return realpathSync(root);
      } catch {
        return root;
      }
    });
  }

  function insideAllowlist(path) {
    return realRoots().some((root) => path === root || path.startsWith(`${root}${sep}`));
  }

  function rootOf(path) {
    const rootsNow = realRoots();
    let best = null;
    for (const root of rootsNow) {
      if ((path === root || path.startsWith(`${root}${sep}`)) && (best === null || root.length > best.length)) {
        best = root;
      }
    }
    return best;
  }

  async function status(path) {
    const cached = cache.get(path);
    const t = now();
    if (cached && t - cached.at < statusTtlMs) return cached.status;
    let value;
    try {
      const output = await gitRun(
        ['status', '--porcelain=v2', '--branch', '--untracked-files=normal', '-z'],
        { cwd: path },
      );
      value = parseStatus(output);
    } catch (err) {
      value = { available: false, reason: err?.killed ? 'git_timeout' : 'git_failed' };
    }
    value.observedAt = new Date(t).toISOString();
    cache.set(path, { at: t, status: value });
    return value;
  }

  async function describe(path) {
    const realPath = safeRealpath(path);
    if (!realPath || !insideAllowlist(realPath)) return null;
    const kind = gitKind(realPath);
    if (!kind) return null;
    const statusValue = await status(realPath);
    const root = rootOf(realPath);
    return {
      id: workspaceId(realPath),
      path: realPath,
      displayPath: displayPath(realPath),
      root,
      rootDisplay: root ? displayPath(root) : null,
      kind,
      name: basename(realPath),
      branch: statusValue.branch ?? null,
      head: statusValue.head ?? null,
      status: statusValue,
    };
  }

  async function inventory() {
    const found = [];
    const seen = new Set();
    for (const root of rootPaths) {
      for (const path of discoverRepos(root, maxDepth)) {
        let realPath;
        try {
          realPath = realpathSync(path);
        } catch {
          continue;
        }
        if (seen.has(realPath)) continue;
        seen.add(realPath);
        found.push(realPath);
      }
    }
    const described = await mapLimit(found, WORKTREE_CONCURRENCY, (path) => describe(path));
    return described.filter(Boolean).sort((a, b) => a.path.localeCompare(b.path));
  }

  async function find(id) {
    if (typeof id !== 'string' || !WORKSPACE_ID_PATTERN.test(id)) return null;
    const items = await inventory();
    return items.find((item) => item.id === id) ?? null;
  }

  function verifyCreatedPath(raw) {
    if (typeof raw !== 'string' || !isAbsolute(raw)) {
      throw dependencyUnavailable('paseo worktree create returned no absolute path');
    }
    let realPath;
    try {
      realPath = realpathSync(raw);
    } catch {
      throw dependencyUnavailable('paseo worktree create reported a path that does not exist');
    }
    if (!insideAllowlist(realPath)) {
      throw dependencyUnavailable('paseo worktree create reported a path outside the allowlisted roots');
    }
    if (!gitKind(realPath)) {
      throw dependencyUnavailable('paseo worktree create reported a path that is not a git worktree');
    }
    return realPath;
  }

  return {
    inventory,
    find,
    status,
    verifyCreatedPath,
  };
}

// --- filesystem walk -------------------------------------------------------

function discoverRepos(root, maxDepth) {
  const out = [];
  if (!existsSync(root)) return out;
  const stack = [{ dir: root, depth: 0 }];
  let visited = 0;
  while (stack.length > 0) {
    const { dir, depth } = stack.pop();
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      if (++visited > 4000) return out;
      // Symlinks are never followed: their target may live outside the roots.
      if (!entry.isDirectory()) continue;
      if (SKIP_DIRS.has(entry.name)) continue;
      const child = join(dir, entry.name);
      if (gitKind(child)) {
        out.push(child);
        continue;
      }
      if (depth + 1 < maxDepth) stack.push({ dir: child, depth: depth + 1 });
    }
  }
  return out;
}

function gitKind(path) {
  try {
    const stats = lstatSync(path);
    if (!stats.isDirectory()) return null;
    const dotGit = join(path, '.git');
    if (!existsSync(dotGit)) return null;
    return lstatSync(dotGit).isDirectory() ? 'repo' : 'worktree';
  } catch {
    return null;
  }
}

function safeRealpath(path) {
  try {
    return realpathSync(path);
  } catch {
    return null;
  }
}

// --- git status ------------------------------------------------------------

export function parseStatus(output) {
  const segments = String(output).split('\u0000').flatMap((part) => part.split('\n')).filter((part) => part !== '');
  const status = {
    available: true,
    clean: true,
    branch: null,
    detached: false,
    head: null,
    upstream: null,
    ahead: 0,
    behind: 0,
    staged: 0,
    modified: 0,
    untracked: 0,
    conflicted: 0,
  };
  for (const segment of segments) {
    if (segment.startsWith('# branch.oid ')) {
      const value = segment.slice('# branch.oid '.length);
      status.head = value === '(initial)' ? null : value.slice(0, 12);
      continue;
    }
    if (segment.startsWith('# branch.head ')) {
      const value = segment.slice('# branch.head '.length);
      status.detached = value === '(detached)';
      status.branch = status.detached ? null : value;
      continue;
    }
    if (segment.startsWith('# branch.upstream ')) {
      status.upstream = segment.slice('# branch.upstream '.length);
      continue;
    }
    if (segment.startsWith('# branch.ab ')) {
      const match = /^\+(\d+) -(\d+)$/.exec(segment.slice('# branch.ab '.length));
      if (match) {
        status.ahead = Number(match[1]);
        status.behind = Number(match[2]);
      }
      continue;
    }
    if (segment.startsWith('? ')) {
      status.untracked += 1;
      continue;
    }
    if (/^[12u] /.test(segment)) {
      const x = segment[2];
      const y = segment[3];
      if (x !== '.' && x !== ' ' && x !== '?') status.staged += 1;
      if (y !== '.' && y !== ' ' && y !== '?') status.modified += 1;
      if (segment[0] === 'u') status.conflicted += 1;
    }
  }
  status.clean = status.staged === 0 && status.modified === 0 && status.untracked === 0 && status.conflicted === 0;
  return status;
}

// --- adapters --------------------------------------------------------------

const execFileAsync = promisify(execFile);

export async function defaultGitRun(args, { cwd, timeoutMs = 5000 } = {}) {
  const { stdout } = await execFileAsync('git', args, {
    cwd,
    timeout: timeoutMs,
    maxBuffer: 4 * 1024 * 1024,
    // Read-only: do not let `git status` take the index lock or rewrite it.
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0' },
  });
  return stdout;
}

// Paseo owns `~/.paseo/worktrees` and the branch bookkeeping, so creation goes
// through its CLI. No `--force`, no removal, no archive: a failed create leaves
// whatever already existed untouched.
export function paseoWorktreeCreator({ bin = resolvePaseoBin(), timeoutMs = 120_000, run = execFileAsync } = {}) {
  // launchd starts the Bridge with PATH=/usr/bin:/bin:..., which has neither
  // the Paseo CLI nor the Node that its shebang needs.
  const path = [dirname(process.execPath), '/opt/homebrew/bin', '/usr/local/bin', process.env.PATH]
    .filter(Boolean)
    .join(':');
  return async ({ repoPath, branch, base }) => {
    const args = ['worktree', 'create', '--mode', 'branch-off', '--cwd', repoPath, '--new-branch', branch, '--json'];
    if (base) args.push('--base', base);
    let stdout;
    try {
      stdout = (await run(bin, args, { timeout: timeoutMs, maxBuffer: 1024 * 1024, env: { ...process.env, PATH: path, HOME: process.env.HOME } })).stdout;
    } catch (err) {
      const message = `${err?.stderr ?? ''} ${err?.message ?? ''}`;
      if (/already exists|already checked out|is already used/i.test(message)) {
        const wrapped = new Error('branch or worktree already exists');
        wrapped.code = 'branch_exists';
        throw wrapped;
      }
      throw err;
    }
    let parsed;
    try {
      parsed = JSON.parse(stdout);
    } catch {
      throw new Error('paseo worktree create returned no JSON');
    }
    if (!parsed?.worktreePath) throw new Error('paseo worktree create returned no worktreePath');
    return { worktreePath: parsed.worktreePath, branchName: parsed.branchName ?? branch };
  };
}

const defaultCreateWorktree = paseoWorktreeCreator();

// --- helpers ---------------------------------------------------------------

function view({ path, kind, status }) {
  return {
    id: workspaceId(path),
    path,
    displayPath: displayPath(path),
    kind,
    name: basename(path),
    branch: status?.branch ?? null,
    head: status?.head ?? null,
    status,
  };
}

function withRegistry(item, record) {
  return {
    ...item,
    projectId: record?.projectId ?? null,
    repoId: record ? workspaceId(record.repoPath) : null,
  };
}

function etagFor(item) {
  return `"${item.id}:${item.head ?? 'none'}:${item.status?.available ? 'ok' : 'unavailable'}"`;
}

function workspaceId(path) {
  return `ws_${createHash('sha256').update(path, 'utf8').digest('hex').slice(0, 16)}`;
}

function displayPath(path) {
  const home = homedir();
  return path === home ? '~' : path.startsWith(`${home}${sep}`) ? `~${path.slice(home.length)}` : path;
}

function safeMessage(err) {
  const raw = `${err?.stderr ?? ''}`.trim() || `${err?.message ?? err}`;
  return raw.split('\n')[0].slice(0, 200);
}

function parseWorktreeName(raw) {
  if (typeof raw !== 'string' || !WORKTREE_NAME_PATTERN.test(raw.trim())) {
    throw badRequest('payload_invalid', 'worktreeName must be 1-64 of A-Z a-z 0-9 . _ - and start with a letter or digit');
  }
  return raw.trim();
}

function parseBranch(raw) {
  if (typeof raw !== 'string') throw badRequest('payload_invalid', 'branch must be a string');
  const branch = raw.trim();
  if (!BRANCH_PATTERN.test(branch) || branch.includes('..') || branch.endsWith('/') || branch.endsWith('.lock')) {
    throw badRequest('payload_invalid', 'branch is not a valid git branch name');
  }
  return branch;
}

function requireId(raw, field) {
  if (typeof raw !== 'string' || raw.trim() === '') throw badRequest('payload_invalid', `${field} is required`);
  return raw.trim();
}

function parseLimit(raw) {
  if (raw === undefined || raw === null || raw === '') return 50;
  const limit = Number(raw);
  if (!Number.isInteger(limit) || limit < 1 || limit > 100) {
    throw badRequest('limit_invalid', 'limit must be an integer between 1 and 100');
  }
  return limit;
}

function encodeCursor(offset) {
  return Buffer.from(JSON.stringify({ offset }), 'utf8').toString('base64url');
}

function parseCursor(raw) {
  if (raw === undefined || raw === null || raw === '') return 0;
  try {
    const parsed = JSON.parse(Buffer.from(raw, 'base64url').toString('utf8'));
    if (Number.isInteger(parsed?.offset) && parsed.offset >= 0) return parsed.offset;
  } catch {
    // fall through
  }
  throw badRequest('cursor_invalid', 'cursor is not recognised');
}

async function mapLimit(items, limit, fn) {
  const out = new Array(items.length);
  let next = 0;
  async function worker() {
    for (;;) {
      const index = next++;
      if (index >= items.length) return;
      out[index] = await fn(items[index], index);
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return out;
}

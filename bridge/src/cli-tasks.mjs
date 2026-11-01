// `laa-bridge tasks …`: the owner's task list from the Mac.
//
// Every write goes through the same service the HTTP routes use, so the CLI
// cannot skip validation, the revision check or the operation ledger. Writes
// require `--request-id`; a caller that retries keeps the same value and gets the
// recorded result instead of a second task.
//
// Exit codes (bridge/docs/owner-tasks.md §9):
//   0 applied or replayed, 1 unexpected, 2 usage, 3 not found, 4 conflict,
//   5 input rejected, 6 store unavailable, 7 Linear source unavailable.

import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { resolveStateDir } from './config.mjs';
import { BridgeError } from './errors.mjs';
import { TaskSourceError } from './tasks/errors.mjs';
import { DEFAULT_BACKUP_GENERATIONS, createOwnerTaskStore } from './tasks/owner-store.mjs';
import { createOwnerTaskService } from './tasks/owner-service.mjs';
import {
  assertManifestCurrent,
  buildManifest,
  createLinearImporter,
  selectedCandidates,
  verifyManifest,
} from './tasks/owner-import.mjs';

export const TASKS_USAGE = `laa-bridge tasks — 社長タスク（保存先は Bridge と同じ）

  tasks add   --request-id <id> (--title <text> | --input <file|->) [--memo <text>]
              [--status todo|doing|done|canceled] [--due YYYY-MM-DD] [--link <url>]…
              [--source owner|agent] [--id <uuid>] [--json]
  tasks list  [--status all|open|closed|<list>] [--limit N] [--cursor C] [--json]
  tasks get   --id <uuid> [--json]          one task with its memo and links
  tasks update --id <uuid> --if-match <revision> --request-id <id>
              [--title <text>] [--memo <text>] [--status <state>]
              [--due YYYY-MM-DD | --clear-due] [--link <url>]… | --input <file|->
              [--json]
  tasks status [--json]
  tasks import-linear --dry-run [--assignee <linear-user-id>] [--include-closed]
              [--out <file>] [--json]
  tasks import-linear --manifest <file> --approve <content-hash> [--json]
  tasks backup [--keep N] [--out <dir>] [--json]
  tasks restore --from <snapshot> --to <dir> [--allow-live] [--force] [--expect-state <sha256>] [--json]

Long text goes through --input (stdin with - or a file), not through arguments.
Exit codes: 0 applied/replayed, 1 unexpected, 2 usage, 3 not found, 4 conflict,
5 input rejected, 6 store unavailable, 7 Linear source unavailable.
`;

class UsageError extends Error {}

function usage(message) {
  throw new UsageError(message);
}

function requireFlag(flags, name) {
  if (flags[name] === undefined || flags[name] === true) usage(`--${name} is required`);
  return flags[name];
}

function errorBody(error) {
  if (error instanceof BridgeError) {
    return {
      code: error.code,
      message: error.message,
      ...(error.details === undefined ? {} : { details: error.details }),
    };
  }
  if (error instanceof TaskSourceError) return { code: error.code, message: error.message };
  if (error instanceof UsageError) return { code: 'usage_error', message: error.message };
  return { code: 'internal_error', message: 'unexpected failure' };
}

export function exitCodeFor(error) {
  if (error instanceof UsageError) return 2;
  if (error instanceof TaskSourceError) return 7;
  if (error instanceof BridgeError) {
    if (error.code.startsWith('owner_tasks_import_')) return 4;
    if (error.code === 'owner_tasks_store_unavailable' || error.status === 503) return 6;
    if (error.status === 404) return 3;
    if (error.status === 409 || error.status === 410 || error.status === 412) return 4;
    if (error.status === 428) return 2;
    if (error.status === 400 || error.status === 413) return 5;
    return 1;
  }
  return 1;
}

function openService() {
  const raw = process.env.LAA_BRIDGE_OWNER_TASKS_LOCK_TIMEOUT_MS;
  const lockTimeoutMs = raw === undefined || raw === '' ? undefined : Number(raw);
  const store = createOwnerTaskStore({
    dir: resolveStateDir(),
    ...(Number.isFinite(lockTimeoutMs) && lockTimeoutMs > 0 ? { lockTimeoutMs } : {}),
  });
  return createOwnerTaskService({ store });
}

function readJsonInput(value) {
  let raw;
  try {
    raw = value === '-' ? readFileSync(0, 'utf8') : readFileSync(resolve(value), 'utf8');
  } catch (error) {
    usage(`cannot read --input (${error.code ?? 'error'})`);
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    usage('--input is not valid JSON');
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) usage('--input must be a JSON object');
  return parsed;
}

const FIELD_FLAGS = ['title', 'memo', 'status', 'due', 'clear-due', 'link', 'source', 'id'];

function bodyFromFlags(flags, { create }) {
  if (flags.input !== undefined) {
    if (flags.input === true) usage('--input needs a file path or -');
    for (const name of FIELD_FLAGS) {
      if (flags[name] !== undefined && (create || name !== 'id')) usage(`--input cannot be combined with --${name}`);
    }
    const body = readJsonInput(flags.input);
    if (create && body.source === undefined) body.source = 'agent';
    return body;
  }
  if (flags.due !== undefined && flags['clear-due']) usage('--due and --clear-due cannot be combined');
  const body = {};
  if (create) {
    if (flags.title === undefined) usage('--title is required (or pass --input -)');
  }
  if (flags.title !== undefined) body.title = flags.title;
  if (flags.memo !== undefined) body.memo = flags.memo;
  if (flags.status !== undefined) body.status = flags.status;
  if (!create && flags.source !== undefined) usage('--source is set at creation only');
  if (flags['clear-due']) body.dueDate = null;
  else if (flags.due !== undefined) body.dueDate = flags.due;
  if (flags.link !== undefined) body.links = flags.link;
  if (create) body.source = flags.source ?? 'agent';
  if (create && flags.id !== undefined) body.id = flags.id;
  return body;
}

function printTask(write, task) {
  write(`  id       ${task.id}\n`);
  write(`  title    ${task.title}\n`);
  write(`  status   ${task.status}\n`);
  write(`  due      ${task.dueDate ?? '(none)'}\n`);
  write(`  source   ${task.source}\n`);
  write(`  revision ${task.revision}\n`);
  write(`  updated  ${task.updatedAt}\n`);
}

function commandAdd(flags, io) {
  requireFlag(flags, 'request-id');
  const body = bodyFromFlags(flags, { create: true });
  const service = openService();
  const result = service.create({
    principal: 'cli',
    key: flags['request-id'],
    method: 'POST',
    path: 'cli:tasks.add',
    body,
  });
  if (io.json) {
    io.write(`${JSON.stringify({ ok: true, replayed: result.replayed, task: result.task })}\n`);
    return 0;
  }
  io.write(`${result.replayed ? 'replayed' : 'created'}  ${result.task.id}  revision ${result.task.revision}\n`);
  printTask(io.write, result.task);
  return 0;
}

function commandList(flags, io) {
  const service = openService();
  const data = service.list({
    status: flags.status,
    limit: flags.limit,
    cursor: flags.cursor,
  });
  if (io.json) {
    io.write(`${JSON.stringify({ ok: true, ...data })}\n`);
    return 0;
  }
  for (const task of data.items) {
    io.write(`${String(task.revision).padStart(3)}  ${task.status.padEnd(8)}  ${(task.dueDate ?? '-').padEnd(10)}  ${task.id}  ${task.title}\n`);
  }
  io.write(`\n${data.total} task(s): open ${data.counts.open}, done ${data.counts.done}, canceled ${data.counts.canceled}\n`);
  if (data.nextCursor) io.write(`next: --cursor ${data.nextCursor}\n`);
  return 0;
}

function commandUpdate(flags, io) {
  const id = requireFlag(flags, 'id');
  const ifMatch = requireFlag(flags, 'if-match');
  requireFlag(flags, 'request-id');
  const body = bodyFromFlags(flags, { create: false });
  if (Object.keys(body).length === 0) {
    usage('nothing to update: pass --title, --memo, --status, --due, --clear-due, --link or --input');
  }
  const service = openService();
  const result = service.update({
    principal: 'cli',
    key: flags['request-id'],
    method: 'PATCH',
    path: `cli:tasks.update:${id}`,
    id,
    ifMatch,
    body,
  });
  if (io.json) {
    io.write(`${JSON.stringify({ ok: true, replayed: result.replayed, changed: result.changed ?? null, task: result.task })}\n`);
    return 0;
  }
  const verb = result.replayed ? 'replayed' : result.changed === false ? 'unchanged' : 'updated';
  io.write(`${verb}  ${result.task.id}  revision ${result.task.revision}\n`);
  printTask(io.write, result.task);
  return 0;
}

function commandGet(flags, io) {
  const id = requireFlag(flags, 'id');
  const task = openService().get(id);
  if (io.json) {
    io.write(`${JSON.stringify({ ok: true, task })}\n`);
    return 0;
  }
  printTask(io.write, task);
  io.write(`  links    ${task.links.length === 0 ? '(none)' : task.links.join(', ')}\n`);
  io.write(`  memo\n${task.memo === '' ? '    (empty)' : task.memo.split('\n').map((line) => `    ${line}`).join('\n')}\n`);
  return 0;
}

function commandStatus(flags, io) {
  const status = openService().status();
  if (io.json) {
    io.write(`${JSON.stringify({ ok: true, status })}\n`);
    return 0;
  }
  io.write(`store        ${status.file}\n`);
  io.write(`initialised  ${status.marker ? 'yes' : 'no'}\n`);
  io.write(`tasks        ${status.counts ? `${status.counts.tasks} (todo ${status.counts.todo}, doing ${status.counts.doing}, done ${status.counts.done}, canceled ${status.counts.canceled})` : 'unavailable'}\n`);
  io.write(`operations   ${status.operations ?? '-'}   tombstones ${status.tombstones ?? '-'}   imports ${status.imports ?? '-'}\n`);
  io.write(`newest       ${status.newestUpdatedAt ?? '-'}\n`);
  io.write(`state hash   ${status.stateSha256 ?? '-'}\n`);
  io.write(`bad backups  ${status.corruptBackups}\n`);
  io.write(`lock         ${status.lock.kind}${status.lock.pid ? ` (pid ${status.lock.pid})` : ''}\n`);
  io.write(`last backup  ${status.lastBackup ? status.lastBackup.file : '(none)'}\n`);
  if (status.error) io.write(`error        ${status.error}\n`);
  return 0;
}

function manifestFileName() {
  const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z');
  return join(resolveStateDir(), 'imports', `linear-${stamp}.json`);
}

function writeManifestFile(path, manifest) {
  mkdirSync(resolve(path, '..'), { recursive: true, mode: 0o700 });
  try {
    writeFileSync(path, `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
  } catch (error) {
    if (error.code === 'EEXIST') {
      throw new BridgeError(409, 'owner_tasks_import_manifest_exists', 'the manifest path already exists', {
        details: { path },
      });
    }
    throw error;
  }
}

function summaryLine(candidate) {
  const due = candidate.dueDate ?? '-';
  const title = candidate.title.length > 60 ? `${candidate.title.slice(0, 59)}…` : candidate.title;
  const flags = [candidate.excluded ? `excluded:${candidate.excluded}` : '', ...candidate.notes].filter(Boolean);
  return `  ${candidate.identifier.padEnd(10)} ${candidate.status.padEnd(8)} ${due.padEnd(10)} ${title}${flags.length ? `  [${flags.join(', ')}]` : ''}`;
}

function warningsOf(manifest) {
  const warnings = [];
  for (const note of ['comments_not_migrated', 'attachments_not_migrated', 'project_not_migrated', 'labels_not_migrated']) {
    const count = manifest.candidates.filter((candidate) => candidate.notes.includes(note)).length;
    if (count > 0) warnings.push(`${note}: ${count}`);
  }
  if (manifest.counts.undecided > 0) warnings.push(`state_undecided: ${manifest.counts.undecided}`);
  return warnings;
}

async function commandImport(flags, io) {
  const dryRun = Boolean(flags['dry-run']);
  if (dryRun && (flags.manifest !== undefined || flags.approve !== undefined)) {
    usage('use either --dry-run or --manifest with --approve');
  }
  if (!dryRun && (flags.manifest === undefined || flags.approve === undefined)) {
    usage('import-linear needs --dry-run, or --manifest <file> with --approve <contentHash>');
  }
  const service = openService();

  if (dryRun) {
    const assignee = flags.assignee ?? process.env.LAA_OWNER_TASKS_LINEAR_ASSIGNEE;
    if (!assignee || assignee === true) {
      usage('--assignee <linear user id> is required (or LAA_OWNER_TASKS_LINEAR_ASSIGNEE)');
    }
    const includeClosed = Boolean(flags['include-closed']);
    const importer = createLinearImporter();
    const issues = await importer.fetchAll({ assignee, includeClosed });
    const manifest = buildManifest({
      issues,
      assigneeId: assignee,
      includeClosed,
      isImported: (linearId) => service.linearTask(linearId),
      taskIdExists: (taskId) => service.taskIdExists(taskId),
    });
    const path = flags.out === undefined ? manifestFileName() : resolve(flags.out);
    writeManifestFile(path, manifest);
    const warnings = warningsOf(manifest);
    if (io.json) {
      io.write(`${JSON.stringify({
        ok: true,
        dryRun: true,
        manifestPath: path,
        contentHash: manifest.contentHash,
        counts: manifest.counts,
        warnings,
      })}\n`);
      return 0;
    }
    for (const candidate of manifest.candidates) io.write(`${summaryLine(candidate)}\n`);
    io.write(`${manifest.counts.fetched} fetched, ${manifest.counts.selected} selected, ${manifest.counts.excluded} excluded, ${manifest.counts.undecided} undecided\n`);
    for (const warning of warnings) io.write(`warning: ${warning}\n`);
    io.write(`manifest     ${path}\n`);
    io.write(`contentHash  ${manifest.contentHash}\n`);
    io.write(`approve with: laa-bridge tasks import-linear --manifest ${path} --approve ${manifest.contentHash}\n`);
    return 0;
  }

  const file = resolve(flags.manifest);
  let raw;
  try {
    raw = readFileSync(file, 'utf8');
  } catch (error) {
    throw new BridgeError(400, 'owner_tasks_import_manifest_invalid', `cannot read the manifest (${error.code ?? 'error'})`);
  }
  let manifest;
  try {
    manifest = JSON.parse(raw);
  } catch {
    throw new BridgeError(400, 'owner_tasks_import_manifest_invalid', 'the manifest is not valid JSON');
  }
  verifyManifest(manifest);
  const approved = String(flags.approve).startsWith('sha256:') ? String(flags.approve) : `sha256:${flags.approve}`;
  if (approved !== manifest.contentHash) {
    throw new BridgeError(409, 'owner_tasks_import_approval_mismatch',
      'the approval does not match the manifest contentHash',
      { details: { contentHash: manifest.contentHash } });
  }

  const prior = service.findImport(manifest.contentHash);
  if (prior) {
    if (io.json) {
      io.write(`${JSON.stringify({ ok: true, replayed: true, import: prior })}\n`);
      return 0;
    }
    io.write(`already imported  ${prior.count} task(s) at ${prior.importedAt}  (${manifest.contentHash})\n`);
    return 0;
  }

  const importer = createLinearImporter();
  const issues = await importer.fetchAll({ assignee: manifest.assigneeId, includeClosed: manifest.includeClosed });
  assertManifestCurrent(manifest, issues, { assigneeId: manifest.assigneeId });
  const result = service.applyImport({
    principal: 'cli',
    manifest,
    candidates: selectedCandidates(manifest),
  });
  if (io.json) {
    io.write(`${JSON.stringify({
      ok: true,
      replayed: result.replayed,
      import: result.record,
      created: result.created ?? [],
      skipped: result.skipped ?? [],
    })}\n`);
    return 0;
  }
  io.write(`imported  ${result.record.count} task(s), skipped ${result.record.skipped} already imported\n`);
  io.write(`manifest  ${manifest.contentHash}\n`);
  return 0;
}

function commandBackup(flags, io) {
  const keep = flags.keep === undefined ? DEFAULT_BACKUP_GENERATIONS : Number(flags.keep);
  const result = openService().backup({
    keep,
    ...(flags.out === undefined ? {} : { outDir: resolve(flags.out) }),
  });
  if (io.json) {
    io.write(`${JSON.stringify({ ok: true, backup: result })}\n`);
    return 0;
  }
  if (result.skipped) {
    io.write(`nothing to back up (${result.reason}); ${result.kept} generation(s) already kept\n`);
    return 0;
  }
  io.write(`snapshot  ${result.path}\n`);
  io.write(`checksum  ${result.stateSha256}\n`);
  io.write(`tasks     ${result.counts.tasks}   generations kept ${result.kept}\n`);
  return 0;
}

function commandRestore(flags, io) {
  const from = requireFlag(flags, 'from');
  const to = requireFlag(flags, 'to');
  const result = openService().restore({
    from: resolve(from),
    to: resolve(to),
    allowLive: Boolean(flags['allow-live']),
    force: Boolean(flags.force),
    expectedStateSha256: flags['expect-state'],
  });
  if (io.json) {
    io.write(`${JSON.stringify({ ok: true, restore: result })}\n`);
    return 0;
  }
  io.write(`restored  ${result.counts.tasks} task(s) into ${result.to}\n`);
  io.write(`checksum  ${result.stateSha256}\n`);
  io.write(`newest    ${result.newestUpdatedAt || '-'}   max revision ${result.maxRevision}\n`);
  return 0;
}

export async function tasksCommand(argv, flags, io = {}) {
  const write = io.write ?? ((text) => process.stdout.write(text));
  const writeErr = io.writeErr ?? ((text) => process.stderr.write(text));
  const json = Boolean(flags.json);
  const context = { write, writeErr, json };
  const sub = argv[0];
  try {
    const allowed = {
      add: 'request-id title input memo status due link source id json',
      list: 'status limit cursor json', get: 'id json',
      update: 'id if-match request-id title input memo status due clear-due link json',
      status: 'json', 'import-linear': 'dry-run assignee include-closed out manifest approve json',
      backup: 'keep out json', restore: 'from to allow-live force expect-state json', help: 'json help',
    };
    if (argv.length > 1) usage('unexpected positional argument');
    if (allowed[sub]) for (const flag of Object.keys(flags)) {
      if (!allowed[sub].split(' ').includes(flag)) usage(`unknown flag --${flag} for ${sub}`);
    }
    switch (sub) {
      case 'add': return commandAdd(flags, context);
      case 'list': return commandList(flags, context);
      case 'get': return commandGet(flags, context);
      case 'update': return commandUpdate(flags, context);
      case 'status': return commandStatus(flags, context);
      case 'import-linear': return await commandImport(flags, context);
      case 'backup': return commandBackup(flags, context);
      case 'restore': return commandRestore(flags, context);
      case undefined:
      case 'help':
      case '--help':
        write(TASKS_USAGE);
        return 0;
      default:
        usage(`unknown tasks subcommand: ${sub}`);
    }
  } catch (error) {
    const body = errorBody(error);
    if (json) write(`${JSON.stringify({ ok: false, error: body })}\n`);
    writeErr(`laa-bridge: ${body.code}: ${body.message}\n`);
    return exitCodeFor(error);
  }
  return 0;
}

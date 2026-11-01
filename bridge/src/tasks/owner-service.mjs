// Owner tasks: validation, ordering, the operation ledger and the Linear import
// commit. The HTTP routes and the CLI both call this module, so a task created
// from the terminal is validated and versioned exactly like one from the phone.
//
// The ledger only records operations that changed the document. A refusal
// (invalid input, stale If-Match) wrote nothing, so it is not recorded and the
// same key may be retried with a corrected body. What the ledger prevents is
// the dangerous case: replaying a key whose create/update already happened.

import { randomUUID } from 'node:crypto';
import { BridgeError } from '../errors.mjs';
import { MAX_OPERATIONS, OPERATION_RETENTION_MS } from './owner-store.mjs';
import { canonicalJson, sha256Hex, UUID_PATTERN } from './stable.mjs';

export const STATUSES = Object.freeze(['todo', 'doing', 'done', 'canceled']);
export const OPEN_STATUSES = Object.freeze(['todo', 'doing']);
export const MAX_TITLE = 500;
export const MAX_MEMO = 20_000;
export const MAX_LINKS = 20;
export const MAX_LINK_LENGTH = 2048;
export const DEFAULT_LIMIT = 50;
export const MAX_LIMIT = 200;

const CURSOR_TTL_MS = 24 * 60 * 60 * 1000;
const MUTABLE_FIELDS = ['title', 'memo', 'status', 'dueDate', 'links'];

function fieldError(field, message) {
  return new BridgeError(400, 'field_invalid', message, { details: { field } });
}

function unsupportedField(field) {
  return new BridgeError(400, 'unsupported_field', `"${field}" is not accepted here`, { details: { field } });
}

function requireObject(body) {
  if (body === undefined || body === null) return {};
  if (typeof body !== 'object' || Array.isArray(body)) {
    throw new BridgeError(400, 'payload_invalid', 'request body must be a JSON object');
  }
  return body;
}

function validateTitle(value) {
  if (typeof value !== 'string') throw fieldError('title', 'title must be a string');
  const title = value.trim();
  if (title.length === 0) throw fieldError('title', 'title must not be empty');
  if (title.length > MAX_TITLE) throw fieldError('title', `title must be at most ${MAX_TITLE} characters`);
  // eslint-disable-next-line no-control-regex
  if (/[\u0000-\u001f\u007f]/.test(title)) throw fieldError('title', 'title must not contain control characters');
  return title;
}

function validateMemo(value) {
  if (typeof value !== 'string') throw fieldError('memo', 'memo must be a string');
  if (value.length > MAX_MEMO) throw fieldError('memo', `memo must be at most ${MAX_MEMO} characters`);
  if (value.includes('\u0000')) throw fieldError('memo', 'memo must not contain NUL');
  return value;
}

function validateStatus(value) {
  if (typeof value !== 'string' || !STATUSES.includes(value)) {
    throw fieldError('status', `status must be one of ${STATUSES.join(', ')}`);
  }
  return value;
}

export function validateDueDate(value) {
  if (value === null) return null;
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    throw fieldError('dueDate', 'dueDate must be YYYY-MM-DD or null');
  }
  const parsed = new Date(`${value}T00:00:00.000Z`);
  if (Number.isNaN(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== value) {
    throw fieldError('dueDate', 'dueDate is not a real calendar date');
  }
  return value;
}

function validateLinks(value) {
  if (!Array.isArray(value)) throw fieldError('links', 'links must be an array of URLs');
  if (value.length > MAX_LINKS) throw fieldError('links', `links must have at most ${MAX_LINKS} entries`);
  return value.map((raw) => {
    if (typeof raw !== 'string') throw fieldError('links', 'every link must be a string');
    const link = raw.trim();
    if (link.length === 0 || link.length > MAX_LINK_LENGTH) {
      throw fieldError('links', `every link must be 1-${MAX_LINK_LENGTH} characters`);
    }
    let url;
    try {
      url = new URL(link);
    } catch {
      throw fieldError('links', 'every link must be an absolute URL');
    }
    if (url.protocol !== 'https:' && url.protocol !== 'http:') {
      throw fieldError('links', 'only http and https links are accepted');
    }
    if (url.username !== '' || url.password !== '') {
      throw fieldError('links', 'links must not embed credentials');
    }
    // eslint-disable-next-line no-control-regex
    if (/[\u0000-\u0020\u007f]/.test(link)) throw fieldError('links', 'links must not contain spaces or control characters');
    return link;
  });
}

function validateId(value) {
  if (typeof value !== 'string' || !UUID_PATTERN.test(value)) {
    throw fieldError('id', 'id must be a UUID');
  }
  return value.toLowerCase();
}

export function validateCreateInput(body) {
  const input = requireObject(body);
  const allowed = new Set(['id', 'title', 'memo', 'status', 'dueDate', 'links', 'source']);
  for (const key of Object.keys(input)) {
    if (!allowed.has(key)) throw unsupportedField(key);
  }
  if (input.title === undefined) throw fieldError('title', 'title is required');
  const source = input.source === undefined ? 'owner' : input.source;
  if (source !== 'owner' && source !== 'agent') {
    throw fieldError('source', 'source must be owner or agent (linear_import is reserved for the import tool)');
  }
  return {
    id: input.id === undefined ? null : validateId(input.id),
    title: validateTitle(input.title),
    memo: input.memo === undefined ? '' : validateMemo(input.memo),
    status: input.status === undefined ? 'todo' : validateStatus(input.status),
    dueDate: input.dueDate === undefined ? null : validateDueDate(input.dueDate),
    links: input.links === undefined ? [] : validateLinks(input.links),
    source,
  };
}

export function validatePatchInput(body) {
  const input = requireObject(body);
  const patch = {};
  for (const key of Object.keys(input)) {
    if (!MUTABLE_FIELDS.includes(key)) throw unsupportedField(key);
    patch[key] = input[key];
  }
  if (Object.keys(patch).length === 0) {
    throw new BridgeError(400, 'patch_empty', 'a PATCH needs at least one of title, memo, status, dueDate, links');
  }
  if (Object.hasOwn(patch, 'title')) patch.title = validateTitle(patch.title);
  if (Object.hasOwn(patch, 'memo')) patch.memo = validateMemo(patch.memo);
  if (Object.hasOwn(patch, 'status')) patch.status = validateStatus(patch.status);
  if (Object.hasOwn(patch, 'dueDate')) patch.dueDate = validateDueDate(patch.dueDate);
  if (Object.hasOwn(patch, 'links')) patch.links = validateLinks(patch.links);
  return patch;
}

export function parseIfMatch(raw) {
  if (raw === undefined || raw === null || raw === '') {
    throw new BridgeError(428, 'precondition_required', 'If-Match header with the current revision is required');
  }
  if (typeof raw === 'number') {
    if (!Number.isInteger(raw) || raw < 1) {
      throw new BridgeError(400, 'precondition_invalid', 'If-Match must be one revision');
    }
    return raw;
  }
  if (typeof raw !== 'string') throw new BridgeError(400, 'precondition_invalid', 'If-Match must be one revision');
  const value = raw.trim();
  const quoted = /^"(\d{1,9})"$/.exec(value);
  const bare = /^(\d{1,9})$/.exec(value);
  const revision = quoted ? Number(quoted[1]) : bare ? Number(bare[1]) : null;
  if (!Number.isSafeInteger(revision) || revision < 1) {
    throw new BridgeError(400, 'precondition_invalid', 'If-Match must be a revision such as "3"');
  }
  return revision;
}

function normalizedStatusFilter(raw) {
  if (raw === undefined || raw === null || raw === '') return { key: 'all', statuses: new Set(STATUSES) };
  const value = String(raw).trim().toLowerCase();
  if (value === '' || value === 'all') return { key: 'all', statuses: new Set(STATUSES) };
  if (value === 'open') return { key: 'open', statuses: new Set(OPEN_STATUSES) };
  if (value === 'closed') return { key: 'closed', statuses: new Set(['done', 'canceled']) };
  const parts = value.split(',').map((part) => part.trim()).filter((part) => part !== '');
  if (parts.length === 0) throw fieldError('status', 'status filter is empty');
  for (const part of parts) {
    if (!STATUSES.includes(part)) throw fieldError('status', `status must be all, open, closed or a list of ${STATUSES.join(', ')}`);
  }
  return { key: [...new Set(parts)].sort().join(','), statuses: new Set(parts) };
}

function compareTasks(a, b) {
  const groupA = OPEN_STATUSES.includes(a.status) ? 0 : 1;
  const groupB = OPEN_STATUSES.includes(b.status) ? 0 : 1;
  if (groupA !== groupB) return groupA - groupB;
  if (a.dueDate !== null && b.dueDate !== null) {
    if (a.dueDate !== b.dueDate) return a.dueDate < b.dueDate ? -1 : 1;
  } else if (a.dueDate !== null) {
    return -1;
  } else if (b.dueDate !== null) {
    return 1;
  }
  if (a.updatedAt !== b.updatedAt) return a.updatedAt > b.updatedAt ? -1 : 1;
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
}

function filterKeyOf(statusKey) {
  return sha256Hex(JSON.stringify({ v: 1, status: statusKey })).slice(0, 16);
}

function encodeCursor(offset, filterKey, issuedAt) {
  return Buffer.from(JSON.stringify({ v: 1, o: offset, f: filterKey, t: issuedAt }), 'utf8').toString('base64url');
}

function decodeCursor(raw, filterKey, issuedAt) {
  let parsed;
  try {
    if (typeof raw !== 'string' || !/^[A-Za-z0-9_-]+$/.test(raw)) throw new Error('encoding');
    parsed = JSON.parse(Buffer.from(raw, 'base64url').toString('utf8'));
  } catch {
    throw new BridgeError(400, 'cursor_invalid', 'cursor is not a value returned by this endpoint');
  }
  if (!parsed || parsed.v !== 1 || !Number.isInteger(parsed.o) || parsed.o < 0 || typeof parsed.f !== 'string') {
    throw new BridgeError(400, 'cursor_invalid', 'cursor is not a value returned by this endpoint');
  }
  if (parsed.f !== filterKey) {
    throw new BridgeError(400, 'cursor_filter_mismatch', 'cursor belongs to a different filter set');
  }
  if (typeof parsed.t !== 'number' || issuedAt - parsed.t > CURSOR_TTL_MS) {
    throw new BridgeError(410, 'cursor_expired', 'cursor has expired; list again from the start');
  }
  return parsed.o;
}

function parseLimit(raw) {
  if (raw === undefined || raw === null || raw === '') return DEFAULT_LIMIT;
  const limit = Number(raw);
  if (!Number.isInteger(limit) || limit < 1 || limit > MAX_LIMIT) {
    throw fieldError('limit', `limit must be an integer between 1 and ${MAX_LIMIT}`);
  }
  return limit;
}

export function etagFor(revision) {
  return `"${revision}"`;
}

// The list carries what a list row needs. The memo (up to 20,000 characters) and
// the links stay in the detail response, so a page cannot grow to megabytes and
// a body is only transferred when it is going to be read.
export function summaryOf(task) {
  return {
    id: task.id,
    title: task.title,
    status: task.status,
    dueDate: task.dueDate,
    source: task.source,
    createdAt: task.createdAt,
    updatedAt: task.updatedAt,
    revision: task.revision,
  };
}

export function createOwnerTaskService({ store, now = () => Date.now() } = {}) {
  if (!store) throw new Error('owner-task service requires a store');
  const iso = (ms = now()) => new Date(ms).toISOString();

  const principalHash = (principal) => sha256Hex(`principal\n${principal}`);
  const keyHash = (principal, key) => sha256Hex(`key\n${principal}\n${key}`);
  const fingerprintOf = ({ method, path, principal, ifMatch, body }) => sha256Hex(canonicalJson({
    method,
    path,
    principal,
    ifMatch: ifMatch ?? null,
    body,
  }));

  function compact(doc) {
    const t = now();
    for (const [hash, entry] of Object.entries(doc.operations)) {
      if (Number.isFinite(entry.updatedAt) && t - entry.updatedAt >= OPERATION_RETENTION_MS) {
        doc.tombstones[hash] = {
          compactedAt: t,
          status: 'succeeded',
          principalHash: entry.principalHash ?? null,
          targetId: entry.targetId ?? null,
          revision: entry.revision ?? null,
        };
        delete doc.operations[hash];
      }
    }
  }

  function replayOf(doc, hash) {
    const tombstone = doc.tombstones[hash];
    if (tombstone) {
      throw new BridgeError(410, 'owner_task_operation_compacted',
        'the completed operation was compacted; read the task instead of sending it again',
        { details: { targetId: tombstone.targetId ?? null, revision: tombstone.revision ?? null } });
    }
    return null;
  }

  function record(doc, {
    hash, principal, fingerprint, method, path, targetId, revision, httpStatus,
  }) {
    const t = now();
    doc.operations[hash] = {
      principalHash: principalHash(principal),
      fingerprint,
      method,
      path,
      status: 'succeeded',
      httpStatus,
      targetId,
      revision,
      createdAt: t,
      updatedAt: t,
    };
  }

  function requireLedgerRoom(doc) {
    if (Object.keys(doc.operations).length >= MAX_OPERATIONS) {
      throw new BridgeError(503, 'owner_tasks_store_unavailable',
        'the operation ledger is full; an operator has to compact it',
        { details: { reason: 'ledger_full' } });
    }
  }

  function getTask(doc, id) {
    if (typeof id !== 'string' || !UUID_PATTERN.test(id)) {
      throw new BridgeError(404, 'owner_task_not_found', 'no such owner task');
    }
    const task = doc.tasks[id.toLowerCase()];
    if (!task) throw new BridgeError(404, 'owner_task_not_found', 'no such owner task');
    return task;
  }

  function list({ status, limit, cursor } = {}) {
    const doc = store.readOptional();
    const filter = normalizedStatusFilter(status);
    const pageLimit = parseLimit(limit);
    const filterKey = filterKeyOf(filter.key);
    const issuedAt = now();
    const offset = cursor === undefined || cursor === null || cursor === '' ? 0 : decodeCursor(cursor, filterKey, issuedAt);

    const all = doc ? Object.values(doc.tasks) : [];
    const counts = { open: 0, done: 0, canceled: 0 };
    for (const task of all) {
      if (task.status === 'done') counts.done += 1;
      else if (task.status === 'canceled') counts.canceled += 1;
      else counts.open += 1;
    }
    const filtered = all.filter((task) => filter.statuses.has(task.status)).sort(compareTasks);
    const total = filtered.length;
    const page = filtered.slice(offset, offset + pageLimit).map(summaryOf);
    const nextOffset = offset + page.length;
    return {
      items: page,
      nextCursor: nextOffset < total ? encodeCursor(nextOffset, filterKey, issuedAt) : null,
      total,
      counts,
      filter: { status: filter.key },
      observedAt: iso(issuedAt),
    };
  }

  function get(id) {
    const doc = store.readOptional();
    if (!doc) throw new BridgeError(404, 'owner_task_not_found', 'no such owner task');
    return getTask(doc, id);
  }

  function create({
    principal, key, method = 'POST', path = '/v1/owner-tasks', body,
  }) {
    const input = validateCreateInput(body);
    const fingerprint = fingerprintOf({ method, path, principal, ifMatch: null, body: input });
    const hash = keyHash(principal, key);

    return store.transact((doc) => {
      compact(doc);
      replayOf(doc, hash);
      const prior = doc.operations[hash];
      if (prior) {
        if (prior.fingerprint !== fingerprint) {
          throw new BridgeError(409, 'owner_task_key_conflict', 'Idempotency-Key was used for a different request', {
            details: { taskId: prior.targetId ?? null },
          });
        }
        const task = doc.tasks[prior.targetId];
        if (!task) {
          throw new BridgeError(409, 'owner_task_operation_target_missing',
            'the recorded task is no longer in the store', { details: { taskId: prior.targetId ?? null } });
        }
        return { status: prior.httpStatus ?? 201, task, replayed: true };
      }
      requireLedgerRoom(doc);
      const id = input.id ?? randomUUID();
      if (doc.tasks[id]) {
        throw new BridgeError(409, 'owner_task_exists', 'a task with this id already exists', { details: { taskId: id } });
      }
      const at = iso();
      const task = {
        id,
        title: input.title,
        memo: input.memo,
        status: input.status,
        dueDate: input.dueDate,
        source: input.source,
        links: input.links,
        createdAt: at,
        updatedAt: at,
        revision: doc.revisionFloor ?? 1,
      };
      doc.tasks[id] = task;
      record(doc, {
        hash, principal, fingerprint, method, path, targetId: id, revision: task.revision, httpStatus: 201,
      });
      return { status: 201, task, replayed: false };
    }, { create: true });
  }

  function update({
    principal, key, method = 'PATCH', path, id, ifMatch, body,
  }) {
    const patch = validatePatchInput(body);
    const expected = parseIfMatch(ifMatch);
    const fingerprint = fingerprintOf({ method, path, principal, ifMatch: expected, body: patch });
    const hash = keyHash(principal, key);

    return store.transact((doc) => {
      compact(doc);
      if (doc.revisionFloor && expected < doc.revisionFloor) {
        const current = doc.tasks[id];
        throw new BridgeError(412, 'owner_task_revision_mismatch', 'the task was restored; read it again before updating', { details: current ? { current } : {} });
      }
      replayOf(doc, hash);
      const prior = doc.operations[hash];
      if (prior) {
        if (prior.fingerprint !== fingerprint) {
          throw new BridgeError(409, 'owner_task_key_conflict', 'Idempotency-Key was used for a different request', {
            details: { taskId: prior.targetId ?? null },
          });
        }
        const replayTask = doc.tasks[prior.targetId];
        if (!replayTask) {
          throw new BridgeError(409, 'owner_task_operation_target_missing',
            'the recorded task is no longer in the store', { details: { taskId: prior.targetId ?? null } });
        }
        return { status: prior.httpStatus ?? 200, task: replayTask, replayed: true };
      }
      requireLedgerRoom(doc);
      const task = getTask(doc, id);
      if (task.revision !== expected) {
        throw new BridgeError(412, 'owner_task_revision_mismatch',
          `the task is at revision ${task.revision}; read it again before updating`,
          { details: { current: task } });
      }
      let changed = false;
      for (const [field, value] of Object.entries(patch)) {
        if (canonicalJson(task[field]) !== canonicalJson(value)) {
          task[field] = value;
          changed = true;
        }
      }
      if (changed) {
        if (!Number.isSafeInteger(task.revision + 1)) {
          throw new BridgeError(503, 'owner_tasks_store_unavailable', 'revision limit reached', { details: { reason: 'corrupt' } });
        }
        task.revision += 1;
        task.updatedAt = iso();
      }
      record(doc, {
        hash, principal, fingerprint, method, path, targetId: task.id, revision: task.revision, httpStatus: 200,
      });
      return { status: 200, task, replayed: false, changed };
    });
  }

  function findImport(manifestHash) {
    return store.readOptional()?.imports[manifestHash] ?? null;
  }

  function linearTask(linearId) {
    return store.readOptional()?.linearMap[linearId] ?? null;
  }

  function taskIdExists(taskId) {
    return Boolean(store.readOptional()?.tasks[taskId]);
  }

  // One transaction for the whole approved manifest: either every selected
  // candidate becomes a task with its Linear mapping, or nothing is written.
  function applyImport({ principal, manifest, candidates }) {
    const manifestHash = manifest.contentHash;
    const key = `import:${manifestHash}`;
    const hash = keyHash(principal, key);
    const fingerprint = fingerprintOf({
      method: 'IMPORT',
      path: '/v1/owner-tasks/import-linear',
      principal,
      ifMatch: null,
      body: { manifestHash, taskIds: candidates.map((candidate) => candidate.taskId) },
    });

    return store.transact((doc) => {
      compact(doc);
      const prior = doc.imports[manifestHash];
      if (prior) return { status: 200, record: prior, replayed: true, created: [] };
      replayOf(doc, hash);
      requireLedgerRoom(doc);

      const created = [];
      const skipped = [];
      for (const candidate of candidates) {
        const mapped = doc.linearMap[candidate.linearId];
        if (mapped) {
          skipped.push({ linearId: candidate.linearId, identifier: candidate.identifier, taskId: mapped.taskId });
          continue;
        }
        if (doc.tasks[candidate.taskId]) {
          throw new BridgeError(409, 'owner_task_key_conflict',
            'the approved manifest reserves a task id that already exists',
            { details: { taskId: candidate.taskId } });
        }
        // The manifest is approved content, but it is still data from outside:
        // the same field rules apply, and one bad candidate aborts the whole
        // transaction.
        const at = iso();
        const task = {
          id: candidate.taskId,
          title: validateTitle(candidate.title),
          memo: validateMemo(candidate.memo),
          status: validateStatus(candidate.status),
          dueDate: validateDueDate(candidate.dueDate),
          source: 'linear_import',
          links: validateLinks(candidate.url ? [candidate.url] : []),
          createdAt: at,
          updatedAt: candidate.linearUpdatedAt ?? at,
          revision: doc.revisionFloor ?? 1,
        };
        doc.tasks[task.id] = task;
        doc.linearMap[candidate.linearId] = {
          taskId: task.id,
          identifier: candidate.identifier,
          importedAt: at,
        };
        created.push(task.id);
      }

      const importRecord = {
        manifestHash,
        importedAt: iso(),
        assigneeId: manifest.assigneeId,
        includeClosed: Boolean(manifest.includeClosed),
        count: created.length,
        skipped: skipped.length,
        taskIds: created,
      };
      doc.imports[manifestHash] = importRecord;
      record(doc, {
        hash,
        principal,
        fingerprint,
        method: 'IMPORT',
        path: '/v1/owner-tasks/import-linear',
        targetId: created[0] ?? null,
        revision: 1,
        httpStatus: 201,
      });
      return { status: 201, record: importRecord, replayed: false, created, skipped };
    }, { create: true });
  }

  return {
    list,
    get,
    create,
    update,
    findImport,
    linearTask,
    taskIdExists,
    applyImport,
    backup: (options) => store.backup(options),
    restore: (options) => store.restore(options),
    status: () => store.status(),
    store,
    now,
  };
}

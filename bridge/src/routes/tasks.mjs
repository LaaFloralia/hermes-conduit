// Read-only task views: GET /v1/tasks and GET /v1/tasks/{id} (ROADMAP task 19).
//
// A task keeps its owner and its executor apart. `owner.kind` says whose work
// it is (the owner's or an agent's); `executor` names the agent that would run
// it. Reading, filtering or listing never assigns anything and never starts a
// worker: this module has no mutation path, the Linear source rejects anything
// but a `query`, and the Kanban source has no dispatch call.
//
// Sources are Linear (the current source of truth, via the existing Mac-side
// wrapper) and Kanban (tagged `kanban`, suppressed when it repeats a Linear
// task). Availability is reported per source instead of being flattened into an
// empty list.

import { createHash } from 'node:crypto';
import { BridgeError, badRequest } from '../errors.mjs';
import { createKanbanTaskSource } from '../tasks/kanban.mjs';
import { TaskSourceError } from '../tasks/errors.mjs';
import { createLinearTaskSource } from '../tasks/linear.mjs';

const DEFAULT_LIMIT = 50;
const MAX_LIMIT = 200;
const SOURCE_FILTERS = ['linear', 'kanban', 'all'];
const OWNER_FILTERS = ['owner', 'agent', 'unassigned', 'any'];
const DETAIL_PATH = /^\/v1\/tasks\/([^/]+)$/;
const TASK_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,80}$/;
const LINEAR_IDENTIFIER = /^[A-Za-z][A-Za-z0-9]*-\d+$/;
const CURSOR_TTL_MS = 24 * 60 * 60 * 1000;

function reasonOf(error) {
  return typeof error?.code === 'string' ? error.code : 'source_error';
}

function toBridgeError(error, fallbackCode) {
  if (error instanceof BridgeError) return error;
  if (!(error instanceof TaskSourceError)) {
    // An unexpected error's message could carry anything; do not forward it.
    return new BridgeError(503, fallbackCode, 'the task source is not available', { retryable: true });
  }
  const status = Number.isInteger(error.status) ? error.status : 503;
  return new BridgeError(status, error.code, error.message, { retryable: Boolean(error.retryable) });
}

function oneOf(name, raw, allowed, fallback) {
  if (raw === null || raw === '') return fallback;
  const value = raw.toLowerCase();
  if (!allowed.includes(value)) {
    throw badRequest('filter_invalid', `${name} must be one of ${allowed.join(', ')}`);
  }
  return value;
}

function textFilter(name, raw) {
  if (raw === null || raw === '') return null;
  const value = raw.trim();
  if (value.length > 100) {
    throw badRequest('filter_invalid', `${name} must be at most 100 characters`);
  }
  return value;
}

function limitFilter(raw) {
  if (raw === null || raw === '') return DEFAULT_LIMIT;
  if (!/^\d+$/.test(raw)) {
    throw badRequest('filter_invalid', `limit must be an integer between 1 and ${MAX_LIMIT}`);
  }
  const value = Number(raw);
  if (value < 1 || value > MAX_LIMIT) {
    throw badRequest('filter_invalid', `limit must be an integer between 1 and ${MAX_LIMIT}`);
  }
  return value;
}

function parseFilters(searchParams) {
  return {
    owner: oneOf('owner', searchParams.get('owner'), OWNER_FILTERS, 'any'),
    source: oneOf('source', searchParams.get('source'), SOURCE_FILTERS, 'all'),
    status: textFilter('status', searchParams.get('status')),
    project: textFilter('project', searchParams.get('project')),
    limit: limitFilter(searchParams.get('limit')),
    cursor: searchParams.get('cursor'),
  };
}

// The cursor is a page offset bound to the filter set, so reusing one with
// different filters fails instead of silently returning a wrong page.
function filterKeyOf(filter) {
  return createHash('sha256')
    .update(JSON.stringify({
      owner: filter.owner,
      source: filter.source,
      status: filter.status === null ? null : filter.status.toLowerCase(),
      project: filter.project === null ? null : filter.project.toLowerCase(),
    }))
    .digest('hex')
    .slice(0, 16);
}

function encodeCursor(offset, filterKey, now) {
  return Buffer.from(
    JSON.stringify({ v: 1, o: offset, f: filterKey, t: now }),
    'utf8',
  ).toString('base64url');
}

function decodeCursor(raw, filterKey, now) {
  let parsed;
  try {
    if (!/^[A-Za-z0-9_-]+$/.test(raw)) throw new Error('encoding');
    parsed = JSON.parse(Buffer.from(raw, 'base64url').toString('utf8'));
  } catch {
    throw badRequest('cursor_invalid', 'cursor is not a value returned by this endpoint');
  }
  if (!parsed || parsed.v !== 1 || !Number.isInteger(parsed.o) || parsed.o < 0 || typeof parsed.f !== 'string') {
    throw badRequest('cursor_invalid', 'cursor is not a value returned by this endpoint');
  }
  if (parsed.f !== filterKey) {
    throw badRequest('cursor_filter_mismatch', 'cursor belongs to a different filter set');
  }
  if (typeof parsed.t !== 'number' || now - parsed.t > CURSOR_TTL_MS) {
    throw new BridgeError(410, 'cursor_expired', 'cursor has expired; list again from the start');
  }
  return parsed.o;
}

function matches(task, filter) {
  if (filter.owner !== 'any' && task.owner?.kind !== filter.owner) return false;
  if (filter.status !== null) {
    const wanted = filter.status.toLowerCase();
    const name = (task.status?.name ?? '').toLowerCase();
    const type = (task.status?.type ?? '').toLowerCase();
    if (name !== wanted && type !== wanted) return false;
  }
  if (filter.project !== null) {
    const wanted = filter.project.toLowerCase();
    const id = (task.project?.id ?? '').toLowerCase();
    const name = (task.project?.name ?? '').toLowerCase();
    if (id !== wanted && name !== wanted) return false;
  }
  return true;
}

function compareTasks(a, b) {
  const at = Date.parse(a.updatedAt ?? '') || 0;
  const bt = Date.parse(b.updatedAt ?? '') || 0;
  if (bt !== at) return bt - at;
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
}

function parseTaskId(raw) {
  if (raw.startsWith('linear:')) {
    return { source: 'linear', sourceId: raw.slice('linear:'.length) };
  }
  if (raw.startsWith('kanban:')) {
    return { source: 'kanban', sourceId: raw.slice('kanban:'.length) };
  }
  if (LINEAR_IDENTIFIER.test(raw)) {
    return { source: 'linear', sourceId: raw };
  }
  return null;
}

export function taskRoutes({ linear, kanban, now = () => Date.now() } = {}) {
  const linearSource = linear ?? createLinearTaskSource();
  const kanbanSource = kanban ?? createKanbanTaskSource();

  async function list({ req }) {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    const filter = parseFilters(url.searchParams);
    const observedAt = new Date(now()).toISOString();
    const states = [];
    const items = [];
    let linearItems = null;

    if (filter.source === 'all' || filter.source === 'linear') {
      try {
        const outcome = await linearSource.listTasks();
        linearItems = outcome.items;
        items.push(...outcome.items);
        states.push({
          source: 'linear',
          state: 'available',
          observedAt,
          truncated: Boolean(outcome.truncated),
        });
      } catch (error) {
        states.push({ source: 'linear', state: 'unavailable', reason: reasonOf(error), observedAt });
        throw toBridgeError(error, 'linear_unavailable');
      }
    }

    let suppressed = 0;
    if (filter.source === 'all' || filter.source === 'kanban') {
      const description = kanbanSource.describe();
      if (description.state !== 'available') {
        states.push(description);
      } else {
        try {
          const outcome = await kanbanSource.listTasks();
          const known = new Set((linearItems ?? []).map((item) => item.sourceId.toUpperCase()));
          for (const raw of outcome.items) {
            const { linearRefs = [], ...item } = raw;
            const linearSourceId = linearRefs[0] ?? null;
            if (linearSourceId && known.has(linearSourceId.toUpperCase())) {
              suppressed += 1;
              continue;
            }
            items.push({ ...item, linearSourceId });
          }
          states.push({ source: 'kanban', state: 'available', observedAt });
        } catch (error) {
          states.push({ source: 'kanban', state: 'unavailable', reason: reasonOf(error), observedAt });
        }
      }
    }

    const filtered = items.filter((task) => matches(task, filter)).sort(compareTasks);
    const filterKey = filterKeyOf(filter);
    const issuedAt = now();
    const offset = filter.cursor ? decodeCursor(filter.cursor, filterKey, issuedAt) : 0;
    const page = filtered.slice(offset, offset + filter.limit);
    const nextOffset = offset + page.length;
    return {
      status: 200,
      data: {
        items: page,
        nextCursor: nextOffset < filtered.length ? encodeCursor(nextOffset, filterKey, issuedAt) : null,
        total: filtered.length,
        sources: states,
        suppressedDuplicates: { kanban: suppressed },
      },
    };
  }

  async function detail({ params }) {
    const rawParam = params?.[0];
    if (typeof rawParam !== 'string') {
      throw new BridgeError(404, 'task_not_found', 'the task id is not valid');
    }
    let raw;
    try {
      raw = decodeURIComponent(rawParam);
    } catch {
      throw new BridgeError(404, 'task_not_found', 'the task id is not valid');
    }
    if (!TASK_ID.test(raw)) {
      throw new BridgeError(404, 'task_not_found', 'the task id is not valid');
    }
    const target = parseTaskId(raw);
    if (!target || !TASK_ID.test(target.sourceId)) {
      throw new BridgeError(404, 'task_not_found', 'the task id is not valid');
    }

    if (target.source === 'kanban') {
      const description = kanbanSource.describe();
      if (description.state !== 'available') {
        throw new BridgeError(503, 'kanban_unavailable', description.detail ?? 'Kanban is not available', {
          retryable: false,
        });
      }
      let found;
      try {
        found = await kanbanSource.getTask(target.sourceId);
      } catch (error) {
        throw toBridgeError(error, 'kanban_unavailable');
      }
      if (!found) throw new BridgeError(404, 'task_not_found', 'no such task in the readable range');
      return { status: 200, data: found };
    }

    let found;
    try {
      found = await linearSource.getTask(target.sourceId);
    } catch (error) {
      throw toBridgeError(error, 'linear_unavailable');
    }
    if (!found) throw new BridgeError(404, 'task_not_found', 'no such task in the readable range');
    return { status: 200, data: found };
  }

  return [
    { method: 'GET', path: '/v1/tasks', auth: true, scope: 'tasks:read', handler: list },
    {
      method: 'GET',
      path: '/v1/tasks/{id}',
      auth: true,
      scope: 'tasks:read',
      pattern: DETAIL_PATH,
      handler: detail,
    },
  ];
}

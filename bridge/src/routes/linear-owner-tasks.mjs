// The owner's own Linear tasks over HTTP: /v1/linear-owner-tasks.
//
// The Work tab is the owner's list, so this endpoint has no team or assignee
// input at all: the source resolves the team (key BUS), the owner id and the
// workflow states from the account, and refuses a credential that is not the
// owner. A task an agent holds, or a delegated one, is never part of it.
//
// Writes use the generic `state.json` idempotency ledger (`idempotent: true`):
// the app keeps its Idempotency-Key and request body in its drafts, so a retry
// after a lost response replays the stored task instead of creating or patching
// twice. The ledger only releases a reservation when the handler failed before
// any write (validation, ownership, If-Match), which is why `releaseOnError` is
// narrow.
//
// PATCH requires If-Match with the task's `updatedAt` (428 when missing, 412
// when stale). Linear has no compare-and-swap, so the check is a read followed
// by a write: it stops the two-device silent overwrite this Bridge forbids
// elsewhere, without claiming atomicity.

import { BridgeError, badRequest, markBeforeWrite } from '../errors.mjs';
import { TaskSourceError, createLinearOwnerTaskSource } from '../tasks/linear-owner.mjs';
import { parseObjectBody } from './state-file.mjs';

const DETAIL_PATH = /^\/v1\/linear-owner-tasks\/([^/]+)$/;
const TASK_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const DUE_DATE = /^\d{4}-\d{2}-\d{2}$/;
const TITLE_MAX = 200;
const DESCRIPTION_MAX = 20_000;
const PRIORITY_MIN = 0;
const PRIORITY_MAX = 4;

const CREATE_FIELDS = ['id', 'title', 'description', 'dueDate', 'priority'];
const PATCH_FIELDS = ['title', 'description', 'dueDate', 'priority', 'completed'];

function toBridgeError(error, fallbackCode = 'linear_unavailable') {
  if (error instanceof BridgeError) return error;
  if (!(error instanceof TaskSourceError)) {
    // An unexpected error's message could carry a token or a GraphQL echo, so
    // only the explicit write marker is carried over; its status and text are
    // not.
    return new BridgeError(503, fallbackCode, 'the Linear task source is not available', {
      retryable: true,
      ...(typeof error?.writeStarted === 'boolean' ? { writeStarted: error.writeStarted } : {}),
    });
  }
  const status = Number.isInteger(error.status) ? error.status : 503;
  return new BridgeError(status, error.code, error.message, {
    retryable: Boolean(error.retryable),
    ...(typeof error.writeStarted === 'boolean' ? { writeStarted: error.writeStarted } : {}),
  });
}

function unknownField(name, allowed) {
  return badRequest('payload_field_unknown', `${name} is not accepted here; allowed: ${allowed.join(', ')}`);
}

function checkFields(body, allowed) {
  for (const name of Object.keys(body)) {
    if (!allowed.includes(name)) throw unknownField(name, allowed);
  }
}

function checkTitle(raw) {
  if (typeof raw !== 'string') throw badRequest('payload_invalid', 'title must be a string');
  const title = raw.trim();
  if (title === '') throw badRequest('payload_invalid', 'title must not be empty');
  if (title.length > TITLE_MAX) throw badRequest('payload_invalid', `title must be at most ${TITLE_MAX} characters`);
  return title;
}

function checkDescription(raw) {
  if (raw === null) return null;
  if (typeof raw !== 'string') throw badRequest('payload_invalid', 'description must be a string or null');
  if (raw.length > DESCRIPTION_MAX) {
    throw badRequest('payload_invalid', `description must be at most ${DESCRIPTION_MAX} characters`);
  }
  return raw;
}

function checkDueDate(raw) {
  if (raw === null) return null;
  if (typeof raw !== 'string' || !DUE_DATE.test(raw)) {
    throw badRequest('payload_invalid', 'dueDate must be YYYY-MM-DD or null');
  }
  const [year, month, day] = raw.split('-').map(Number);
  const parsed = new Date(Date.UTC(year, month - 1, day));
  if (
    parsed.getUTCFullYear() !== year
    || parsed.getUTCMonth() !== month - 1
    || parsed.getUTCDate() !== day
  ) {
    throw badRequest('payload_invalid', 'dueDate is not a real date');
  }
  return raw;
}

function checkPriority(raw) {
  if (!Number.isInteger(raw) || raw < PRIORITY_MIN || raw > PRIORITY_MAX) {
    throw badRequest('payload_invalid', `priority must be an integer between ${PRIORITY_MIN} and ${PRIORITY_MAX}`);
  }
  return raw;
}

function checkTaskId(raw) {
  let id;
  try {
    id = decodeURIComponent(raw ?? '');
  } catch {
    throw new BridgeError(404, 'linear_owner_task_not_found', 'no such owner task');
  }
  if (!TASK_UUID.test(id)) {
    throw new BridgeError(404, 'linear_owner_task_not_found', 'no such owner task');
  }
  return id.toLowerCase();
}

// The client echoes the `updatedAt` it last saw. Quoted and weak forms are
// accepted because that is what an HTTP client library may send.
function checkIfMatch(raw) {
  if (raw === undefined || raw === null || raw === '') {
    throw new BridgeError(428, 'precondition_required', 'If-Match with the task updatedAt is required');
  }
  let value = String(raw).trim();
  if (value.startsWith('W/')) value = value.slice(2).trim();
  if (value.startsWith('"') && value.endsWith('"') && value.length >= 2) value = value.slice(1, -1);
  if (value === '' || value === '*' || value.includes(',')) {
    throw badRequest('precondition_invalid', 'If-Match must be one task updatedAt');
  }
  return value;
}

// Only an error explicitly marked as happening before the mutation may release
// the reservation. Status codes are not that proof: a source can fail with 503
// while resolving its settings (no write) or with 400/404 after sending a write.
// The ledger's own 409s are raised before the handler and never reach this.
const beforeWrite = (error) => error?.writeStarted === false;

export function linearOwnerTaskRoutes({ source } = {}) {
  const tasks = source ?? createLinearOwnerTaskSource();

  async function list() {
    try {
      const outcome = await tasks.listOwnerTasks();
      return { status: 200, data: { items: outcome.items, nextCursor: null } };
    } catch (error) {
      throw toBridgeError(error);
    }
  }

  async function detail({ params }) {
    const id = checkTaskId(params?.[0]);
    let task;
    try {
      task = await tasks.readOwnerTask(id);
    } catch (error) {
      throw toBridgeError(error);
    }
    if (!task) throw new BridgeError(404, 'linear_owner_task_not_found', 'no such owner task');
    return { status: 200, data: task };
  }

  async function create({ rawBody }) {
    let input;
    try {
      const body = parseObjectBody(rawBody);
      checkFields(body, CREATE_FIELDS);
      if (typeof body.id !== 'string' || !TASK_UUID.test(body.id)) {
        throw badRequest('payload_invalid', 'id must be a UUID v4 generated by the client');
      }
      input = {
        id: body.id.toLowerCase(),
        title: checkTitle(body.title),
        priority: body.priority === undefined ? 0 : checkPriority(body.priority),
      };
      if (Object.hasOwn(body, 'description') && body.description !== null) {
        input.description = checkDescription(body.description);
      }
      if (Object.hasOwn(body, 'dueDate') && body.dueDate !== null) {
        input.dueDate = checkDueDate(body.dueDate);
      }
    } catch (error) {
      throw markBeforeWrite(error);
    }
    let task;
    try {
      task = await tasks.createOwnerTask(input);
    } catch (error) {
      throw toBridgeError(error);
    }
    return { status: 201, data: task };
  }

  async function patch({ req, rawBody, params }) {
    let id;
    let fields;
    try {
      id = checkTaskId(params?.[0]);
      const expected = checkIfMatch(req.headers['if-match']);
      const body = parseObjectBody(rawBody);
      checkFields(body, PATCH_FIELDS);

      fields = {};
      if (Object.hasOwn(body, 'completed')) {
        if (body.completed !== true) {
          throw badRequest('payload_invalid', 'completed may only be true; a task is reopened in Linear');
        }
        const extra = Object.keys(body).filter((name) => name !== 'completed');
        if (extra.length > 0) {
          throw badRequest('payload_invalid', 'completed cannot be combined with other fields');
        }
        fields.completed = true;
      } else {
        if (Object.hasOwn(body, 'title')) fields.title = checkTitle(body.title);
        if (Object.hasOwn(body, 'description')) fields.description = checkDescription(body.description);
        if (Object.hasOwn(body, 'dueDate')) fields.dueDate = checkDueDate(body.dueDate);
        if (Object.hasOwn(body, 'priority')) fields.priority = checkPriority(body.priority);
        if (Object.keys(fields).length === 0) {
          throw badRequest('payload_invalid', 'at least one of title, description, dueDate, priority or completed is required');
        }
      }

      const current = await tasks.readOwnerTask(id);
      if (!current) throw new BridgeError(404, 'linear_owner_task_not_found', 'no such owner task');
      if (current.updatedAt !== expected) {
        throw new BridgeError(412, 'precondition_failed', 'the task changed since it was read', {
          details: { updatedAt: current.updatedAt },
        });
      }
    } catch (error) {
      throw markBeforeWrite(toBridgeError(error));
    }

    let task;
    try {
      task = await tasks.patchOwnerTask(id, fields);
    } catch (error) {
      throw toBridgeError(error);
    }
    return { status: 200, data: task };
  }

  async function remove({ req, params }) {
    let id;
    try {
      id = checkTaskId(params?.[0]);
      // The app cannot undo a delete, so it carries the same If-Match as an
      // edit: a task that changed since it was read is not deleted by this
      // request.
      const expected = checkIfMatch(req.headers['if-match']);
      const current = await tasks.readOwnerTask(id);
      if (!current) throw new BridgeError(404, 'linear_owner_task_not_found', 'no such owner task');
      if (current.updatedAt !== expected) {
        throw new BridgeError(412, 'precondition_failed', 'the task changed since it was read', {
          details: { updatedAt: current.updatedAt },
        });
      }
    } catch (error) {
      throw markBeforeWrite(toBridgeError(error));
    }
    let outcome;
    try {
      outcome = await tasks.deleteOwnerTask(id);
    } catch (error) {
      throw toBridgeError(error);
    }
    return { status: 200, data: { id, deleted: true, alreadyDeleted: outcome?.alreadyDeleted === true } };
  }

  return [
    { method: 'GET', path: '/v1/linear-owner-tasks', auth: true, scope: 'tasks:read', handler: list },
    {
      method: 'POST',
      path: '/v1/linear-owner-tasks',
      auth: true,
      scope: 'tasks:write',
      idempotent: true,
      handler: create,
      releaseOnError: beforeWrite,
    },
    {
      method: 'GET',
      path: '/v1/linear-owner-tasks/{id}',
      auth: true,
      scope: 'tasks:read',
      pattern: DETAIL_PATH,
      handler: detail,
    },
    {
      method: 'PATCH',
      path: '/v1/linear-owner-tasks/{id}',
      auth: true,
      scope: 'tasks:write',
      additionalScopes: ['tasks:read'],
      idempotent: true,
      pattern: DETAIL_PATH,
      handler: patch,
      releaseOnError: beforeWrite,
    },
    {
      method: 'DELETE',
      path: '/v1/linear-owner-tasks/{id}',
      auth: true,
      scope: 'tasks:write',
      additionalScopes: ['tasks:read'],
      idempotent: true,
      pattern: DETAIL_PATH,
      handler: remove,
      releaseOnError: beforeWrite,
    },
  ];
}

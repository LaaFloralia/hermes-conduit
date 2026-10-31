// Owner-scoped Linear endpoints. The existing /v1/tasks agent view remains
// untouched for clients which depend on it.
import { BridgeError, badRequest } from '../errors.mjs';
import { randomUUID } from 'node:crypto';
import { IDEMPOTENCY_KEY_PATTERN } from '../idempotency.mjs';
import { parseObjectBody } from './state-file.mjs';
import { createTaskOperationLedger, operationFingerprint } from '../tasks/operation-ledger.mjs';
import { createPersonalLinearSource } from '../tasks/personal.mjs';
import { TaskSourceError } from '../tasks/errors.mjs';

const DETAIL = /^\/v1\/personal-tasks\/([^/]+)$/;
const OPERATION = /^\/v1\/task-operations\/([0-9a-f-]+)$/i;
const RESOLUTION = /^\/v1\/task-operations\/([0-9a-f-]+)\/resolve$/i;
const ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,200}$/;

function asBridgeError(error) {
  if (error instanceof BridgeError) return error;
  if (error instanceof TaskSourceError) {
    return new BridgeError(error.status, error.code, error.message, { retryable: error.retryable });
  }
  // Dependency and helper exceptions may contain credentials or issue text.
  return new BridgeError(503, 'linear_unavailable', 'the personal Linear source is not available', { retryable: true });
}

function parameters(req) { return new URL(req.url ?? '/', 'http://127.0.0.1').searchParams; }
function requestedId(value) {
  try {
    const id = decodeURIComponent(value);
    if (ID.test(id)) return id;
  } catch { /* same refusal for all malformed ids */ }
  throw badRequest('task_id_invalid', 'the task id is invalid');
}
function guarded(handler) {
  return async (context) => {
    try { return await handler(context); } catch (error) { throw asBridgeError(error); }
  };
}

function requireKey(req) {
  const key = req.headers['idempotency-key'];
  if (typeof key !== 'string' || !IDEMPOTENCY_KEY_PATTERN.test(key)) {
    throw badRequest('idempotency_key_required', 'a valid Idempotency-Key is required');
  }
  return key;
}

const ISSUE_IDS = new Set(['teamId', 'assigneeId', 'stateId', 'projectId', 'projectMilestoneId', 'cycleId', 'parentId']);
const NULLABLE_IDS = new Set(['assigneeId', 'projectId', 'projectMilestoneId', 'cycleId', 'parentId']);
function issueInput(rawBody, creating) {
  const { expectedViewerId, ...input } = parseObjectBody(rawBody);
  if (typeof expectedViewerId !== 'string' || !ID.test(expectedViewerId)) {
    throw badRequest('expected_viewer_required', 'the original Linear viewer is required');
  }
  const allowed = new Set(['title', 'description', 'priority', 'estimate', 'dueDate', 'labelIds', ...ISSUE_IDS]);
  if (Object.keys(input).length === 0 || Object.keys(input).some((name) => !allowed.has(name))) {
    throw badRequest('payload_invalid', 'the task contains an unsupported field');
  }
  if (creating && (typeof input.teamId !== 'string' || typeof input.title !== 'string')) {
    throw badRequest('payload_invalid', 'teamId and title are required');
  }
  if ('title' in input && (typeof input.title !== 'string' || input.title.trim() === '' || input.title.length > 512)) {
    throw badRequest('payload_invalid', 'title must contain 1–512 characters');
  }
  if ('description' in input && (typeof input.description !== 'string' || Buffer.byteLength(input.description, 'utf8') > 48 * 1024)) {
    throw badRequest('payload_invalid', 'description must be text of at most 48 KiB');
  }
  for (const field of ISSUE_IDS) {
    if (!(field in input)) continue;
    const value = input[field];
    if (value === null && NULLABLE_IDS.has(field)) continue;
    if (typeof value !== 'string' || !ID.test(value)) throw badRequest('payload_invalid', `${field} is invalid`);
  }
  if ('priority' in input && (!Number.isInteger(input.priority) || input.priority < 0 || input.priority > 4)) {
    throw badRequest('payload_invalid', 'priority must be between 0 and 4');
  }
  if ('estimate' in input && input.estimate !== null && (!Number.isInteger(input.estimate) || input.estimate < 0 || input.estimate > 10000)) {
    throw badRequest('payload_invalid', 'estimate must be a non-negative integer or null');
  }
  if ('dueDate' in input && input.dueDate !== null) {
    if (typeof input.dueDate !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(input.dueDate)
        || !Number.isFinite(Date.parse(`${input.dueDate}T00:00:00Z`))
        || new Date(`${input.dueDate}T00:00:00Z`).toISOString().slice(0, 10) !== input.dueDate) {
      throw badRequest('payload_invalid', 'dueDate must be a valid ISO date or null');
    }
  }
  if ('labelIds' in input && (!Array.isArray(input.labelIds) || input.labelIds.length > 100
      || input.labelIds.some((id) => typeof id !== 'string' || !ID.test(id)))) {
    throw badRequest('payload_invalid', 'labelIds must be an array of at most 100 ids');
  }
  return { input, expectedViewerId };
}

export function personalTaskRoutes({ personal, personalConfig, store, now = () => Date.now() } = {}) {
  const source = personal ?? createPersonalLinearSource({ ...personalConfig, now });
  const operations = createTaskOperationLedger({ store, now });
  const inFlight = new Set();
  const read = (path, handler, pattern) => ({
    method: 'GET', path, ...(pattern ? { pattern } : {}), auth: true, scope: 'tasks:read', handler: guarded(handler),
  });
  const collection = (name) => async ({ req }) => {
    const query = parameters(req);
    return { status: 200, data: await source.listCollection(name, { cursor: query.get('cursor'), limit: query.get('limit') }) };
  };
  const write = (method, path, handler, pattern) => ({
    method, path, ...(pattern ? { pattern } : {}), auth: true, scope: 'tasks:write', handler: guarded(handler),
  });
  async function requestSession() { return source.session(); }
  const statusFor = (entry) => ({ status: 200, data: { operation: entry } });

  async function mutateIssue({ req, device, rawBody, params }, creating) {
    const key = requireKey(req);
    const { input, expectedViewerId } = issueInput(rawBody, creating);
    const target = creating ? randomUUID() : requestedId(params[0]);
    const hasDescription = !creating && Object.hasOwn(input, 'description');
    const ifMatch = req.headers['if-match'];
    if (hasDescription && (typeof ifMatch !== 'string' || ifMatch.trim() === '')) {
      throw new BridgeError(428, 'if_match_required', 'editing a description requires its previously read version');
    }
    const personalSession = await requestSession();
    const viewerId = personalSession.viewer.id;
    if (viewerId !== expectedViewerId) {
      throw new BridgeError(409, 'linear_viewer_changed', 'the task was prepared for a different Linear viewer');
    }
    const path = creating ? '/v1/personal-tasks' : `/v1/personal-tasks/${encodeURIComponent(target)}`;
    const reserved = operations.reserve({ deviceId: device.id, viewerId, key, method: req.method, path,
      ifMatch: typeof ifMatch === 'string' ? ifMatch : null, rawBody, kind: creating ? 'create' : 'update', targetId: target });
    if (reserved.action === 'conflict') throw new BridgeError(409, 'idempotency_key_conflict', 'the key belongs to a different request');
    if (reserved.action === 'expired') {
      throw new BridgeError(409, 'idempotency_outcome_unknown', 'the earlier result must be reconciled', { details: { operation: reserved.entry } });
    }
    if (reserved.action === 'existing') {
      const previous = reserved.entry;
      if (previous.status === 'succeeded') return statusFor(previous);
      if (previous.status === 'rejected') {
        if (reserved.rejection === 'version_mismatch') {
          const current = await source.getTaskInSession(personalSession, target);
          throw new BridgeError(412, 'version_mismatch', 'the description changed; compare it before saving', { details: { current: current?.task ?? null } });
        }
        throw new BridgeError(409, 'task_operation_rejected', 'the previous request was refused before the Linear write');
      }
      if (previous.status === 'in_progress') {
        throw new BridgeError(409, 'idempotency_key_in_flight', 'the same operation is still in progress', { details: { operation: previous } });
      }
      throw new BridgeError(409, 'idempotency_outcome_unknown', 'the earlier operation must be reconciled', { details: { operation: previous } });
    }
    const operationId = reserved.entry.operationId;
    inFlight.add(operationId);
    let sent = false;
    try {
      if (hasDescription) {
        const current = await source.getTaskInSession(personalSession, target);
        if (!current) throw new BridgeError(404, 'task_not_found', 'the task was not found');
        if (current.task.updatedAt !== ifMatch) {
          throw new BridgeError(412, 'version_mismatch', 'the description changed; compare it before saving', { details: { current: current.task } });
        }
      }
      sent = true;
      const result = creating
        ? await source.createIssue(personalSession, { ...input, id: target })
        : await source.updateIssue(personalSession, target, input);
      const comparable = target.replace(/^linear:/, '');
      if ((creating && result.id !== target) || (!creating && result.id !== comparable && result.identifier !== comparable)) {
        throw new Error('Linear returned a different target');
      }
      const finished = operations.finish({ deviceId: device.id, viewerId, key, status: 'succeeded', result });
      return { status: creating ? 201 : 200, data: { operation: finished } };
    } catch (error) {
      if (!sent) {
        const rejection = error instanceof BridgeError && ['version_mismatch', 'task_not_found'].includes(error.code)
          ? error.code : 'preflight_failed';
        operations.finish({ deviceId: device.id, viewerId, key, status: 'rejected', rejection });
        throw error;
      }
      try { operations.finish({ deviceId: device.id, viewerId, key, status: 'outcome_unknown' }); } catch { /* fail closed */ }
      throw new BridgeError(409, 'idempotency_outcome_unknown', 'Linear may have received the operation; reconcile before retrying', {
        details: { operationId },
      });
    } finally {
      inFlight.delete(operationId);
    }
  }
  async function operationContext(device) {
    const session = await requestSession();
    return { deviceId: device.id, viewerId: session.viewer.id };
  }
  return [
    read('/v1/personal-tasks', async ({ req }) => {
      const query = parameters(req);
      return { status: 200, data: await source.listTasks({
        view: query.get('view'), search: query.get('search'), project: query.get('project'),
        cycle: query.get('cycle'), customView: query.get('customView'),
        cursor: query.get('cursor'), limit: query.get('limit'),
      }) };
    }),
    read('/v1/personal-tasks/{id}', async ({ params }) => {
      const result = await source.getTask(requestedId(params[0]));
      if (!result) throw new BridgeError(404, 'task_not_found', 'the task was not found');
      return { status: 200, data: result };
    }, DETAIL),
    read('/v1/task-metadata', async () => ({ status: 200, data: await source.metadata() })),
    read('/v1/task-projects', collection('projects')),
    read('/v1/task-cycles', collection('cycles')),
    read('/v1/task-views', collection('views')),
    read('/v1/task-inbox', collection('inbox')),
    read('/v1/task-options', async ({ req }) => {
      const query = parameters(req);
      const kind = query.get('kind');
      if (!['teams', 'users', 'states', 'labels', 'milestones'].includes(kind)) {
        throw badRequest('filter_invalid', 'kind is invalid');
      }
      return { status: 200, data: await source.listCollection(kind, { cursor: query.get('cursor'), limit: query.get('limit') }) };
    }),
    write('POST', '/v1/personal-tasks', (ctx) => mutateIssue(ctx, true)),
    write('PATCH', '/v1/personal-tasks/{id}', (ctx) => mutateIssue(ctx, false), DETAIL),
    write('GET', '/v1/task-operations/by-key', async ({ device, req }) => {
      const entry = operations.byKey({ ...await operationContext(device), key: requireKey(req) });
      if (!entry) throw new BridgeError(404, 'operation_not_found', 'the task operation was not found');
      return statusFor(entry);
    }),
    write('GET', '/v1/task-operations', async ({ device }) => ({ status: 200, data: {
      items: operations.list(await operationContext(device)), nextCursor: null,
    } })),
    write('GET', '/v1/task-operations/{id}', async ({ device, params }) => {
      const entry = operations.get({ ...await operationContext(device), operationId: params[0] });
      if (!entry) throw new BridgeError(404, 'operation_not_found', 'the task operation was not found');
      return statusFor(entry);
    }, OPERATION),
    write('POST', '/v1/task-operations/{id}/resolve', async ({ device, params, rawBody, req }) => {
      const key = requireKey(req);
      const input = parseObjectBody(rawBody);
      if (Object.keys(input).sort().join(',') !== 'confirmed,resolution' || input.confirmed !== true
          || !['applied', 'not_applied'].includes(input.resolution)) {
        throw badRequest('payload_invalid', 'explicit confirmation and a reconciliation result are required');
      }
      if (inFlight.has(params[0])) throw new BridgeError(409, 'idempotency_key_in_flight', 'the operation is still running');
      const context = await operationContext(device);
      const fingerprint = operationFingerprint({ method: 'POST', path: `/v1/task-operations/${params[0]}/resolve`,
        viewerId: context.viewerId, ifMatch: null, rawBody });
      const entry = operations.resolve({ ...context, operationId: params[0], resolution: input.resolution, key, fingerprint });
      return statusFor(entry);
    }, RESOLUTION),
  ];
}

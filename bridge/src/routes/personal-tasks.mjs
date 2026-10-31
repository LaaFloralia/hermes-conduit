// Owner-scoped Linear endpoints. The existing /v1/tasks agent view remains
// untouched for clients which depend on it.
import { BridgeError, badRequest } from '../errors.mjs';
import { createPersonalLinearSource } from '../tasks/personal.mjs';
import { TaskSourceError } from '../tasks/errors.mjs';

const DETAIL = /^\/v1\/personal-tasks\/([^/]+)$/;
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

export function personalTaskRoutes({ personal, personalConfig, now = () => Date.now() } = {}) {
  const source = personal ?? createPersonalLinearSource({ ...personalConfig, now });
  const read = (path, handler, pattern) => ({
    method: 'GET', path, ...(pattern ? { pattern } : {}), auth: true, scope: 'tasks:read', handler: guarded(handler),
  });
  const collection = (name) => async ({ req }) => {
    const query = parameters(req);
    return { status: 200, data: await source.listCollection(name, { cursor: query.get('cursor'), limit: query.get('limit') }) };
  };
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
  ];
}

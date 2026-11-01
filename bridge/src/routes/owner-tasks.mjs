// Owner tasks over HTTP: GET/POST /v1/owner-tasks and GET/PATCH
// /v1/owner-tasks/{id} (bridge/docs/owner-tasks.md).
//
// Idempotency is handled by the store, not by the generic `state.json` ledger:
// the task change and the ledger row that proves it are written by the same
// atomic replace, so there is no window in which a key is reserved but the task
// is missing. That is why these routes are not marked `idempotent: true`.

import { BridgeError, badRequest } from '../errors.mjs';
import { IDEMPOTENCY_KEY_PATTERN } from '../idempotency.mjs';
import { etagFor } from '../tasks/owner-service.mjs';
import { parseObjectBody } from './state-file.mjs';

const DETAIL_PATH = /^\/v1\/owner-tasks\/([^/]+)$/;

function idempotencyKey(req) {
  const key = req.headers['idempotency-key'];
  if (typeof key !== 'string' || key === '') {
    throw badRequest('idempotency_key_required', 'Idempotency-Key header is required');
  }
  if (!IDEMPOTENCY_KEY_PATTERN.test(key)) {
    throw badRequest('idempotency_key_invalid', 'Idempotency-Key must be 1-200 of A-Z a-z 0-9 . _ : -');
  }
  return key;
}

function taskHeaders(result) {
  return {
    etag: etagFor(result.task.revision),
    ...(result.replayed ? { 'idempotency-replayed': 'true' } : {}),
  };
}

export function ownerTaskRoutes({ service } = {}) {
  function list({ req }) {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    return {
      status: 200,
      data: service.list({
        status: url.searchParams.get('status'),
        limit: url.searchParams.get('limit'),
        cursor: url.searchParams.get('cursor'),
      }),
    };
  }

  function detail({ params }) {
    let id;
    try {
      id = decodeURIComponent(params?.[0] ?? '');
    } catch {
      throw new BridgeError(404, 'owner_task_not_found', 'no such owner task');
    }
    const task = service.get(id);
    return { status: 200, data: task, headers: { etag: etagFor(task.revision) } };
  }

  function create({ req, rawBody, device }) {
    const result = service.create({
      principal: device.id,
      key: idempotencyKey(req),
      method: 'POST',
      path: '/v1/owner-tasks',
      body: parseObjectBody(rawBody),
    });
    return { status: result.status, data: result.task, headers: taskHeaders(result) };
  }

  function update({ req, rawBody, device, params }) {
    let id;
    try {
      id = decodeURIComponent(params?.[0] ?? '');
    } catch {
      throw new BridgeError(404, 'owner_task_not_found', 'no such owner task');
    }
    const result = service.update({
      principal: device.id,
      key: idempotencyKey(req),
      method: 'PATCH',
      path: `/v1/owner-tasks/${id}`,
      id,
      ifMatch: req.headers['if-match'],
      body: parseObjectBody(rawBody),
    });
    return { status: result.status, data: result.task, headers: taskHeaders(result) };
  }

  return [
    { method: 'GET', path: '/v1/owner-tasks', auth: true, scope: 'tasks:read', handler: list },
    { method: 'POST', path: '/v1/owner-tasks', auth: true, scope: 'tasks:write', handler: create },
    { method: 'GET', path: '/v1/owner-tasks/{id}', auth: true, scope: 'tasks:read', pattern: DETAIL_PATH, handler: detail },
    { method: 'PATCH', path: '/v1/owner-tasks/{id}', auth: true, scope: 'tasks:write', pattern: DETAIL_PATH, handler: update },
  ];
}

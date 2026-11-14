import { BridgeError } from '../errors.mjs';
import { createHabitStore } from '../habits/store.mjs';
import { createHabitService, habitETag } from '../habits/service.mjs';
import { parseObjectBody } from './state-file.mjs';

export function habitRoutes({ dir, now = () => Date.now(), store, service } = {}) {
  service ??= createHabitService({ store: store ?? createHabitStore({ dir, now }), now });
  const query = (req) => new URL(req.url ?? '/', 'http://127.0.0.1').searchParams;
  function decode(value) {
    try { return decodeURIComponent(value); } catch { throw new BridgeError(404, 'habit_not_found', 'no such habit'); }
  }
  // Every write answers with the habit or its week, so a device also needs
  // `tasks:read`: write-only access must not read the owner's habits.
  return [
    { method: 'GET', path: '/v1/habits', auth: true, scope: 'tasks:read', handler: ({ req }) => ({ status: 200, data: service.week({ week: query(req).get('week') }) }) },
    { method: 'GET', path: '/v1/habits/history', auth: true, scope: 'tasks:read', handler: ({ req }) => ({ status: 200, data: service.history({ weeks: query(req).get('weeks') }) }) },
    { method: 'GET', path: '/v1/habits/archived', auth: true, scope: 'tasks:read', handler: () => ({ status: 200, data: service.archived() }) },
    { method: 'GET', path: '/v1/habits/events', auth: true, scope: 'tasks:read', handler: ({ req }) => ({ status: 200, data: service.events({ limit: query(req).get('limit'), cursor: query(req).get('cursor') }) }) },
    { method: 'POST', path: '/v1/habits', auth: true, scope: 'tasks:write', additionalScopes: ['tasks:read'], handler: ({ req, device, rawBody }) => {
      const result = service.create({ principal: device.id, key: req.headers['idempotency-key'], body: parseObjectBody(rawBody) });
      return { status: result.status, data: result.habit, headers: { etag: habitETag(result.habit.revision), ...(result.replayed ? { 'idempotency-replayed': 'true' } : {}) } };
    } },
    { method: 'PATCH', path: '/v1/habits/{id}', pattern: /^\/v1\/habits\/([^/]+)$/, auth: true, scope: 'tasks:write', additionalScopes: ['tasks:read'], handler: ({ req, params, rawBody }) => {
      const habit = service.update({ id: decode(params[0]), ifMatch: req.headers['if-match'], body: parseObjectBody(rawBody) });
      return { status: 200, data: habit, headers: { etag: habitETag(habit.revision) } };
    } },
    { method: 'PUT', path: '/v1/habits/{id}/checkins/{date}', pattern: /^\/v1\/habits\/([^/]+)\/checkins\/([^/]+)$/, auth: true, scope: 'tasks:write', additionalScopes: ['tasks:read'], handler: ({ params, rawBody }) => ({
      status: 200, data: service.check({ id: decode(params[0]), date: decode(params[1]), body: parseObjectBody(rawBody) }),
    }) },
  ];
}

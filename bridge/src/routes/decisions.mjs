import { parseObjectBody } from './state-file.mjs';

export function createDecisionRoutes({ service }) {
  return [
    { method: 'GET', path: '/v1/decisions', auth: true, scope: 'sessions:read', handler: async () => ({ status: 200, data: await service.list() }) },
    { method: 'GET', pattern: /^\/v1\/decisions\/(dec_[0-9a-f]{16})$/, auth: true, scope: 'sessions:read', handler: ({ params }) => ({ status: 200, data: service.get(params[0]) }) },
    ...['answer', 'retry'].map((action) => ({ method: 'POST', pattern: new RegExp(`^/v1/decisions/(dec_[0-9a-f]{16})/${action}$`), auth: true, scope: 'sessions:write', idempotent: true,
      handler: async ({ params, device, rawBody }) => ({ status: 200, data: await service.answer({ id: params[0], deviceId: device.id, body: parseObjectBody(rawBody), retry: action === 'retry' }) }) })),
  ];
}

import { parseObjectBody } from './state-file.mjs';
import { badRequest } from '../errors.mjs';

export function createDecisionRoutes({ service }) {
  return [
    { method: 'GET', path: '/v1/decisions', auth: true, scope: 'sessions:read', handler: async ({ req }) => {
      const query = new URL(req.url, 'http://127.0.0.1').searchParams;
      if (query.get('answeredBy') === 'monet') return { status: 200, data: service.digest(query.get('since')) };
      if (query.has('answeredBy') || query.has('since')) throw badRequest('decision_query_invalid', 'expected answeredBy=monet and optional since');
      return { status: 200, data: await service.list() };
    } },
    { method: 'GET', path: '/v1/decisions/delegation', auth: true, scope: 'sessions:read',
      handler: () => ({ status: 200, data: service.delegation() }) },
    { method: 'PUT', path: '/v1/decisions/delegation', auth: true, scope: 'sessions:write', additionalScopes: ['decisions:delegate'], idempotent: true,
      handler: ({ rawBody }) => ({ status: 200, data: service.setDelegation(parseObjectBody(rawBody)) }) },
    { method: 'POST', pattern: /^\/v1\/decisions\/(dec_[0-9a-f]{16})\/reopen$/, auth: true, scope: 'sessions:write',
      additionalScopes: ['decisions:delegate'], idempotent: true, handler: ({ params }) => ({ status: 200, data: { decision: service.reopen(params[0]) } }) },
    { method: 'GET', pattern: /^\/v1\/decisions\/(dec_[0-9a-f]{16})$/, auth: true, scope: 'sessions:read', handler: ({ params }) => ({ status: 200, data: service.get(params[0]) }) },
    ...['answer', 'retry'].map((action) => ({ method: 'POST', pattern: new RegExp(`^/v1/decisions/(dec_[0-9a-f]{16})/${action}$`), auth: true, scope: 'sessions:write', idempotent: true,
      handler: async ({ params, device, rawBody }) => ({ status: 200, data: await service.answer({ id: params[0], deviceId: device.id, body: parseObjectBody(rawBody), retry: action === 'retry' }) }) })),
  ];
}

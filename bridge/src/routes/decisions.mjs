import { imageNotFound } from '../decisions/images.mjs';
import { parseObjectBody } from './state-file.mjs';

export function createDecisionRoutes({ service }) {
  return [
    { method: 'GET', path: '/v1/decisions', auth: true, scope: 'sessions:read', handler: async () => ({ status: 200, data: await service.list() }) },
    { method: 'GET', pattern: /^\/v1\/decisions\/(dec_[0-9a-f]{16})$/, auth: true, scope: 'sessions:read', handler: ({ params }) => ({ status: 200, data: service.get(params[0]) }) },
    { method: 'GET', pattern: /^\/v1\/decisions\/(dec_[0-9a-f]{16})\/images\/(img_[0-9a-f]{12})$/, auth: true, scope: 'sessions:read',
      handler: ({ req, params: [id, imgId] }) => {
        // The router normalizes dot segments first; reject aliases of the image path.
        const [path] = req.url.split('?', 1);
        if (path !== `/v1/decisions/${id}/images/${imgId}`) throw imageNotFound();
        const size = new URLSearchParams(req.url.slice(path.length)).get('size');
        const { bytes, etag, ...meta } = service.image(id, imgId, size);
        const headers = { etag };
        const matches = req.headers['if-none-match']?.split(',').some((tag) => tag.trim() === '*' || tag.trim().replace(/^W\//, '') === etag);
        return matches ? { status: 304, headers } : { status: 200, headers, data: { ...meta, etag, data: bytes.toString('base64') } };
      } },
    ...['answer', 'retry'].map((action) => ({ method: 'POST', pattern: new RegExp(`^/v1/decisions/(dec_[0-9a-f]{16})/${action}$`), auth: true, scope: 'sessions:write', idempotent: true,
      handler: async ({ params, device, rawBody }) => ({ status: 200, data: await service.answer({ id: params[0], deviceId: device.id, body: parseObjectBody(rawBody), retry: action === 'retry' }) }) })),
  ];
}

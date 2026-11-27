import { imageNotFound } from '../decisions/images.mjs';

const detail = '/v1/findings/(fnd_[0-9a-f]{16})';
const read = { method: 'GET', auth: true, scope: 'sessions:read' };
const respond = (data) => ({ status: 200, data });

export function createFindingRoutes({ service }) {
  return [
    { ...read, path: '/v1/findings', handler: () => respond(service.list()) },
    { ...read, pattern: new RegExp(`^${detail}$`), handler: ({ params }) => respond(service.get(params[0])) },
    { ...read, pattern: new RegExp(`^${detail}/images/(img_[0-9a-f]{12})$`), handler: ({ req, params: [id, imageId] }) => {
      const [path] = req.url.split('?', 1);
      if (path !== `/v1/findings/${id}/images/${imageId}`) throw imageNotFound();
      const size = new URLSearchParams(req.url.slice(path.length)).get('size');
      const { bytes, etag, ...meta } = service.image(id, imageId, size);
      const headers = { etag };
      const matches = req.headers['if-none-match']?.split(',').some((tag) => tag.trim() === '*' || tag.trim().replace(/^W\//, '') === etag);
      return matches ? { status: 304, headers } : { status: 200, headers, data: { ...meta, etag, data: bytes.toString('base64') } };
    } },
    // These transitions are idempotent in findings.json; no request key is
    // required and a replay cannot reapply an obsolete transition.
    ...['delegate', 'dismiss'].map((action) => ({ method: 'POST', pattern: new RegExp(`^${detail}/${action}$`),
      auth: true, scope: 'sessions:write', handler: ({ params }) => respond({ finding: service[action](params[0]) }) })),
  ];
}

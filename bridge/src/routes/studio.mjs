import { randomUUID } from 'node:crypto';
import { pipeline } from 'node:stream/promises';
import { Transform } from 'node:stream';
import { BridgeError } from '../errors.mjs';
import { createStudioBackend } from '../studio/backend.mjs';
import { parseBody, validateAction, validateRequest } from '../studio/validation.mjs';

const UUID = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}';
const mediaPattern = /^\/v1\/studio\/media\/([a-zA-Z0-9-]{1,100})\/([a-f0-9]{64}\.(?:jpg|png|webp|mp4|mp3|glb))$/;
const requestPattern = new RegExp(`^/v1/studio/requests/(${UUID})$`);
const MAX_MEDIA = 16 * 1024 * 1024;
const MEDIA_TYPES = { jpg: 'image/jpeg', png: 'image/png', webp: 'image/webp', mp4: 'video/mp4', mp3: 'audio/mpeg', glb: 'model/gltf-binary' };

function validateAnswer(action, record) {
  const approval = record?.report?.approvals?.find((item) => item.id === action.approvalId);
  if (!approval || record.status !== 'approval') throw new BridgeError(409, 'studio_approval_changed', 'The question is no longer current');
  if (!approval.supported) throw new BridgeError(409, 'studio_approval_on_mac', 'This question must be handled on the Mac');
  if (action.persist && !approval.allowSession) throw new BridgeError(400, 'studio_payload_invalid', 'This question does not permit session persistence');
  const fields = Array.isArray(approval.fields) ? approval.fields : [];
  if (Object.keys(action.content).some((name) => !fields.some((field) => field.name === name))) {
    throw new BridgeError(400, 'studio_payload_invalid', 'Unknown question field');
  }
  if (!action.accept) return;
  for (const field of fields) {
    const value = action.content[field.name];
    if (value === undefined || value === '') {
      if (field.required) throw new BridgeError(400, 'studio_payload_invalid', 'A required answer is missing');
      continue;
    }
    const valid = (field.type === 'string' && typeof value === 'string') ||
      (field.type === 'number' && typeof value === 'number' && Number.isFinite(value)) ||
      (field.type === 'integer' && Number.isSafeInteger(value)) ||
      (field.type === 'boolean' && typeof value === 'boolean');
    if (!valid || (Array.isArray(field.options) && !field.options.includes(String(value)))) {
      throw new BridgeError(400, 'studio_payload_invalid', 'Answer does not match the question');
    }
  }
}

export function studioRoutes({ backend = createStudioBackend() } = {}) {
  async function snapshot() { return { status: 200, data: await backend.snapshot() }; }
  async function getRequest({ params }) { return { status: 200, data: await backend.getRequest(params[0]) }; }
  async function createRequest({ rawBody }) {
    const body = validateRequest(parseBody(rawBody));
    return { status: 202, data: await backend.createRequest(body) };
  }
  async function replayRequest({ rawBody }) {
    // A replay confirms the original mutation but must report current state.
    return backend.getRequest(validateRequest(parseBody(rawBody)).id);
  }
  async function action({ rawBody }) {
    const body = validateAction(parseBody(rawBody));
    if (body.action === 'answer') validateAnswer(body, await backend.getRequest(body.id));
    return { status: 200, data: await backend.action(body) };
  }
  async function media({ req, res, requestId, params }) {
    const abort = new AbortController();
    const onClose = () => { if (!res.writableEnded) abort.abort(); };
    res.on('close', onClose);
    let upstream;
    try {
      upstream = await backend.media(`/api/studio/media/${params[0]}/${params[1]}`,
        { method: 'GET', range: req.headers.range, signal: abort.signal });
      const status = upstream.statusCode;
      if (status === 416) {
        const headers = { 'content-type': 'application/json', 'accept-ranges': 'bytes', 'cache-control': 'no-store', 'x-request-id': requestId };
        if (upstream.headers['content-range']) headers['content-range'] = upstream.headers['content-range'];
        upstream.resume();
        res.writeHead(416, headers); res.end(JSON.stringify({ error: { code: 'range_not_satisfiable', message: 'Requested range is outside the media', retryable: false }, requestId }));
        return;
      }
      if (status !== 200 && status !== 206) {
        upstream.resume();
        throw new BridgeError(status === 404 ? 404 : 503, status === 404 ? 'studio_media_not_found' : 'studio_not_connected', 'Studio media is unavailable');
      }
      const length = Number(upstream.headers['content-length']);
      const contentRange = upstream.headers['content-range'];
      const totalMatch = typeof contentRange === 'string' ? /^bytes (\d+)-(\d+)\/(\d+)$/.exec(contentRange) : null;
      const total = totalMatch ? Number(totalMatch[3]) : length;
      const start = totalMatch ? Number(totalMatch[1]) : 0;
      const end = totalMatch ? Number(totalMatch[2]) : 0;
      const extension = params[1].split('.').pop();
      const contentType = String(upstream.headers['content-type'] ?? '').split(';', 1)[0].trim().toLowerCase();
      if (!Number.isSafeInteger(length) || length < 0 || !Number.isSafeInteger(total) || total > MAX_MEDIA ||
          contentType !== MEDIA_TYPES[extension] ||
          (status === 206 && (!totalMatch || !Number.isSafeInteger(start) || !Number.isSafeInteger(end) ||
            end < start || end >= total || end - start + 1 !== length))) {
        upstream.destroy(); throw new BridgeError(502, 'studio_media_invalid', 'Studio media exceeds the limit or has invalid headers');
      }
      const headers = { 'cache-control': 'private, max-age=0, must-revalidate', 'x-content-type-options': 'nosniff', 'x-request-id': requestId };
      for (const name of ['content-type', 'content-length', 'content-range', 'accept-ranges', 'etag', 'last-modified']) {
        if (upstream.headers[name] !== undefined) headers[name] = upstream.headers[name];
      }
      res.writeHead(status, headers);
      if (req.method === 'HEAD') { upstream.destroy(); res.end(); return; }
      let bytes = 0;
      const bounded = new Transform({ transform(chunk, _encoding, done) {
        bytes += chunk.length;
        done(bytes > length || bytes > MAX_MEDIA ? new Error('media limit exceeded') : null, chunk);
      } });
      await pipeline(upstream, bounded, res, { signal: abort.signal });
    } catch (error) {
      if (res.headersSent) { if (!res.writableEnded) res.destroy(); return; }
      if (error?.name === 'AbortError') return;
      throw error;
    } finally { res.off('close', onClose); }
  }
  return [
    { method: 'GET', path: '/v1/studio/snapshot', auth: true, scope: 'studio:read', handler: snapshot },
    { method: 'GET', path: '/v1/studio/request-id', auth: true, scope: 'studio:request', handler: () => ({ status: 200, data: { id: randomUUID() } }) },
    { method: 'GET', pattern: requestPattern, auth: true, scope: 'studio:read', handler: getRequest },
    { method: 'POST', path: '/v1/studio/requests', auth: true, scope: 'studio:request', idempotent: true, bodyLimit: 1024 * 1024, handler: createRequest, replay: replayRequest },
    { method: 'POST', path: '/v1/studio/action', auth: true, scope: 'studio:request', idempotent: true, bodyLimit: 1024 * 1024, handler: action },
    { method: 'GET', pattern: mediaPattern, auth: true, scope: 'studio:read', handler: media },
    { method: 'HEAD', pattern: mediaPattern, auth: true, scope: 'studio:read', handler: media },
  ];
}

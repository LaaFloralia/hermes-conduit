import { randomUUID } from 'node:crypto';
import { pipeline } from 'node:stream/promises';
import { Transform } from 'node:stream';
import { createLastGood, createReadCache } from '../cache.mjs';
import { BridgeError } from '../errors.mjs';
import { createStudioBackend } from '../studio/backend.mjs';
import { createStudioQueue } from '../studio/queue.mjs';
import { parseBody, validateAction, validateRequest, validateReview } from '../studio/validation.mjs';

const UUID = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}';
const mediaPattern = /^\/v1\/studio\/media\/([a-zA-Z0-9-]{1,100})\/([a-f0-9]{64}\.(?:jpg|png|webp|mp4|mp3|glb|pdf|usdz))$/;
const requestPattern = new RegExp(`^/v1/studio/requests/(${UUID})$`);
const projectPattern = /^\/v1\/studio\/projects\/([a-zA-Z0-9-]{1,100})$/;
const MEDIA_TYPES = { jpg: 'image/jpeg', png: 'image/png', webp: 'image/webp', mp4: 'video/mp4', mp3: 'audio/mpeg', glb: 'model/gltf-binary', pdf: 'application/pdf', usdz: 'model/vnd.usdz+zip' };
const MIB = 1024 * 1024;

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

export function studioRoutes({ store, backend = createStudioBackend(), now = () => Date.now(),
  queueIntervalMs = 30_000, registerCleanup } = {}) {
  const queue = createStudioQueue({ store, backend, now, intervalMs: queueIntervalMs, registerCleanup });
  // Reads must not wait on a slow or absent Studio: the last good answer is
  // served with `fetchedAt`, and one refresh runs behind it.
  const snapshots = createReadCache({ read: () => backend.snapshot(), waitMs: 1500, cooldownMs: 5000, now });
  const catalogs = createLastGood({ now });
  const iso = (ms) => new Date(ms).toISOString();
  async function snapshot({ device }) {
    const { value, fetchedAt, stale, error } = await snapshots.get();
    // The first answer decides the shape; a cached one is marked, never reshaped.
    const pending = queue.all(device.id);
    if (fetchedAt === null && pending.length) {
      return { status: 200, data: { online: false, accepting: false, projects: [], principles: [], requests: pending } };
    }
    if (fetchedAt === null) throw new BridgeError(503, 'studio_not_connected', 'Studio is not connected on the Mac', { retryable: true });
    if (value === null || typeof value !== 'object' || Array.isArray(value)) {
      throw new BridgeError(502, 'studio_response_invalid', 'Studio returned an invalid snapshot');
    }
    const remote = Array.isArray(value.requests) ? value.requests : [];
    const ids = new Set(pending.map((entry) => entry.request.id));
    const requests = [...pending, ...remote.filter((entry) => !ids.has(entry?.request?.id))];
    const offline = stale && error?.code === 'studio_not_connected';
    return { status: 200, data: { ...value, requests, ...(offline ? { online: false, accepting: false } : {}),
      fetchedAt: iso(fetchedAt), ...(stale ? { stale: true } : {}) } };
  }
  async function catalog({ req, res, requestId }) {
    const ifNoneMatch = req.headers['if-none-match'];
    if (ifNoneMatch !== undefined && (typeof ifNoneMatch !== 'string' || ifNoneMatch.length > 1024)) {
      throw new BridgeError(400, 'studio_payload_invalid', 'Invalid If-None-Match header');
    }
    let result;
    try { result = await backend.catalog(ifNoneMatch); }
    catch (error) {
      const cached = catalogs.fallback(error);
      return { status: 200, data: { ...cached.value.data, fetchedAt: iso(cached.fetchedAt), stale: true }, headers: { etag: cached.value.etag } };
    }
    if (typeof result.etag !== 'string' || !result.etag || result.etag.length > 1024 ||
        (result.status === 304 ? !ifNoneMatch : result.status !== 200)) {
      throw new BridgeError(502, 'studio_response_invalid', 'Studio returned an invalid catalog response');
    }
    const headers = { etag: result.etag };
    if (result.status === 304) {
      res.writeHead(304, { 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', 'x-request-id': requestId, ...headers });
      res.end();
      return;
    }
    catalogs.accept({ data: result.data, etag: result.etag });
    const { fetchedAt } = catalogs.peek();
    return { status: 200, data: { ...result.data, fetchedAt: iso(fetchedAt) }, headers };
  }
  async function project({ params }) { return { status: 200, data: await backend.project(params[0]) }; }
  async function review({ rawBody }) {
    const result = await backend.review(validateReview(parseBody(rawBody)));
    if (result.status !== 200 && result.status !== 201) {
      throw new BridgeError(502, 'studio_response_invalid', 'Studio returned an invalid review response');
    }
    return result;
  }
  async function getRequest({ params, device }) {
    return { status: 200, data: queue.get(params[0], device.id) ?? await backend.getRequest(params[0]) };
  }
  async function createRequest({ rawBody, device }) {
    const body = validateRequest(parseBody(rawBody));
    const queued = queue.replay(body, device.id);
    if (queued) return { status: 202, data: queued };
    try { return { status: 202, data: await backend.createRequest(body) }; }
    catch (error) {
      if (error instanceof BridgeError && error.status === 409 && error.code === 'studio_work_busy') {
        try { return { status: 202, data: queue.enqueue(body, device.id) }; }
        catch (queueError) {
          if (queueError instanceof BridgeError) throw queueError;
          throw new BridgeError(503, 'studio_queue_unavailable', 'Bridge could not save the request queue');
        }
      }
      throw error;
    }
  }
  async function replayRequest({ rawBody, device }) {
    // A replay confirms the original mutation but must report current state.
    const body = validateRequest(parseBody(rawBody));
    try { return queue.replay(body, device.id) ?? await backend.getRequest(body.id); }
    catch (error) {
      if (error instanceof BridgeError && error.code === 'studio_not_connected') {
        throw new BridgeError(503, error.code, 'The request was accepted earlier, but its current status is unavailable; check it with GET when Studio reconnects', { retryable: true });
      }
      throw error;
    }
  }
  async function action({ rawBody, device }) {
    const body = validateAction(parseBody(rawBody));
    if (body.action === 'stop') {
      const stopped = queue.stop(body.id, device.id);
      if (stopped) return { status: 200, data: stopped };
    }
    if (body.action === 'answer') validateAnswer(body, await backend.getRequest(body.id));
    return { status: 200, data: await backend.action(body) };
  }
  async function replayAction({ rawBody, device }) {
    const { id } = validateAction(parseBody(rawBody));
    try { return queue.get(id, device.id) ?? await backend.getRequest(id); }
    catch (error) {
      if (error instanceof BridgeError && error.code === 'studio_not_connected') {
        throw new BridgeError(503, error.code, 'The action was accepted earlier, but its current status is unavailable; check it with GET when Studio reconnects', { retryable: true });
      }
      throw error;
    }
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
      const lengthHeader = upstream.headers['content-length'];
      const length = typeof lengthHeader === 'string' && /^\d+$/.test(lengthHeader) ? Number(lengthHeader) : NaN;
      const contentRange = upstream.headers['content-range'];
      const totalMatch = typeof contentRange === 'string' ? /^bytes (\d+)-(\d+)\/(\d+)$/.exec(contentRange) : null;
      const total = status === 206 && totalMatch ? Number(totalMatch[3]) : length;
      const start = totalMatch ? Number(totalMatch[1]) : 0;
      const end = totalMatch ? Number(totalMatch[2]) : 0;
      const extension = params[1].split('.').pop();
      // Converted audio/video previews may be larger than the original limit.
      const maxMedia = (extension === 'mp4' || extension === 'mp3' ? 256 : 128) * MIB;
      const contentType = String(upstream.headers['content-type'] ?? '').split(';', 1)[0].trim().toLowerCase();
      if (!Number.isSafeInteger(length) || length < 0 || !Number.isSafeInteger(total) || total > maxMedia ||
          contentType !== MEDIA_TYPES[extension] ||
          (status === 200 && contentRange !== undefined) ||
          (status === 206 && (!totalMatch || !Number.isSafeInteger(start) || !Number.isSafeInteger(end) ||
            end < start || end >= total || end - start + 1 !== length))) {
        upstream.destroy(); throw new BridgeError(502, 'studio_media_invalid', 'Studio media exceeds the limit or has invalid headers');
      }
      const headers = { 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', 'x-request-id': requestId };
      for (const name of ['content-type', 'content-length', 'content-range', 'accept-ranges', 'etag', 'last-modified']) {
        if (upstream.headers[name] !== undefined) headers[name] = upstream.headers[name];
      }
      res.writeHead(status, headers);
      if (req.method === 'HEAD') { upstream.destroy(); res.end(); return; }
      let bytes = 0;
      const bounded = new Transform({ transform(chunk, _encoding, done) {
        bytes += chunk.length;
        done(bytes > length ? new Error('media length exceeded') : null, chunk);
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
    { method: 'GET', path: '/v1/studio/catalog', auth: true, scope: 'studio:read', handler: catalog },
    { method: 'GET', pattern: projectPattern, auth: true, scope: 'studio:read', handler: project },
    { method: 'POST', path: '/v1/studio/reviews', auth: true, scope: 'studio:request', idempotent: true, bodyLimit: 1024 * 1024,
      handler: review, replayStatus: 200, releaseOnError: (error) => error.status === 400 && error.code === 'studio_payload_invalid' },
    { method: 'GET', path: '/v1/studio/request-id', auth: true, scope: 'studio:request', handler: () => ({ status: 200, data: { id: randomUUID() } }) },
    { method: 'GET', pattern: requestPattern, auth: true, scope: 'studio:read', handler: getRequest },
    { method: 'POST', path: '/v1/studio/requests', auth: true, scope: 'studio:request', idempotent: true, bodyLimit: 1024 * 1024, handler: createRequest, replay: replayRequest,
      releaseOnError: (error) => error.code === 'studio_queue_full' },
    { method: 'POST', path: '/v1/studio/action', auth: true, scope: 'studio:request', idempotent: true, bodyLimit: 1024 * 1024, handler: action, replay: replayAction,
      releaseOnError: (error) => error.code === 'studio_queue_dispatching' },
    { method: 'GET', pattern: mediaPattern, auth: true, scope: 'studio:read', handler: media },
    { method: 'HEAD', pattern: mediaPattern, auth: true, scope: 'studio:read', handler: media },
  ];
}

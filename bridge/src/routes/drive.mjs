// /v1/drive/files — authenticated listing and byte ranges from the read-only
// Drive API metadata and content. Google-native documents export as PDF.

import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { createHash } from 'node:crypto';
import { BridgeError } from '../errors.mjs';

const MAX_PAGE_SIZE = 200;
const DEFAULT_PAGE_SIZE = 50;
const MAX_QUERY_LENGTH = 200;
const VIEWS = new Set(['my', 'shared', 'sharedWithMe', 'recent', 'starred']);
const CURSOR_TTL_MS = 24 * 60 * 60 * 1000;
const ID_PATTERN = /^[A-Za-z0-9_-]{5,2048}$/;
const RELAYED_HEADERS = [
  'content-type',
  'content-length',
  'content-range',
  'accept-ranges',
  'etag',
  'last-modified',
];

const badRequest = (code, message) => new BridgeError(400, code, message);

export function parseRange(header, size) {
  if (typeof header !== 'string' || header.trim() === '') return { kind: 'full' };
  const match = /^bytes=(.*)$/i.exec(header.trim());
  if (!match) return { kind: 'ignore' };
  const specs = match[1].split(',').map((spec) => spec.trim()).filter((spec) => spec !== '');
  // Multiple ranges are legal but useless to a media player; RFC 9110 lets the
  // server ignore Range, so the whole file is served instead of a bad 206.
  if (specs.length !== 1) return { kind: 'ignore' };
  const spec = specs[0];
  let start;
  let end;
  const closed = /^(\d+)-(\d*)$/.exec(spec);
  if (closed) {
    start = Number(closed[1]);
    end = closed[2] === '' ? size - 1 : Number(closed[2]);
    if (end > size - 1) end = size - 1;
    if (start > end || start >= size) return { kind: 'unsatisfiable' };
  } else {
    const suffix = /^-(\d+)$/.exec(spec);
    if (!suffix) return { kind: 'ignore' };
    const length = Number(suffix[1]);
    if (length === 0 || size === 0) return { kind: 'unsatisfiable' };
    start = Math.max(0, size - length);
    end = size - 1;
  }
  return { kind: 'range', start, end };
}

function fingerprint(parts) {
  return createHash('sha256').update(parts.join('\u0000')).digest('hex').slice(0, 16);
}

function encodeCursor({ pageToken, filter, issuedAt }) {
  return Buffer.from(JSON.stringify({ v: 1, p: pageToken, f: filter, t: issuedAt }), 'utf8').toString('base64url');
}

function decodeCursor(raw, filter, now) {
  let parsed;
  try {
    parsed = JSON.parse(Buffer.from(raw, 'base64url').toString('utf8'));
  } catch {
    throw badRequest('cursor_invalid', 'cursor is not a value returned by this endpoint');
  }
  if (!parsed || parsed.v !== 1 || typeof parsed.p !== 'string' || parsed.p === '' || parsed.f !== filter) {
    throw badRequest('cursor_invalid', 'cursor does not match this query');
  }
  if (typeof parsed.t !== 'number' || now - parsed.t > CURSOR_TTL_MS) {
    throw new BridgeError(410, 'cursor_expired', 'cursor has expired; list again from the start');
  }
  return parsed.p;
}

function driveError(error) {
  if (error instanceof BridgeError) return error;
  switch (error?.code) {
    case 'drive_not_configured':
      return new BridgeError(503, 'drive_not_configured', 'Google Drive is not connected');
    case 'drive_export_too_large':
      return new BridgeError(409, 'export_too_large', 'the exported PDF exceeds the size limit');
    default:
      return error;
  }
}

function defaultDriveLog() {
  if (process.env.LAA_BRIDGE_QUIET === '1') return null;
  return (entry) => {
    process.stdout.write(`${JSON.stringify({ ts: new Date().toISOString(), ...entry })}\n`);
  };
}

function sendJsonError(res, requestId, status, code, message, headers = {}) {
  const payload = `${JSON.stringify({ error: { code, message, retryable: false }, requestId })}\n`;
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(payload),
    'x-request-id': requestId,
    'x-content-type-options': 'nosniff',
    'cache-control': 'no-store',
    ...headers,
  });
  res.end(payload);
}

function itemVersion(item) {
  return typeof item.version === 'string' && /^\d{1,30}$/.test(item.version) ? item.version : null;
}

function checkVersion(item, requestedVersion) {
  const version = itemVersion(item);
  if (requestedVersion !== undefined) {
    if (typeof requestedVersion !== 'string' || !/^\d{1,30}$/.test(requestedVersion)) {
      throw badRequest('version_invalid', 'the expected Drive version must be a decimal string');
    }
    if (version === null) throw new BridgeError(409, 'version_unavailable', 'Drive did not provide the expected file version');
    if (requestedVersion !== version) throw new BridgeError(409, 'version_changed', 'the Drive file changed; reload it before continuing');
  }
  return version;
}

export function driveRoutes({ adapter = null, now = () => Date.now(), log = defaultDriveLog() } = {}) {
  function requireAdapter() {
    if (!adapter) {
      throw new BridgeError(503, 'drive_not_configured', 'Google Drive is not connected');
    }
    return adapter;
  }

  async function listFiles({ req, res }) {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    const query = url.searchParams.get('query') ?? '';
    if (query.length > MAX_QUERY_LENGTH) {
      throw badRequest('query_too_long', `query must be at most ${MAX_QUERY_LENGTH} characters`);
    }
    const folderId = url.searchParams.get('folderId');
    if (folderId !== null && !ID_PATTERN.test(folderId)) {
      throw badRequest('folder_id_invalid', 'folderId is not a Drive folder id');
    }
    const view = url.searchParams.get('view');
    if (view !== null && !VIEWS.has(view)) throw badRequest('view_invalid', 'unknown Drive view');
    const rawPageSize = url.searchParams.get('pageSize');
    const pageSize = rawPageSize === null ? DEFAULT_PAGE_SIZE : Number(rawPageSize);
    if (!Number.isInteger(pageSize) || pageSize < 1 || pageSize > MAX_PAGE_SIZE) {
      throw badRequest('page_size_invalid', `pageSize must be 1-${MAX_PAGE_SIZE}`);
    }
    // Preserve old unqualified cursors while binding new cursors to their view.
    const filter = fingerprint([query, folderId ?? '', String(pageSize), ...(view === null ? [] : [view])]);
    const rawCursor = url.searchParams.get('cursor');
    const pageToken = rawCursor === null ? null : decodeCursor(rawCursor, filter, now());

    let page;
    const abort = new AbortController();
    const onClose = () => { if (!res.writableEnded) abort.abort(); };
    const clientClosed = () => { res.statusCode = 499; return undefined; };
    res.on('close', onClose);
    try {
      page = await requireAdapter().list({ query, folderId, pageSize, pageToken, view, signal: abort.signal });
      if (abort.signal.aborted) return clientClosed();
    } catch (error) {
      if (abort.signal.aborted) return clientClosed();
      throw driveError(error);
    } finally {
      res.off('close', onClose);
    }
    const nextCursor = page.nextPageToken
      ? encodeCursor({ pageToken: page.nextPageToken, filter, issuedAt: now() })
      : null;
    return { status: 200, data: { items: page.items, nextCursor,
      incompleteSearch: typeof page.incompleteSearch === 'boolean' ? page.incompleteSearch : null } };
  }

  async function fileMetadata({ params }) {
    const id = params[0];
    let found;
    try {
      found = await requireAdapter().get(id);
    } catch (error) {
      throw driveError(error);
    }
    if (!found) throw new BridgeError(404, 'not_found', 'no such Drive file in the allowed range');
    return { status: 200, data: found.item };
  }

  async function fileThumbnail({ req, res, requestId, params }) {
    const drive = requireAdapter();
    if (typeof drive.thumbnail !== 'function') throw new BridgeError(503, 'thumbnail_unavailable', 'thumbnail access is unavailable');
    const abort = new AbortController();
    const onClose = () => { if (!res.writableEnded) abort.abort(); };
    res.on('close', onClose);
    try {
      let thumbnail;
      try {
        thumbnail = await drive.thumbnail(params[0], { signal: abort.signal });
      } catch (error) {
        if (error?.name === 'AbortError') return undefined;
        throw driveError(error);
      }
      if (abort.signal.aborted) return undefined;
      if (!thumbnail) throw new BridgeError(404, 'thumbnail_unavailable', 'no accessible thumbnail is available');
      if (!Buffer.isBuffer(thumbnail.body) || thumbnail.body.length > 2 * 1024 * 1024 ||
          !['image/jpeg', 'image/png', 'image/gif', 'image/webp'].includes(thumbnail.mimeType)) {
        throw new BridgeError(503, 'thumbnail_unavailable', 'the thumbnail could not be validated');
      }
      res.writeHead(200, {
        'content-type': thumbnail.mimeType,
        'content-length': String(thumbnail.body.length),
        'cache-control': 'private, no-store',
        'x-content-type-options': 'nosniff',
        'x-request-id': requestId,
      });
      res.end(thumbnail.body);
      return undefined;
    } finally {
      res.off('close', onClose);
    }
  }

  async function fileExport({ req, res, requestId, params }) {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    if (url.searchParams.get('mimeType') !== 'application/pdf') {
      throw badRequest('export_format_invalid', 'only PDF export is supported');
    }
    if (req.headers.range !== undefined) throw badRequest('export_range_unsupported', 'PDF export does not support Range');
    const drive = requireAdapter();
    if (typeof drive.exportPdf !== 'function') throw new BridgeError(503, 'export_unavailable', 'PDF export is unavailable');
    const abort = new AbortController();
    const onClose = () => { if (!res.writableEnded) abort.abort(); };
    res.on('close', onClose);
    try {
      const before = await drive.get(params[0], { signal: abort.signal });
      if (abort.signal.aborted) return undefined;
      if (!before) throw new BridgeError(404, 'not_found', 'no such Drive file in the allowed range');
      const item = before.item;
      const exportable = ['application/vnd.google-apps.document', 'application/vnd.google-apps.spreadsheet',
        'application/vnd.google-apps.presentation'].includes(item.mimeType);
      if (item.kind !== 'workspace_document' || !exportable) {
        throw new BridgeError(409, 'export_unsupported', 'this file cannot be exported as a PDF here');
      }
      if (item.downloadable === false) throw new BridgeError(403, 'download_forbidden', 'Drive does not permit exporting this file');
      if (item.downloadable !== true) throw new BridgeError(409, 'download_permission_unknown', 'Drive did not report export permission');
      const version = checkVersion(item, req.headers['x-laa-drive-version']);
      if (version === null) throw new BridgeError(409, 'version_unavailable', 'Drive did not provide a file version');
      const exported = await drive.exportPdf(params[0], { signal: abort.signal });
      if (abort.signal.aborted) return undefined;
      if (!exported) throw new BridgeError(404, 'export_unavailable', 'the PDF export is no longer accessible');
      if (!Buffer.isBuffer(exported.body) || exported.body.length > 10_000_000 ||
          exported.mimeType !== 'application/pdf' || !exported.body.subarray(0, 5).equals(Buffer.from('%PDF-'))) {
        throw new BridgeError(503, 'export_unavailable', 'the exported PDF could not be validated');
      }
      const after = await drive.get(params[0], { signal: abort.signal });
      if (!after) throw new BridgeError(404, 'not_found', 'the Drive file is no longer accessible');
      if (after.item.downloadable !== true) throw new BridgeError(403, 'download_forbidden', 'Drive no longer permits exporting this file');
      checkVersion(after.item, version);
      if (abort.signal.aborted) return undefined;
      res.writeHead(200, {
        'content-type': 'application/pdf',
        'content-length': String(exported.body.length),
        'content-disposition': `inline; filename*=UTF-8''${encodeURIComponent(`${item.name}.pdf`)}`,
        'x-laa-drive-version': version,
        'cache-control': 'private, no-store',
        'x-content-type-options': 'nosniff',
        'x-request-id': requestId,
      });
      res.end(exported.body);
      return undefined;
    } catch (error) {
      if (error?.name === 'AbortError') return undefined;
      throw driveError(error);
    } finally {
      res.off('close', onClose);
    }
  }

  function contentHeaders({ requestId, item, status, upstream, size, start, end }) {
    const headers = {
      'content-type': upstream?.get('content-type') ?? item.mimeType,
      'accept-ranges': 'bytes',
      'cache-control': 'private, max-age=0, must-revalidate',
      'x-content-type-options': 'nosniff',
      'x-request-id': requestId,
      'content-disposition': `inline; filename*=UTF-8''${encodeURIComponent(item.name)}`,
    };
    const etag = upstream?.get('etag');
    if (etag) headers.etag = etag;
    const version = itemVersion(item);
    if (version !== null) headers['x-laa-drive-version'] = version;
    if (upstream) {
      for (const name of RELAYED_HEADERS) {
        const value = upstream.get(name);
        if (value) headers[name] = value;
      }
    } else if (status === 206) {
      headers['content-range'] = `bytes ${start}-${end}/${size}`;
      headers['content-length'] = String(end - start + 1);
    } else {
      headers['content-length'] = String(size);
    }
    return headers;
  }

  async function fileContent({ req, res, requestId, params }) {
    const id = params[0];
    const started = now();
    const drive = requireAdapter();
    let found;
    try {
      found = await drive.get(id);
    } catch (error) {
      throw driveError(error);
    }
    if (!found) throw new BridgeError(404, 'not_found', 'no such Drive file in the allowed range');
    const item = found.item;
    if (item.kind === 'folder') throw badRequest('not_a_file', 'a folder has no content');
    if (item.kind === 'shortcut') {
      throw new BridgeError(409, 'shortcut_target_required', 'open the authorized shortcut target instead');
    }
    if (item.kind === 'workspace_document') {
      const formats = (item.exportFormats ?? []).join(', ');
      throw new BridgeError(
        409,
        'export_required',
        `Workspace documents have no streamable bytes; open their web link. Available export formats: ${formats}`,
      );
    }
    if (item.downloadable === false) {
      throw new BridgeError(403, 'download_forbidden', 'Drive does not permit downloading this file');
    }

    // Opt-in pinning lets a client detect a change between separate ranges.
    // The media request itself can still race with a change after metadata was
    // read; this is not a revision-pinned Drive download.
    checkVersion(item, req.headers['x-laa-drive-version']);

    const size = item.size ?? 0;
    const rangeHeader = req.headers.range;

    // HEAD never touches the media endpoint: metadata plus the same range
    // arithmetic is enough for a player to decide what to request next.
    if (req.method === 'HEAD') {
      const parsed = parseRange(rangeHeader, size);
      if (parsed.kind === 'unsatisfiable') {
        sendJsonError(res, requestId, 416, 'range_not_satisfiable', `requested range is outside 0-${Math.max(0, size - 1)}`, {
          'content-range': `bytes */${size}`,
          'accept-ranges': 'bytes',
        });
        return undefined;
      }
      const status = parsed.kind === 'range' ? 206 : 200;
      res.writeHead(status, contentHeaders({
        requestId,
        item,
        status,
        size,
        start: parsed.kind === 'range' ? parsed.start : 0,
        end: parsed.kind === 'range' ? parsed.end : size - 1,
      }));
      res.end();
      return undefined;
    }

    const abort = new AbortController();
    let aborted = false;
    const onClose = () => {
      if (!res.writableEnded) {
        aborted = true;
        abort.abort();
      }
    };
    res.on('close', onClose);

    let opened;
    try {
      opened = await drive.open(id, { range: rangeHeader ?? null, signal: abort.signal, expectedVersion: itemVersion(item) });
    } catch (error) {
      res.off('close', onClose);
      if (error?.name === 'AbortError') return undefined;
      throw driveError(error);
    }
    if (!opened) {
      res.off('close', onClose);
      throw new BridgeError(404, 'not_found', 'the file is no longer readable');
    }

    if (opened.status === 416) {
      res.off('close', onClose);
      const contentRange = opened.headers?.get('content-range') ?? `bytes */${size}`;
      sendJsonError(res, requestId, 416, 'range_not_satisfiable', 'Drive refused the requested range', {
        'content-range': contentRange,
        'accept-ranges': 'bytes',
      });
      return undefined;
    }

    const status = opened.status === 206 ? 206 : 200;
    res.writeHead(status, contentHeaders({
      requestId,
      item,
      status,
      upstream: opened.headers,
      size,
      start: 0,
      end: size - 1,
    }));

    let sent = 0;
    const counter = new Transform({
      transform(chunk, _encoding, callback) {
        sent += chunk.length;
        callback(null, chunk);
      },
    });
    try {
      await pipeline(opened.stream, counter, res, { signal: abort.signal });
    } catch (error) {
      if (!aborted) {
        if (log) log({ area: 'drive', level: 'error', requestId, error: 'file stream failed' });
        res.destroy();
      }
    } finally {
      res.off('close', onClose);
      if (log) {
        log({
          area: 'drive',
          level: 'info',
          requestId,
          status: aborted ? 'aborted' : status,
          bytes: sent,
          ms: now() - started,
        });
      }
    }
    return undefined;
  }

  const contentPattern = /^\/v1\/drive\/files\/([A-Za-z0-9_-]{5,2048})\/content$/;
  const thumbnailPattern = /^\/v1\/drive\/files\/([A-Za-z0-9_-]{5,2048})\/thumbnail$/;
  const exportPattern = /^\/v1\/drive\/files\/([A-Za-z0-9_-]{5,2048})\/export$/;
  const itemPattern = /^\/v1\/drive\/files\/([A-Za-z0-9_-]{5,2048})$/;

  async function beginUpload({ rawBody, device }) {
    let p; try { p = JSON.parse(rawBody); } catch { throw badRequest('upload_invalid', 'Invalid upload file'); }
    if (!p || typeof p.name !== 'string' || !p.name.trim() || p.name.length > 255 || /[\x00-\x1f/]/.test(p.name)
      || typeof p.mimeType !== 'string' || !/^[a-zA-Z0-9.+_-]+\/[a-zA-Z0-9.+_-]+$/.test(p.mimeType)
      || !Number.isSafeInteger(p.size) || p.size < 1 || p.size > 5 * 1024 ** 4
      || (p.folderId != null && !ID_PATTERN.test(p.folderId))) throw badRequest('upload_invalid', 'Invalid upload file');
    const service = requireAdapter();
    if (!service.beginUpload) throw new BridgeError(503, 'upload_unavailable', 'Upload is unavailable');
    return { status: 201, data: await service.beginUpload({ ...p, deviceId: device.id }) };
  }
  async function uploadChunk({ rawBody, params, device }) {
    const service = requireAdapter();
    if (!service.uploadChunk) throw new BridgeError(503, 'upload_unavailable', 'Upload is unavailable');
    return { status: 200, data: await service.uploadChunk({ id: params[0], offset: Number(params[1]), body: rawBody, deviceId: device.id }) };
  }

  return [
    { method: 'GET', pattern: /^\/v1\/drive\/uploads\/([a-f0-9-]{36})$/, auth: true, scope: 'media:write', handler: async ({ params, device }) => {
      const service = requireAdapter();
      if (!service.uploadStatus) throw new BridgeError(503, 'upload_unavailable', 'Upload is unavailable');
      return { status: 200, data: await service.uploadStatus({ id: params[0], deviceId: device.id }) };
    } },
    { method: 'POST', path: '/v1/drive/uploads', auth: true, scope: 'media:write', idempotent: true, handler: beginUpload },
    { method: 'PUT', pattern: /^\/v1\/drive\/uploads\/([a-f0-9-]{36})\/chunks\/(\d{1,16})$/, auth: true, scope: 'media:write', idempotent: true,
      bodyLimit: 4 * 1024 * 1024, handler: uploadChunk },
    { method: 'GET', path: '/v1/drive/files', auth: true, scope: 'media:read', handler: listFiles },
    { method: 'GET', pattern: itemPattern, auth: true, scope: 'media:read', handler: fileMetadata },
    { method: 'GET', pattern: contentPattern, auth: true, scope: 'media:read', handler: fileContent },
    { method: 'HEAD', pattern: contentPattern, auth: true, scope: 'media:read', handler: fileContent },
    { method: 'GET', pattern: thumbnailPattern, auth: true, scope: 'media:read', handler: fileThumbnail },
    { method: 'GET', pattern: exportPattern, auth: true, scope: 'media:read', handler: fileExport },
  ];
}

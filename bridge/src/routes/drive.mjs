// /v1/drive/files — listing, metadata and byte-range streaming through the
// Google Drive API (see src/drive/google-api.mjs).
//
// The content endpoint forwards the client's Range header to
// files.get?alt=media and relays Drive's status, Content-Range, length and MIME
// to AVPlayer, so playback and seeking happen on Drive's own byte ranges. The
// upstream request is aborted when the client disconnects.
// Workspace documents (Docs/Sheets/Slides) have no streamable bytes; they
// answer 409 export_required with the formats the Drive API would export,
// instead of pretending to be a binary download.

import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { createHash } from 'node:crypto';
import { BridgeError } from '../errors.mjs';

const MAX_PAGE_SIZE = 200;
const DEFAULT_PAGE_SIZE = 50;
const MAX_QUERY_LENGTH = 200;
const CURSOR_TTL_MS = 24 * 60 * 60 * 1000;
const ID_PATTERN = /^[A-Za-z0-9_-]{5,200}$/;
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
      return new BridgeError(503, 'drive_not_configured', 'no Google Drive authorization is configured for the Bridge');
    case 'drive_auth_failed':
      return new BridgeError(503, 'drive_auth_failed', 'the Google Drive authorization was refused; reauthorize the Mac-side credential');
    case 'drive_upstream_failed':
      return new BridgeError(503, 'drive_unavailable', 'the Google Drive API request failed', { retryable: true });
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

export function driveRoutes({ adapter = null, now = () => Date.now(), log = defaultDriveLog() } = {}) {
  function requireAdapter() {
    if (!adapter) {
      throw new BridgeError(503, 'drive_not_configured', 'no Google Drive authorization is configured for the Bridge');
    }
    return adapter;
  }

  async function listFiles({ req }) {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    const query = url.searchParams.get('query') ?? '';
    if (query.length > MAX_QUERY_LENGTH) {
      throw badRequest('query_too_long', `query must be at most ${MAX_QUERY_LENGTH} characters`);
    }
    const folderId = url.searchParams.get('folderId');
    if (folderId !== null && !ID_PATTERN.test(folderId)) {
      throw badRequest('folder_id_invalid', 'folderId is not a Drive folder id');
    }
    const rawPageSize = url.searchParams.get('pageSize');
    const pageSize = rawPageSize === null ? DEFAULT_PAGE_SIZE : Number(rawPageSize);
    if (!Number.isInteger(pageSize) || pageSize < 1 || pageSize > MAX_PAGE_SIZE) {
      throw badRequest('page_size_invalid', `pageSize must be 1-${MAX_PAGE_SIZE}`);
    }
    const filter = fingerprint([query, folderId ?? '', String(pageSize)]);
    const rawCursor = url.searchParams.get('cursor');
    const pageToken = rawCursor === null ? null : decodeCursor(rawCursor, filter, now());

    let page;
    try {
      page = await requireAdapter().list({ query, folderId, pageSize, pageToken });
    } catch (error) {
      throw driveError(error);
    }
    const nextCursor = page.nextPageToken
      ? encodeCursor({ pageToken: page.nextPageToken, filter, issuedAt: now() })
      : null;
    return { status: 200, data: { items: page.items, nextCursor } };
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
    if (item.kind === 'workspace_document') {
      const formats = (item.exportFormats ?? []).join(', ');
      throw new BridgeError(
        409,
        'export_required',
        `Workspace documents have no streamable bytes; export through the Drive API as one of: ${formats}`,
      );
    }

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
      opened = await drive.open(id, { range: rangeHeader ?? null, signal: abort.signal });
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
        if (log) log({ area: 'drive', level: 'error', requestId, id, error: error?.message ?? String(error) });
        res.destroy();
      }
    } finally {
      res.off('close', onClose);
      if (log) {
        log({
          area: 'drive',
          level: 'info',
          requestId,
          id,
          status: aborted ? 'aborted' : status,
          bytes: sent,
          ms: now() - started,
        });
      }
    }
    return undefined;
  }

  const contentPattern = /^\/v1\/drive\/files\/([A-Za-z0-9_-]{5,200})\/content$/;
  const itemPattern = /^\/v1\/drive\/files\/([A-Za-z0-9_-]{5,200})$/;

  return [
    { method: 'GET', path: '/v1/drive/files', auth: true, scope: 'media:read', handler: listFiles },
    { method: 'GET', pattern: itemPattern, auth: true, scope: 'media:read', handler: fileMetadata },
    { method: 'GET', pattern: contentPattern, auth: true, scope: 'media:read', handler: fileContent },
    { method: 'HEAD', pattern: contentPattern, auth: true, scope: 'media:read', handler: fileContent },
  ];
}

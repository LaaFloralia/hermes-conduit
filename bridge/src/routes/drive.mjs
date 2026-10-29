// /v1/drive/files — listing, metadata and byte-range streaming for the owner's
// existing Google Drive authorization (see src/drive/drivefs.mjs).
//
// The content endpoint relays a single HTTP Range to a local file read, so
// AVPlayer can start playback and seek inside a large video without the Bridge
// buffering the file or holding a Google token:
//   200 full body, 206 partial with Content-Range, 416 unsatisfiable,
//   Content-Length/MIME/Accept-Ranges, and the read is cancelled when the
//   client disconnects.
// Workspace documents (Docs/Sheets/Slides) are placeholders on disk, so they
// answer 409 export_required with the formats the Drive API would export,
// instead of pretending to be streamable bytes.

import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { BridgeError } from '../errors.mjs';
import { fingerprint } from '../drive/drivefs.mjs';

const MAX_PAGE_SIZE = 200;
const DEFAULT_PAGE_SIZE = 50;
const MAX_QUERY_LENGTH = 200;
const CURSOR_TTL_MS = 24 * 60 * 60 * 1000;
const ID_PATTERN = /^[A-Za-z0-9_-]{5,200}$/;

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

function encodeCursor({ offset, filter, issuedAt }) {
  return Buffer.from(JSON.stringify({ v: 1, o: offset, f: filter, t: issuedAt }), 'utf8').toString('base64url');
}

function decodeCursor(raw, filter, now) {
  let parsed;
  try {
    parsed = JSON.parse(Buffer.from(raw, 'base64url').toString('utf8'));
  } catch {
    throw badRequest('cursor_invalid', 'cursor is not a value returned by this endpoint');
  }
  if (!parsed || parsed.v !== 1 || typeof parsed.o !== 'number' || parsed.f !== filter) {
    throw badRequest('cursor_invalid', 'cursor does not match this query');
  }
  if (typeof parsed.t !== 'number' || now - parsed.t > CURSOR_TTL_MS) {
    throw new BridgeError(410, 'cursor_expired', 'cursor has expired; list again from the start');
  }
  return parsed.o;
}

function driveError(error) {
  if (error instanceof BridgeError) return error;
  if (error && error.code === 'drive_unavailable') {
    return new BridgeError(503, 'drive_unavailable', 'the Mac-side Google Drive client is not available', { retryable: true });
  }
  return error;
}

function defaultDriveLog() {
  if (process.env.LAA_BRIDGE_QUIET === '1') return null;
  return (entry) => {
    process.stdout.write(`${JSON.stringify({ ts: new Date().toISOString(), ...entry })}\n`);
  };
}

export function driveRoutes({ adapter, now = () => Date.now(), log = defaultDriveLog() } = {}) {
  if (!adapter) throw new Error('driveRoutes needs a Drive adapter');

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
    const offset = rawCursor === null ? 0 : decodeCursor(rawCursor, filter, now());

    let page;
    try {
      page = await adapter.list({ query, folderId, pageSize, offset });
    } catch (error) {
      throw driveError(error);
    }
    const nextOffset = offset + page.items.length;
    const nextCursor = nextOffset < page.total ? encodeCursor({ offset: nextOffset, filter, issuedAt: now() }) : null;
    return { status: 200, data: { items: page.items, nextCursor } };
  }

  async function fileMetadata({ params }) {
    const id = params[0];
    let found;
    try {
      found = await adapter.get(id);
    } catch (error) {
      throw driveError(error);
    }
    if (!found) throw new BridgeError(404, 'not_found', 'no such Drive file in the allowed range');
    return { status: 200, data: found.item };
  }

  async function fileContent({ req, res, requestId, params }) {
    const id = params[0];
    const started = now();
    let found;
    try {
      found = await adapter.get(id);
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
    const parsed = parseRange(req.headers.range, size);
    if (parsed.kind === 'unsatisfiable') {
      const payload = `${JSON.stringify({
        error: { code: 'range_not_satisfiable', message: `requested range is outside 0-${Math.max(0, size - 1)}`, retryable: false },
        requestId,
      })}\n`;
      res.writeHead(416, {
        'content-type': 'application/json; charset=utf-8',
        'content-length': Buffer.byteLength(payload),
        'content-range': `bytes */${size}`,
        'accept-ranges': 'bytes',
        'x-request-id': requestId,
        'x-content-type-options': 'nosniff',
        'cache-control': 'no-store',
      });
      res.end(payload);
      return undefined;
    }

    const start = parsed.kind === 'range' ? parsed.start : 0;
    const end = parsed.kind === 'range' ? parsed.end : (size > 0 ? size - 1 : undefined);
    const status = parsed.kind === 'range' ? 206 : 200;
    const headers = {
      'content-type': item.mimeType,
      'content-length': String(parsed.kind === 'range' ? end - start + 1 : size),
      'accept-ranges': 'bytes',
      etag: found.etag,
      'cache-control': 'private, max-age=0, must-revalidate',
      'x-content-type-options': 'nosniff',
      'x-request-id': requestId,
      'content-disposition': `inline; filename*=UTF-8''${encodeURIComponent(item.name)}`,
    };
    if (parsed.kind === 'range') headers['content-range'] = `bytes ${start}-${end}/${size}`;

    if (req.method === 'HEAD') {
      res.writeHead(status, headers);
      res.end();
      return undefined;
    }

    let opened;
    try {
      opened = await adapter.open(id, { start, end });
    } catch (error) {
      throw driveError(error);
    }
    if (!opened || opened.kind !== 'binary') {
      throw new BridgeError(404, 'not_found', 'the file disappeared before it could be read');
    }

    // Open before the status line so a file that vanished between get() and
    // open() still gets a clean JSON error instead of headers without a body.
    const abort = new AbortController();
    let aborted = false;
    const onClose = () => {
      if (!res.writableEnded) {
        aborted = true;
        abort.abort();
      }
    };
    res.on('close', onClose);
    res.writeHead(status, headers);
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

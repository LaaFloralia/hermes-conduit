// The owner's own picture, shown beside the owner's messages on every device.
//
// One image in the state directory, replaced atomically (0600). The body is
// JSON — `{contentType, data}` with base64 bytes — so the app reuses its one
// Bridge client, the same way session images travel. Only JPEG and PNG are
// accepted, checked by their leading bytes rather than trusted from the label.
import { createHash } from 'node:crypto';
import { chmodSync, closeSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, rmSync, statSync, writeSync } from 'node:fs';
import { join } from 'node:path';
import { BridgeError, badRequest } from '../errors.mjs';
import { parseObjectBody } from './state-file.mjs';

export const OWNER_AVATAR_MAX_BYTES = 512 * 1024;
const PATH = '/v1/owner/avatar';
const TYPES = {
  'image/jpeg': (bytes) => bytes.length > 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff,
  'image/png': (bytes) => bytes.length > 8 && bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])),
};

const etagOf = (bytes) => `"${createHash('sha256').update(bytes).digest('hex').slice(0, 32)}"`;
const typeOf = (bytes) => Object.keys(TYPES).find((type) => TYPES[type](bytes)) ?? null;

export function ownerProfileRoutes({ dir }) {
  const file = join(dir, 'owner-avatar.img');

  function read() {
    let bytes;
    try {
      bytes = readFileSync(file);
    } catch (error) {
      if (error.code === 'ENOENT') return null;
      throw new BridgeError(503, 'owner_avatar_unavailable', 'owner avatar cannot be read');
    }
    const contentType = typeOf(bytes);
    // A file this route did not write is never served as the owner's face.
    if (!contentType || bytes.length > OWNER_AVATAR_MAX_BYTES) {
      throw new BridgeError(503, 'owner_avatar_unavailable', 'owner avatar is not a valid image');
    }
    return { bytes, contentType, etag: etagOf(bytes), updatedAt: statSync(file).mtime.toISOString() };
  }

  const meta = (current) => ({ contentType: current.contentType, etag: current.etag, updatedAt: current.updatedAt, size: current.bytes.length });

  function get({ req, res, requestId }) {
    const current = read();
    if (!current) throw new BridgeError(404, 'owner_avatar_not_set', 'no owner avatar is set');
    if (req.headers['if-none-match'] === current.etag) {
      res.writeHead(304, { etag: current.etag, 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', 'x-request-id': requestId });
      res.end();
      return undefined;
    }
    return { status: 200, data: { ...meta(current), data: current.bytes.toString('base64') }, headers: { etag: current.etag } };
  }

  function put({ rawBody }) {
    const body = parseObjectBody(rawBody);
    if (Object.keys(body).some((key) => key !== 'contentType' && key !== 'data')) {
      throw badRequest('payload_invalid', 'only contentType and data are accepted');
    }
    if (!Object.hasOwn(TYPES, body.contentType)) throw new BridgeError(415, 'unsupported_media_type', 'contentType must be image/jpeg or image/png');
    if (typeof body.data !== 'string' || body.data.length === 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(body.data)) {
      throw badRequest('payload_invalid', 'data must be base64');
    }
    const bytes = Buffer.from(body.data, 'base64');
    if (bytes.length > OWNER_AVATAR_MAX_BYTES) throw new BridgeError(413, 'payload_too_large', `image exceeds ${OWNER_AVATAR_MAX_BYTES} bytes`);
    if (!TYPES[body.contentType](bytes)) throw badRequest('image_invalid', `data is not ${body.contentType}`);

    mkdirSync(dir, { recursive: true, mode: 0o700 });
    const tmp = `${file}.${process.pid}.${Math.random().toString(16).slice(2)}.tmp`;
    const fd = openSync(tmp, 'wx', 0o600);
    try {
      writeSync(fd, bytes);
      fsyncSync(fd);
    } catch (error) {
      closeSync(fd);
      rmSync(tmp, { force: true });
      throw error;
    }
    closeSync(fd);
    renameSync(tmp, file);
    chmodSync(file, 0o600);
    const current = read();
    return { status: 200, data: meta(current), headers: { etag: current.etag } };
  }

  function remove() {
    let removed = true;
    try {
      rmSync(file);
    } catch (error) {
      if (error.code !== 'ENOENT') throw new BridgeError(503, 'owner_avatar_unavailable', 'owner avatar cannot be removed');
      removed = false;
    }
    return { status: 200, data: { removed } };
  }

  return [
    { method: 'GET', path: PATH, auth: true, scope: 'sessions:read', handler: get },
    // base64 grows the image by a third; leave room for the JSON around it.
    { method: 'PUT', path: PATH, auth: true, scope: 'sessions:write', bodyLimit: Math.ceil(OWNER_AVATAR_MAX_BYTES * 4 / 3) + 1024, handler: put },
    { method: 'DELETE', path: PATH, auth: true, scope: 'sessions:write', handler: remove },
  ];
}

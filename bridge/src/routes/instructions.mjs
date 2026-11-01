// Only the two owner-selected instruction sources are exposed. No path comes
// from the client. A conditional write never stores document bodies in the
// Bridge's idempotency ledger or request log.
import { createHash, randomUUID } from 'node:crypto';
import { constants, closeSync, fstatSync, fsyncSync, lstatSync, mkdirSync, openSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { BridgeError, badRequest } from '../errors.mjs';
import { parseObjectBody } from './state-file.mjs';

const MAX_BYTES = 1024 * 1024;
const hash = (data) => `"${createHash('sha256').update(data).digest('hex')}"`;

export function instructionRoutes({ backupDir, files = {
  agents: '/Users/laa/hq/AGENTS.md',
  claude: '/Users/laa/.claude/CLAUDE.md',
} }) {
  function read(id) {
    const file = files[id];
    if (!file || !['agents', 'claude'].includes(id)) throw new BridgeError(404, 'not_found', 'no such instruction document');
    let fd;
    try {
      fd = openSync(file, constants.O_RDONLY | constants.O_NOFOLLOW);
      const stat = fstatSync(fd);
      if (!stat.isFile() || stat.size > MAX_BYTES) throw new BridgeError(400, 'instruction_invalid', 'instruction document is not a regular file or exceeds the limit');
      const data = readFileSync(fd);
      const text = new TextDecoder('utf-8', { fatal: true }).decode(data);
      return { file, data, text, stat, etag: hash(data) };
    } catch (error) {
      if (error instanceof BridgeError) throw error;
      throw new BridgeError(503, 'instruction_unavailable', 'instruction document cannot be read');
    } finally { if (fd !== undefined) closeSync(fd); }
  }
  function get({ params }) {
    const current = read(params[0]);
    return { status: 200, data: { id: params[0], text: current.text, etag: current.etag }, headers: { etag: current.etag } };
  }
  function put({ params, req, rawBody }) {
    const expected = req.headers['if-match'];
    if (!expected) throw new BridgeError(428, 'if_match_required', 'If-Match is required');
    const body = parseObjectBody(rawBody);
    if (typeof body.text !== 'string' || Object.keys(body).some((key) => key !== 'text') || Buffer.byteLength(body.text) > MAX_BYTES) {
      throw badRequest('payload_invalid', 'text must be UTF-8 and no larger than 1 MiB');
    }
    const original = read(params[0]);
    if (expected !== original.etag) throw new BridgeError(412, 'instruction_conflict', 'document changed; reload before saving');
    mkdirSync(backupDir, { recursive: true, mode: 0o700 });
    const backup = join(backupDir, `${params[0]}-${randomUUID()}.md`);
    writeFileSync(backup, original.data, { flag: 'wx', mode: 0o600 });
    const backupFD = openSync(backup, 'r');
    try { fsyncSync(backupFD); } finally { closeSync(backupFD); }
    const temporary = join(dirname(original.file), `.laa-instructions-${randomUUID()}.tmp`);
    let tempCreated = false;
    try {
      const fd = openSync(temporary, 'wx', original.stat.mode & 0o777);
      tempCreated = true;
      try { writeFileSync(fd, body.text, 'utf8'); fsyncSync(fd); } finally { closeSync(fd); }
      // Detect replacement or modification since the initial read as well as
      // edits from another Bridge request. External writers must coordinate to
      // eliminate the remaining check-to-rename race.
      const latest = read(params[0]);
      const link = lstatSync(original.file);
      if (latest.etag !== expected || latest.stat.ino !== original.stat.ino || link.ino !== original.stat.ino || !link.isFile()) {
        throw new BridgeError(412, 'instruction_conflict', 'document changed; reload before saving');
      }
      renameSync(temporary, original.file);
      tempCreated = false;
    } finally { if (tempCreated) try { unlinkSync(temporary); } catch {} }
    const result = read(params[0]);
    return { status: 200, data: { id: params[0], text: result.text, etag: result.etag }, headers: { etag: result.etag } };
  }
  const pattern = /^\/v1\/instructions\/(agents|claude)$/;
  return [
    { method: 'GET', pattern, auth: true, scope: 'instructions:read', handler: get },
    { method: 'PUT', pattern, auth: true, scope: 'instructions:write', bodyLimit: MAX_BYTES * 6 + 1024, handler: put },
  ];
}

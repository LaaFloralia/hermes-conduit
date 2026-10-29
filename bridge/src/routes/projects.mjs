// /v1/projects — a project is a genre (topic) with shared instructions.
//
// Separation from workspaces is deliberate: a project carries no path, branch
// or repo. A session picks one project and one workspace independently, which
// is what lets the same genre run in `/Users/laa/dev/x` or a worktree without
// the two identities drifting apart.
//
// Instruction versioning: the instruction text is never stored here (it lives
// in Brain/Drive and would duplicate content the Bridge must not hold). What is
// stored is a version hash over the reference and a hash of the text, plus a
// monotonic instruction version and a bounded history of past hashes. A client
// can therefore say which instruction version a session was started with, and
// the Bridge can prove the instructions did not change under it.
//
// Naming: `nameSource` records who named the project. `owner` means a human
// (or the owner's explicit instruction) chose the name and an automatic name
// can never replace it; `auto` marks a generated name that may be recomputed.

import { createHash, randomBytes } from 'node:crypto';
import { badRequest, BridgeError, conflict, notFound } from '../errors.mjs';
import { createJsonFile, parseObjectBody } from './state-file.mjs';

const PROJECT_SCHEMA = 1;
const PROJECT_ID_PATTERN = /^prj_[0-9a-f]{12}$/;
const NAME_MAX = 80;
const INSTRUCTION_REF_MAX = 300;
const INSTRUCTIONS_MAX_BYTES = 32 * 1024;
const HISTORY_LIMIT = 20;
const NAME_SOURCES = new Set(['owner', 'auto']);

export function createProjectStore({ file, now = () => Date.now() }) {
  const state = createJsonFile({ file, schema: PROJECT_SCHEMA, initial: () => ({ projects: {} }) });

  function all() {
    return state.read().projects ?? {};
  }

  return {
    file,
    get(id) {
      return all()[id] ?? null;
    },
    list() {
      return Object.values(all());
    },
    mutate(fn) {
      return state.mutate((doc) => {
        doc.projects ??= {};
        return fn(doc.projects);
      });
    },
    now,
  };
}

export function createProjectRoutes({ projects, now = () => Date.now() }) {
  function list({ req }) {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    const limit = parseLimit(url.searchParams.get('limit'));
    const offset = parseCursor(url.searchParams.get('cursor'));
    const items = projects
      .list()
      .sort((a, b) => (a.updatedAt === b.updatedAt ? a.id.localeCompare(b.id) : b.updatedAt.localeCompare(a.updatedAt)))
      .map(view);
    const page = items.slice(offset, offset + limit);
    return {
      status: 200,
      data: {
        items: page,
        nextCursor: offset + limit < items.length ? encodeCursor(offset + limit) : null,
      },
    };
  }

  function get({ params }) {
    const project = projects.get(params[0]);
    if (!project) throw notFound('project not found');
    return { status: 200, data: view(project), headers: { etag: etagFor(project.version) } };
  }

  function create({ device, rawBody }) {
    const body = parseObjectBody(rawBody);
    const name = parseName(body.name, { required: true });
    const nameSource = parseNameSource(body.nameSource);
    const instructionRef = parseInstructionRef(body.instructionRef);
    const instructionTextHash = parseInstructions(body.instructions);
    const t = now();
    const instructionHash = digestInstructions(instructionRef, instructionTextHash);

    const project = projects.mutate((all) => {
      let id;
      do {
        id = `prj_${randomBytes(6).toString('hex')}`;
      } while (all[id]);
      const record = {
        id,
        name,
        nameSource,
        instructionRef,
        instructionTextHash,
        instructionHash,
        instructionVersion: 1,
        instructionHistory: [{ version: 1, hash: instructionHash, at: new Date(t).toISOString() }],
        version: 1,
        createdAt: new Date(t).toISOString(),
        updatedAt: new Date(t).toISOString(),
        createdBy: device?.id ?? null,
      };
      all[id] = record;
      return record;
    });

    return { status: 201, data: view(project), headers: { etag: etagFor(project.version) } };
  }

  function patch({ device, rawBody, params, req }) {
    const current = projects.get(params[0]);
    if (!current) throw notFound('project not found');
    const expected = parseIfMatch(req.headers['if-match'], current.version);
    const body = parseObjectBody(rawBody);
    const t = now();

    const requested = body.name !== undefined || body.nameSource !== undefined
      || body.instructionRef !== undefined || body.instructions !== undefined;
    if (!requested) throw badRequest('payload_invalid', 'no supported change was requested');

    const name = body.name === undefined ? undefined : parseName(body.name, { required: true });
    if (body.nameSource !== undefined && name === undefined) {
      throw badRequest('payload_invalid', 'nameSource is only meaningful together with name');
    }
    const nameSource = body.nameSource === undefined ? undefined : parseNameSource(body.nameSource);
    if (name !== undefined && current.nameSource === 'owner' && nameSource === 'auto') {
      // Owner-given names always win: an automatic rename is refused, not
      // silently ignored, so the caller cannot believe it succeeded.
      throw conflict('name_source_locked', 'the project name was chosen by the owner and cannot be replaced automatically');
    }

    const instructionRef = body.instructionRef === undefined
      ? current.instructionRef
      : parseInstructionRef(body.instructionRef);
    const instructionTextHash = body.instructions === undefined
      ? current.instructionTextHash
      : parseInstructions(body.instructions);
    const instructionHash = digestInstructions(instructionRef, instructionTextHash);
    const instructionsChanged = instructionHash !== current.instructionHash;
    const identityChanged = name !== undefined && name !== current.name;
    const refChanged = instructionRef !== current.instructionRef;
    const textChanged = instructionTextHash !== current.instructionTextHash;

    // A PATCH that names fields identical to the stored state is accepted as a
    // no-op: the caller read the current version, and nothing is bumped.
    const changed = identityChanged || refChanged || textChanged;

    const updated = projects.mutate((all) => {
      const record = all[current.id];
      if (!record || record.version !== expected) {
        throw new BridgeError(412, 'version_mismatch', 'project changed since the supplied etag');
      }
      if (!changed) return record;
      if (name !== undefined) {
        record.name = name;
        record.nameSource = nameSource ?? 'owner';
      }
      record.instructionRef = instructionRef;
      record.instructionTextHash = instructionTextHash;
      if (instructionsChanged) {
        record.instructionHash = instructionHash;
        record.instructionVersion += 1;
        record.instructionHistory = [
          ...(record.instructionHistory ?? []),
          { version: record.instructionVersion, hash: instructionHash, at: new Date(t).toISOString() },
        ].slice(-HISTORY_LIMIT);
      }
      record.version += 1;
      record.updatedAt = new Date(t).toISOString();
      record.updatedBy = device?.id ?? null;
      return record;
    });

    return { status: 200, data: view(updated), headers: { etag: etagFor(updated.version) } };
  }

  return [
    { method: 'GET', path: '/v1/projects', auth: true, scope: 'sessions:read', handler: list },
    { method: 'POST', path: '/v1/projects', auth: true, scope: 'sessions:write', idempotent: true, handler: create },
    { method: 'GET', pattern: /^\/v1\/projects\/(prj_[0-9a-f]{12})$/, auth: true, scope: 'sessions:read', handler: get },
    { method: 'PATCH', pattern: /^\/v1\/projects\/(prj_[0-9a-f]{12})$/, auth: true, scope: 'sessions:write', idempotent: true, handler: patch },
  ];
}

// --- projection ------------------------------------------------------------

function view(project) {
  return {
    id: project.id,
    name: project.name,
    nameSource: project.nameSource,
    instructionRef: project.instructionRef,
    instructionHash: project.instructionHash,
    instructionVersion: project.instructionVersion,
    version: project.version,
    etag: etagFor(project.version),
    createdAt: project.createdAt,
    updatedAt: project.updatedAt,
  };
}

function etagFor(version) {
  return `"${version}"`;
}

// --- validation ------------------------------------------------------------

function parseName(raw, { required }) {
  if (raw === undefined || raw === null) {
    if (required) throw badRequest('payload_invalid', 'name is required');
    return undefined;
  }
  if (typeof raw !== 'string') throw badRequest('payload_invalid', 'name must be a string');
  const name = raw.trim().replace(/\s+/g, ' ');
  if (name.length === 0 || name.length > NAME_MAX) {
    throw badRequest('payload_invalid', `name must be 1-${NAME_MAX} characters`);
  }
  if (/[\u0000-\u001f\u007f]/.test(name)) {
    throw badRequest('payload_invalid', 'name must not contain control characters');
  }
  return name;
}

function parseNameSource(raw) {
  if (raw === undefined || raw === null) return 'owner';
  if (!NAME_SOURCES.has(raw)) throw badRequest('payload_invalid', 'nameSource must be "owner" or "auto"');
  return raw;
}

function parseInstructionRef(raw) {
  if (raw === undefined || raw === null) return null;
  if (typeof raw !== 'string') throw badRequest('payload_invalid', 'instructionRef must be a string');
  const ref = raw.trim();
  if (ref.length === 0) return null;
  if (ref.length > INSTRUCTION_REF_MAX) {
    throw badRequest('payload_invalid', `instructionRef must be at most ${INSTRUCTION_REF_MAX} characters`);
  }
  if (/[\u0000-\u001f\u007f]/.test(ref)) {
    throw badRequest('payload_invalid', 'instructionRef must not contain control characters');
  }
  return ref;
}

// Returns the SHA-256 of the instruction text, or null when the caller only
// supplied a reference. The text itself is not stored.
function parseInstructions(raw) {
  if (raw === undefined || raw === null) return null;
  if (typeof raw !== 'string') throw badRequest('payload_invalid', 'instructions must be a string');
  if (Buffer.byteLength(raw, 'utf8') > INSTRUCTIONS_MAX_BYTES) {
    throw badRequest('payload_invalid', `instructions must be at most ${INSTRUCTIONS_MAX_BYTES} bytes`);
  }
  return createHash('sha256').update(raw, 'utf8').digest('hex');
}

export function digestInstructions(ref, textHash) {
  const h = createHash('sha256');
  h.update('laa.project.instructions.v1\n');
  h.update(`ref:${ref ?? ''}\n`);
  h.update(`text:${textHash ?? '-'}\n`);
  return `sha256:${h.digest('hex')}`;
}

// If-Match is mandatory for updates so two devices cannot silently overwrite
// each other. `*` is accepted (resource exists), weak tags are compared by
// version value only.
function parseIfMatch(header, currentVersion) {
  if (typeof header !== 'string' || header.trim() === '') {
    throw new BridgeError(428, 'precondition_required', 'If-Match header with the project version is required');
  }
  const tags = header.split(',').map((tag) => tag.trim()).filter(Boolean);
  if (tags.includes('*')) return currentVersion;
  for (const tag of tags) {
    const match = /^(?:W\/)?"?(\d+)"?$/.exec(tag);
    if (match && Number(match[1]) === currentVersion) return currentVersion;
  }
  throw new BridgeError(412, 'version_mismatch', `project is at version ${currentVersion}; read it again before updating`);
}

// --- pagination ------------------------------------------------------------

function parseLimit(raw) {
  if (raw === undefined || raw === null || raw === '') return 50;
  const limit = Number(raw);
  if (!Number.isInteger(limit) || limit < 1 || limit > 100) {
    throw badRequest('limit_invalid', 'limit must be an integer between 1 and 100');
  }
  return limit;
}

function encodeCursor(offset) {
  return Buffer.from(JSON.stringify({ offset }), 'utf8').toString('base64url');
}

function parseCursor(raw) {
  if (raw === undefined || raw === null || raw === '') return 0;
  try {
    const parsed = JSON.parse(Buffer.from(raw, 'base64url').toString('utf8'));
    if (Number.isInteger(parsed?.offset) && parsed.offset >= 0) return parsed.offset;
  } catch {
    // fall through
  }
  throw badRequest('cursor_invalid', 'cursor is not recognised');
}

export { PROJECT_ID_PATTERN };

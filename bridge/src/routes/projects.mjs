// /v1/projects — a project is a genre (topic) with shared instructions.
//
// Separation from workspaces is deliberate: a project carries no path, branch
// or repo. A session picks one project and one workspace independently, which
// is what lets the same genre run in `/Users/laa/dev/x` or a worktree without
// the two identities drifting apart.
//
// Instructions (BRIDGE.md §9): the owner edits one shared instruction body per
// project from the phone, and every session started in that project receives
// it. The body is therefore stored here, in the Bridge's 0600 state file, with
// a monotonic `instructionVersion`, a `sha256:` hash of the body and the last
// ten revisions (body, hash, version, time) so two devices can compare and
// restore instead of silently overwriting each other. Events and logs carry
// only the version and hash, never the body.
//
// `instructionRef` is the alternative source: a vault-relative file under the
// Brain root that is read at *use* time, so editing the file changes what the
// next session gets without another PATCH. Body and ref are mutually exclusive;
// setting one clears the other.
//
// Naming: `nameSource` records who named the project. `owner` means a human
// (or the owner's explicit instruction) chose the name and an automatic name
// can never replace it; `auto` marks a generated name that may be recomputed.

import { createHash, randomBytes } from 'node:crypto';
import { lstatSync, readFileSync, realpathSync, renameSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { resolveBrainRoot } from '../config.mjs';
import { badRequest, BridgeError, conflict, notFound } from '../errors.mjs';
import { parseCursor, parseLimit, encodeCursor } from './pagination.mjs';
import { createJsonFile, parseObjectBody } from './state-file.mjs';

const PROJECT_SCHEMA = 2;
const NAME_MAX = 80;
const INSTRUCTION_REF_MAX = 300;
const INSTRUCTIONS_MAX_BYTES = 32 * 1024;
const INSTRUCTION_HISTORY_LIMIT = 10;
const INSTRUCTION_TAG = 'project_instructions';
const NAME_SOURCES = new Set(['owner', 'auto']);

// --- instruction references -------------------------------------------------

// A ref is a vault-relative path under the Brain root: no absolute paths, no
// `..`, no backslashes and no control characters. Resolution then requires the
// realpath to stay exactly where the relative path points, so a symlink on any
// component is refused instead of followed outside the vault.
export function createInstructionRefResolver({ root = resolveBrainRoot(), maxBytes = INSTRUCTIONS_MAX_BYTES } = {}) {
  return function resolveInstructionRef(raw) {
    const rel = parseInstructionRef(raw);
    if (rel === null) throw badRequest('payload_invalid', 'instructionRef must not be empty');
    const base = vaultRoot(root);
    const absolute = join(base, ...rel.split('/'));
    let target;
    try {
      target = realpathSync(absolute);
    } catch {
      throw new BridgeError(400, 'instruction_ref_unavailable', `instructionRef ${rel} does not exist`);
    }
    if (target !== absolute) {
      throw new BridgeError(400, 'instruction_ref_unavailable', `instructionRef ${rel} is not addressable`);
    }
    const info = lstatSync(target);
    if (!info.isFile()) {
      throw new BridgeError(400, 'instruction_ref_unavailable', `instructionRef ${rel} is not a regular file`);
    }
    if (info.size > maxBytes) {
      throw new BridgeError(400, 'instruction_ref_too_large', `instructionRef ${rel} is larger than ${maxBytes} bytes`);
    }
    try {
      return new TextDecoder('utf-8', { fatal: true }).decode(readFileSync(target));
    } catch {
      throw new BridgeError(400, 'instruction_ref_unavailable', `instructionRef ${rel} is not UTF-8 text`);
    }
  };
}

function vaultRoot(root) {
  try {
    const real = realpathSync(root);
    if (!statSync(real).isDirectory()) throw new Error('not a directory');
    return real;
  } catch {
    throw new BridgeError(503, 'instruction_vault_unavailable', 'the instruction vault is not available', { retryable: true });
  }
}

// --- store ------------------------------------------------------------------

export function createProjectStore({
  file,
  now = () => Date.now(),
  resolveInstructionRef = createInstructionRefResolver(),
}) {
  migrateLegacyProjects(file);
  const state = createJsonFile({ file, schema: PROJECT_SCHEMA, initial: () => ({ projects: {} }) });

  function all() {
    return state.read().projects ?? {};
  }

  return {
    file,
    resolveInstructionRef,
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
    // The instructions a session must apply right now: the stored body, or the
    // referenced file read at this moment. Throws when a ref cannot be read so
    // the caller can refuse the session instead of running without them.
    instructionsFor(project) {
      if (!project) return null;
      if (project.instructionRef) {
        const body = resolveInstructionRef(project.instructionRef);
        return { body, hash: hashBody(body), version: project.instructionVersion ?? 0, source: 'ref' };
      }
      if (typeof project.instructions === 'string' && project.instructions.trim() !== '') {
        return {
          body: project.instructions,
          hash: hashBody(project.instructions),
          version: project.instructionVersion ?? 0,
          source: 'body',
        };
      }
      return null;
    },
    now,
  };
}

// Projects written before the body was stored (schema 1) kept only a hash over
// a reference plus a hash of text the Bridge never kept, so the body cannot be
// re-derived. They are converted once: identity, name and reference survive,
// the instruction body starts empty and the app re-saves it from the phone.
function migrateLegacyProjects(file) {
  let raw;
  try {
    raw = readFileSync(file, 'utf8');
  } catch {
    return; // no state yet
  }
  let doc;
  try {
    doc = JSON.parse(raw);
  } catch {
    return; // createJsonFile reports corruption with the operator-facing error
  }
  if (!doc || doc.schema !== 1) return;
  const projects = {};
  for (const [id, record] of Object.entries(doc.projects ?? {})) {
    projects[id] = {
      ...record,
      instructionRef: record.instructionRef ?? null,
      instructions: null,
      instructionVersion: record.instructionVersion ?? 0,
      instructionHash: null,
      instructionHistory: [],
    };
    delete projects[id].instructionTextHash;
  }
  const tmp = `${file}.${process.pid}.migrate.tmp`;
  writeFileSync(tmp, `${JSON.stringify({ schema: PROJECT_SCHEMA, projects }, null, 2)}\n`, { mode: 0o600 });
  renameSync(tmp, file);
}

// --- routes -----------------------------------------------------------------

export function createProjectRoutes({ projects, now = () => Date.now() }) {
  function requireProject(id) {
    const project = projects.get(id);
    if (!project) throw notFound('project not found');
    return project;
  }

  function detail(project) {
    const resolved = tryInstructions(project, projects);
    return {
      ...view(project),
      instructions: resolved.value?.body ?? null,
      instructionHash: resolved.value?.hash ?? project.instructionHash ?? null,
      ...(resolved.error === null ? {} : { instructionError: resolved.error }),
    };
  }

  function mismatch(project) {
    const resolved = tryInstructions(project, projects);
    return new BridgeError(412, 'version_mismatch', `project is at version ${project.version}; read it again before updating`, {
      details: {
        current: {
          id: project.id,
          version: project.version,
          etag: etagFor(project.version),
          instructionVersion: project.instructionVersion ?? 0,
          instructionHash: resolved.value?.hash ?? project.instructionHash ?? null,
          instructionRef: project.instructionRef ?? null,
          instructions: resolved.value?.body ?? null,
        },
      },
    });
  }

  function list({ req }) {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    const limit = parseLimit(url.searchParams.get('limit'));
    const offset = parseCursor(url.searchParams.get('cursor'));
    const items = projects
      .list()
      .sort((a, b) => (a.updatedAt === b.updatedAt ? a.id.localeCompare(b.id) : b.updatedAt.localeCompare(a.updatedAt)))
      .map((project) => view(project));
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
    const project = requireProject(params[0]);
    return { status: 200, data: detail(project), headers: { etag: etagFor(project.version) } };
  }

  function versions({ params }) {
    const project = requireProject(params[0]);
    const items = [...(project.instructionHistory ?? [])].reverse();
    return { status: 200, data: { items, nextCursor: null } };
  }

  function create({ device, rawBody }) {
    const body = parseObjectBody(rawBody);
    const name = parseName(body.name, { required: true });
    const nameSource = parseNameSource(body.nameSource);
    const instructionRef = parseInstructionRef(body.instructionRef);
    const instructions = parseInstructions(body.instructions);
    if (instructionRef !== null && instructions !== null) {
      throw badRequest('payload_invalid', 'a project has either instructions or an instructionRef, not both');
    }
    const instructionHash = instructionHashFor({ instructionRef, instructions }, projects.resolveInstructionRef);
    const t = now();
    const iso = new Date(t).toISOString();

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
        instructions,
        instructionHash,
        instructionVersion: instructionHash === null ? 0 : 1,
        instructionHistory: instructionHash === null
          ? []
          : [{ version: 1, hash: instructionHash, body: instructions, instructionRef, updatedAt: iso }],
        version: 1,
        createdAt: iso,
        updatedAt: iso,
        createdBy: device?.id ?? null,
      };
      all[id] = record;
      return record;
    });

    return { status: 201, data: detail(project), headers: { etag: etagFor(project.version) } };
  }

  function patch({ device, rawBody, params, req }) {
    const current = requireProject(params[0]);
    const expected = requireIfMatch(req.headers['if-match'], current, mismatch);
    const body = parseObjectBody(rawBody);
    const t = now();
    const iso = new Date(t).toISOString();

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

    // Replacing one instruction source clears the other, so a project is never
    // left with both a body and a ref. Sending both non-empty is a refusal.
    let nextRef = body.instructionRef === undefined
      ? (current.instructionRef ?? null)
      : parseInstructionRef(body.instructionRef);
    let nextInstructions = body.instructions === undefined
      ? (current.instructions ?? null)
      : parseInstructions(body.instructions);
    if (body.instructionRef !== undefined && body.instructions !== undefined) {
      if (nextRef !== null && nextInstructions !== null) {
        throw badRequest('payload_invalid', 'a project has either instructions or an instructionRef, not both');
      }
    } else if (body.instructions !== undefined && nextInstructions !== null) {
      nextRef = null;
    } else if (body.instructionRef !== undefined && nextRef !== null) {
      nextInstructions = null;
    }

    const instructionsChanged = nextRef !== (current.instructionRef ?? null)
      || nextInstructions !== (current.instructions ?? null);
    // A ref is only re-read when the instruction source changes: a rename must
    // not fail because the vault is briefly unavailable.
    const nextHash = instructionsChanged
      ? instructionHashFor({ instructionRef: nextRef, instructions: nextInstructions }, projects.resolveInstructionRef)
      : (current.instructionHash ?? null);
    const identityChanged = name !== undefined && name !== current.name;

    // A PATCH that names fields identical to the stored state is accepted as a
    // no-op: the caller read the current version, and nothing is bumped.
    const changed = identityChanged || instructionsChanged;

    const updated = projects.mutate((all) => {
      const record = all[current.id];
      if (!record || record.version !== expected) throw mismatch(record ?? current);
      if (!changed) return record;
      if (name !== undefined) {
        record.name = name;
        record.nameSource = nameSource ?? 'owner';
      }
      record.instructionRef = nextRef;
      record.instructions = nextInstructions;
      if (instructionsChanged) {
        record.instructionVersion = (record.instructionVersion ?? 0) + 1;
        record.instructionHash = nextHash;
        record.instructionHistory = [
          ...(record.instructionHistory ?? []),
          {
            version: record.instructionVersion,
            hash: nextHash,
            body: nextInstructions,
            instructionRef: nextRef,
            updatedAt: iso,
          },
        ].slice(-INSTRUCTION_HISTORY_LIMIT);
      }
      record.version += 1;
      record.updatedAt = iso;
      record.updatedBy = device?.id ?? null;
      return record;
    });

    return { status: 200, data: detail(updated), headers: { etag: etagFor(updated.version) } };
  }

  return [
    { method: 'GET', path: '/v1/projects', auth: true, scope: 'sessions:read', handler: list },
    { method: 'POST', path: '/v1/projects', auth: true, scope: 'sessions:write', idempotent: true, handler: create },
    { method: 'GET', pattern: /^\/v1\/projects\/(prj_[0-9a-f]{12})$/, auth: true, scope: 'sessions:read', handler: get },
    {
      method: 'GET',
      pattern: /^\/v1\/projects\/(prj_[0-9a-f]{12})\/instructions\/versions$/,
      auth: true,
      scope: 'sessions:read',
      handler: versions,
    },
    { method: 'PATCH', pattern: /^\/v1\/projects\/(prj_[0-9a-f]{12})$/, auth: true, scope: 'sessions:write', idempotent: true, handler: patch },
  ];
}

// --- projection ------------------------------------------------------------

// List view: no instruction body, so a phone listing many projects does not
// download every shared prompt. `GET /v1/projects/{id}` adds `instructions`.
function view(project) {
  return {
    id: project.id,
    name: project.name,
    nameSource: project.nameSource,
    instructionRef: project.instructionRef ?? null,
    instructionHash: project.instructionHash ?? null,
    instructionVersion: project.instructionVersion ?? 0,
    version: project.version,
    etag: etagFor(project.version),
    createdAt: project.createdAt,
    updatedAt: project.updatedAt,
  };
}

// A GET must not fail because a referenced file moved: it reports
// `instructionError` and keeps the stored hash instead of returning 500.
function tryInstructions(project, projects) {
  try {
    return { value: projects.instructionsFor(project), error: null };
  } catch (err) {
    if (!(err instanceof BridgeError)) throw err;
    return { value: null, error: err.code };
  }
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
  if (ref === '') return null;
  if (ref.length > INSTRUCTION_REF_MAX) {
    throw badRequest('payload_invalid', `instructionRef must be at most ${INSTRUCTION_REF_MAX} characters`);
  }
  if (/[\u0000-\u001f\u007f]/.test(ref)) {
    throw badRequest('payload_invalid', 'instructionRef must not contain control characters');
  }
  if (ref.startsWith('/') || ref.includes('\\')) {
    throw badRequest('payload_invalid', 'instructionRef must be a vault-relative path');
  }
  const segments = ref.split('/');
  if (segments.some((segment) => segment === '' || segment === '.' || segment === '..')) {
    throw badRequest('payload_invalid', 'instructionRef must not contain empty, "." or ".." segments');
  }
  return segments.join('/');
}

// The stored body. An empty or whitespace-only body clears the instructions;
// a body that closes the delimiter would let the text escape its block when a
// session is composed, so it is refused instead of silently rewritten.
function parseInstructions(raw) {
  if (raw === undefined || raw === null) return null;
  if (typeof raw !== 'string') throw badRequest('payload_invalid', 'instructions must be a string');
  if (raw.trim() === '') return null;
  if (Buffer.byteLength(raw, 'utf8') > INSTRUCTIONS_MAX_BYTES) {
    throw badRequest('payload_invalid', `instructions must be at most ${INSTRUCTIONS_MAX_BYTES} bytes`);
  }
  if (raw.includes('\u0000')) throw badRequest('payload_invalid', 'instructions must not contain NUL');
  if (new RegExp(`</${INSTRUCTION_TAG}`, 'i').test(raw)) {
    throw badRequest('payload_invalid', `instructions must not contain the </${INSTRUCTION_TAG}> delimiter`);
  }
  return raw;
}

function instructionHashFor({ instructionRef, instructions }, resolveRef) {
  if (instructionRef !== null) return hashBody(resolveRef(instructionRef));
  if (instructions !== null) return hashBody(instructions);
  return null;
}

export function hashBody(body) {
  return `sha256:${createHash('sha256').update(body, 'utf8').digest('hex')}`;
}

// If-Match is mandatory for updates so two devices cannot silently overwrite
// each other. `*` is accepted (resource exists), weak tags are compared by
// version value only. A mismatch returns the current side of the project so
// the app can show both versions and let the owner choose; it never merges.
function requireIfMatch(header, project, mismatch) {
  if (typeof header !== 'string' || header.trim() === '') {
    throw new BridgeError(428, 'precondition_required', 'If-Match header with the project version is required');
  }
  const tags = header.split(',').map((tag) => tag.trim()).filter(Boolean);
  if (tags.includes('*')) return project.version;
  for (const tag of tags) {
    const match = /^(?:W\/)?"?(\d+)"?$/.exec(tag);
    if (match && Number(match[1]) === project.version) return project.version;
  }
  throw mismatch(project);
}

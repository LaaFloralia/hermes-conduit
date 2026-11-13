// /v1/projects — a project is a genre (topic) with shared instructions.
//
// Separation from workspaces is deliberate: a project carries no path, branch
// or repo. A session picks one project and one workspace independently, which
// is what lets the same genre run in `/Users/laa/dev/x` or a worktree without
// the two identities drifting apart.
//
// Instructions (BRIDGE.md §9): the owner edits one shared instruction body per
// project from the phone, and every session started in that project receives
// it. The body is stored here, in the Bridge's 0600 state file, with a
// monotonic `instructionVersion`, a `sha256:` hash of the body and the last ten
// revisions (body, hash, version, time) so two devices can compare and restore
// instead of silently overwriting each other. Events and logs carry only the
// version and hash, never the body.
//
// Inline bodies only: the Bridge never reads an instruction file. A path would
// turn `sessions:write` into a read of any file the Bridge process can open
// (`.git/config`, `.env`) and would need a second, weaker copy of the Brain's
// path rules; agents already read a repo's AGENTS.md / PROJECT-RULES.md
// themselves. `instructionRef` is therefore refused on write
// (400 `instruction_ref_unsupported`). Records written before this decision may
// still carry a ref: it is returned as legacy metadata, is never read and never
// applied, and a PATCH with `instructionRef: null` clears it.
//
// Naming: `nameSource` records who named the project. `owner` means a human
// (or the owner's explicit instruction) chose the name and an automatic name
// can never replace it; `auto` marks a generated name that may be recomputed.

import { createHash, randomBytes } from 'node:crypto';
import { chmodSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { badRequest, BridgeError, conflict, markBeforeWrite, notFound } from '../errors.mjs';
import { parseCursor, parseLimit, encodeCursor } from './pagination.mjs';
import { createJsonFile, parseObjectBody } from './state-file.mjs';
import { projectRefItem } from '../refs/items.mjs';

const PROJECT_SCHEMA = 2;
const NAME_MAX = 80;
const INSTRUCTIONS_MAX_BYTES = 32 * 1024;
const INSTRUCTION_HISTORY_LIMIT = 10;
const INSTRUCTION_TAG = 'project_instructions';
const NAME_SOURCES = new Set(['owner', 'auto']);
const FILE_NAME_MAX = 120;
const FILE_MAX_BYTES = 5 * 1024 * 1024;
const FILES_PER_PROJECT = 20;
// APFS allows 255 UTF-8 bytes per path component. `storedFileName` keeps the
// stored basename within that; the display name itself keeps its length.

// --- store ------------------------------------------------------------------

export function createProjectStore({ file, now = () => Date.now() }) {
  migrateLegacyProjects(file);
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
    // Reference files (like Claude Projects knowledge) live next to the state
    // file; sessions get their paths, never their bytes.
    filesDir: join(dirname(file), 'project-files'),
    filesFor(project) {
      return (project?.files ?? []).map((item) => ({ name: item.name, path: item.path, sha256: item.sha256 }));
    },
    mutate(fn) {
      return state.mutate((doc) => {
        doc.projects ??= {};
        return fn(doc.projects);
      });
    },
    // The instructions a session must apply: the stored body only. A legacy
    // `instructionRef` is metadata and is deliberately not read.
    instructionsFor(project) {
      if (!project) return null;
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
// re-derived. They are converted once: identity, name and reference survive as
// metadata, the instruction body starts empty and the app re-saves it from the
// phone.
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

export function createProjectRoutes({ projects, now = () => Date.now(), refs = null, choices = () => ({ profiles: [] }) }) {
  const releasesReservation = (error) => error?.writeStarted === false;

  function parseDefaultProfile(value) {
    if (value === undefined || value === null) return null;
    if (typeof value !== 'string' || !choices().profiles.some((item) => item.id === value)) {
      throw badRequest('model_choice_invalid', 'choose a listed project default profile');
    }
    return value;
  }

  function decorate(item) {
    return refs ? { ...item, ref: refs.refFor('project', item.id) } : item;
  }
  function assign(project) {
    if (!refs || !project) return;
    refs.assign('project', project.id, project.name, projectRefItem(project).external);
  }
  function observeVisible() {
    if (!refs) return;
    try {
      refs.observe('project', projects.list().filter((project) => !project.archivedAt).map(projectRefItem));
    } catch {
      // Reconcile never fails the list response it decorates.
    }
  }

  function requireProject(id) {
    const project = projects.get(id);
    if (!project) throw notFound('project not found');
    return project;
  }

  function detail(project) {
    return {
      ...view(project),
      instructions: project.instructions ?? null,
      files: (project.files ?? []).map(({ id, name, size, mimeType, sha256, createdAt }) => ({ id, name, size, mimeType, sha256, createdAt })),
    };
  }

  function mismatch(project) {
    return new BridgeError(412, 'version_mismatch', `project is at version ${project.version}; read it again before updating`, {
      details: {
        current: {
          id: project.id,
          version: project.version,
          etag: etagFor(project.version),
          instructionVersion: project.instructionVersion ?? 0,
          instructionHash: project.instructionHash ?? null,
          instructionRef: project.instructionRef ?? null,
          instructions: project.instructions ?? null,
          defaultProfile: project.defaultProfile ?? null,
        },
      },
    });
  }

  function list({ req }) {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    const limit = parseLimit(url.searchParams.get('limit'));
    const offset = parseCursor(url.searchParams.get('cursor'));
    const archivedOnly = url.searchParams.get('archived') === 'only';
    const items = projects
      .list()
      .filter((project) => Boolean(project.archivedAt) === archivedOnly)
      .sort((a, b) => (a.updatedAt === b.updatedAt ? a.id.localeCompare(b.id) : b.updatedAt.localeCompare(a.updatedAt)))
      .map((project) => view(project));
    const page = items.slice(offset, offset + limit);
    observeVisible();
    return {
      status: 200,
      data: {
        items: page.map(decorate),
        nextCursor: offset + limit < items.length ? encodeCursor(offset + limit) : null,
      },
    };
  }

  function get({ params }) {
    const project = requireProject(params[0]);
    return { status: 200, data: decorate(detail(project)), headers: { etag: etagFor(project.version) } };
  }

  function versions({ params }) {
    const project = requireProject(params[0]);
    const items = [...(project.instructionHistory ?? [])].reverse();
    return { status: 200, data: { items, nextCursor: null } };
  }

  function create({ device, rawBody }) {
    let name;
    let nameSource;
    let instructions;
    let instructionHash;
    let defaultProfile;
    try {
      const body = parseObjectBody(rawBody);
      name = parseName(body.name, { required: true });
      nameSource = parseNameSource(body.nameSource);
      rejectInstructionRef(body);
      instructions = parseInstructions(body.instructions);
      instructionHash = instructions === null ? null : hashBody(instructions);
      defaultProfile = parseDefaultProfile(body.defaultProfile);
    } catch (error) {
      throw markBeforeWrite(error);
    }
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
        defaultProfile,
        instructionRef: null,
        instructions,
        instructionHash,
        instructionVersion: instructionHash === null ? 0 : 1,
        instructionHistory: instructionHash === null
          ? []
          : [{ version: 1, hash: instructionHash, body: instructions, updatedAt: iso }],
        version: 1,
        createdAt: iso,
        updatedAt: iso,
        createdBy: device?.id ?? null,
      };
      all[id] = record;
      return record;
    });

    assign(project);
    return { status: 201, data: decorate(detail(project)), headers: { etag: etagFor(project.version) } };
  }

  function patch({ device, rawBody, params, req }) {
    let current;
    let expected;
    let name;
    let nameSource;
    let nextInstructions;
    let refCleared;
    let instructionsChanged;
    let nextHash;
    let archivedChanged;
    let nextArchivedAt;
    let nextDefaultProfile;
    let changed;
    let iso;
    try {
      current = requireProject(params[0]);
      expected = requireIfMatch(req.headers['if-match'], current, mismatch);
      const body = parseObjectBody(rawBody);
      iso = new Date(now()).toISOString();

      const requested = body.name !== undefined || body.nameSource !== undefined
        || body.instructionRef !== undefined || body.instructions !== undefined || body.archived !== undefined
        || body.defaultProfile !== undefined;
      if (!requested) throw badRequest('payload_invalid', 'no supported change was requested');

      name = body.name === undefined ? undefined : parseName(body.name, { required: true });
      if (body.nameSource !== undefined && name === undefined) {
        throw badRequest('payload_invalid', 'nameSource is only meaningful together with name');
      }
      nameSource = body.nameSource === undefined ? undefined : parseNameSource(body.nameSource);
      if (name !== undefined && current.nameSource === 'owner' && nameSource === 'auto') {
        // Owner-given names always win: an automatic rename is refused, not
        // silently ignored, so the caller cannot believe it succeeded.
        throw conflict('name_source_locked', 'the project name was chosen by the owner and cannot be replaced automatically');
      }

      // `instructionRef: null` is the only accepted ref value: it clears legacy
      // metadata written before refs were refused. Any other value is refused.
      // Saving a body also drops the legacy ref, so a record never shows both.
      rejectInstructionRef(body);
      nextInstructions = body.instructions === undefined
        ? (current.instructions ?? null)
        : parseInstructions(body.instructions);
      refCleared = (current.instructionRef ?? null) !== null
        && (body.instructionRef === null || nextInstructions !== null);

      instructionsChanged = nextInstructions !== (current.instructions ?? null);
      nextHash = instructionsChanged
        ? (nextInstructions === null ? null : hashBody(nextInstructions))
        : (current.instructionHash ?? null);
      const identityChanged = name !== undefined && name !== current.name;

      // A PATCH that names fields identical to the stored state is accepted as a
      // no-op: the caller read the current version, and nothing is bumped.
      if (body.archived !== undefined && typeof body.archived !== 'boolean') {
        throw badRequest('payload_invalid', 'archived must be a boolean');
      }
      archivedChanged = body.archived !== undefined && body.archived !== Boolean(current.archivedAt);
      nextArchivedAt = body.archived ? iso : null;
      nextDefaultProfile = body.defaultProfile === undefined ? (current.defaultProfile ?? null) : parseDefaultProfile(body.defaultProfile);
      changed = identityChanged || instructionsChanged || refCleared || archivedChanged
        || nextDefaultProfile !== (current.defaultProfile ?? null);
    } catch (error) {
      throw markBeforeWrite(error);
    }

    let updated;
    try {
      updated = projects.mutate((all) => {
        const record = all[current.id];
        if (!record || record.version !== expected) throw mismatch(record ?? current);
        if (!changed) return record;
        if (name !== undefined) {
          record.name = name;
          record.nameSource = nameSource ?? 'owner';
        }
        record.defaultProfile = nextDefaultProfile;
        if (refCleared) record.instructionRef = null;
        if (archivedChanged) record.archivedAt = nextArchivedAt;
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
              updatedAt: iso,
            },
          ].slice(-INSTRUCTION_HISTORY_LIMIT);
        }
        record.version += 1;
        record.updatedAt = iso;
        record.updatedBy = device?.id ?? null;
        return record;
      });
    } catch (error) {
      // The callback throws before the state file is replaced, so a version
      // mismatch wrote nothing.
      if (error?.status === 412) throw markBeforeWrite(error);
      throw error;
    }

    if (archivedChanged) observeVisible();
    return { status: 200, data: decorate(detail(updated)), headers: { etag: etagFor(updated.version) } };
  }

  function addFile({ device, rawBody, params }) {
    let current;
    let name;
    let bytes;
    let mimeType;
    try {
      current = requireProject(params[0]);
      const body = parseObjectBody(rawBody);
      name = parseFileName(body.name);
      bytes = parseFileContent(body.contentBase64);
      mimeType = body.mimeType === undefined || body.mimeType === null ? null : parseMimeType(body.mimeType);
      if ((current.files ?? []).length >= FILES_PER_PROJECT) {
        throw conflict('file_limit_reached', `a project holds at most ${FILES_PER_PROJECT} files`);
      }
    } catch (error) {
      throw markBeforeWrite(error);
    }
    const id = `file_${randomBytes(6).toString('hex')}`;
    const dir = join(projects.filesDir, current.id);
    const stored = storedFileName(id, name);
    if (stored === `${id}-` || Buffer.byteLength(stored, 'utf8') > 255) {
      // A defensive 4xx: the shortener above makes this unreachable, but a
      // filesystem limit must never become an unexplained 500.
      throw markBeforeWrite(badRequest('file_name_too_long', 'name is too long to store on this Mac'));
    }
    const path = join(dir, stored);
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    chmodSync(projects.filesDir, 0o700);
    chmodSync(dir, 0o700);
    writeFileSync(path, bytes, { mode: 0o600, flag: 'wx' });
    const iso = new Date(now()).toISOString();
    let updated;
    try {
      updated = projects.mutate((all) => {
        const record = all[current.id];
        if (!record) throw notFound('project not found');
        if ((record.files ?? []).length >= FILES_PER_PROJECT) {
          throw conflict('file_limit_reached', `a project holds at most ${FILES_PER_PROJECT} files`);
        }
        record.files = [...(record.files ?? []), {
          id,
          name,
          size: bytes.length,
          mimeType,
          sha256: `sha256:${createHash('sha256').update(bytes).digest('hex')}`,
          path,
          createdAt: iso,
        }];
        record.version += 1;
        record.updatedAt = iso;
        record.updatedBy = device?.id ?? null;
        return record;
      });
    } catch (err) {
      rmSync(path, { force: true });
      throw err;
    }
    return { status: 201, data: decorate(detail(updated)), headers: { etag: etagFor(updated.version) } };
  }

  function removeFile({ device, params }) {
    let current;
    let entry;
    try {
      current = requireProject(params[0]);
      entry = (current.files ?? []).find((item) => item.id === params[1]);
      if (!entry) throw notFound('file not found');
    } catch (error) {
      throw markBeforeWrite(error);
    }
    const iso = new Date(now()).toISOString();
    const updated = projects.mutate((all) => {
      const record = all[current.id];
      if (!record) throw notFound('project not found');
      record.files = (record.files ?? []).filter((item) => item.id !== entry.id);
      record.version += 1;
      record.updatedAt = iso;
      record.updatedBy = device?.id ?? null;
      return record;
    });
    rmSync(entry.path, { force: true });
    return { status: 200, data: decorate(detail(updated)), headers: { etag: etagFor(updated.version) } };
  }

  return [
    { method: 'GET', path: '/v1/projects', auth: true, scope: 'sessions:read', handler: list },
    {
      method: 'POST',
      pattern: /^\/v1\/projects\/(prj_[0-9a-f]{12})\/files$/,
      auth: true,
      scope: 'sessions:write',
      idempotent: true,
      bodyLimit: 8 * 1024 * 1024,
      handler: addFile,
      releaseOnError: releasesReservation,
    },
    {
      method: 'DELETE',
      pattern: /^\/v1\/projects\/(prj_[0-9a-f]{12})\/files\/(file_[0-9a-f]{12})$/,
      auth: true,
      scope: 'sessions:write',
      idempotent: true,
      handler: removeFile,
      releaseOnError: releasesReservation,
    },
    { method: 'POST', path: '/v1/projects', auth: true, scope: 'sessions:write', idempotent: true, handler: create, releaseOnError: releasesReservation },
    { method: 'GET', pattern: /^\/v1\/projects\/(prj_[0-9a-f]{12})$/, auth: true, scope: 'sessions:read', handler: get },
    {
      method: 'GET',
      pattern: /^\/v1\/projects\/(prj_[0-9a-f]{12})\/instructions\/versions$/,
      auth: true,
      scope: 'sessions:read',
      handler: versions,
    },
    { method: 'PATCH', pattern: /^\/v1\/projects\/(prj_[0-9a-f]{12})$/, auth: true, scope: 'sessions:write', idempotent: true, handler: patch, releaseOnError: releasesReservation },
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
    defaultProfile: project.defaultProfile ?? null,
    // Legacy metadata only (see the header). Null for every project written
    // after refs were refused.
    instructionRef: project.instructionRef ?? null,
    instructionHash: project.instructionHash ?? null,
    instructionVersion: project.instructionVersion ?? 0,
    fileCount: (project.files ?? []).length,
    version: project.version,
    etag: etagFor(project.version),
    createdAt: project.createdAt,
    updatedAt: project.updatedAt,
    archivedAt: project.archivedAt ?? null,
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

// A ref would make the Bridge read an arbitrary file for any device allowed to
// write a project. Only `null` (clear legacy metadata) is accepted.
function rejectInstructionRef(body) {
  if (body.instructionRef === undefined || body.instructionRef === null) return;
  throw badRequest(
    'instruction_ref_unsupported',
    'instructionRef is not supported; store the instructions inline (agents read AGENTS.md / PROJECT-RULES.md themselves)',
  );
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

function truncateUtf8(text, maxBytes) {
  if (maxBytes <= 0) return '';
  let out = '';
  let used = 0;
  for (const char of text) {
    const size = Buffer.byteLength(char, 'utf8');
    if (used + size > maxBytes) break;
    out += char;
    used += size;
  }
  return out;
}

// The on-disk basename, not the display name. It is NFC-normalised and cut on
// code-point boundaries so a 120-character Japanese name cannot exceed APFS's
// 255-byte component limit (`ENAMETOOLONG` -> 500). The extension is kept when
// it is small enough to be useful; `name` in the project record is unchanged.
export function storedFileName(id, name) {
  const prefix = `${id}-`;
  const budget = 255 - Buffer.byteLength(prefix, 'utf8');
  const normalized = name.normalize('NFC');
  if (Buffer.byteLength(normalized, 'utf8') <= budget) return `${prefix}${normalized}`;

  const dot = normalized.lastIndexOf('.');
  const extension = dot > 0 ? normalized.slice(dot) : '';
  const extensionBytes = Buffer.byteLength(extension, 'utf8');
  const keepExtension = extensionBytes > 0 && extensionBytes <= 32 && extensionBytes < budget;
  const base = keepExtension ? normalized.slice(0, dot) : normalized;
  const tail = keepExtension ? extension : '';
  return `${prefix}${truncateUtf8(base, budget - Buffer.byteLength(tail, 'utf8'))}${tail}`;
}

function parseFileName(raw) {
  if (typeof raw !== 'string') throw badRequest('payload_invalid', 'name is required');
  const name = raw.trim();
  if (name === '' || [...name].length > FILE_NAME_MAX || name === '.' || name === '..'
    || /[/\\\u0000-\u001f\u007f]/.test(name)) {
    throw badRequest('payload_invalid', `name must be 1-${FILE_NAME_MAX} characters without / \\ or control characters`);
  }
  return name;
}

function parseFileContent(raw) {
  if (typeof raw !== 'string' || raw === '' || !/^[A-Za-z0-9+/]+={0,2}$/.test(raw)) {
    throw badRequest('payload_invalid', 'contentBase64 must be non-empty base64');
  }
  const bytes = Buffer.from(raw, 'base64');
  if (bytes.length === 0) throw badRequest('payload_invalid', 'contentBase64 must not be empty');
  if (bytes.length > FILE_MAX_BYTES) throw badRequest('payload_too_large', `a file must be at most ${FILE_MAX_BYTES} bytes`);
  return bytes;
}

function parseMimeType(raw) {
  if (typeof raw !== 'string' || !/^[a-z0-9.+-]+\/[a-z0-9.+-]+$/i.test(raw) || raw.length > 100) {
    throw badRequest('payload_invalid', 'mimeType must look like type/subtype');
  }
  return raw.toLowerCase();
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

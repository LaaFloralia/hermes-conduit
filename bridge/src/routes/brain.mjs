// /v1/brain — read, search and create-only access to the Brain vault.
//
// ROADMAP 25 with the task-24 decision in docs/laa/BRAIN-WRITE.md:
//   `brain:write` stays disabled (no replacement of existing content);
//   `brain:create` creates a new path with O_EXCL under an allowed prefix.
//
// Scopes: reads and search need `brain:read`; the single mutation needs
// `brain:create`, which is opt-in per device (BRIDGE §9 initial set unchanged).

import { join } from 'node:path';
import { createBrainService } from '../brain/service.mjs';
import { createGitGate, createDiskGate, createSyncthingGate } from '../brain/gates.mjs';
import { badRequest } from '../errors.mjs';
import {
  resolveBrainCreatePrefixes, resolveBrainFolderId, resolveBrainPolicyPath, resolveBrainRoot,
  resolveBrainSearchBin, resolveSyncthingConfigPath, resolveSyncthingUrl,
} from '../config.mjs';
import { parseCursor, parseLimit, encodeCursor } from './pagination.mjs';
import { parseObjectBody } from './state-file.mjs';

const FILE_ID = /^\/v1\/brain\/files\/(bf_[A-Za-z0-9_-]{1,400})$/;

function parseAreas(url) {
  const values = [...url.searchParams.getAll('area')];
  for (const raw of url.searchParams.getAll('areas')) {
    for (const part of raw.split(',')) values.push(part);
  }
  return values.map((value) => value.trim()).filter((value) => value !== '');
}

function parseFlag(raw, fallback = false) {
  if (raw === undefined || raw === null || raw === '') return fallback;
  return ['1', 'true', 'yes', 'on'].includes(String(raw).toLowerCase());
}

export function createBrainRoutes({
  service = null,
  vaultRoot,
  policyFile,
  searchBin,
  createPrefixes,
  journalFile,
  search = null,
  gates = null,
  syncthing = {},
  now = () => Date.now(),
} = {}) {
  const brain = service ?? createBrainService({
    vaultRoot,
    policyFile,
    searchBin,
    createPrefixes,
    journalFile,
    search,
    now,
    gates: gates ?? {
      git: createGitGate({ vaultRoot }),
      disk: createDiskGate({ vaultRoot }),
      sync: createSyncthingGate(syncthing),
    },
  });

  function url(req) {
    return new URL(req.url ?? '/', 'http://127.0.0.1');
  }

  function list({ req }) {
    const q = url(req);
    const limit = parseLimit(q.searchParams.get('limit'), { max: 200, fallback: 50 });
    const offset = parseCursor(q.searchParams.get('cursor'));
    const page = brain.list({ areas: parseAreas(q), limit, offset });
    return {
      status: 200,
      data: {
        items: page.items,
        nextCursor: page.nextCursor === null ? null : encodeCursor(page.nextCursor),
        total: page.total,
        areas: page.areas,
        optionalAreas: page.optionalAreas,
      },
    };
  }

  function get({ req, params }) {
    const q = url(req);
    const note = brain.read({ id: params[0], areas: parseAreas(q) });
    return { status: 200, data: note, headers: { etag: `"${note.contentHash}"` } };
  }

  // Named apart from the `search` adapter parameter: a function declaration has
  // no effect on a destructured binding, so reusing the name would register the
  // adapter as the route handler.
  async function searchNotes({ req }) {
    const q = url(req);
    const rawK = q.searchParams.get('k');
    const k = rawK === null || rawK === '' ? 5 : Number(rawK);
    if (!Number.isInteger(k) || k < 1 || k > 10) throw badRequest('k_invalid', 'k must be an integer between 1 and 10');
    const data = await brain.search({
      query: q.searchParams.get('q') ?? '',
      k,
      areas: parseAreas(q),
      adopted: parseFlag(q.searchParams.get('adopted')),
      rerank: parseFlag(q.searchParams.get('rerank')),
    });
    return { status: 200, data };
  }

  async function create({ device, requestId, rawBody }) {
    const body = parseObjectBody(rawBody);
    if (body.content === undefined) throw badRequest('payload_invalid', 'content is required');
    if (body.onConflict !== undefined && !['suffix', 'reject'].includes(body.onConflict)) {
      throw badRequest('payload_invalid', 'onConflict must be "suffix" or "reject"');
    }
    // There is no replacement path: say so instead of ignoring an overwrite
    // flag a client may have taken from an older contract.
    for (const field of ['baseHash', 'contentHash', 'overwrite', 'replace']) {
      if (body[field] !== undefined) {
        throw badRequest('unsupported_field', `the Bridge never replaces an existing note; ${field} is not accepted`);
      }
    }
    const created = await brain.create({
      device,
      requestId,
      path: body.path,
      content: body.content,
      onConflict: body.onConflict,
    });
    return { status: 201, data: created };
  }

  async function gateReport() {
    return { status: 200, data: await brain.gates() };
  }

  return [
    { method: 'GET', path: '/v1/brain/files', auth: true, scope: 'brain:read', handler: list },
    { method: 'POST', path: '/v1/brain/files', auth: true, scope: 'brain:create', idempotent: true, handler: create },
    { method: 'GET', pattern: FILE_ID, auth: true, scope: 'brain:read', handler: get },
    { method: 'GET', path: '/v1/brain/search', auth: true, scope: 'brain:read', handler: searchNotes },
    { method: 'GET', path: '/v1/brain/gates', auth: true, scope: 'brain:read', handler: gateReport },
  ];
}

// Production wiring: paths and credentials come from config.mjs (existing
// material on this Mac), the journal lives in the Bridge state directory, and a
// test or an operator can override any piece through `options.brain`.
export function brainRoutes({ store, now = () => Date.now(), options = {} } = {}) {
  const vaultRoot = options.vaultRoot ?? resolveBrainRoot();
  return createBrainRoutes({
    vaultRoot,
    policyFile: options.policyFile ?? resolveBrainPolicyPath(),
    searchBin: options.searchBin ?? resolveBrainSearchBin(),
    createPrefixes: options.createPrefixes ?? resolveBrainCreatePrefixes(),
    journalFile: options.journalFile ?? join(store.dir, 'brain-create', 'journal.jsonl'),
    search: options.search ?? null,
    gates: options.gates ?? null,
    syncthing: {
      configPath: options.syncthing?.configPath ?? resolveSyncthingConfigPath(),
      baseUrl: options.syncthing?.baseUrl ?? resolveSyncthingUrl(),
      folder: options.syncthing?.folder ?? resolveBrainFolderId(),
      ...(options.syncthing?.fetchImpl ? { fetchImpl: options.syncthing.fetchImpl } : {}),
    },
    now,
  });
}

// GET /v1/refs and GET /v1/refs/<ref>.
//
// Read-only: the registry is written by decoration, creation and reconcile, not
// by these routes. Scope follows the data: tasks need `tasks:read`, everything
// else `sessions:read`. A kind the device may not read is reported as a 403
// rather than silently omitted from an explicit request; an unfiltered list
// only includes the kinds the device may read.

import { hasScope } from '../auth.mjs';
import { BridgeError } from '../errors.mjs';
import { KINDS, RefInputError, requireRefInput } from './registry.mjs';

function scopeFor(kind) {
  return kind === 'task' ? 'tasks:read' : 'sessions:read';
}

function readableKinds(device) {
  return KINDS.filter((kind) => hasScope(device, scopeFor(kind)));
}

function requireScope(device, kind) {
  if (!hasScope(device, scopeFor(kind))) {
    throw new BridgeError(403, 'insufficient_scope', `device is missing scope ${scopeFor(kind)}`);
  }
}

export function refRoutes({ refs }) {
  async function list({ req, device }) {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    const requested = url.searchParams.get('kind');
    if (requested !== null && !KINDS.includes(requested)) {
      throw new BridgeError(400, 'query_invalid', `kind must be one of ${KINDS.join(', ')}`);
    }
    if (requested !== null) requireScope(device, requested);
    const kinds = requested === null ? readableKinds(device) : [requested];
    const fetchedAt = new Date().toISOString();
    let items;
    let observedAt;
    try {
      items = refs.list(kinds);
      observedAt = refs.observedAt(kinds);
    } catch {
      throw new BridgeError(500, 'refs_unavailable', 'the refs registry could not be read');
    }
    return {
      status: 200,
      data: {
        items: items.map((record) => ({
          ref: record.ref,
          kind: record.kind,
          key: record.key,
          title: record.title,
          external: record.external,
        })),
        observedAt,
        fetchedAt,
      },
    };
  }

  async function resolve({ params, device }) {
    let normalized;
    let raw;
    try {
      raw = decodeURIComponent(params?.[0] ?? '');
    } catch {
      throw new BridgeError(400, 'ref_invalid', 'ref must look like T12');
    }
    try {
      normalized = requireRefInput(raw);
    } catch (error) {
      if (error instanceof RefInputError) {
        throw new BridgeError(400, 'ref_invalid', 'ref must look like T12');
      }
      throw error;
    }
    requireScope(device, normalized.kind);
    let result;
    try {
      result = refs.resolve(normalized.ref);
    } catch (error) {
      if (error instanceof RefInputError) throw new BridgeError(400, 'ref_invalid', 'ref must look like T12');
      throw new BridgeError(500, 'refs_unavailable', 'the refs registry could not be read');
    }
    if (result.status === 'unknown') {
      throw new BridgeError(404, 'ref_unknown', 'no object holds this ref and it has no recent history');
    }
    return { status: 200, data: result };
  }

  return [
    { method: 'GET', path: '/v1/refs', auth: true, handler: list },
    { method: 'GET', pattern: /^\/v1\/refs\/([^/]+)$/, auth: true, handler: resolve },
  ];
}

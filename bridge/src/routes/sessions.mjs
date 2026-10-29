// /v1/sessions — the Bridge's session API over the existing `laa-personal-agent`
// delegation path (docs/laa/BRIDGE.md sections 4, 5 and 9).
//
// The route module owns HTTP shapes only: query/body parsing, status codes and
// the long-poll loop is delegated to the service, which owns the session record
// and its event journal. Responses always carry the session's requested AND
// observed provider/model/effort; nothing here rewrites the requested profile.
//
// Events: `/events` is a long-poll (`wait` seconds, max 25) with `cursor` or
// `afterSeq`. `cursor` is the opaque value returned by create/list/detail and
// expires with the 24-hour journal; expiry or a pruned gap is a 410 so the
// client re-reads instead of assuming it saw everything.

import { parseObjectBody } from './state-file.mjs';

export function createSessionRoutes({ sessions }) {
  async function list({ req }) {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    const page = await sessions.listSessions({
      limit: url.searchParams.get('limit'),
      cursor: url.searchParams.get('cursor'),
      projectId: url.searchParams.get('projectId'),
      workspaceId: url.searchParams.get('workspaceId'),
      parentId: url.searchParams.get('parentId'),
      requestId: url.searchParams.get('requestId'),
      phase: url.searchParams.get('phase'),
    });
    return {
      status: 200,
      data: { items: page.items.map(sessions.view), nextCursor: page.nextCursor },
    };
  }

  async function create({ device, rawBody }) {
    const result = await sessions.createSession({ deviceId: device.id, body: parseObjectBody(rawBody) });
    return { status: result.created ? 201 : 200, data: sessions.view(result.session) };
  }

  async function detail({ params }) {
    const result = await sessions.getSession(params[0]);
    return {
      status: 200,
      data: {
        ...sessions.view(result.session),
        observation: result.observation,
      },
    };
  }

  async function send({ req, params, rawBody }) {
    const result = await sessions.sendMessage({
      id: params[0],
      body: parseObjectBody(rawBody),
      key: req.headers['idempotency-key'],
    });
    return { status: 202, data: sessions.view(result.session) };
  }

  async function stop({ params }) {
    const result = await sessions.stopSession(params[0]);
    return { status: 200, data: sessions.view(result.session) };
  }

  async function resume({ device, req, params, rawBody }) {
    const result = await sessions.resumeSession({
      id: params[0],
      body: parseObjectBody(rawBody),
      key: req.headers['idempotency-key'],
      deviceId: device?.id,
    });
    return {
      status: result.created ? 201 : 200,
      data: { ...sessions.view(result.session), resumedFrom: result.resumedFrom },
    };
  }

  async function events({ req, res, params }) {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    const id = params[0];
    const page = await sessions.readEventPage({
      id,
      cursor: url.searchParams.get('cursor'),
      afterSeq: url.searchParams.get('afterSeq'),
      limit: url.searchParams.get('limit'),
      wait: url.searchParams.get('wait'),
      res,
    });
    // A closed socket must not be written to; the pipeline treats `undefined`
    // as "the handler ended the response itself".
    if (res.writableEnded || res.destroyed) return undefined;
    const nextSeq = page.page.items.at(-1)?.seq ?? page.startSeq;
    return {
      status: 200,
      data: {
        items: page.page.items,
        nextCursor: sessions.eventCursor(id, nextSeq),
        oldestSeq: page.page.oldestSeq,
        headSeq: page.page.headSeq,
        resyncRequired: Boolean(page.resync),
        resyncReason: page.resync,
      },
    };
  }

  async function artifacts({ params }) {
    const result = await sessions.listArtifacts(params[0]);
    return { status: 200, data: { items: result.items, nextCursor: null } };
  }

  return [
    { method: 'GET', path: '/v1/sessions', auth: true, scope: 'sessions:read', handler: list },
    { method: 'POST', path: '/v1/sessions', auth: true, scope: 'sessions:write', idempotent: true, handler: create },
    { method: 'GET', pattern: /^\/v1\/sessions\/(ses_[0-9a-f]{16})$/, auth: true, scope: 'sessions:read', handler: detail },
    {
      method: 'GET',
      pattern: /^\/v1\/sessions\/(ses_[0-9a-f]{16})\/events$/,
      auth: true,
      scope: 'sessions:read',
      handler: events,
    },
    {
      method: 'GET',
      pattern: /^\/v1\/sessions\/(ses_[0-9a-f]{16})\/artifacts$/,
      auth: true,
      scope: 'sessions:read',
      handler: artifacts,
    },
    {
      method: 'POST',
      pattern: /^\/v1\/sessions\/(ses_[0-9a-f]{16})\/messages$/,
      auth: true,
      scope: 'sessions:write',
      idempotent: true,
      handler: send,
    },
    {
      method: 'POST',
      pattern: /^\/v1\/sessions\/(ses_[0-9a-f]{16})\/stop$/,
      auth: true,
      scope: 'sessions:write',
      idempotent: true,
      handler: stop,
    },
    {
      method: 'POST',
      pattern: /^\/v1\/sessions\/(ses_[0-9a-f]{16})\/resume$/,
      auth: true,
      scope: 'sessions:write',
      idempotent: true,
      handler: resume,
    },
  ];
}

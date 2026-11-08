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

import { sessionRefItem } from '../refs/items.mjs';
import { parseObjectBody } from './state-file.mjs';

export function createSessionRoutes({ sessions, sessionOptions, refs = null }) {
  function refItem(record) {
    return sessionRefItem(record, refs?.refFor);
  }
  function decorate(view) {
    return refs ? { ...view, ref: refs.refFor('session', view.id) } : view;
  }
  function assign(record) {
    if (!refs || !record) return;
    refs.assign('session', record.id, record.name, refItem(record).external);
  }
  // The local store is the complete live set (same visibility as the default
  // list), so a successful list request is also a safe release point.
  function observeVisible() {
    if (!refs || typeof sessions.visibleRecords !== 'function') return;
    try {
      refs.observe('session', sessions.visibleRecords().map(refItem));
    } catch {
      // Reconcile never fails the list response it decorates.
    }
  }
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
      archived: url.searchParams.get('archived'),
      scope: url.searchParams.get('scope'),
    });
    observeVisible();
    return {
      status: 200,
      data: { items: page.items.map(sessions.view).map(decorate), nextCursor: page.nextCursor },
    };
  }

  async function create({ device, rawBody }) {
    const result = await sessions.createSession({ deviceId: device.id, body: parseObjectBody(rawBody) });
    assign(result.session);
    return { status: result.created ? 201 : 200, data: decorate(sessions.view(result.session)) };
  }

  async function detail({ params }) {
    const result = await sessions.getSession(params[0]);
    return {
      status: 200,
      data: {
        ...decorate(sessions.view(result.session)),
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
    return { status: 202, data: decorate(sessions.view(result.session)) };
  }

  async function update({ params, rawBody }) {
    const body = parseObjectBody(rawBody);
    const result = await sessions.updateSession({ id: params[0], body });
    // Archive takes the children with it and restore brings one row back:
    // re-read the complete visible set so both are released/assigned now.
    if (body.archived !== undefined) observeVisible();
    return { status: 200, data: decorate(sessions.view(result.session)) };
  }

  async function decision({ params }) { return { status: 200, data: await sessions.decision(params[0]) }; }
  async function reply({ params, rawBody }) {
    const result = await sessions.reply({ id: params[0], body: parseObjectBody(rawBody) });
    return { status: 200, data: decorate(sessions.view(result.session)) };
  }

  async function options() {
    return { status: 200, data: sessionOptions() };
  }

  async function stop({ params }) {
    const result = await sessions.stopSession(params[0]);
    return { status: 200, data: decorate(sessions.view(result.session)) };
  }

  async function resume({ device, req, params, rawBody }) {
    const result = await sessions.resumeSession({
      id: params[0],
      body: parseObjectBody(rawBody),
      key: req.headers['idempotency-key'],
      deviceId: device?.id,
    });
    assign(result.session);
    return {
      status: result.created ? 201 : 200,
      data: { ...decorate(sessions.view(result.session)), resumedFrom: result.resumedFrom },
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

  async function conversation({ params }) {
    return { status: 200, data: { items: await sessions.conversation(params[0]) } };
  }

  return [
    { method: "POST", pattern: /^\/v1\/sessions\/(ses_[0-9a-f]{16})\/interrupt$/, auth: true, scope: "sessions:write", idempotent: true, handler: async ({ params }) => { const result = await sessions.interruptSession(params[0]); return { status: 200, data: sessions.view(result.session) }; } },
    { method: 'GET', pattern: /^\/v1\/sessions\/(ses_[0-9a-f]{16})\/images\/([0-9a-f]{64})$/, auth: true, scope: 'sessions:read', handler: async ({ params }) => ({ status: 200, data: sessions.image(params[0], params[1]) }) },
    { method: 'GET', pattern: /^\/v1\/sessions\/(ses_[0-9a-f]{16})\/decision$/, auth: true, scope: 'sessions:read', handler: decision },
    { method: 'POST', pattern: /^\/v1\/sessions\/(ses_[0-9a-f]{16})\/reply$/, auth: true, scope: 'sessions:write', idempotent: true, handler: reply },
    { method: 'GET', path: '/v1/sessions', auth: true, scope: 'sessions:read', handler: list },
    { method: 'POST', path: '/v1/sessions', auth: true, scope: 'sessions:write', idempotent: true, handler: create },
    { method: 'GET', pattern: /^\/v1\/sessions\/(ses_[0-9a-f]{16})$/, auth: true, scope: 'sessions:read', handler: detail },
    { method: 'PATCH', pattern: /^\/v1\/sessions\/(ses_[0-9a-f]{16})$/, auth: true, scope: 'sessions:write', idempotent: true, handler: update },
    { method: 'GET', path: '/v1/session-options', auth: true, scope: 'sessions:read', handler: options },
    { method: 'GET', pattern: /^\/v1\/sessions\/(ses_[0-9a-f]{16})\/conversation$/, auth: true, scope: 'sessions:read', handler: conversation },
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
      bodyLimit: 6 * 1024 * 1024,
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

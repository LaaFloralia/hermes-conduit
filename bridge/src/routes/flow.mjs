// HTTP surface of the requirement flow and Monet's inbox.
//
// Everything that starts, withdraws, claims or decides is Monet-only: the same
// bearer the completion report uses (routes/monet.mjs), never a paired device's
// token and never a Work session's. Paired devices may read flows.
//
//   POST /v1/flows                          start a flow (one tool call from Monet's chat turn)
//   POST /v1/flows/{id}/withdraw            stop a flow
//   GET  /v1/flows, GET /v1/flows/{id}      read (device, sessions:read)
//   POST /v1/monet/inbox/claim              lease events for one verification turn, with evidence
//   POST /v1/monet/inbox/{evt}/ack          apply a verdict
//   POST /v1/monet/inbox/replay             offer one session's return again (verification replay)
//   POST /v1/monet/digest                   the ≤600-character digest for Monet's owner turn

import { badRequest, notFound } from '../errors.mjs';
import { monetAuthorizer } from './monet.mjs';
import { parseObjectBody } from './state-file.mjs';

const FLOW = /^\/v1\/flows\/(flw_[0-9a-f]{12})$/;

export function flowRoutes({ pipeline, flows, inbox, tokenHash }) {
  const authorize = monetAuthorizer(tokenHash);
  const only = (body, allowed) => {
    if (Object.keys(body).some((key) => !allowed.includes(key))) throw badRequest('payload_invalid', `expected fields: ${allowed.join(', ')}`);
    return body;
  };
  const monet = (path, handler, { pattern = null, bodyLimit = 16_384 } = {}) => ({
    method: 'POST', ...(pattern ? { pattern } : { path }), auth: false, bodyLimit,
    handler: async ({ req, rawBody, params }) => {
      const caller = authorize(req);
      return handler({ caller, body: parseObjectBody(rawBody), params });
    },
  });
  const read = (id) => { const flow = flows.get(id); if (!flow) throw notFound('flow not found'); return flow; };
  return [
    monet('/v1/flows', async ({ body }) => {
      const { flow, created } = await pipeline.start(body);
      return { status: created ? 201 : 200, data: { flow: pipeline.summary(flow), created } };
    }, { bodyLimit: 32_768 }),
    monet(null, async ({ body, params }) => {
      only(body, ['withRequirements']);
      const result = await pipeline.withdraw(params[0], { withRequirements: body.withRequirements === true });
      return { status: 200, data: { flow: pipeline.summary(result.flow), withdrawn: result.withdrawn, stopped: result.stopped ?? [] } };
    }, { pattern: /^\/v1\/flows\/(flw_[0-9a-f]{12})\/withdraw$/ }),
    { method: 'GET', path: '/v1/flows', auth: true, scope: 'sessions:read', handler: ({ req }) => {
      const query = new URL(req.url, 'http://localhost').searchParams;
      const items = flows.list({ state: query.get('state'), projectId: query.get('projectId'), open: query.get('open') === '1' }).map(pipeline.summary);
      return { status: 200, data: { items } };
    } },
    { method: 'GET', pattern: FLOW, auth: true, scope: 'sessions:read', handler: ({ params }) => ({ status: 200, data: { flow: read(params[0]) } }) },
    monet('/v1/monet/inbox/claim', async ({ caller, body }) => {
      only(body, ['limit']);
      if (body.limit !== undefined && !Number.isInteger(body.limit)) throw badRequest('payload_invalid', 'limit is an integer');
      return { status: 200, data: await pipeline.claim({ limit: body.limit ?? 3, caller }) };
    }),
    monet(null, async ({ caller, body, params }) => ({ status: 200, data: await pipeline.applyVerdict(params[0], body, { caller }) }),
      { pattern: /^\/v1\/monet\/inbox\/(evt_[0-9a-f]{12})\/ack$/, bodyLimit: 32_768 }),
    monet('/v1/monet/inbox/replay', async ({ body }) => {
      only(body, ['sessionId']);
      if (typeof body.sessionId !== 'string') throw badRequest('payload_invalid', 'sessionId is required');
      return { status: 201, data: { event: pipeline.replay(body.sessionId) } };
    }),
    monet('/v1/monet/digest', async ({ caller }) => {
      const reports = await pipeline.settle({ caller });
      return { status: 200, data: { text: pipeline.digest(), counts: inbox.counts(), reports } };
    }),
  ];
}

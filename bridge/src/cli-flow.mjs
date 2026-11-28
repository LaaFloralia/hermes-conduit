// `laa-bridge flow …` and `laa-bridge monet …`: the requirement flow and Monet's
// inbox from a shell. Reads come from the state files; everything that starts,
// withdraws, claims or decides goes to the running Bridge with the Monet runner
// credential (cli-monet.mjs), so a Work session's shell cannot do it.
// Request bodies and verdicts come from a file or stdin, never from argv.
import { readFileSync } from 'node:fs';
import { resolveStateDir } from './config.mjs';
import { monetPost } from './cli-monet.mjs';
import { badRequest, notFound } from './errors.mjs';
import { createFlowStore, FLOW_ID, FLOW_STATES } from './flow/store.mjs';
import { createMonetInbox, EVENT_ID } from './monet/inbox.mjs';
import { SESSION_ID_PATTERN } from './sessions/store.mjs';

export const FLOW_USAGE = `laa-bridge flow start [--file <json>]      start a requirement flow; the body is read from the file or stdin
      body: { projectId, requestId, title, details?, ownerText?, size?: S|M|L, risk?: [..], repo?, refs?, dryStaff? }
  laa-bridge flow status <flw_id>          one flow with its steps, staff, packages and decisions
  laa-bridge flow list [--state <state>] [--project <prj_id>] [--open]
  laa-bridge flow withdraw <flw_id> [--with-requirements]
  laa-bridge monet inbox [--claim] [--limit <n>]   waiting events; --claim leases them with their evidence
  laa-bridge monet ack <evt_id> --verdict-file <json|->   apply one verdict
  laa-bridge monet digest                  the short digest for Monet's turn with the owner
  laa-bridge monet replay <ses_id>         offer one session's return again
  (start, withdraw, --claim, ack, digest and replay need the trusted Monet runner credential)`;

const MAX_INPUT = 65_536;

async function readStdin() {
  const chunks = [];
  let bytes = 0;
  for await (const chunk of process.stdin) {
    bytes += chunk.length;
    if (bytes > MAX_INPUT) throw badRequest('input_oversize', 'input exceeds 64 KiB');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

async function readObject(path, stdin) {
  let raw;
  if (path === undefined || path === '-') raw = await stdin();
  else {
    try { raw = readFileSync(path); } catch { throw badRequest('input_unreadable', 'the input file cannot be read'); }
    if (raw.length > MAX_INPUT) throw badRequest('input_oversize', 'input exceeds 64 KiB');
  }
  try {
    const value = JSON.parse(raw);
    if (value && typeof value === 'object' && !Array.isArray(value)) return value;
  } catch { /* The error carries no input. */ }
  throw badRequest('payload_invalid', 'expected a JSON object');
}

const only = (flags, allowed) => {
  if (Object.keys(flags).some((flag) => !allowed.includes(flag))) throw badRequest('flow_operation_invalid', FLOW_USAGE);
};
const listed = (flow) => ({ id: flow.id, state: flow.state, projectId: flow.projectId, requestId: flow.requestId, title: flow.request.title, size: flow.size,
  packages: flow.packages.map((item) => `${item.id}:${item.state}`), failure: flow.failure?.code ?? null, updatedAt: flow.updatedAt });
const waiting = (event) => ({ id: event.id, kind: event.kind, state: event.state, attempts: event.attempts, sessionId: event.sessionId ?? null,
  flowId: event.flowId ?? null, decisionId: event.decisionId ?? null, title: event.packet?.title ?? null, createdAt: event.createdAt });

function done(result) {
  console.log(JSON.stringify({ ok: true, data: result }));
  return 0;
}

function failed(error) {
  const known = Boolean(error.status);
  console.log(JSON.stringify({ ok: false, error: known ? error.code : 'flow_unavailable', ...(known ? { status: error.status, message: error.message } : {}),
    ...(known && error.details ? { details: error.details } : {}) }));
  return error.status === 404 ? 3 : error.status === 409 || error.status === 412 ? 4 : 1;
}

export async function flowCommand(positional, flags, { stateDir = resolveStateDir(), stdin = readStdin, post = monetPost } = {}) {
  const [command, target, extra] = positional;
  try {
    if (flags.help) { console.log(FLOW_USAGE); return 0; }
    if (extra !== undefined) throw badRequest('flow_operation_invalid', FLOW_USAGE);
    switch (command) {
      case 'start': {
        only(flags, ['file', 'json']);
        if (target !== undefined) throw badRequest('flow_operation_invalid', FLOW_USAGE);
        return done(await post('/v1/flows', await readObject(flags.file, stdin)));
      }
      case 'status': {
        only(flags, ['json']);
        if (!FLOW_ID.test(target ?? '')) throw badRequest('flow_operation_invalid', FLOW_USAGE);
        const flow = createFlowStore({ dir: stateDir }).get(target);
        if (!flow) throw notFound('flow not found');
        return done({ flow });
      }
      case 'list': {
        only(flags, ['state', 'project', 'open', 'json']);
        if (target !== undefined || (flags.state !== undefined && !FLOW_STATES.includes(flags.state))) throw badRequest('flow_operation_invalid', FLOW_USAGE);
        const items = createFlowStore({ dir: stateDir }).list({ state: flags.state ?? null, projectId: flags.project ?? null, open: flags.open === true });
        return done({ items: items.map(listed) });
      }
      case 'withdraw': {
        only(flags, ['with-requirements', 'json']);
        if (!FLOW_ID.test(target ?? '')) throw badRequest('flow_operation_invalid', FLOW_USAGE);
        return done(await post(`/v1/flows/${target}/withdraw`, { withRequirements: flags['with-requirements'] === true }));
      }
      default: throw badRequest('flow_operation_invalid', FLOW_USAGE);
    }
  } catch (error) { return failed(error); }
}

export async function monetCommand(positional, flags, { stateDir = resolveStateDir(), stdin = readStdin, post = monetPost } = {}) {
  const [command, target, extra] = positional;
  try {
    if (flags.help) { console.log(FLOW_USAGE); return 0; }
    if (extra !== undefined) throw badRequest('flow_operation_invalid', FLOW_USAGE);
    switch (command) {
      case 'inbox': {
        only(flags, ['claim', 'limit', 'json']);
        const limit = flags.limit === undefined ? 3 : Number(flags.limit);
        if (target !== undefined || !Number.isInteger(limit) || limit < 1 || limit > 20) throw badRequest('flow_operation_invalid', FLOW_USAGE);
        if (flags.claim) return done(await post('/v1/monet/inbox/claim', { limit }));
        const inbox = createMonetInbox({ dir: stateDir });
        const open = inbox.list({ handler: 'monet', limit: 500 }).filter((event) => ['new', 'claimed'].includes(event.state));
        return done({ counts: inbox.counts(), waiting: open.length, events: open.slice(0, flags.limit === undefined ? 20 : limit).map(waiting) });
      }
      case 'ack': {
        only(flags, ['verdict-file', 'json']);
        if (!EVENT_ID.test(target ?? '') || typeof flags['verdict-file'] !== 'string') throw badRequest('flow_operation_invalid', FLOW_USAGE);
        return done(await post(`/v1/monet/inbox/${target}/ack`, await readObject(flags['verdict-file'], stdin)));
      }
      case 'digest': {
        only(flags, ['json']);
        if (target !== undefined) throw badRequest('flow_operation_invalid', FLOW_USAGE);
        return done(await post('/v1/monet/digest', {}));
      }
      case 'replay': {
        only(flags, ['json']);
        if (!SESSION_ID_PATTERN.test(target ?? '')) throw badRequest('flow_operation_invalid', FLOW_USAGE);
        return done(await post('/v1/monet/inbox/replay', { sessionId: target }));
      }
      default: throw badRequest('flow_operation_invalid', FLOW_USAGE);
    }
  } catch (error) { return failed(error); }
}

// Monet's inbox: the one durable queue for everything Monet must react to —
// session returns and errors of every origin, decision-board answers, delegated
// findings and the requirement flow's own steps.
//
// It replaces four disjoint paths that each dropped events (a wake gate that
// saw only one origin, answers stored without an agent to deliver to, pushes
// that reached devices but never Monet). An event is offered once per `key`,
// leased to one verification turn at a time, and either acknowledged with a
// verdict or — after `maxAttempts` leases — marked failed so the caller raises
// a single decision-board item instead of looping.
//
// `handler` says who consumes an event:
//   monet    — claimed by Monet's verification turn (`claim` → `ack`)
//   pipeline — consumed by Bridge code (adviser returns, the flow's decisions)
//   digest   — recorded for the digest only; no turn is spent on it

import { randomBytes } from 'node:crypto';
import { join } from 'node:path';
import { createJsonFile } from '../routes/state-file.mjs';
import { BridgeError, conflict, notFound } from '../errors.mjs';

export const EVENT_ID = /^evt_[0-9a-f]{12}$/;
export const EVENT_KINDS = ['session.returned', 'session.error', 'session.stalled', 'decision.answered', 'decision.opened',
  'finding.delegated', 'engine.notice', 'flow.step'];
const HANDLERS = ['monet', 'pipeline', 'digest'];
const TERMINAL = ['acked', 'failed'];
const KEEP_TERMINAL = 400;
const KEEP_MS = 14 * 86400_000;

const idOrNull = (value, pattern) => (typeof value === 'string' && pattern.test(value) ? value : null);

export function createMonetInbox({ dir, now = () => Date.now(), leaseMs = 600_000, maxAttempts = 3 }) {
  const stamp = () => new Date(now()).toISOString();
  const file = createJsonFile({ file: join(dir, 'monet-inbox.json'), initial: () => ({ since: stamp(), events: [] }) });

  function access(fn) {
    try { return fn(); } catch (error) {
      if (error instanceof BridgeError) throw error;
      throw new BridgeError(503, 'monet_inbox_unavailable', 'Monet の受信箱を読み書きできません。', { retryable: true });
    }
  }
  function prune(doc) {
    const time = now();
    const terminal = doc.events.filter((event) => TERMINAL.includes(event.state)).sort((a, b) => b.at.localeCompare(a.at));
    const drop = new Set(terminal.filter((event, index) => index >= KEEP_TERMINAL || time - Date.parse(event.at) > KEEP_MS).map((event) => event.id));
    if (drop.size) doc.events = doc.events.filter((event) => !drop.has(event.id));
  }
  const read = () => access(() => { const doc = file.read(); doc.events ??= []; return doc; });
  const mutate = (fn) => access(() => file.mutate((doc) => { doc.events ??= []; doc.since ??= stamp(); const out = fn(doc); prune(doc); return structuredClone(out); }));
  function find(doc, id) {
    const event = doc.events.find((row) => row.id === id);
    if (!event) throw notFound('inbox event not found');
    return event;
  }
  const leaseOpen = (event) => event.state === 'claimed' && now() - Date.parse(event.claimedAt) < leaseMs;

  return {
    file: file.file,
    // Events older than this are history from before the inbox existed; scanners skip them.
    since: () => read().since ?? stamp(),
    // Idempotent per `key`: a second offer of the same fact returns the first event.
    offer(input) {
      if (!input || !EVENT_KINDS.includes(input.kind) || typeof input.key !== 'string' || !input.key || input.key.length > 300) {
        throw new BridgeError(400, 'monet_event_invalid', 'an inbox event needs a known kind and a key');
      }
      const handler = HANDLERS.includes(input.handler) ? input.handler : 'monet';
      return mutate((doc) => {
        const existing = doc.events.find((row) => row.key === input.key);
        if (existing) return { event: existing, created: false };
        const event = {
          id: `evt_${randomBytes(6).toString('hex')}`, kind: input.kind, key: input.key, at: stamp(), handler,
          flowId: idOrNull(input.flowId, /^flw_[0-9a-f]{12}$/), projectId: idOrNull(input.projectId, /^prj_[0-9a-f]{12}$/),
          requirementId: idOrNull(input.requirementId, /^req_[0-9a-f]{12}$/), packageId: typeof input.packageId === 'string' ? input.packageId.slice(0, 24) : null,
          sessionId: idOrNull(input.sessionId, /^ses_[0-9a-f]{6,40}$/), decisionId: idOrNull(input.decisionId, /^dec_[0-9a-f]{16}$/),
          findingId: idOrNull(input.findingId, /^fnd_[0-9a-f]{16}$/), origin: typeof input.origin === 'string' ? input.origin.slice(0, 40) : null,
          packet: input.packet && typeof input.packet === 'object' ? structuredClone(input.packet) : {},
          // A digest-only event is a record, not work: it is born acknowledged.
          state: handler === 'digest' ? 'acked' : 'new', claimedAt: null, attempts: 0, verdict: handler === 'digest' ? { verdict: 'noted', by: 'bridge' } : null,
          ackedAt: handler === 'digest' ? stamp() : null, error: null,
        };
        doc.events.push(event);
        return { event, created: true };
      });
    },
    // Lease up to `limit` events to one verification turn. An event whose lease
    // expired is offered again; after `maxAttempts` it fails and is returned in
    // `exhausted` exactly once so the caller can raise one decision-board item.
    claim({ limit = 3, handler = 'monet' } = {}) {
      const size = Math.min(Math.max(Number.isInteger(limit) ? limit : 3, 1), 10);
      return mutate((doc) => {
        const events = [], exhausted = [];
        for (const event of doc.events) {
          if (event.handler !== handler || !(event.state === 'new' || (event.state === 'claimed' && !leaseOpen(event)))) continue;
          if (event.attempts >= maxAttempts) {
            Object.assign(event, { state: 'failed', error: 'verification_unanswered', claimedAt: null, ackedAt: stamp() });
            exhausted.push(event);
            continue;
          }
          if (events.length >= size) continue;
          Object.assign(event, { state: 'claimed', claimedAt: stamp(), attempts: event.attempts + 1 });
          events.push(event);
        }
        return { events, exhausted };
      });
    },
    // Replaying the same verdict is a no-op; a different one on a closed event is refused.
    ack(id, verdict, { by = 'monet' } = {}) {
      return mutate((doc) => {
        const event = find(doc, id);
        const next = { ...verdict, by };
        if (event.state === 'acked') {
          if (JSON.stringify(event.verdict) === JSON.stringify(next)) return { event, replayed: true };
          throw conflict('monet_event_closed', 'the event already has a verdict');
        }
        if (event.state === 'failed') throw conflict('monet_event_closed', 'the event already failed; re-arm it first');
        Object.assign(event, { state: 'acked', verdict: next, ackedAt: stamp(), claimedAt: null, error: null });
        return { event, replayed: false };
      });
    },
    fail(id, code) {
      return mutate((doc) => {
        const event = find(doc, id);
        if (!TERMINAL.includes(event.state)) Object.assign(event, { state: 'failed', error: String(code).slice(0, 80), ackedAt: stamp(), claimedAt: null });
        return event;
      });
    },
    // Give a claimed event back without spending one of its attempts (the turn
    // could not start, or its verdict was refused and it may answer again).
    release(id, { refund = false } = {}) {
      return mutate((doc) => {
        const event = find(doc, id);
        if (event.state === 'claimed') Object.assign(event, { state: 'new', claimedAt: null, attempts: Math.max(0, event.attempts - (refund ? 1 : 0)) });
        return event;
      });
    },
    // A failed event the owner or Monet chose to look at again.
    rearm(id) {
      return mutate((doc) => {
        const event = find(doc, id);
        if (event.state === 'failed') Object.assign(event, { state: 'new', attempts: 0, error: null, ackedAt: null, claimedAt: null });
        return event;
      });
    },
    annotate(id, patch) {
      return mutate((doc) => {
        const event = find(doc, id);
        for (const key of ['flowId', 'projectId', 'requirementId', 'packageId', 'decisionId', 'handler']) if (patch[key] !== undefined) event[key] = patch[key];
        if (patch.packet) event.packet = { ...event.packet, ...structuredClone(patch.packet) };
        return event;
      });
    },
    get: (id) => structuredClone(find(read(), id)),
    list({ state = null, kind = null, handler = null, limit = 50 } = {}) {
      return structuredClone(read().events.filter((event) => (!state || event.state === state) && (!kind || event.kind === kind)
        && (!handler || event.handler === handler)).slice(-Math.min(Math.max(limit, 1), 500)));
    },
    counts() {
      const out = { new: 0, claimed: 0, acked: 0, failed: 0 };
      for (const event of read().events) out[event.state] = (out[event.state] ?? 0) + 1;
      return out;
    },
  };
}

const KIND_LABEL = { 'session.returned': '戻り', 'session.error': 'エラー', 'session.stalled': '停滞', 'decision.answered': '回答', 'decision.opened': '判断待ち',
  'finding.delegated': '気づき', 'engine.notice': '通知', 'flow.step': 'フロー' };
const FLOW_LABEL = { intake: '受付', expanding: '社員の検討', advising: '設計の助言', designed: '設計済み', dispatching: '実装へ派遣', verifying: '照合中',
  awaiting_decision: '判断待ち', reported: '報告済み', failed: '停止', withdrawn: '取下げ' };

// At most `limit` characters: the open flows by state and the newest events,
// so Monet's owner turn knows what came back without a tool call.
export function monetDigest({ events = [], flows = [], limit = 600 } = {}) {
  const open = flows.filter((flow) => !['reported', 'withdrawn'].includes(flow.state));
  const waiting = events.filter((event) => event.handler === 'monet' && ['new', 'claimed'].includes(event.state)).length;
  const failed = events.filter((event) => event.state === 'failed').length;
  const lines = [`受信箱: 未照合${waiting}件${failed ? `・照合できず${failed}件` : ''} / 進行中の要件フロー${open.length}件`];
  for (const flow of open.slice(-6)) {
    const packages = flow.packages ?? [];
    const done = packages.filter((item) => item.state === 'verified').length;
    lines.push(`- ${flow.id.slice(4, 10)} ${FLOW_LABEL[flow.state] ?? flow.state}${packages.length ? ` ${done}/${packages.length}` : ''}: ${[...String(flow.request?.title ?? '')].slice(0, 28).join('')}`);
  }
  for (const event of events.slice(-5).reverse()) {
    const verdict = event.verdict?.verdict ? `→${event.verdict.verdict}` : event.state === 'failed' ? '→照合できず' : '';
    lines.push(`· ${event.at.slice(5, 16).replace('T', ' ')} ${KIND_LABEL[event.kind] ?? event.kind}${verdict} ${[...String(event.packet?.title ?? '')].slice(0, 26).join('')}`.trimEnd());
  }
  let text = '';
  for (const line of lines) {
    if ([...text].length + [...line].length + 1 > limit) break;
    text += (text ? '\n' : '') + line;
  }
  return text;
}

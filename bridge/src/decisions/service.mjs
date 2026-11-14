import { daemonSessionID } from '../sessions/daemon.mjs';
import { notifyOwner } from '../notify/index.mjs';

// A busy conversation gets the answer when its turn ends. The wait is bounded:
// checked every 15 s for ten minutes, then every minute, for at most a day or
// 50 refused sends; Paseo may be unreachable for five minutes of that.
export const WAIT_LIMITS = Object.freeze({ fastMs: 15_000, fastForMs: 600_000, slowMs: 60_000, maxMs: 86_400_000, maxHolds: 50, unavailableMs: 300_000 });
export const isWaiting = (r) => r.status === 'answered' && r.delivery?.state === 'pending' && r.delivery.waitingSince !== undefined;

export function createDecisionService({ store, sessionStore = null, sessions = null, daemon = null, notify = notifyOwner,
  refs = null, observeRefs = null, now = () => Date.now(), limits = WAIT_LIMITS }) {
  const sessionRef = (id) => refs?.('session', id) ?? null;
  function view(record) {
    const { requestId, ...visible } = record;
    return { ...visible, ref: refs?.('decision', record.id) ?? record.ref, sourceRef: sessionRef(record.source.sessionId) };
  }
  const hasOpen = (session) => store.all().some((r) => r.status === 'open' &&
    (r.source.sessionId === session.id || (r.source.paseoAgentId && r.source.paseoAgentId === session.delegate?.sessionId)));
  let syncing;
  async function sync() {
    if (syncing) return syncing;
    syncing = (async () => {
      store.prune();
      // Number new decisions before announcing them, so the notice carries J….
      await observeRefs?.();
      for (let r of store.all()) {
        // An interrupted Bridge must not leave an accepted answer pending forever.
        // A waiting answer is not interrupted: `deliverWaiting` owns it.
        if (r.delivery?.state === 'pending' && !r.delivery.waiting && now() - Date.parse(r.updatedAt) > 60_000) r = store.settle(r.id, r.delivery.messageId, 'failed', 'delivery_unconfirmed');
        const key = r.status === 'open' ? 'new' : r.delivery?.state === 'failed' ? `failed:${r.delivery.attempts}` : null;
        if (!notify || !key || store.notificationDone(r.id, key)) continue;
        const failed = key.startsWith('failed:');
        const result = await notify({ kind: failed ? 'decision.failed' : 'decision.new', title: `${failed ? '届いていません' : '判断'}${refs?.('decision', r.id) ? ` ${refs('decision', r.id)}` : ''}: ${r.title}`,
          body: failed ? '回答を保存しました。判断ボードから再送してください。' : r.options.find((o) => o.recommended) ? `推奨: ${r.options.find((o) => o.recommended).label}` : r.summary.slice(0, 160),
          deepLink: `laa://work/decisions/${r.id}`, dedupeKey: `${r.id}:${key}` });
        // The existing notifier owns queued retries and durable deduplication.
        if (result?.reason !== 'invalid_notification') store.markNotification(r.id, key);
      }
    })().finally(() => { syncing = null; });
    return syncing;
  }
  async function list() {
    await sessions?.syncDaemon();
    await sync();
    const items = store.all().filter((r) => r.status === 'open' || (r.status === 'answered' && r.delivery?.state === 'failed') || isWaiting(r)).map((r) => ({ kind: 'board', ...view(r) }));
    for (const r of sessions ? sessionStore?.all() ?? [] : []) {
      // A conversation Paseo no longer holds has nobody left to answer.
      if (r.phase !== 'awaiting_decision' || r.archivedAt || r.daemonArchivedAt || r.daemonDeletedAt) continue;
      // Use the existing ticket/read path. Failure is surfaced, never converted
      // to a misleading empty board while Paseo is unavailable.
      const detail = await sessions.decision(r.id);
      const first = detail.requests?.[0];
      items.push({ kind: 'session', sessionId: r.id, ref: sessionRef(r.id), title: r.name,
        summary: first?.questions?.[0]?.question || first?.name || '判断待ち', kinds: r.pending?.kinds ?? [], createdAt: r.createdAt, deadline: null });
    }
    items.sort((a, b) => Number(b.delivery?.state === 'failed') - Number(a.delivery?.state === 'failed')
      || (a.deadline === null ? Infinity : Date.parse(a.deadline)) - (b.deadline === null ? Infinity : Date.parse(b.deadline))
      || Date.parse(b.createdAt) - Date.parse(a.createdAt));
    return { items, fetchedAt: new Date(now()).toISOString() };
  }
  const KNOWN = ['agent_archived', 'pending_decision_requires_reply', 'session_busy', 'paseo_unavailable', 'delivery_unconfirmed', 'not_found'];
  const failure = (e) => (KNOWN.includes(e.code ?? e.message) ? (e.code ?? e.message) : 'paseo_unavailable');
  async function deliver(record) {
    if (record.delivery.state !== 'pending' || record.delivery.waiting) return record;
    let error = null;
    try {
      if (!daemon) throw new Error('paseo_unavailable');
      const before = await daemon.status(record.source.paseoAgentId);
      if (before.archivedAt) throw new Error('agent_archived');
      if (before.pending?.length) throw new Error('pending_decision_requires_reply');
      const sentAt = now();
      const a = record.answer;
      const message = `【判断ボードの回答】${refs?.('decision', record.id) ?? record.ref ?? record.id}「${record.title}」\n選択: ${a.label}${a.note ? `\n補足: ${a.note}` : ''}\n（社長が判断ボードで選びました。この判断で作業を続けてください。）`;
      await daemon.send(record.source.paseoAgentId, { text: message, messageId: record.delivery.messageId });
      const after = await daemon.status(record.source.paseoAgentId);
      if (!after.activeTurn && after.daemonStatus !== 'running' && !(Date.parse(after.updatedAt) > sentAt && Date.parse(after.updatedAt) > Date.parse(before.updatedAt))) throw new Error('delivery_unconfirmed');
    } catch (e) {
      error = failure(e);
    }
    // `session_busy` is the daemon refusing a second foreground turn before it
    // accepted anything: the answer waits and the Bridge delivers it when that
    // turn ends, instead of asking the owner to resend (2026-11-13).
    if (error === 'session_busy' && (record.delivery.holds ?? 0) < limits.maxHolds) return store.hold(record.id, record.delivery.messageId);
    const updated = store.settle(record.id, record.delivery.messageId, error ? 'failed' : 'delivered', error === 'session_busy' ? 'delivery_wait_expired' : error);
    await sync();
    return updated;
  }
  const nextCheck = new Map(), unavailableSince = new Map();
  let delivering;
  // Called at startup and on a timer. One pass at a time; each waiting answer is
  // claimed in the store before its single send, so it is never sent twice.
  async function deliverWaiting() {
    if (delivering) return delivering;
    delivering = (async () => {
      store.requeueBusy();
      const waiting = store.all().filter((r) => isWaiting(r) && r.delivery.waiting);
      for (const key of nextCheck.keys()) if (!waiting.some((r) => r.delivery.messageId === key)) { nextCheck.delete(key); unavailableSince.delete(key); }
      let settled = false;
      for (const r of waiting) {
        const key = r.delivery.messageId, waited = now() - Date.parse(r.delivery.waitingSince);
        const fail = (error) => { const claimed = store.release(r.id, key); if (claimed) { store.settle(r.id, key, 'failed', error); settled = true; } };
        if (waited > limits.maxMs) { fail('delivery_wait_expired'); continue; }
        if (now() < (nextCheck.get(key) ?? 0)) continue;
        nextCheck.set(key, now() + (waited < limits.fastForMs ? limits.fastMs : limits.slowMs));
        let status;
        try {
          if (!daemon) throw new Error('paseo_unavailable');
          status = await daemon.status(r.source.paseoAgentId);
          unavailableSince.delete(key);
        } catch (e) {
          const error = failure(e);
          if (error === 'paseo_unavailable') {
            // A restarting Paseo is not a lost conversation; a stopped one is.
            if (!unavailableSince.has(key)) unavailableSince.set(key, now());
            if (now() - unavailableSince.get(key) >= limits.unavailableMs) fail(error);
          } else fail(error);
          continue;
        }
        if (status.archivedAt) { fail('agent_archived'); continue; }
        // Still working, or asking its own question: the turn has not ended.
        if (status.activeTurn || status.pending?.length || !['idle', 'closed', 'error'].includes(status.daemonStatus)) continue;
        const claimed = store.release(r.id, key);
        if (!claimed) continue;
        const result = await deliver(claimed);
        if (result.delivery?.state !== 'pending') settled = true;
      }
      if (settled) await sync();
    })().finally(() => { delivering = null; });
    return delivering;
  }
  return {
    view, hasOpen, sync, list, deliverWaiting,
    get: (id) => view(store.get(id)),
    add(body) {
      const agent = body.source?.paseoAgentId ?? null;
      const session = agent && sessionStore?.all().find((r) => r.delegate?.sessionId === agent);
      return store.add({ ...body, source: { paseoAgentId: agent, sessionId: session?.id ?? (agent ? daemonSessionID(agent) : null), name: body.source?.name ?? session?.name ?? null } });
    },
    withdraw: (id, reason) => view(store.withdraw(id, reason)),
    async answer({ id, deviceId, body, retry = false }) {
      const result = store.reserve(id, deviceId, body, retry);
      return { decision: view(result.replayed ? result.decision : await deliver(result.decision)) };
    },
  };
}

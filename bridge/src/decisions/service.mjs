import { daemonSessionID } from '../sessions/daemon.mjs';
import { notifyOwner } from '../notify/index.mjs';

export function createDecisionService({ store, sessionStore = null, sessions = null, daemon = null, notify = notifyOwner,
  refs = null, now = () => Date.now() }) {
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
      for (let r of store.all()) {
        // An interrupted Bridge must not leave an accepted answer pending forever.
        if (r.delivery?.state === 'pending' && now() - Date.parse(r.updatedAt) > 60_000) r = store.settle(r.id, r.delivery.messageId, 'failed', 'delivery_unconfirmed');
        const key = r.status === 'open' ? 'new' : r.delivery?.state === 'failed' ? `failed:${r.delivery.attempts}` : null;
        if (!notify || !key || store.notificationDone(r.id, key)) continue;
        const failed = key.startsWith('failed:');
        const result = await notify({ kind: failed ? 'decision.failed' : 'decision.new', title: `${failed ? '届いていません' : '判断'}: ${r.title}`,
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
    const items = store.all().filter((r) => r.status === 'open' || (r.status === 'answered' && r.delivery?.state === 'failed')).map((r) => ({ kind: 'board', ...view(r) }));
    for (const r of sessions ? sessionStore?.all() ?? [] : []) {
      if (r.phase !== 'awaiting_decision' || r.archivedAt || r.daemonArchivedAt) continue;
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
  async function deliver(record) {
    if (record.delivery.state !== 'pending') return record;
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
      const known = ['agent_archived', 'pending_decision_requires_reply', 'paseo_unavailable', 'delivery_unconfirmed', 'not_found'];
      error = known.includes(e.code ?? e.message) ? (e.code ?? e.message) : 'paseo_unavailable';
    }
    const updated = store.settle(record.id, record.delivery.messageId, error ? 'failed' : 'delivered', error);
    await sync();
    return updated;
  }
  return {
    view, hasOpen, sync, list,
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

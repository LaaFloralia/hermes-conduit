// Turns facts the Bridge already holds — a session's phase change, the decision
// board, the findings list — into Monet inbox events. Each builder is pure and
// keyed so that offering the same fact twice changes nothing; the decision and
// finding builders read the stores themselves, which also catches records the
// CLI wrote without going through the HTTP server.

// Where a session came from, as Monet needs to know it:
//   laa-bridge     — started through the Bridge (the Work tab, task dispatch, the requirement flow)
//   hermes-conduit — handed off by Monet or a staff Chat through the personal-agent wrapper
//   work           — started in the Work engine itself (laa-orchestrate, laa-work run, the desktop)
export function sessionOrigin(record, labels = null) {
  if (record?.delegate?.origin) return record.delegate.origin;
  if (labels?.['laa.personal_agent'] === 'worker') return 'hermes-conduit';
  return record?.source === 'paseo' ? 'work' : 'laa-bridge';
}

const stampOf = (record) => record.attentionTimestamp ?? record.sourceUpdatedAt ?? record.updatedAt ?? '';

// One event per finished turn or error of a root session, whatever its origin.
// Mirrors the owner push in sessions/service.mjs: children belong to their
// parent, routines and archived rows are not work in progress, and a session
// that is waiting on the decision board has not returned yet.
export function sessionEvent({ previous = null, current, child = false, labels = null, hasOpenDecision = false, reconciled = false }) {
  if (!current || current.archivedAt || current.daemonArchivedAt || current.daemonDeletedAt || current.routine) return null;
  if (child || current.parentId) return null;
  const phase = current.phase;
  const kind = phase === 'error' ? 'session.error'
    : phase === 'awaiting_review' && (reconciled || previous === 'running' || current.attentionReason === 'finished') ? 'session.returned' : null;
  if (!kind || (kind === 'session.returned' && hasOpenDecision)) return null;
  return {
    kind, key: `${current.id}:${kind}:${stampOf(current)}`, sessionId: current.id, projectId: current.projectId ?? null,
    origin: sessionOrigin(current, labels),
    packet: { title: String(current.name ?? '').slice(0, 120), phase, profile: current.profile ?? null },
  };
}

// Decision-board facts since the inbox began. `link(record)` lets the caller
// attach what it knows about a decision: `fields` (flowId, projectId…),
// `answered` — who consumes the answer ('pipeline' for a decision the flow
// raised) — and `skipOpen` for one that needs no turn while open. Without a
// link, an answer stored with no conversation to deliver it to goes to Monet
// (the drop the inbox exists to close) and a delivered one is digest-only.
export function decisionEvents(records, { since, link = () => null, offerOpen = true } = {}) {
  const from = Date.parse(since ?? 0) || 0;
  const events = [];
  for (const r of records) {
    const { fields = {}, answered = null, skipOpen = false } = link(r) ?? {};
    const base = { decisionId: r.id, sessionId: r.source?.sessionId ?? null, origin: r.source?.paseoAgentId ? 'work' : 'monet', ...fields };
    if (r.status === 'answered' && r.answer && r.delivery && Date.parse(r.answer.answeredAt) >= from) {
      events.push({ ...base, kind: 'decision.answered', key: `${r.id}:answer:${r.delivery.attempts}`,
        handler: answered ?? (r.delivery.state === 'stored' ? 'monet' : 'digest'),
        packet: { title: r.title, label: r.answer.label, note: r.answer.note ?? null, answeredBy: r.answer.answeredBy ?? 'owner',
          overturned: r.overturned === true, delivery: r.delivery.state, optionIndex: r.answer.optionIndex } });
    } else if (offerOpen && !skipOpen && r.status === 'open' && r.category === 'delegable' && Date.parse(r.createdAt) >= from) {
      // Monet answers these with the recommended option; the owner can overturn (AGENTS, 2026-11-28).
      events.push({ ...base, kind: 'decision.opened', key: `${r.id}:open`, handler: 'monet',
        packet: { title: r.title, summary: r.summary, options: r.options.map((o) => o.label), recommended: r.options.findIndex((o) => o.recommended), deadline: r.deadline } });
    }
  }
  return events;
}

// Findings the owner handed to Monet and nobody has picked up yet.
export function findingEvents(rows, { since } = {}) {
  const from = Date.parse(since ?? 0) || 0;
  return rows.filter((row) => row.status === 'delegated' && !row.pickup && Date.parse(row.delegatedAt) >= from).map((row) => ({
    kind: 'finding.delegated', key: `${row.id}:delegated`, findingId: row.id, sessionId: row.source?.sessionId ?? null, origin: 'owner', handler: 'monet',
    packet: { title: row.title, found: row.found ?? null, plan: row.plan ?? null, effort: row.effort ?? null },
  }));
}

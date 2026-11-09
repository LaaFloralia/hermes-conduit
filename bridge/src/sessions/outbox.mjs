// A follow-up the owner sends while the session is still working.
//
// Paseo runs one foreground turn per agent. Handing it a second prompt while the
// first is running makes the provider's "steer" fallback replace that turn, and
// for an agent without autonomous steering (the DSH/ACP provider) the provider
// refuses the start outright ("A foreground turn is already active"): the turn
// stops and the owner's text is gone (2026-11-09, session of the Dots run).
// So the Bridge never sends into a working agent. It records the message on the
// session and sends it once the turn has ended; waiting is acceptable, losing
// the owner's input is not.
//
// What is left here is the state shapes and the one decision that matters:
// whether an observed status may take a message now.

// A session carries at most this many unsent follow-ups; the owner can send
// past it only after one is delivered, which keeps a stuck queue visible.
export const MAX_QUEUED = 20;
// Attempts counted only for real send failures, not for "still working".
export const MAX_ATTEMPTS = 30;
// Delivered rows are kept briefly so a retried request with the same message id
// is recognised as already sent instead of being queued a second time.
export const KEEP_SENT = 3;

const IDLE_STATES = new Set(['idle', 'closed', 'error']);

export function outboxEntries(record) {
  return Array.isArray(record?.outbox) ? record.outbox : [];
}

export function queuedEntries(record) {
  return outboxEntries(record).filter((entry) => entry?.status === 'queued');
}

export function nextQueued(record) {
  return queuedEntries(record)[0] ?? null;
}

/// Paseo's own status is the authority, in both shapes the Bridge reads it:
/// the daemon snapshot (`activeTurn`, `pending`) and the delegation wrapper
/// (`daemonStatus`, `phase`). An unknown shape is "not yet": a message that
/// waits is recoverable, a turn that was replaced is not.
export function readiness(status) {
  if (!status || typeof status !== 'object') return 'unknown';
  if (status.activeTurn === true) return 'working';
  if (Array.isArray(status.pending) && status.pending.length > 0) return 'decision';
  const state = typeof status.daemonStatus === 'string' ? status.daemonStatus.toLowerCase() : '';
  if (state !== '') return IDLE_STATES.has(state) ? 'ready' : 'working';
  return status.phase === 'awaiting_review' ? 'ready' : 'unknown';
}

// Which model wrote which reply. Paseo's timeline carries no model per message,
// so the Bridge keeps what it observed instead: consecutive observations of one
// model form a span [from, to]. A reply is named only when its timestamp falls
// inside a span, that is, when the Bridge saw that model both before and after
// the reply. Older replies, and replies in a gap between two spans, get no name
// rather than a guessed one.
//
// Paseo refreshes a Claude session's runtime model at the start of a turn, so a
// switch the provider makes by itself mid-turn (Claude Code's
// `model_refusal_fallback`) is only seen at the next turn. When a change the
// owner did not ask for appears, the replies of the turn before it lose their
// name too: that turn may already have run on the new model.

const MAX_SPANS = 16;

const same = (a, b) => a?.provider === b?.provider && a?.model === b?.model;

/** Adds one observation at `at` (ISO). Returns a new list; the old is not changed. */
export function foldModelLog(log, observed, at) {
  const spans = Array.isArray(log) ? log.filter((span) => span && typeof span.model === 'string') : [];
  if (!observed || typeof observed.model !== 'string' || observed.model === '' || typeof at !== 'string') return spans;
  const last = spans.at(-1);
  if (last && same(last, observed)) {
    if (Date.parse(at) > Date.parse(last.to)) return [...spans.slice(0, -1), { ...last, to: at }];
    return spans;
  }
  const next = { provider: observed.provider ?? null, model: observed.model, from: at, to: at };
  return [...spans, next].slice(-MAX_SPANS);
}

/** Marks the newest span as the owner's own choice when it is on `model`. */
export function markOwnerChange(log, model) {
  const spans = Array.isArray(log) ? [...log] : [];
  const last = spans.at(-1);
  if (last && last.model === model) spans[spans.length - 1] = { ...last, owner: true };
  return spans;
}

/** The last change between two spans, for the detail's "requested → running". */
export function lastModelChange(log) {
  const spans = Array.isArray(log) ? log : [];
  if (spans.length < 2) return null;
  const [before, after] = spans.slice(-2);
  return {
    from: { provider: before.provider ?? null, model: before.model },
    to: { provider: after.provider ?? null, model: after.model },
    seenAt: after.from,
    byOwner: after.owner === true,
  };
}

/**
 * Adds `model: {provider, model}` to the assistant messages the log can vouch
 * for. Messages without a parsable timestamp, and every user or tool row, are
 * returned unchanged.
 */
export function attributeReplies(messages, log) {
  const spans = (Array.isArray(log) ? log : [])
    .map((span) => ({ ...span, start: Date.parse(span.from), end: Date.parse(span.to) }))
    .filter((span) => Number.isFinite(span.start) && Number.isFinite(span.end));
  if (spans.length === 0) return messages;
  const owner = messages
    .filter((message) => message.role === 'user')
    .map((message) => Date.parse(message.timestamp))
    .filter(Number.isFinite)
    .sort((a, b) => a - b);
  // Where a span's name cannot be trusted: from the start of the turn before
  // an unrequested change up to the moment the change was seen.
  const doubtful = [];
  for (let index = 1; index < spans.length; index += 1) {
    if (spans[index].owner === true) continue;
    const seen = spans[index].start;
    const before = owner.filter((time) => time <= seen);
    const start = before.length >= 2 ? before.at(-2) : -Infinity;
    doubtful.push([start, seen]);
  }
  return messages.map((message) => {
    if (message.role !== 'assistant') return message;
    const time = Date.parse(message.timestamp);
    if (!Number.isFinite(time)) return message;
    const span = spans.find((candidate) => candidate.start <= time && time <= candidate.end);
    if (!span) return message;
    if (doubtful.some(([start, end]) => start <= time && time < end)) return message;
    return { ...message, model: { provider: span.provider ?? null, model: span.model } };
  });
}

// Session records and their per-session event journal.
//
// Records and journal live in one JSON document so a phase change and the event
// that describes it commit together: a crash cannot leave an event for a change
// that was not stored (or the other way round). Events are kept for 24 hours
// (BRIDGE.md section 9). Sequence numbers keep counting after old events are
// pruned, so a cursor below `oldestSeq` is an explicit gap and never a silent
// "no new events".

import { createJsonFile } from '../routes/state-file.mjs';

export const SESSION_SCHEMA = 1;
export const SESSION_ID_PATTERN = /^ses_[0-9a-f]{16}$/;
export const EVENT_RETENTION_MS = 24 * 60 * 60 * 1000;

export function createSessionStore({
  file,
  now = () => Date.now(),
  retentionMs = EVENT_RETENTION_MS,
}) {
  const state = createJsonFile({
    file,
    schema: SESSION_SCHEMA,
    initial: () => ({ sessions: {}, streams: {} }),
  });

  function cutoff() {
    return now() - retentionMs;
  }

  // Pruning never removes a stream's lastSeq: a cursor issued before the prune
  // must still be recognisable as expired instead of looking like "new stream".
  function prune(doc) {
    const limit = cutoff();
    doc.sessions ??= {};
    doc.streams ??= {};
    for (const [id, stream] of Object.entries(doc.streams)) {
      const events = (stream.events ?? []).filter((event) => Date.parse(event.occurredAt) >= limit);
      stream.events = events;
      if (events.length === 0 && doc.sessions[id] === undefined) delete doc.streams[id];
    }
  }

  function readEvents(doc, id, { afterSeq = 0, limit = 100 } = {}) {
    prune(doc);
    const stream = doc.streams[id];
    const events = (stream?.events ?? []).filter((event) => event.seq > afterSeq);
    return {
      items: events.slice(0, limit),
      headSeq: stream?.lastSeq ?? 0,
      oldestSeq: events[0]?.seq ?? (stream?.lastSeq ?? 0) + 1,
    };
  }

  return {
    file,
    get(id) {
      const doc = state.read();
      return doc.sessions?.[id] ?? null;
    },
    all() {
      const doc = state.read();
      return Object.values(doc.sessions ?? {});
    },
    // Create a session and its first events atomically. Returns
    // `{record, created}`; a retried create for the same id returns the record
    // that already exists instead of producing a second session.
    create({ record, events = [] }) {
      return state.mutate((doc) => {
        prune(doc);
        const existing = doc.sessions?.[record.id];
        if (existing) return { record: existing, created: false };
        const stream = (doc.streams[record.id] ??= { lastSeq: 0, events: [] });
        doc.sessions[record.id] = record;
        for (const event of events) {
          const seq = ++stream.lastSeq;
          stream.events.push({
            seq,
            type: event.type,
            version: record.version ?? 1,
            occurredAt: new Date(now()).toISOString(),
            payload: event.payload ?? {},
          });
        }
        return { record, created: true };
      }, { tag: record.id });
    },
    // Apply an observation or an operation: `mutate(record)` may edit the
    // record in place and returns the events to append. Version increments once
    // per change set; unchanged observations only refresh `observedAt`.
    update(id, mutate) {
      return state.mutate((doc) => {
        prune(doc);
        const record = doc.sessions?.[id];
        if (!record) return null;
        const stream = (doc.streams[id] ??= { lastSeq: 0, events: [] });
        const events = mutate(record) ?? [];
        const appended = [];
        if (events.length > 0) {
          record.version = (record.version ?? 1) + 1;
          for (const event of events) {
            const seq = ++stream.lastSeq;
            const entry = {
              seq,
              type: event.type,
              version: record.version,
              occurredAt: new Date(now()).toISOString(),
              payload: event.payload ?? {},
            };
            stream.events.push(entry);
            appended.push(entry);
          }
        }
        record.updatedAt = new Date(now()).toISOString();
        return { record, events: appended };
      }, { tag: id });
    },
    // One atomic directory snapshot, rather than rewriting the complete file
    // once per agent. Directory input contains metadata only.
    importDirectory(rows) {
      return state.mutate((doc) => {
        prune(doc);
        const transitions = [];
        for (const row of rows) {
          const previous = doc.sessions[row.id];
          const current = previous ? { ...previous, ...row,
            // A sync that could not read Paseo's pin leaves the local choice
            // alone; only a known value replaces it.
            favorite: row.favorite === undefined ? previous.favorite === true : row.favorite === true,
            // Paseo decides: a session it brought back is back here too.
            archivedAt: previous.daemonArchivedAt && !row.daemonArchivedAt ? null : previous.archivedAt,
            // The agent is in Paseo's directory again, so an earlier "gone from
            // Paseo" mark no longer describes it.
            daemonDeletedAt: null,
            // A read without a feature list says nothing about Fast support.
            fastAvailable: row.fastAvailable === undefined ? previous.fastAvailable : row.fastAvailable,
            name: previous.nameSource === 'owner' ? previous.name : row.name,
            nameSource: previous.nameSource === 'owner' ? 'owner' : 'agent',
            requested: previous.requested ?? row.requested,
            delegate: previous.delegate ?? row.delegate,
            requestId: previous.requestId ?? row.requestId,
            source: previous.source ?? row.source,
            projectId: previous.projectId ?? row.projectId,
          } : row;
          if (previous?.stopRequestedAt) current.phase = previous.phase;
          const changed = previous && (previous.phase !== current.phase || previous.pending?.hash !== current.pending?.hash || (current.requiresAttention && previous.attentionTimestamp !== current.attentionTimestamp));
          const stream = (doc.streams[row.id] ??= { lastSeq: 0, events: [] });
          if (changed) {
            current.version = (previous.version ?? 1) + 1;
            stream.events.push({ seq: ++stream.lastSeq, type: 'session.phase', version: current.version,
              occurredAt: new Date(now()).toISOString(), payload: { phase: current.phase, previous: previous.phase } });
            transitions.push({ previous: previous.phase, current });
          }
          if (!previous && ['awaiting_decision', 'error'].includes(current.phase)) transitions.push({ previous: null, current });
          doc.sessions[row.id] = current;
        }
        return transitions;
      });
    },
    readEvents(id, options) {
      const doc = state.read();
      return readEvents(doc, id, options);
    },
    // One read for the three things a long-poll needs on arrival: the record,
    // the oldest sequence the journal still covers, and the page itself. The
    // 2.4 MB document is parsed once instead of once per field.
    eventPage(id, options) {
      const doc = state.read();
      const record = doc.sessions?.[id];
      if (!record) return null;
      return { record, ...readEvents(doc, id, options) };
    },
    // Announce every write to this file, tagged with the session id when the
    // store knows it (`null` for a directory sync, which can touch any).
    subscribe(listener) {
      return state.subscribe(listener);
    },
    // Journal-only read used by the log artifact: no write, same retention.
    allEvents(id) {
      const doc = state.read();
      prune(doc);
      return [...(doc.streams[id]?.events ?? [])];
    },
    headSeq(id) {
      return state.read().streams?.[id]?.lastSeq ?? 0;
    },
    oldestSeq(id) {
      const doc = state.read();
      prune(doc);
      const events = doc.streams?.[id]?.events ?? [];
      return events[0]?.seq ?? (doc.streams?.[id]?.lastSeq ?? 0) + 1;
    },
  };
}

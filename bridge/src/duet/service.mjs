import { randomUUID } from 'node:crypto';
import { join } from 'node:path';
import { conflict, markBeforeWrite } from '../errors.mjs';
import { createJsonFile } from '../routes/state-file.mjs';

const ITEM_LIMIT = 200;
const NOTE_LIMIT = 200;
const NOTE_RETRY_BATCH = 20;
const PERIOD = 5 * 60_000;
const newerFirst = (a, b) => b.createdAt.localeCompare(a.createdAt) || Number(b.id) - Number(a.id);

export function createDuetService({ dir, client = null, notify, now = Date.now, idleError = 'not_configured' }) {
  const file = createJsonFile({ file: join(dir, 'duet-items.json'), initial: () => ({
    cursor: '0', pending: [], ackPending: null, items: [], notes: [], lastPullAt: null, lastError: null,
  }) });
  let work = Promise.resolve(), activePoll;
  const enqueue = (run) => {
    const result = work.then(run);
    work = result.catch(() => {});
    return result;
  };
  // One indexed snapshot per pass; atomic checkpoints re-read through the
  // shared file helper (constant per batch, never once per row).
  const save = (snapshot) => file.mutate((doc) => Object.assign(doc, snapshot));

  async function settleItems(snapshot) {
    if (snapshot.pending.length > 0) {
      const delivery = await Promise.allSettled(snapshot.pending.map((item) => Promise.resolve().then(() => notify(item))));
      snapshot.pending = snapshot.pending.filter((_, i) => delivery[i].status === 'rejected');
      save(snapshot); // Persist notifier acceptance before sending a possibly ambiguous ACK.
      if (snapshot.pending.length) return 'notification_unavailable';
    }
    if (snapshot.ackPending === null) return null;
    try { await client.ack(snapshot.ackPending); } catch { return 'ack_failed'; }
    snapshot.ackPending = null;
    return null;
  }

  async function pullAndCommit(snapshot) {
    if (snapshot.ackPending !== null) {
      const error = await settleItems(snapshot);
      if (error) return error;
    }
    let incoming;
    try { incoming = await client.pull(snapshot.cursor); } catch { return 'pull_failed'; }
    snapshot.lastPullAt = new Date(now()).toISOString();
    const items = new Map(snapshot.items.map((item) => [item.id, item]));
    const after = Number(snapshot.cursor);
    let through = after;
    for (const item of incoming) {
      const seq = Number(item.id);
      if (seq <= after || items.has(item.id)) continue;
      through = Math.max(through, seq);
      snapshot.pending.push(item);
      items.set(item.id, item);
    }
    if (through === after) return null;
    snapshot.cursor = snapshot.ackPending = String(through);
    snapshot.items = [...items.values()].sort(newerFirst).slice(0, ITEM_LIMIT);
    save(snapshot);
    return settleItems(snapshot);
  }

  async function syncNotes(snapshot) {
    const queued = snapshot.notes.filter((note) => note.state === 'queued').slice(0, NOTE_RETRY_BATCH);
    const results = await Promise.allSettled(queued.map((note) => client.send(note)));
    results.forEach((result, i) => { if (result.status === 'fulfilled') queued[i].state = 'sent'; });
    const sent = snapshot.notes.filter((note) => note.state === 'sent');
    if (sent.length) {
      let read;
      try { read = await client.readStatus(); } catch { return 'notes_status_failed'; }
      for (const note of sent) if (read.has(note.id)) note.state = 'read';
    }
    return results.some((result) => result.status === 'rejected') ? 'notes_send_failed' : null;
  }

  const api = {
    listItems(limit) {
      const { items, lastPullAt, lastError } = file.read();
      return { items: items.slice(0, limit), status: { configured: !!client, lastPullAt, lastError: client ? lastError : idleError } };
    },
    listNotes() { return file.read().notes.slice().reverse(); },
    postNote(text) {
      return enqueue(async () => {
        const note = { id: randomUUID(), text, createdAt: new Date(now()).toISOString(), state: 'queued' };
        file.mutate(({ notes }) => {
          if (notes.length >= NOTE_LIMIT) {
            const expired = notes.findIndex((row) => row.state !== 'queued');
            if (expired === -1) throw markBeforeWrite(conflict('duet_notes_queue_full', 'Duet notes are waiting for delivery.'));
            notes.splice(expired, 1);
          }
          notes.push(note);
        });
        if (client) {
          try { await client.send(note); } catch { return { id: note.id, state: 'queued' }; }
          file.mutate(({ notes }) => { notes.find((row) => row.id === note.id).state = 'sent'; });
          note.state = 'sent';
        }
        return { id: note.id, state: note.state };
      });
    },
    poll() {
      if (!client) return Promise.resolve();
      if (!activePoll) activePoll = enqueue(async () => {
        const snapshot = file.read();
        const itemsError = await pullAndCommit(snapshot);
        snapshot.lastError = (await syncNotes(snapshot)) || itemsError;
        save(snapshot);
      }).finally(() => { activePoll = undefined; });
      return activePoll;
    },
    start() {
      if (!client) return () => {};
      const tick = () => { api.poll().catch(() => {}); };
      const timer = setInterval(tick, PERIOD);
      timer.unref();
      tick();
      return () => clearInterval(timer);
    },
  };
  return api;
}

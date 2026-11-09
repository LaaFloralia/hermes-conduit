// A session row shows two journal positions (headSeq, oldestSeq). They used to
// be read one row at a time, and each read parsed the whole sessions document
// (2.4 MB live, 1297 sessions): 50 rows cost ~2.5x the time of one, which is
// what made the list slow. `seqInfo` answers for a whole page from one read, so
// these pin that it answers exactly what the single-session reads did:
// a pruned stream still reports the gap, and an empty one reports 0/1.

import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { createSessionStore } from '../src/sessions/store.mjs';

const HOUR = 60 * 60 * 1000;
const ID_A = 'ses_aaaaaaaaaaaaaaaa';
const ID_B = 'ses_bbbbbbbbbbbbbbbb';
const ID_C = 'ses_cccccccccccccccc';

function fixture(t) {
  const dir = mkdtempSync(join(tmpdir(), 'laa-bridge-seq-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  let clock = Date.parse('2026-11-10T00:00:00.000Z');
  const now = () => clock;
  const store = createSessionStore({ file: join(dir, 'sessions.json'), now });
  const record = (id) => ({ id, name: id.slice(-4), phase: 'idle', createdAt: new Date(clock).toISOString() });
  // A keeps its events, B's events are all older than the 24-hour journal, C
  // never journaled anything.
  store.create({ record: record(ID_A), events: [{ type: 'session.created' }, { type: 'session.phase' }] });
  store.create({ record: record(ID_B), events: [{ type: 'session.created' }, { type: 'session.phase' }] });
  store.create({ record: record(ID_C), events: [] });
  clock += 23 * HOUR;
  // B's events age out; A gets one fresh event so it still has a head above B.
  store.update(ID_A, () => [{ type: 'session.phase' }]);
  return { store, ids: [ID_A, ID_B, ID_C], advance: (ms) => { clock += ms; }, now };
}

test('seqInfo answers for a page what the event page reports for each id', (t) => {
  const f = fixture(t);
  const info = f.store.seqInfo(f.ids);
  for (const id of f.ids) {
    // The long-poll's own one-read shape is the reference: a client must not
    // see a different head or gap in the list than it gets from /events.
    const page = f.store.readEvents(id, { afterSeq: 0, limit: 1 });
    assert.deepEqual(info.get(id), { lastSeq: page.headSeq, oldestSeq: page.oldestSeq }, id);
  }
  assert.deepEqual(info.get(ID_A), { lastSeq: 3, oldestSeq: 1 });
  assert.deepEqual(info.get(ID_C), { lastSeq: 0, oldestSeq: 1 });
});

test('a pruned stream is a gap in seqInfo too, not "no new events"', (t) => {
  const f = fixture(t);
  f.advance(2 * HOUR);
  // The open of the next read prunes B's journal; both shapes must agree that
  // a cursor at 1 is expired rather than current.
  assert.deepEqual(f.store.seqInfo([ID_B]).get(ID_B), { lastSeq: 2, oldestSeq: 3 });
  const page = f.store.readEvents(ID_B, { afterSeq: 0, limit: 1 });
  assert.deepEqual({ lastSeq: page.headSeq, oldestSeq: page.oldestSeq }, { lastSeq: 2, oldestSeq: 3 });
});

test('seqInfo tolerates an unknown id and an empty page', (t) => {
  const f = fixture(t);
  const ids = [ID_A, ID_B, ID_C];
  // A page of one id and a page of three agree on the shared row.
  const one = f.store.seqInfo([ID_A]);
  const many = f.store.seqInfo(ids);
  assert.deepEqual(many.get(ID_A), one.get(ID_A));
  // Ids the store does not know answer "empty journal" instead of throwing.
  assert.deepEqual(f.store.seqInfo(['ses_ffffffffffffffff']).get('ses_ffffffffffffffff'), { lastSeq: 0, oldestSeq: 1 });
  assert.equal(f.store.seqInfo([]).size, 0);
});

test('a session updated after seqInfo is read is not answered from the old page', (t) => {
  const f = fixture(t);
  const before = f.store.seqInfo([ID_A]).get(ID_A);
  f.advance(1000);
  f.store.update(ID_A, () => [{ type: 'session.phase' }]);
  const after = f.store.seqInfo([ID_A]).get(ID_A);
  assert.equal(after.lastSeq, before.lastSeq + 1);
});

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createMonetInbox, monetDigest } from '../src/monet/inbox.mjs';
import { decisionEvents, findingEvents, sessionEvent, sessionOrigin } from '../src/monet/events.mjs';
import { lastAssistantText, packetFor } from '../src/monet/evidence.mjs';

const T0 = Date.parse('2026-11-28T09:00:00.000Z');
function harness(t, options = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'monet-inbox-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const clock = { now: T0 };
  const make = () => createMonetInbox({ dir, now: () => clock.now, ...options });
  return { dir, clock, inbox: make(), reopen: make };
}
const returned = (n, extra = {}) => ({ kind: 'session.returned', key: `ses_${String(n).padStart(16, '0')}:session.returned:t${n}`,
  sessionId: `ses_${String(n).padStart(16, '0')}`, origin: 'laa-bridge', packet: { title: `作業${n}` }, ...extra });

test('one event per key, kept across a restart', (t) => {
  const h = harness(t);
  const first = h.inbox.offer(returned(1));
  assert.equal(first.created, true);
  assert.match(first.event.id, /^evt_[0-9a-f]{12}$/);
  assert.equal(first.event.state, 'new');
  assert.equal(h.inbox.offer(returned(1, { packet: { title: '別の文面' } })).created, false);
  const again = h.reopen();
  assert.equal(again.offer(returned(1)).event.id, first.event.id);
  assert.deepEqual(again.counts(), { new: 1, claimed: 0, acked: 0, failed: 0 });
  assert.throws(() => h.inbox.offer({ kind: 'session.exploded', key: 'k' }), /known kind/);
});

test('a claim leases an event to one turn; an expired lease is offered again', (t) => {
  const h = harness(t, { leaseMs: 600_000 });
  h.inbox.offer(returned(1));
  h.inbox.offer(returned(2));
  h.inbox.offer(returned(3, { handler: 'digest' }));
  h.inbox.offer(returned(4, { handler: 'pipeline' }));
  const first = h.inbox.claim({ limit: 5 });
  assert.deepEqual(first.events.map((event) => event.packet.title), ['作業1', '作業2']);
  assert.ok(first.events.every((event) => event.state === 'claimed' && event.attempts === 1));
  assert.deepEqual(h.inbox.claim({ limit: 5 }).events, []);
  h.clock.now += 600_001;
  assert.deepEqual(h.inbox.claim({ limit: 1 }).events.map((event) => [event.packet.title, event.attempts]), [['作業1', 2]]);
  // Digest-only events are records: born acknowledged, never claimed.
  assert.equal(h.inbox.list({ handler: 'digest' })[0].state, 'acked');
  assert.equal(h.inbox.claim({ handler: 'pipeline' }).events.length, 1);
});

test('an event nobody answers is offered three times, then fails and is reported exactly once', (t) => {
  const h = harness(t, { leaseMs: 1000, maxAttempts: 3 });
  const { event } = h.inbox.offer(returned(1));
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    const { events, exhausted } = h.inbox.claim();
    assert.equal(events[0].attempts, attempt);
    assert.deepEqual(exhausted, []);
    h.clock.now += 1001;
  }
  const last = h.inbox.claim();
  assert.deepEqual(last.events, []);
  assert.deepEqual(last.exhausted.map((row) => [row.id, row.state, row.error]), [[event.id, 'failed', 'verification_unanswered']]);
  assert.deepEqual(h.inbox.claim(), { events: [], exhausted: [] });
  // Re-armed by a decision, it is offered from the start again.
  assert.equal(h.inbox.rearm(event.id).state, 'new');
  assert.equal(h.inbox.claim().events[0].attempts, 1);
});

test('a verdict closes an event; the same verdict replays, a different one is refused', (t) => {
  const h = harness(t);
  const { event } = h.inbox.offer(returned(1));
  h.inbox.claim();
  const verdict = { verdict: 'verified', note: '実物を確認' };
  const acked = h.inbox.ack(event.id, verdict);
  assert.equal(acked.event.state, 'acked');
  assert.deepEqual(acked.event.verdict, { ...verdict, by: 'monet' });
  assert.equal(h.inbox.ack(event.id, verdict).replayed, true);
  assert.throws(() => h.inbox.ack(event.id, { verdict: 'rework' }), /already has a verdict/);
  assert.throws(() => h.inbox.ack('evt_ffffffffffff', verdict), /not found/);
  const other = h.inbox.offer(returned(2)).event;
  h.inbox.claim();
  assert.equal(h.inbox.release(other.id, { refund: true }).attempts, 0);
  assert.equal(h.inbox.fail(other.id, 'boom').state, 'failed');
  assert.throws(() => h.inbox.ack(other.id, verdict), /re-arm/);
});

test('session events: every origin, but not children, routines, archived rows or a session waiting on the board', () => {
  const row = (extra = {}) => ({ id: 'ses_00000000000000aa', name: 'Bridge｜件数', phase: 'awaiting_review', attentionTimestamp: '2026-11-28T09:00:00Z', projectId: 'prj_aaaaaaaaaaaa',
    delegate: { sessionId: 'agent-1' }, source: 'paseo', ...extra });
  const event = sessionEvent({ previous: 'running', current: row() });
  assert.equal(event.kind, 'session.returned');
  assert.equal(event.key, 'ses_00000000000000aa:session.returned:2026-11-28T09:00:00Z');
  assert.equal(event.origin, 'work');
  assert.equal(sessionEvent({ previous: 'running', current: row({ phase: 'error' }) }).kind, 'session.error');
  assert.equal(sessionEvent({ previous: 'awaiting_review', current: row({ attentionReason: 'finished' }) }).kind, 'session.returned');
  assert.equal(sessionEvent({ previous: 'awaiting_review', current: row() }), null);
  assert.equal(sessionEvent({ current: row(), reconciled: true }).kind, 'session.returned');
  assert.equal(sessionEvent({ previous: 'running', current: row({ phase: 'running' }) }), null);
  for (const skipped of [{ parentId: 'ses_00000000000000bb' }, { routine: 'nightly' }, { archivedAt: 'x' }, { daemonArchivedAt: 'x' }, { daemonDeletedAt: 'x' }]) {
    assert.equal(sessionEvent({ previous: 'running', current: row(skipped) }), null);
  }
  assert.equal(sessionEvent({ previous: 'running', current: row(), child: true }), null);
  assert.equal(sessionEvent({ previous: 'running', current: row(), hasOpenDecision: true }), null);
  assert.equal(sessionEvent({ previous: 'running', current: row({ phase: 'error' }), hasOpenDecision: true }).kind, 'session.error');
  assert.equal(sessionOrigin(row({ delegate: { origin: 'laa-bridge', sessionId: 'a' } })), 'laa-bridge');
  assert.equal(sessionOrigin(row(), { 'laa.personal_agent': 'worker' }), 'hermes-conduit');
  assert.equal(sessionOrigin(row({ source: 'bridge' })), 'laa-bridge');
});

test('decision and finding events: stored answers reach Monet, delivered ones are digest-only, history is skipped', () => {
  const since = '2026-11-28T09:00:00.000Z';
  const answered = (id, state, extra = {}) => ({ id: `dec_${id.repeat(16)}`, status: 'answered', title: `判断${id}`, summary: 's', category: 'delegable', createdAt: since,
    options: [{ label: '案A', recommended: true }, { label: '案B', recommended: false }], source: { paseoAgentId: state === 'stored' ? null : 'agent-1', sessionId: null },
    answer: { optionIndex: 0, label: '案A', note: null, answeredAt: '2026-11-28T09:05:00.000Z', answeredBy: 'owner' }, delivery: { state, attempts: 1 }, ...extra });
  const open = { ...answered('c', 'stored'), status: 'open', answer: null, delivery: null };
  const records = [answered('a', 'stored'), answered('b', 'delivered'), open, { ...open, id: `dec_${'d'.repeat(16)}`, category: 'owner' },
    answered('e', 'stored', { answer: { ...answered('e', 'stored').answer, answeredAt: '2026-11-27T00:00:00.000Z' } })];
  const events = decisionEvents(records, { since });
  assert.deepEqual(events.map((event) => [event.kind, event.handler, event.key]), [
    ['decision.answered', 'monet', `dec_${'a'.repeat(16)}:answer:1`], ['decision.answered', 'digest', `dec_${'b'.repeat(16)}:answer:1`], ['decision.opened', 'monet', `dec_${'c'.repeat(16)}:open`]]);
  const linked = decisionEvents(records, { since, link: (r) => (/^dec_[ac]+$/.test(r.id) ? { fields: { flowId: 'flw_000000000001' }, answered: 'pipeline', skipOpen: true } : null) });
  assert.deepEqual(linked.map((event) => [event.kind, event.handler, event.flowId ?? null]), [['decision.answered', 'pipeline', 'flw_000000000001'], ['decision.answered', 'digest', null]]);
  assert.equal(decisionEvents(records, { since, offerOpen: false }).some((event) => event.kind === 'decision.opened'), false);
  const findings = findingEvents([{ id: `fnd_${'1'.repeat(16)}`, status: 'delegated', pickup: null, delegatedAt: since, title: '気づき', found: 'f', plan: 'p', effort: 'small', source: { sessionId: null } },
    { id: `fnd_${'2'.repeat(16)}`, status: 'delegated', pickup: { at: since, plan: 'x' }, delegatedAt: since, title: '着手済み', source: {} },
    { id: `fnd_${'3'.repeat(16)}`, status: 'open', pickup: null, delegatedAt: null, title: '未委譲', source: {} }], { since });
  assert.deepEqual(findings.map((event) => [event.kind, event.key, event.packet.title]), [['finding.delegated', `fnd_${'1'.repeat(16)}:delegated`, '気づき']]);
});

test('evidence packet: the slip as fields, the tail of the last reply, the acceptance list', () => {
  const event = { id: 'evt_000000000001', kind: 'session.returned', packet: { title: 'Bridge｜件数' } };
  const reply = `${'前置き'.repeat(3000)}\nRESULT: done\nCHANGED: x.mjs — abc\nVERIFIED: node --test — pass\nRESIDUAL: none\nNEEDS_OWNER: none`;
  const packet = packetFor({ event, session: { id: 'ses_00000000000000aa', name: 'Bridge｜件数', phase: 'awaiting_review' },
    requirement: { id: 'req_000000000001', title: '件数を出す', status: 'in_progress', acceptance: [{ id: 'a1', text: '件数が出る', check: '開く', status: 'open', note: null }] },
    pkg: { id: 'wp1', title: 'Bridge｜件数', task: { completion: 'done' }, owns: [], rework: 1 }, lastMessage: reply });
  assert.equal(packet.claimedResult, 'done');
  assert.equal(packet.slip.VERIFIED, 'node --test — pass');
  assert.deepEqual(packet.acceptance, [{ id: 'a1', text: '件数が出る', check: '開く', status: 'open' }]);
  assert.equal([...packet.lastMessage].length, 6001);
  assert.ok(packet.lastMessage.endsWith('NEEDS_OWNER: none'));
  assert.equal(packet.package.rework, 1);
  assert.equal(packetFor({ event, unavailable: 'conversation_unavailable' }).slipPresent, false);
  assert.equal(lastAssistantText([{ role: 'assistant', text: '古い' }, { role: 'user', text: '直して' }, { role: 'assistant', text: '新しい' }, { role: 'user', text: 'x' }]), '新しい');
});

test('digest stays within 600 characters and names what is waiting', (t) => {
  const h = harness(t);
  for (let n = 1; n <= 12; n += 1) h.inbox.offer(returned(n, { packet: { title: `とても長い作業の名前とても長い作業の名前とても長い作業の名前${n}` } }));
  const flows = Array.from({ length: 9 }, (_, n) => ({ id: `flw_${String(n).padStart(12, '0')}`, state: n === 0 ? 'reported' : 'verifying', request: { title: `要件${n}`.repeat(20) },
    packages: [{ state: 'verified' }, { state: 'running' }] }));
  const text = monetDigest({ events: h.inbox.list({ limit: 40 }), flows });
  assert.ok([...text].length <= 600, String([...text].length));
  assert.match(text, /^受信箱: 未照合12件 \/ 進行中の要件フロー8件/);
  assert.match(text, /照合中 1\/2/);
  assert.equal(monetDigest({}), '受信箱: 未照合0件 / 進行中の要件フロー0件');
});

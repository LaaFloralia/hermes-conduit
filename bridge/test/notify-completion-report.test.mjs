import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createProjectStore } from '../src/routes/projects.mjs';
import { createOwnerNotifier } from '../src/notify/index.mjs';
import { createNotificationPreferences } from '../src/notify/preferences.mjs';
import { createCompletionReporter, evaluateCompletion, refuseAllCallers } from '../src/notify/completion-report.mjs';

const P1 = 'prj_aaaaaaaaaaaa', P2 = 'prj_bbbbbbbbbbbb';
const S1 = 'ses_1111111111111111', S2 = 'ses_2222222222222222', CHILD = 'ses_3333333333333333';
const SECRET = 'EVIDENCE-SECRET token=abc123 /Users/laa/private';
const iso = '2026-11-25T08:00:00.000Z';
const req = (id, requestId, extra = {}) => ({ id: `req_${id.padStart(12, '0')}`, title: `要件${id}`, details: SECRET, source: 'owner',
  status: 'completed', sessionIds: [S1], order: Number(id), updatedAt: iso, requestId,
  verifiedAt: iso, verifiedBy: 'monet', note: '成果物を照合して確認', evidence: SECRET, ...extra });

function harness({ requirements = {}, decisions = [], sessions = [], deliverFails = false } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'c3-report-'));
  const projects = createProjectStore({ file: join(dir, 'projects.json'), now: () => Date.parse(iso) });
  projects.mutate((all) => {
    all[P1] = { id: P1, name: '案件A', nameSource: 'owner', version: 1, createdAt: iso, updatedAt: iso, requirements: requirements[P1] ?? [] };
    all[P2] = { id: P2, name: '案件B', nameSource: 'owner', version: 1, createdAt: iso, updatedAt: iso, requirements: requirements[P2] ?? [] };
  });
  const sent = [];
  const deliver = async (event) => { if (deliverFails) return { delivered: false, reason: 'delivery_unavailable' }; sent.push(event); return { delivered: true }; };
  const file = join(dir, 'owner-notifications.json');
  const notify = createOwnerNotifier({ deliver, file, now: () => Date.parse(iso),
    preferences: createNotificationPreferences({ file: join(dir, 'notification-preferences.json'), now: () => Date.parse(iso) }) });
  const monet = (c) => (c === 'monet-token' ? { kind: 'monet' } : c === 'child-token' ? { kind: 'monet', parentId: S1 } : null);
  const make = (resolveCaller = monet) => createCompletionReporter({ notify, resolveCaller, readProject: (id) => projects.get(id),
    readOpenDecisions: () => decisions, readSessions: () => sessions });
  return { dir, sent, file, trigger: make(), make, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}
const go = (h, projectId, requestId, caller = 'monet-token') => h.trigger({ caller, projectId, requestId });

test('all verified → exactly one monet.report; replays are no-ops (also after restart)', async () => {
  const h = harness({ requirements: { [P1]: [req('1', 'r1'), req('2', 'r1')] } });
  try {
    const first = await go(h, P1, 'r1');
    assert.equal(first.sent, true); assert.equal(first.dedupeKey, `monet.report:${P1}:r1`);
    for (let i = 0; i < 3; i++) assert.deepEqual([(await go(h, P1, 'r1')).reason], ['duplicate']);
    const restarted = h.make(); // new reporter, same temp ledger
    assert.equal((await restarted({ caller: 'monet-token', projectId: P1, requestId: 'r1' })).reason, 'duplicate');
    assert.equal(h.sent.length, 1);
    assert.ok(JSON.parse(readFileSync(h.file, 'utf8')).reports, 'permanent report ledger written');
  } finally { h.cleanup(); }
});

test('two distinct requests → two reports, each once; other-request/other-project requirements ignored', async () => {
  const h = harness({ requirements: { [P1]: [req('1', 'r1'), req('2', 'r2'), req('3', 'r3', { status: 'in_progress', verifiedAt: undefined })],
    [P2]: [req('4', 'r1', { status: 'in_progress' })] } });
  try {
    assert.equal((await go(h, P1, 'r1')).sent, true);
    assert.equal((await go(h, P1, 'r2')).sent, true);
    assert.equal((await go(h, P1, 'r1')).reason, 'duplicate');
    assert.equal((await go(h, P2, 'r1')).reason, 'unverified'); // same requestId, other project: not proven
    assert.equal(h.sent.length, 2);
    assert.notEqual(h.sent[0].event_id, h.sent[1].event_id);
  } finally { h.cleanup(); }
});

test('one unverified among the request blocks; withdrawn unverified does not', async () => {
  const h = harness({ requirements: { [P1]: [req('1', 'r1'), req('2', 'r1', { verifiedBy: undefined })],
    [P2]: [req('3', 'r1'), req('4', 'r1', { status: 'not_started', verifiedAt: undefined, withdrawnAt: iso })] } });
  try {
    const r = await go(h, P1, 'r1');
    assert.equal(r.reason, 'unverified'); assert.deepEqual(r.unverified, ['req_000000000002']);
    assert.equal((await go(h, P2, 'r1')).sent, true);
    assert.equal(h.sent.length, 1);
  } finally { h.cleanup(); }
});

test('verification marker rules: note required ≤200, verifiedBy monet|ses_*, completed status, valid time', () => {
  const project = (r) => ({ id: P1, name: 'x', requirements: [r] });
  for (const bad of [{ note: '' }, { note: 'あ'.repeat(201) }, { verifiedBy: 'child' }, { verifiedBy: 'ses_bad' }, { verifiedAt: 'yesterday' }, { status: 'in_progress' }])
    assert.equal(evaluateCompletion({ project: project(req('1', 'r1', bad)), requestId: 'r1' }).reason, 'unverified', JSON.stringify(bad));
  assert.equal(evaluateCompletion({ project: project(req('1', 'r1', { verifiedBy: S2 })), requestId: 'r1' }).ready, true);
});

test('terminal session alone is not proof: completed status + archived/closed session without verification → no report', async () => {
  const h = harness({ requirements: { [P1]: [req('1', 'r1', { verifiedAt: undefined, verifiedBy: undefined, note: undefined })] },
    sessions: [{ id: S1, projectId: P1, phase: 'closed', archivedAt: iso }] });
  try { assert.equal((await go(h, P1, 'r1')).reason, 'unverified'); assert.equal(h.sent.length, 0); } finally { h.cleanup(); }
});

test('pending decision suppresses: requirement awaiting_decision, or open decision from a project session', async () => {
  const h1 = harness({ requirements: { [P1]: [req('1', 'r1'), req('2', 'r1', { status: 'awaiting_decision' })] } });
  const h2 = harness({ requirements: { [P1]: [req('1', 'r1')] }, sessions: [{ id: S2, projectId: P1 }],
    decisions: [{ id: 'dec_0000000000000001', status: 'open', source: { sessionId: S2 } }] });
  const h3 = harness({ requirements: { [P1]: [req('1', 'r1')] }, sessions: [{ id: S2, projectId: P2 }],
    decisions: [{ id: 'dec_0000000000000001', status: 'open', source: { sessionId: S2 } }, { id: 'dec_0000000000000002', status: 'answered', source: { sessionId: S1 } }] });
  try {
    assert.equal((await go(h1, P1, 'r1')).reason, 'decision_pending');
    assert.equal((await go(h2, P1, 'r1')).reason, 'decision_pending');
    assert.equal((await go(h3, P1, 'r1')).sent, true, 'other-project open / answered decisions do not suppress');
    assert.equal(h1.sent.length + h2.sent.length, 0);
  } finally { h1.cleanup(); h2.cleanup(); h3.cleanup(); }
});

test('unknown / empty / invalid inputs fail closed', async () => {
  const h = harness({ requirements: { [P1]: [req('1', 'r1')] } });
  try {
    assert.equal((await go(h, 'prj_cccccccccccc', 'r1')).reason, 'unknown_project');
    assert.equal((await go(h, 'nope', 'r1')).reason, 'unknown_project');
    assert.equal((await go(h, P2, 'r1')).reason, 'no_requirements'); // empty project
    assert.equal((await go(h, P1, 'r9')).reason, 'no_requirements'); // unknown request
    assert.equal((await go(h, P1, '')).reason, 'invalid_request');
    assert.equal((await go(h, P1, 'a b')).reason, 'invalid_request');
    assert.equal(h.sent.length, 0);
  } finally { h.cleanup(); }
});

test('unauthorized callers: none, unknown, child, default resolver, throwing resolver — no store read, no send', async () => {
  const h = harness({ requirements: { [P1]: [req('1', 'r1')] } });
  try {
    for (const c of [null, 'device-token', 'child-token']) assert.equal((await go(h, P1, 'r1', c)).reason, 'caller_unauthorized');
    let read = 0;
    const reporters = [refuseAllCallers, () => { throw new Error('x'); }, () => ({ kind: 'session' })].map((resolveCaller) =>
      createCompletionReporter({ notify: async () => { throw new Error('must not send'); }, resolveCaller, readProject: () => { read++; return null; } }));
    for (const t of reporters) assert.equal((await t({ caller: 'monet-token', projectId: P1, requestId: 'r1' })).reason, 'caller_unauthorized');
    assert.equal(read, 0); assert.equal(h.sent.length, 0);
  } finally { h.cleanup(); }
});

test('owner payload carries no evidence/details/note; only counts, project name, link', async () => {
  const h = harness({ requirements: { [P1]: [req('1', 'r1')] } });
  try {
    await go(h, P1, 'r1');
    const wire = JSON.stringify(h.sent);
    assert.ok(!wire.includes('EVIDENCE-SECRET') && !wire.includes('abc123') && !wire.includes('成果物を照合'));
    assert.equal(h.sent[0].title, 'Monetの報告');
    assert.match(h.sent[0].body, /^「案件A」の要件1件をすべて確認しました。$/);
  } finally { h.cleanup(); }
});

test('failed delivery is queued and not written to the permanent report ledger', async () => {
  const h = harness({ requirements: { [P1]: [req('1', 'r1')] }, deliverFails: true });
  try {
    const r = await go(h, P1, 'r1');
    assert.equal(r.sent, false); assert.equal(r.queued, true);
    assert.equal(JSON.parse(readFileSync(h.file, 'utf8')).reports, undefined);
  } finally { h.cleanup(); }
});

test('owner muting report → muted, nothing sent', async () => {
  const h = harness({ requirements: { [P1]: [req('1', 'r1')] } });
  try {
    createNotificationPreferences({ file: join(h.dir, 'notification-preferences.json') }).update({ kinds: { report: 'off' } });
    assert.equal((await go(h, P1, 'r1')).reason, 'muted'); assert.equal(h.sent.length, 0);
  } finally { h.cleanup(); }
});

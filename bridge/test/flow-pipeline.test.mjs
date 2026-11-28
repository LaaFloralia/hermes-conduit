// The requirement flow end to end with fake runners: real project, decision,
// flow and inbox stores in a throwaway directory; staff one-shots and Work
// sessions are stubs that record what they were asked.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createProjectStore } from '../src/routes/projects.mjs';
import { projectRequirements } from '../src/routes/project-requirements.mjs';
import { createDecisionStore } from '../src/decisions/store.mjs';
import { createDecisionService } from '../src/decisions/service.mjs';
import { createCompletionReporter } from '../src/notify/completion-report.mjs';
import { createMonetInbox } from '../src/monet/inbox.mjs';
import { loadFlowConfig } from '../src/flow/config.mjs';
import { createFlowPipeline } from '../src/flow/pipeline.mjs';
import { createFlowRequirements } from '../src/flow/requirements.mjs';
import { createFlowStore } from '../src/flow/store.mjs';

const P = 'prj_aaaaaaaaaaaa';
const T0 = Date.parse('2026-11-28T09:00:00.000Z');
const MONET = { kind: 'monet' };
const ROSTER = `roles:
  - id: cto
    name: Ada
    company: { seat: member, work: [implementation], lens: "実現性" }
  - id: cos
    name: Merlin
    company: { seat: member, work: [simple], lens: "順番" }
  - id: cfo
    name: Morgan
    company: { seat: member, work: [judgment], lens: "費用" }
    confidential: true
`;
const SLIP = 'RESULT: done\nCHANGED: bridge/src/x.mjs — abc1234\nVERIFIED: node --test — 3 pass\nRESIDUAL: none\nNEEDS_OWNER: none';
const designReply = (over = {}) => `設計しました。\n\`\`\`json\n${JSON.stringify({ schema: 'laa.design.v1', summary: '件数を一覧に出す',
  requirements: [{ title: '件数を出す', details: '一覧の見出しに件数', acceptance: [{ id: 'a1', text: '見出しに件数が出る', check: '一覧を開く' }, { id: 'a2', text: 'テストが通る', check: 'node --test' }] }],
  packages: [
    { id: 'wp1', requirement: 0, title: 'Bridge｜件数を返す', profile: 'opus-medium', repo: '/Users/laa/dev/hermes-conduit', owns: ['bridge/src/x.mjs'], after: [], purpose: 'p1', completion: 'c1', scope: 's1', prompt: 'do wp1' },
    { id: 'wp2', requirement: 0, title: 'アプリ｜件数を表示', profile: 'swe-high', repo: null, owns: ['Conduit/x.swift'], after: ['wp1'], purpose: 'p2', completion: 'c2', scope: 's2', prompt: 'do wp2' },
  ], risks: [], ownerDecisions: [], ...over })}\n\`\`\``;

function harness(t, { config: over = {}, staff = null, reporterFails = false } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'flow-pipeline-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const clock = { now: T0 };
  const now = () => clock.now;
  const iso = () => new Date(clock.now).toISOString();
  writeFileSync(join(dir, 'roster.yaml'), ROSTER);
  writeFileSync(join(dir, 'override.json'), JSON.stringify({ retryMs: 0, staff: { rosterFile: join(dir, 'roster.yaml') }, ...over }));
  const config = () => loadFlowConfig({ file: join(dir, 'override.json') });
  assert.deepEqual(config().problems, []);
  const projects = createProjectStore({ file: join(dir, 'projects.json'), now });
  projects.mutate((all) => { all[P] = { id: P, name: '案件A', nameSource: 'owner', version: 1, createdAt: iso(), updatedAt: iso(), requirements: [] }; });
  const rows = new Map();
  const sessionStore = { get: (id) => (rows.has(id) ? structuredClone(rows.get(id)) : null), all: () => [...rows.values()].map((row) => structuredClone(row)) };
  const decisionStore = createDecisionStore({ dir, now });
  const decisions = createDecisionService({ store: decisionStore, sessionStore, notify: null, now });
  const inbox = createMonetInbox({ dir, now, leaseMs: config().inbox.leaseMs, maxAttempts: config().inbox.maxAttempts });
  const flows = createFlowStore({ dir, now });
  const requirements = createFlowRequirements({ projects, now });
  const calls = { staff: [], start: [], send: [], stop: [], reports: [] };
  const replies = new Map();
  const failStart = new Map();
  const runners = {
    async runStaff({ member, prompt }) {
      calls.staff.push({ role: member.role, prompt });
      return staff ? staff(member) : { state: 'done', ms: 5, position: 'go', evidence: '', risk: `${member.role}のリスク`, alternative: 'none', ask: 'none', scope: `${member.role}の範囲`, acceptance: [`${member.role}が確認できる`] };
    },
    async startSession(input) {
      calls.start.push(structuredClone(input));
      const code = failStart.get(input.profile) ?? failStart.get(input.requestId);
      if (code) { const error = new Error(code); error.message = code; throw error; }
      const id = `ses_${createHash('sha256').update(input.requestId).digest('hex').slice(0, 16)}`;
      const created = !rows.has(id);
      if (created) rows.set(id, { id, name: input.name, phase: 'running', projectId: input.projectId, profile: input.profile, delegate: { origin: 'laa-bridge', sessionId: `agent-${id}` }, attentionTimestamp: null });
      return { sessionId: id, created };
    },
    async lastReply(id) { return replies.get(id) ?? ''; },
    async send(input) { calls.send.push(input); return { queued: false }; },
    async stop(id) { calls.stop.push(id); },
  };
  const reporter = createCompletionReporter({ resolveCaller: (c) => (c === MONET ? MONET : null), readProject: (id) => projects.get(id),
    readOpenDecisions: () => decisionStore.all(), readSessions: () => sessionStore.all(),
    notify: async (event) => { if (reporterFails) return { delivered: false, reason: 'delivery_unavailable' };
      if (calls.reports.some((sent) => sent.dedupeKey === event.dedupeKey)) return { delivered: false, reason: 'duplicate' };
      calls.reports.push(event); return { delivered: true }; } });
  const make = () => createFlowPipeline({ flows, inbox, requirements, projects, sessionStore, decisionStore, decisions, runners, config, reporter, now });
  const pipeline = make();
  // A Work session ends its turn: the row changes and the session service reports the transition.
  const returns = (sessionId, text, { phase = 'awaiting_review', through = pipeline } = {}) => {
    clock.now += 1000;
    const row = rows.get(sessionId);
    Object.assign(row, { phase, attentionTimestamp: iso() });
    replies.set(sessionId, text);
    return through.onTransition({ previous: 'running', current: structuredClone(row) });
  };
  const settle = async (through = pipeline) => { await through.idle(); await through.tick(); await through.idle(); };
  return { dir, clock, config, projects, rows, decisionStore, decisions, inbox, flows, requirements, calls, replies, failStart, pipeline, make, returns, settle,
    requirementsOf: () => projectRequirements(projects.get(P)),
    start: (body = {}, through = pipeline) => through.start({ projectId: P, requestId: 'r1', title: 'Work一覧に件数を出す', details: 'アプリの一覧の見出しに件数', size: 'S', ...body }) };
}
const verified = (ids, note = '実物と照合して確認') => ({ verdict: 'verified', note, acceptance: ids.map((id) => ({ id, status: 'passed', note: '確認済み' })) });

test('S without risk: staff expand, no adviser, one session, verified, one report', async (t) => {
  const h = harness(t);
  const { flow, created } = await h.start();
  assert.equal(created, true);
  assert.match(flow.id, /^flw_[0-9a-f]{12}$/);
  const [requirement] = h.requirementsOf();
  assert.equal(requirement.title, 'Work一覧に件数を出す');
  assert.equal(requirement.source, 'owner');
  assert.equal(requirement.flowId, flow.id);
  assert.equal(requirement.requestId, 'r1');
  assert.deepEqual(flow.requirementIds, [requirement.id]);

  await h.settle();
  assert.deepEqual(h.calls.staff.map((call) => call.role), ['cto', 'cos']);
  let current = h.flows.get(flow.id);
  assert.deepEqual(current.staff.map((row) => [row.role, row.state]), [['cto', 'done'], ['cos', 'done']]);
  assert.deepEqual(current.advisor, { profile: null, sessionId: null, state: 'skipped', reason: 'size_S' });
  // Each consulted role contributed scope, risk and acceptance; the acceptance became the requirement's.
  assert.equal(current.staff[0].scope, 'ctoの範囲');
  assert.deepEqual(h.requirementsOf()[0].acceptance.map((item) => [item.id, item.text, item.status]), [['a1', 'ctoが確認できる', 'open'], ['a2', 'cosが確認できる', 'open']]);
  assert.deepEqual(h.requirementsOf()[0].design.staff, ['cto', 'cos']);
  assert.equal(h.requirementsOf()[0].design.advisedBy, null);

  await h.settle();
  current = h.flows.get(flow.id);
  assert.equal(current.state, 'verifying');
  assert.equal(h.calls.start.length, 1);
  const [launch] = h.calls.start;
  assert.equal(launch.requestId, `${flow.id}:wp1`);
  assert.equal(launch.profile, 'opus-medium');
  assert.equal(launch.requirementId, requirement.id);
  assert.match(launch.name, /^実装｜/);
  for (const part of ['TASK:', 'OWNED FILES', 'DONE CONDITION:', 'ACCEPTANCE ITEMS', 'VERIFICATION YOU MUST RUN', 'RESULT: done | partial | blocked', 'ctoが確認できる']) assert.ok(launch.task.prompt.includes(part), part);
  for (const field of ['purpose', 'completion', 'scope', 'returnTo']) assert.ok(launch.task[field], field);

  // Re-entrancy: more ticks do not start a second session.
  await h.settle(); await h.settle();
  assert.equal(h.calls.start.length, 1);

  const sessionId = current.packages[0].sessionId;
  const event = h.returns(sessionId, `実装しました。\n${SLIP}`);
  assert.equal(event.kind, 'session.returned');
  assert.equal(event.handler, 'monet');
  assert.equal(event.flowId, flow.id);
  assert.equal(h.flows.get(flow.id).packages[0].state, 'returned');

  const claimed = await h.pipeline.claim({ caller: MONET });
  assert.equal(claimed.events.length, 1);
  const [turn] = claimed.events;
  assert.equal(turn.packet.claimedResult, 'done');
  assert.equal(turn.packet.slip.CHANGED, 'bridge/src/x.mjs — abc1234');
  assert.deepEqual(turn.packet.acceptance.map((item) => item.id), ['a1', 'a2']);
  assert.ok(turn.prompt.includes(`laa-bridge monet ack ${turn.id} --verdict-file`));

  // A verdict that leaves an item open cannot complete the requirement.
  await assert.rejects(h.pipeline.applyVerdict(turn.id, verified(['a1']), { caller: MONET }), (error) => error.code === 'acceptance_open');
  assert.equal(h.requirementsOf()[0].status, 'in_progress');
  await assert.rejects(h.pipeline.applyVerdict(turn.id, verified(['a1', 'zz']), { caller: MONET }), (error) => error.code === 'verdict_acceptance_unknown');
  await assert.rejects(h.pipeline.applyVerdict(turn.id, { verdict: 'verified', note: 'checked it' }, { caller: MONET }), (error) => error.code === 'owner_surface_language');

  const applied = await h.pipeline.applyVerdict(turn.id, { ...verified(['a1', 'a2']), report: { result: '件数を出した', verification: 'テスト3件', residual: 'なし' } }, { caller: MONET });
  assert.equal(applied.requirement, 'completed');
  assert.deepEqual(applied.reports, [{ flowId: flow.id, reported: true, reason: null }]);
  const done = h.requirementsOf()[0];
  assert.equal(done.status, 'completed');
  assert.equal(done.verifiedBy, 'monet');
  assert.equal(done.note, '実物と照合して確認');
  assert.ok(done.acceptance.every((item) => item.status === 'passed' && item.checkedAt));
  current = h.flows.get(flow.id);
  assert.equal(current.state, 'reported');
  assert.deepEqual(current.report, { result: '件数を出した', verification: 'テスト3件', residual: 'なし' });
  assert.equal(h.calls.reports.length, 1);
  assert.equal(h.calls.reports[0].dedupeKey, `monet.report:${P}:r1`);

  // Replays change nothing: the same verdict, more ticks, another claim.
  assert.equal((await h.pipeline.applyVerdict(turn.id, verified(['a1', 'a2']), { caller: MONET })).replayed, true);
  await h.settle();
  assert.deepEqual((await h.pipeline.claim({ caller: MONET })).events, []);
  assert.equal(h.calls.reports.length, 1);
  assert.equal(h.calls.start.length, 1);
  assert.deepEqual(current.steps.map((step) => step.state), ['intake', 'expanding', 'designed', 'dispatching', 'verifying', 'reported']);
});

test('the same request starts one flow; a different title under its requestId is refused', async (t) => {
  const h = harness(t);
  const first = await h.start({ dryStaff: true });
  const second = await h.start({ dryStaff: true });
  assert.equal(second.created, false);
  assert.equal(second.flow.id, first.flow.id);
  assert.equal(h.requirementsOf().length, 1);
  await assert.rejects(h.start({ title: '別の要件' }), (error) => error.code === 'flow_request_conflict');
  await assert.rejects(h.start({ requestId: 'r2', title: 'english only' }), (error) => error.code === 'owner_surface_language');
  await assert.rejects(h.start({ requestId: 'r2', size: 'XL' }), (error) => error.code === 'flow_invalid');
  await assert.rejects(h.start({ requestId: 'r2', risk: ['fun'] }), (error) => error.code === 'flow_invalid');
  await assert.rejects(h.start({ requestId: 'r2', repo: '/etc/passwd' }), (error) => error.code === 'flow_invalid');
  await assert.rejects(h.pipeline.start({ projectId: 'prj_bbbbbbbbbbbb', requestId: 'r2', title: '要件' }), (error) => error.status === 404);
});

test('M: Mythos advises in a session, the design becomes requirements and briefs, packages run in order', async (t) => {
  const h = harness(t);
  const { flow } = await h.start({ size: 'M', risk: ['money'] });
  await h.settle();
  // The confidential role is consulted on the title only.
  const cfo = h.calls.staff.find((call) => call.role === 'cfo');
  assert.ok(cfo && !cfo.prompt.includes('一覧の見出しに件数') && cfo.prompt.includes('Work一覧に件数を出す'));
  let current = h.flows.get(flow.id);
  assert.equal(current.state, 'advising');
  await h.settle();
  current = h.flows.get(flow.id);
  assert.equal(current.advisor.state, 'running');
  const advise = h.calls.start.at(-1);
  assert.equal(advise.profile, 'mythos-high');
  assert.equal(advise.requestId, `${flow.id}:advise`);
  assert.match(advise.name, /^設計｜/);
  assert.ok(advise.task.prompt.includes('STAFF CONTRIBUTIONS') && advise.task.prompt.includes('ctoのリスク') && advise.task.prompt.includes('laa.design.v1'));

  // The adviser's return is consumed by the pipeline, not by a Monet turn.
  const event = h.returns(current.advisor.sessionId, designReply());
  assert.equal(event.handler, 'pipeline');
  await h.settle();
  current = h.flows.get(flow.id);
  assert.equal(current.advisor.state, 'done');
  assert.equal(h.inbox.get(event.id).state, 'acked');
  assert.deepEqual((await h.pipeline.claim({ caller: MONET })).events, []);
  const [requirement] = h.requirementsOf();
  assert.equal(requirement.title, 'Work一覧に件数を出す');
  assert.equal(requirement.details, '一覧の見出しに件数');
  assert.deepEqual(requirement.acceptance.map((item) => item.id), ['a1', 'a2']);
  assert.equal(requirement.design.advisedBy, 'mythos-high');
  // A Devin profile named by the design falls back to the configured parent.
  assert.deepEqual(current.packages.map((item) => [item.id, item.profile, item.requestedProfile, item.state]), [['wp1', 'opus-medium', 'opus-medium', 'running'], ['wp2', 'opus-medium', 'swe-high', 'waiting']]);
  assert.equal(current.state, 'dispatching');

  // wp2 waits for wp1's verdict.
  await h.settle(); await h.settle();
  assert.deepEqual(h.calls.start.map((call) => call.requestId), [`${flow.id}:advise`, `${flow.id}:wp1`]);
  h.returns(current.packages[0].sessionId, SLIP);
  let [turn] = (await h.pipeline.claim({ caller: MONET })).events;
  const first = await h.pipeline.applyVerdict(turn.id, verified(['a1'], 'Bridge側を確認'), { caller: MONET });
  assert.equal(first.requirement, 'in_progress');
  assert.deepEqual(h.requirementsOf()[0].acceptance.map((item) => item.status), ['passed', 'open']);
  await h.settle();
  current = h.flows.get(flow.id);
  assert.deepEqual(current.packages.map((item) => item.state), ['verified', 'running']);
  assert.equal(current.state, 'verifying');
  assert.ok(h.calls.start.at(-1).task.prompt.includes('Depends on packages already verified: wp1'));

  h.returns(current.packages[1].sessionId, SLIP);
  [turn] = (await h.pipeline.claim({ caller: MONET })).events;
  const last = await h.pipeline.applyVerdict(turn.id, verified(['a2'], 'アプリ側を確認'), { caller: MONET });
  assert.equal(last.requirement, 'completed');
  assert.equal(h.flows.get(flow.id).state, 'reported');
  assert.equal(h.calls.reports.length, 1);
});

test('an unusable design gets one repair; a second one stops the flow and tells Monet once', async (t) => {
  const h = harness(t);
  const { flow } = await h.start({ size: 'L' });
  await h.settle(); await h.settle();
  const sessionId = h.flows.get(flow.id).advisor.sessionId;
  h.returns(sessionId, '設計は口頭で説明します。');
  await h.settle();
  assert.equal(h.flows.get(flow.id).state, 'advising');
  assert.equal(h.calls.send.length, 1);
  assert.equal(h.calls.send[0].messageId, `${flow.id}:advise:repair`);
  assert.match(h.calls.send[0].text, /design_block_missing/);
  // Owner-facing text must be Japanese: an English acceptance item is a second unusable reply.
  h.returns(sessionId, designReply({ requirements: [{ title: '件数', acceptance: [{ id: 'a1', text: 'the count is shown' }] }] }));
  await h.settle();
  const failed = h.flows.get(flow.id);
  assert.equal(failed.state, 'failed');
  assert.equal(failed.failure.step, 'design');
  assert.equal(h.calls.send.length, 1);
  const notices = h.inbox.list({ kind: 'flow.step' });
  assert.deepEqual(notices.map((event) => [event.key, event.handler, event.packet.state]), [[`${flow.id}:failed`, 'monet', 'failed']]);
  await h.settle(); await h.settle();
  assert.equal(h.inbox.list({ kind: 'flow.step' }).length, 1);
  assert.equal(h.calls.start.length, 1);
});

test('a step that fails twice with the same error stops; a different error starts the count again', async (t) => {
  const h = harness(t);
  const { flow } = await h.start({ dryStaff: true });
  await h.settle();
  h.failStart.set(`${flow.id}:wp1`, 'delegation_busy');
  await h.settle();
  let current = h.flows.get(flow.id);
  assert.equal(current.state, 'dispatching');
  assert.deepEqual([current.failure.step, current.failure.code, current.failure.count], ['dispatch:wp1', 'delegation_busy', 1]);
  h.failStart.set(`${flow.id}:wp1`, 'delegation_timeout');
  await h.settle();
  current = h.flows.get(flow.id);
  assert.deepEqual([current.state, current.failure.code, current.failure.count], ['dispatching', 'delegation_timeout', 1]);
  await h.settle();
  current = h.flows.get(flow.id);
  assert.equal(current.state, 'failed');
  assert.equal(current.failure.count, 2);
  assert.equal(h.inbox.list({ kind: 'flow.step' }).length, 1);
  const attempts = h.calls.start.length;
  await h.settle(); await h.settle();
  assert.equal(h.calls.start.length, attempts);
});

test('an adviser that cannot take a session: the next enabled one is used; Neon stays off until it is switched on', async (t) => {
  const withFallback = harness(t, { config: { advisorProfiles: [{ profile: 'mythos-high', enabled: true }, { profile: 'neon-high', enabled: false, reason: 'waiting for contract' }, { profile: 'opus-high', enabled: true }] } });
  withFallback.failStart.set('mythos-high', 'model_choice_invalid');
  const { flow } = await withFallback.start({ size: 'M', dryStaff: true });
  await withFallback.settle(); await withFallback.settle(); await withFallback.settle();
  assert.deepEqual(withFallback.calls.start.map((call) => [call.profile, call.requestId]), [['mythos-high', `${flow.id}:advise`], ['opus-high', `${flow.id}:advise:1`]]);
  assert.equal(withFallback.flows.get(flow.id).advisor.profile, 'opus-high');
  assert.ok(!withFallback.calls.start.some((call) => call.profile === 'neon-high'));

  const alone = harness(t);
  alone.failStart.set('mythos-high', 'model_choice_invalid');
  const lone = await alone.start({ size: 'M', dryStaff: true });
  await alone.settle(); await alone.settle();
  assert.equal(alone.flows.get(lone.flow.id).state, 'failed');
  assert.deepEqual(alone.calls.start.map((call) => call.profile), ['mythos-high']);
});

test('rework goes back to the same session, twice at most; then it is a board item', async (t) => {
  const h = harness(t);
  const { flow } = await h.start({ dryStaff: true });
  await h.settle(); await h.settle();
  const sessionId = h.flows.get(flow.id).packages[0].sessionId;
  for (let round = 1; round <= 2; round += 1) {
    h.returns(sessionId, SLIP);
    const [turn] = (await h.pipeline.claim({ caller: MONET })).events;
    assert.equal(turn.packet.package.rework, round - 1);
    const out = await h.pipeline.applyVerdict(turn.id, { verdict: 'rework', note: 'テストが未実行', followup: 'Run node --test and report the outcome.', acceptance: [{ id: 'a1', status: 'failed', note: '未確認' }] }, { caller: MONET });
    assert.equal(out.applied, 'rework');
    assert.deepEqual(h.calls.send.at(-1), { sessionId, messageId: `${turn.id}:rework`, text: 'Run node --test and report the outcome.' });
    const pkg = h.flows.get(flow.id).packages[0];
    assert.deepEqual([pkg.state, pkg.rework], ['running', round]);
    assert.equal(h.requirementsOf()[0].acceptance[0].status, 'failed');
  }
  h.returns(sessionId, SLIP);
  const [turn] = (await h.pipeline.claim({ caller: MONET })).events;
  const sends = h.calls.send.length;
  const out = await h.pipeline.applyVerdict(turn.id, { verdict: 'rework', note: 'まだ通らない', followup: 'again' }, { caller: MONET });
  assert.equal(out.escalated, 'rework_limit');
  assert.equal(h.calls.send.length, sends);
  const decision = h.decisionStore.get(out.decisionId);
  assert.equal(decision.status, 'open');
  assert.equal(decision.category, 'delegable');
  assert.equal(decision.title, '手直しが収束しません');
  const current = h.flows.get(flow.id);
  assert.equal(current.state, 'awaiting_decision');
  assert.equal(current.packages[0].state, 'blocked');
  assert.equal(h.requirementsOf()[0].status, 'awaiting_decision');

  // The open item reaches Monet as an inbox event; its answer goes back to the session.
  await h.settle();
  const [opened] = (await h.pipeline.claim({ caller: MONET })).events;
  assert.equal(opened.kind, 'decision.opened');
  await h.decisions.answerAsMonet({ id: decision.id, body: { optionIndex: 1 }, reason: '範囲を絞って続ける' });
  await h.pipeline.applyVerdict(opened.id, { verdict: 'noted', note: '判断ボードで回答' }, { caller: MONET });
  await h.settle();
  const resumed = h.flows.get(flow.id);
  assert.equal(resumed.state, 'verifying');
  assert.equal(resumed.packages[0].state, 'running');
  assert.equal(h.requirementsOf()[0].status, 'in_progress');
  assert.match(h.calls.send.at(-1).text, /^【判断ボードの回答】「手直しが収束しません」\n選択: /);
  assert.equal(h.calls.send.at(-1).sessionId, sessionId);
  const answers = h.inbox.list({ kind: 'decision.answered' });
  assert.deepEqual(answers.map((event) => [event.handler, event.state]), [['pipeline', 'acked']]);
  // The same answer is not sent twice.
  const sent = h.calls.send.length;
  await h.settle(); await h.settle();
  assert.equal(h.calls.send.length, sent);
});

test('needs_owner: an owner-only choice waits on the board; a delegable one is answered with Monet\'s own recommendation', async (t) => {
  const h = harness(t);
  const { flow } = await h.start({ dryStaff: true });
  await h.settle(); await h.settle();
  const sessionId = h.flows.get(flow.id).packages[0].sessionId;
  h.returns(sessionId, SLIP);
  let [turn] = (await h.pipeline.claim({ caller: MONET })).events;
  const brand = await h.pipeline.applyVerdict(turn.id, { verdict: 'needs_owner', note: '見出しの色が決まらない',
    decision: { title: '見出しの色', options: ['藤色', '白'], recommended: 0, impact: '【必ず社長：ブランドの好み】見出しの色' } }, { caller: MONET });
  assert.equal(brand.answeredBy, undefined);
  assert.equal(h.decisionStore.get(brand.decisionId).category, 'owner');
  assert.equal(h.flows.get(flow.id).state, 'awaiting_decision');
  await h.settle();
  // No turn is spent while the owner has not answered.
  assert.deepEqual((await h.pipeline.claim({ caller: MONET })).events, []);
  await h.decisions.answer({ id: brand.decisionId, deviceId: 'dev_1', body: { requestId: 'ans1', optionIndex: 1 } });
  await h.settle();
  assert.equal(h.flows.get(flow.id).state, 'verifying');
  assert.match(h.calls.send.at(-1).text, /選択: 白/);

  h.returns(sessionId, SLIP);
  [turn] = (await h.pipeline.claim({ caller: MONET })).events;
  const sends = h.calls.send.length;
  const delegable = await h.pipeline.applyVerdict(turn.id, { verdict: 'needs_owner', note: '保存先が二通りある',
    decision: { title: '保存先', options: ['既存の場所', '新しい場所'], recommended: 0, impact: '【任せられる】保存先の選択' } }, { caller: MONET });
  assert.equal(delegable.answeredBy, 'monet');
  const record = h.decisionStore.get(delegable.decisionId);
  assert.equal(record.answer.answeredBy, 'monet');
  assert.equal(record.answer.label, '既存の場所');
  assert.equal(h.calls.send.length, sends + 1);
  assert.match(h.calls.send.at(-1).text, /選択: 既存の場所[\s\S]*Monetが回答しました/);
  assert.equal(h.flows.get(flow.id).state, 'verifying');
  assert.equal(h.inbox.list({ kind: 'decision.opened' }).length, 0);
});

test('design decisions go to the board first; the flow dispatches once they are answered', async (t) => {
  const h = harness(t);
  const { flow } = await h.start({ size: 'M', dryStaff: true });
  await h.settle(); await h.settle();
  h.returns(h.flows.get(flow.id).advisor.sessionId, designReply({ ownerDecisions: [{ title: '件数の置き場所', summary: '見出しか行末か', options: ['見出し', '行末'], recommended: 1 }] }));
  await h.settle(); await h.settle();
  let current = h.flows.get(flow.id);
  assert.equal(current.state, 'awaiting_decision');
  assert.equal(h.calls.start.length, 1);
  const [item] = current.decisions;
  const record = h.decisionStore.get(item.id);
  assert.equal(record.category, 'delegable');
  assert.equal(record.options[0].label, '行末');
  await h.settle(); await h.settle();
  assert.equal(h.decisionStore.all().length, 1);
  await h.decisions.answerAsMonet({ id: item.id, body: { optionIndex: 0 }, reason: '行末が読みやすい' });
  await h.settle(); await h.settle();
  current = h.flows.get(flow.id);
  assert.equal(current.decisions[0].answer, '行末');
  assert.ok(ACTIVE(current.state));
  assert.ok(h.calls.start.at(-1).task.prompt.includes('- 件数の置き場所: 行末'));
});
const ACTIVE = (state) => ['dispatching', 'verifying'].includes(state);

test('sessions outside a flow: a requirement-linked return is verified, a Monet hand-off is verified, the owner\'s own session is digest-only', async (t) => {
  const h = harness(t);
  const linked = 'ses_00000000000000a1', handoff = 'ses_00000000000000a2', own = 'ses_00000000000000a3';
  const requirement = h.requirements.add(P, { title: '手で登録した要件', source: 'owner', requestId: 'r9' });
  h.projects.mutate((all) => { all[P].requirements.find((item) => item.id === requirement.id).sessionIds = [linked]; });
  for (const id of [linked, handoff, own]) h.rows.set(id, { id, name: `作業${id.slice(-2)}`, phase: 'running', projectId: P, source: 'paseo', delegate: { sessionId: `agent-${id}` } });
  const fire = (id, labels = null) => { h.clock.now += 1000; Object.assign(h.rows.get(id), { phase: 'awaiting_review', attentionTimestamp: new Date(h.clock.now).toISOString() }); h.replies.set(id, SLIP);
    return h.pipeline.onTransition({ previous: 'running', current: structuredClone(h.rows.get(id)), labels }); };
  const a = fire(linked);
  const b = fire(handoff, { 'laa.personal_agent': 'worker' });
  const c = fire(own);
  assert.deepEqual([a.handler, a.requirementId, a.origin], ['monet', requirement.id, 'work']);
  assert.deepEqual([b.handler, b.origin], ['monet', 'hermes-conduit']);
  assert.deepEqual([c.handler, c.state], ['digest', 'acked']);
  assert.equal(h.pipeline.onTransition({ previous: 'running', current: { ...h.rows.get(own), parentId: linked } }), null);
  const { events } = await h.pipeline.claim({ limit: 5, caller: MONET });
  assert.deepEqual(events.map((event) => event.sessionId), [linked, handoff]);
  await h.pipeline.applyVerdict(events[0].id, { verdict: 'verified', note: '成果物を確認' }, { caller: MONET });
  const row = h.requirementsOf().find((item) => item.id === requirement.id);
  assert.deepEqual([row.status, row.verifiedBy, row.note], ['completed', 'monet', '成果物を確認']);
  const rework = await h.pipeline.applyVerdict(events[1].id, { verdict: 'rework', followup: 'VERIFIED is missing; run the check.' }, { caller: MONET });
  assert.equal(rework.applied, 'rework');
  assert.equal(h.calls.send.at(-1).sessionId, handoff);
  await assert.rejects(h.pipeline.applyVerdict(c.id, { verdict: 'noted' }, { caller: MONET }), (error) => error.code === 'monet_event_not_claimable');
  assert.match(h.pipeline.digest(), /^受信箱: 未照合0件/);
});

test('a decision answered with nobody to deliver it to reaches Monet instead of being stored and forgotten', async (t) => {
  const h = harness(t);
  const { decision } = h.decisionStore.add({ title: '保存先を選ぶ', summary: 'Monetの会話から登録', impact: '【必ず社長：ブランドの好み】名前', requestId: 'd1',
    options: [{ label: '案A' }, { label: '案B' }], source: { paseoAgentId: null } });
  await h.settle();
  assert.deepEqual((await h.pipeline.claim({ caller: MONET })).events, []);
  await h.decisions.answer({ id: decision.id, deviceId: 'dev_1', body: { requestId: 'a1', optionIndex: 1 } });
  assert.equal(h.decisionStore.get(decision.id).delivery.state, 'stored');
  await h.settle();
  const { events } = await h.pipeline.claim({ caller: MONET });
  assert.deepEqual(events.map((event) => [event.kind, event.decisionId, event.packet.label]), [['decision.answered', decision.id, '案B']]);
  await h.pipeline.applyVerdict(events[0].id, { verdict: 'noted', note: '回答を受け取りました' }, { caller: MONET });
  await h.settle();
  assert.deepEqual((await h.pipeline.claim({ caller: MONET })).events, []);
});

test('a return Monet never verifies raises one board item; choosing to look again re-arms it once', async (t) => {
  const h = harness(t, { config: { inbox: { leaseMs: 1000, maxAttempts: 2 } } });
  const { flow } = await h.start({ dryStaff: true });
  await h.settle(); await h.settle();
  const event = h.returns(h.flows.get(flow.id).packages[0].sessionId, SLIP);
  for (let i = 0; i < 2; i += 1) { assert.equal((await h.pipeline.claim({ caller: MONET })).events.length, 1); h.clock.now += 1001; }
  const out = await h.pipeline.claim({ caller: MONET });
  assert.deepEqual(out.events, []);
  assert.equal(out.exhausted.length, 1);
  const decision = h.decisionStore.get(out.exhausted[0].decisionId);
  assert.equal(decision.title, 'Monetが照合できなかった返却');
  assert.equal(h.inbox.get(event.id).state, 'failed');
  h.clock.now += 1001;
  assert.deepEqual((await h.pipeline.claim({ caller: MONET })).exhausted, []);
  assert.equal(h.decisionStore.all().length, 1);
  await h.decisions.answerAsMonet({ id: decision.id, body: { optionIndex: 0 }, reason: 'もう一度確認する' });
  await h.settle();
  const again = h.inbox.get(event.id);
  assert.deepEqual([again.state, again.attempts, again.packet.rearmed], ['new', 0, true]);
  // A second exhaustion does not ask again.
  for (let i = 0; i < 3; i += 1) { await h.pipeline.claim({ caller: MONET }); h.clock.now += 1001; }
  assert.equal(h.inbox.get(event.id).state, 'failed');
  assert.equal(h.decisionStore.all().length, 1);
});

test('a missed transition is recovered from the stored row; a restart mid-flow continues without doing work twice', async (t) => {
  const h = harness(t);
  const { flow } = await h.start({ dryStaff: true });
  await h.settle(); await h.settle();
  const sessionId = h.flows.get(flow.id).packages[0].sessionId;
  // The turn ended while no hook was listening.
  h.clock.now += 1000;
  Object.assign(h.rows.get(sessionId), { phase: 'awaiting_review', attentionTimestamp: new Date(h.clock.now).toISOString() });
  h.replies.set(sessionId, SLIP);
  const restarted = h.make();
  await h.settle(restarted);
  assert.equal(h.flows.get(flow.id).packages[0].state, 'returned');
  await h.settle(restarted); await h.settle(restarted);
  assert.equal(h.inbox.list({ kind: 'session.returned' }).length, 1);
  assert.equal(h.calls.start.length, 1);
  const [turn] = (await restarted.claim({ caller: MONET })).events;
  await restarted.applyVerdict(turn.id, verified(['a1']), { caller: MONET });
  assert.equal(h.flows.get(flow.id).state, 'reported');
});

test('the report needs Monet\'s authenticated call and is retried until it is accepted', async (t) => {
  const h = harness(t, { reporterFails: true });
  const { flow } = await h.start({ dryStaff: true });
  await h.settle(); await h.settle();
  h.returns(h.flows.get(flow.id).packages[0].sessionId, SLIP);
  const [turn] = (await h.pipeline.claim({ caller: MONET })).events;
  const out = await h.pipeline.applyVerdict(turn.id, verified(['a1']), { caller: MONET });
  assert.deepEqual(out.reports, [{ flowId: flow.id, reported: false, reason: 'delivery_unavailable' }]);
  assert.equal(h.flows.get(flow.id).state, 'verifying');
  await h.settle();
  assert.deepEqual(await h.pipeline.settle({ caller: null }), []);
  assert.deepEqual(await h.pipeline.settle({ caller: { kind: 'device' } }), [{ flowId: flow.id, reported: false, reason: 'caller_unauthorized' }]);
  assert.equal(h.flows.get(flow.id).state, 'verifying');
});

test('withdraw stops the flow\'s sessions and open decisions; requirements go only when asked', async (t) => {
  const h = harness(t);
  const { flow } = await h.start({ dryStaff: true });
  await h.settle(); await h.settle();
  const sessionId = h.flows.get(flow.id).packages[0].sessionId;
  const out = await h.pipeline.withdraw(flow.id, { withRequirements: true });
  assert.equal(out.flow.state, 'withdrawn');
  assert.deepEqual(h.calls.stop, [sessionId]);
  assert.deepEqual(h.requirementsOf(), []);
  await h.settle(); await h.settle();
  assert.equal(h.calls.start.length, 1);
  assert.equal((await h.pipeline.withdraw(flow.id)).withdrawn, true);
  // The same request can be started again after a withdrawal.
  const again = await h.start({ dryStaff: true });
  assert.equal(again.created, true);
  assert.notEqual(again.flow.id, flow.id);
});

test('an absent or late staff member does not hold the flow', async (t) => {
  const h = harness(t, { staff: (member) => (member.role === 'cto' ? { state: 'timeout', reason: 'timeout', ms: 180000 } : { state: 'absent', reason: 'reply_unparsed', ms: 3 }) });
  const { flow } = await h.start();
  await h.settle(); await h.settle();
  const current = h.flows.get(flow.id);
  assert.deepEqual(current.staff.map((row) => row.state), ['timeout', 'absent']);
  assert.ok(ACTIVE(current.state));
  assert.deepEqual(h.requirementsOf()[0].acceptance.map((item) => item.text), ['依頼した結果が実物で確認できる']);
  assert.equal(h.calls.staff.length, 2);
});

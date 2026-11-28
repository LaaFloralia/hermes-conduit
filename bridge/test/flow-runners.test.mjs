// The requirement flow against the real session service: what the runners send
// to createSession / sendMessage / conversation must be what the service takes.
// Only the delegation adapter, the conversation log and the staff one-shot are stubs.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createDecisionStore } from '../src/decisions/store.mjs';
import { createDecisionService } from '../src/decisions/service.mjs';
import { runHermesOneshot } from '../src/flow/runners.mjs';
import { createMonetFlow } from '../src/flow/wire.mjs';
import { createProjectStore } from '../src/routes/projects.mjs';
import { projectRequirements } from '../src/routes/project-requirements.mjs';
import { assignSessionProject } from '../src/sessions/projects.mjs';
import { createSessionService } from '../src/sessions/service.mjs';
import { createSessionStore } from '../src/sessions/store.mjs';

const P = 'prj_aaaaaaaaaaaa';
const MONET = { kind: 'monet' };
const SLIP = 'RESULT: done\nCHANGED: bridge/src/x.mjs — abc1234\nVERIFIED: node --test — 3 pass\nRESIDUAL: none\nNEEDS_OWNER: none';
const STAFF = 'POSITION: 進めてよい\nEVIDENCE: 既存の一覧で足りる\nRISK: 件数の取得が遅い\nALTERNATIVE: none\nASK: none\nSCOPE: 一覧の見出しだけ\nACCEPTANCE:\n- 見出しに件数が出る\n- 既存の試験が通る';

// The delegation path (laa-personal-agent) reduced to what the service calls.
function delegation() {
  const records = new Map();
  const calls = [];
  const need = (requestId) => records.get(requestId);
  return {
    origin: 'laa-bridge', calls, records,
    idle(requestId) { Object.assign(need(requestId), { daemonStatus: 'idle', updatedAt: new Date(Date.now() + 1000).toISOString() }); },
    async create({ requestId, profile, cwd, task, title, mode }) {
      calls.push({ op: 'create', requestId, profile, cwd, task, title, mode });
      if (!records.has(requestId)) records.set(requestId, { sessionId: `agent-${records.size + 1}`, daemonStatus: 'running', messages: [], updatedAt: new Date().toISOString(),
        requested: { profile, provider: 'claude', model: 'claude-opus', effort: 'medium' } });
      const record = need(requestId);
      return { sessionId: record.sessionId, requested: record.requested, phase: 'created', reused: false };
    },
    async status({ requestId }) {
      const record = need(requestId);
      return { phase: record.daemonStatus === 'idle' ? 'awaiting_review' : 'running', requested: record.requested, daemonStatus: record.daemonStatus, title: null, pending: [], result: null, updatedAt: record.updatedAt };
    },
    async send({ requestId, messageId, text }) {
      calls.push({ op: 'send', requestId, messageId, text });
      Object.assign(need(requestId), { daemonStatus: 'running' });
      need(requestId).messages.push(text);
      return { sent: true };
    },
    async stop({ requestId }) { calls.push({ op: 'stop', requestId }); return { stopConfirmed: true, daemonStatus: 'idle' }; },
  };
}

test('staff one-shot, session start with the brief, reply read-back, rework message and the verdict, through the real session service', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'flow-runners-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const now = () => Date.now();
  writeFileSync(join(dir, 'roster.yaml'), 'roles:\n  - id: cto\n    name: Ada\n    company: { seat: member, work: [implementation], lens: "実現性" }\n  - id: cos\n    name: Merlin\n    company: { seat: member, work: [simple], lens: "順番" }\n');
  writeFileSync(join(dir, 'flow.json'), JSON.stringify({ retryMs: 0, staff: { rosterFile: join(dir, 'roster.yaml'), hermesBin: process.execPath } }));
  const projects = createProjectStore({ file: join(dir, 'projects.json'), now });
  const iso = new Date().toISOString();
  projects.mutate((all) => { all[P] = { id: P, name: '案件A', nameSource: 'owner', version: 1, createdAt: iso, updatedAt: iso, requirements: [] }; });
  const sessionStore = createSessionStore({ file: join(dir, 'sessions.json') });
  const adapter = delegation();
  const decisionStore = createDecisionStore({ dir, now });
  const decisions = createDecisionService({ store: decisionStore, sessionStore, notify: null, now });
  const replies = new Map();
  let flow = null;
  const service = createSessionService({ sessionStore, adapter, decisions, notify: async () => ({ delivered: false }), now, observationTtlMs: 0,
    history: async (agentId) => ({ items: replies.get(agentId) ?? [] }),
    onTransition: (transition) => flow?.onTransition(transition),
    findProject: (id) => projects.get(id), activeProjectIds: () => new Set([P]),
    moveProject: (input) => assignSessionProject({ projects, sessionStore, ...input }) });
  const oneshots = [];
  const reports = [];
  flow = createMonetFlow({ dir, now, projects, sessionStore, sessions: () => service, decisionStore, decisions,
    options: { configFile: join(dir, 'flow.json'), oneshot: async (input) => { oneshots.push(input); return { state: 'done', text: STAFF, reason: null, ms: 4 }; } },
    reporter: async ({ caller, projectId, requestId }) => { if (caller !== MONET) return { sent: false, reason: 'caller_unauthorized' }; reports.push(`${projectId}:${requestId}`); return { sent: true }; } });
  const { pipeline } = flow;
  const settle = async () => { await pipeline.idle(); await pipeline.tick(); await pipeline.idle(); };

  const started = await pipeline.start({ projectId: P, requestId: 'r1', title: 'Work一覧に件数を出す', details: '一覧の見出しに件数を出す', size: 'S', repo: '/Users/laa/dev/hermes-conduit' });
  await settle(); await settle(); await settle();

  // Staff: one hermes one-shot per chosen role, on that role's own profile.
  assert.deepEqual(oneshots.map((call) => call.profile), ['laa-cto', 'laa-cos']);
  assert.ok(oneshots[0].prompt.includes('Work一覧に件数を出す') && oneshots[0].timeoutMs > 0);
  let current = flow.flows.get(started.flow.id);
  assert.deepEqual(current.staff.map((row) => [row.state, row.scope]), [['done', '一覧の見出しだけ'], ['done', '一覧の見出しだけ']]);
  assert.equal(current.state, 'verifying', JSON.stringify(current.failure));

  // The session: created once by the real service, in the project, linked to the requirement, with the brief as its first instruction.
  const creates = adapter.calls.filter((call) => call.op === 'create');
  assert.equal(creates.length, 1);
  assert.equal(creates[0].profile, 'opus-medium');
  const pkg = current.packages[0];
  const row = sessionStore.get(pkg.sessionId);
  assert.equal(row.projectId, P);
  assert.match(row.name, /^実装｜/);
  const [requirement] = projectRequirements(projects.get(P));
  assert.deepEqual(requirement.sessionIds, [pkg.sessionId]);
  const sent = JSON.stringify(creates[0].task);
  for (const part of ['/Users/laa/dev/hermes-conduit', 'DONE CONDITION', '見出しに件数が出る', 'RESULT: done | partial | blocked']) assert.ok(sent.includes(part), part);
  await settle(); await settle();
  assert.equal(adapter.calls.filter((call) => call.op === 'create').length, 1);

  // The turn ends; the row is refreshed by a read, and the flow picks the return up from the stored row.
  const delegateRequest = creates[0].requestId;
  replies.set(row.delegate.sessionId, [{ id: 'm1', type: 'assistant_message', role: 'assistant', text: `実装しました。\n${SLIP}` }]);
  adapter.idle(delegateRequest);
  await service.getSession(pkg.sessionId);
  assert.equal(sessionStore.get(pkg.sessionId).phase, 'awaiting_review');
  await settle();
  let { events } = await pipeline.claim({ caller: MONET });
  assert.equal(events.length, 1);
  assert.equal(events[0].packet.claimedResult, 'done');
  assert.ok(events[0].packet.lastMessage.includes('CHANGED: bridge/src/x.mjs'));

  // Rework goes to the same conversation through the service.
  await pipeline.applyVerdict(events[0].id, { verdict: 'rework', note: '試験の結果がない', followup: 'Run node --test and paste the summary line.' }, { caller: MONET });
  const message = adapter.calls.find((call) => call.op === 'send');
  assert.deepEqual([message.requestId, message.text.includes('Run node --test and paste the summary line.')], [delegateRequest, true]);
  await settle(); await settle();
  assert.deepEqual((await pipeline.claim({ caller: MONET })).events, []);

  adapter.idle(delegateRequest);
  await service.getSession(pkg.sessionId);
  await settle();
  ({ events } = await pipeline.claim({ caller: MONET }));
  assert.equal(events.length, 1);
  assert.equal(events[0].packet.package.rework, 1);
  const out = await pipeline.applyVerdict(events[0].id, { verdict: 'verified', note: '試験の結果を確認', acceptance: events[0].packet.acceptance.map((item) => ({ id: item.id, status: 'passed' })) }, { caller: MONET });
  assert.equal(out.requirement, 'completed');
  assert.equal(flow.flows.get(started.flow.id).state, 'reported');
  assert.deepEqual(reports, [`${P}:r1`]);
});

test('the staff one-shot runs hermes with the profile and the prompt, bounds the wait and the output, and never throws', async () => {
  const script = (code) => ['-e', code];
  const run = (code, extra = {}) => runHermesOneshot({ bin: process.execPath, profile: 'laa-cto', prompt: 'P', timeoutMs: 5000,
    spawnImpl: (bin, args, options) => { seen.push(args); return spawnNode(bin, script(code), options); }, ...extra });
  const seen = [];
  const { spawn: spawnNode } = await import('node:child_process');
  const ok = await run('process.stdout.write("POSITION: ok")');
  assert.deepEqual([ok.state, ok.text], ['done', 'POSITION: ok']);
  assert.deepEqual(seen[0], ['-p', 'laa-cto', '-z', 'P']);
  assert.deepEqual((await run('process.exit(3)')).state, 'absent');
  assert.deepEqual((await run('')).reason, 'empty_reply');
  const slow = await run('setTimeout(() => {}, 60000)', { timeoutMs: 200 });
  assert.deepEqual([slow.state, slow.reason], ['timeout', 'timeout']);
  const big = await run('process.stdout.write("x".repeat(200000)); setTimeout(() => {}, 60000)', { outputLimitBytes: 1000 });
  assert.deepEqual([big.state, big.reason], ['done', 'output_truncated']);
  assert.equal((await runHermesOneshot({ bin: '/nonexistent/hermes', profile: 'laa-cto', prompt: 'P', timeoutMs: 100 })).reason, 'hermes_missing');
});

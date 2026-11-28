// The Monet-only HTTP routes of the requirement flow and the `laa-bridge flow` /
// `laa-bridge monet` commands on top of them. The commands post to the route
// handlers in-process, so one test covers argv → route → pipeline → state file.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { flowCommand, monetCommand } from '../src/cli-flow.mjs';
import { createDecisionStore } from '../src/decisions/store.mjs';
import { createDecisionService } from '../src/decisions/service.mjs';
import { BridgeError } from '../src/errors.mjs';
import { createMonetFlow } from '../src/flow/wire.mjs';
import { createProjectStore } from '../src/routes/projects.mjs';
import { projectRequirements } from '../src/routes/project-requirements.mjs';

const cli = fileURLToPath(new URL('../src/cli.mjs', import.meta.url));
const P = 'prj_aaaaaaaaaaaa';
const TOKEN = 'm'.repeat(43);
const SLIP = 'RESULT: done\nCHANGED: a.mjs — abc1234\nVERIFIED: node --test — pass\nRESIDUAL: none\nNEEDS_OWNER: none';

function bridge(t) {
  const dir = mkdtempSync(join(tmpdir(), 'cli-flow-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const clock = { now: Date.parse('2026-11-28T09:00:00.000Z') };
  const now = () => clock.now;
  const iso = () => new Date(clock.now).toISOString();
  writeFileSync(join(dir, 'roster.yaml'), 'roles:\n  - id: cto\n    name: Ada\n    company: { seat: member, work: [implementation], lens: "実現性" }\n');
  writeFileSync(join(dir, 'flow.json'), JSON.stringify({ retryMs: 0, staff: { rosterFile: join(dir, 'roster.yaml') } }));
  const projects = createProjectStore({ file: join(dir, 'projects.json'), now });
  projects.mutate((all) => { all[P] = { id: P, name: '案件A', nameSource: 'owner', version: 1, createdAt: iso(), updatedAt: iso(), requirements: [] }; });
  const rows = new Map();
  const sessionStore = { get: (id) => (rows.has(id) ? structuredClone(rows.get(id)) : null), all: () => [...rows.values()].map((row) => structuredClone(row)) };
  const decisionStore = createDecisionStore({ dir, now });
  const decisions = createDecisionService({ store: decisionStore, sessionStore, notify: null, now });
  const started = [];
  const runners = {
    runStaff: async () => ({ state: 'absent', reason: 'not_used', ms: 0 }),
    async startSession(input) {
      started.push(input.requestId);
      const id = `ses_${createHash('sha256').update(input.requestId).digest('hex').slice(0, 16)}`;
      if (!rows.has(id)) rows.set(id, { id, name: input.name, phase: 'running', projectId: input.projectId, delegate: { origin: 'laa-bridge', sessionId: `agent-${id}` }, attentionTimestamp: null });
      return { sessionId: id, created: true };
    },
    lastReply: async () => SLIP, send: async () => ({ queued: false }), stop: async () => {},
  };
  const reports = [];
  const flow = createMonetFlow({ dir, now, options: { configFile: join(dir, 'flow.json'), runners }, projects, sessionStore, sessions: () => null, decisionStore, decisions,
    reporter: async ({ caller, projectId, requestId }) => { if (caller?.kind !== 'monet') return { sent: false, reason: 'caller_unauthorized' };
      reports.push(`${projectId}:${requestId}`); return { sent: true }; },
    tokenHash: createHash('sha256').update(TOKEN).digest('hex') });
  // What cli-monet.mjs does over HTTP, against the same route table.
  const call = async (method, path, body, token = TOKEN) => {
    const url = new URL(path, 'http://localhost');
    for (const route of flow.routes) {
      if (route.method !== method) continue;
      const params = route.pattern ? url.pathname.match(route.pattern)?.slice(1) : route.path === url.pathname ? [] : null;
      if (!params) continue;
      const out = await route.handler({ req: { url: path, headers: token ? { authorization: `Bearer ${token}` } : {} }, rawBody: body === undefined ? undefined : Buffer.from(JSON.stringify(body)), params });
      return out;
    }
    throw new BridgeError(404, 'not_found', 'no route');
  };
  const post = async (path, body) => (await call('POST', path, body)).data;
  const output = async (run) => {
    const lines = [];
    const original = console.log;
    console.log = (line) => lines.push(line);
    try { const code = await run(); return { code, out: JSON.parse(lines.at(-1)) }; } finally { console.log = original; }
  };
  const stdin = (value) => async () => Buffer.from(JSON.stringify(value));
  const settle = async () => { await flow.pipeline.idle(); await flow.pipeline.tick(); await flow.pipeline.idle(); };
  return { dir, clock, flow, rows, started, reports, call, post, output, stdin, settle, projects };
}
const START = { projectId: P, requestId: 'r1', title: 'Work一覧に件数を出す', details: '見出しに件数', size: 'S', dryStaff: true };

test('every mutating flow and inbox route refuses a caller without the Monet credential', async (t) => {
  const h = bridge(t);
  const posts = ['/v1/flows', '/v1/flows/flw_000000000000/withdraw', '/v1/monet/inbox/claim', '/v1/monet/inbox/evt_000000000000/ack', '/v1/monet/inbox/replay', '/v1/monet/digest'];
  for (const path of posts) {
    for (const token of [null, 'x'.repeat(43)]) {
      await assert.rejects(h.call('POST', path, START, token), (error) => error.status === 403 && error.code === 'monet_caller_required', path);
    }
  }
  assert.deepEqual(h.flow.flows.list(), []);
  assert.deepEqual(projectRequirements(h.projects.get(P)), []);
  // Reads are ordinary device routes (the HTTP layer checks the device token and the scope).
  const reads = h.flow.routes.filter((route) => route.method === 'GET');
  assert.deepEqual(reads.map((route) => [route.auth, route.scope]), [[true, 'sessions:read'], [true, 'sessions:read']]);
  assert.ok(h.flow.routes.filter((route) => route.method === 'POST').every((route) => route.auth === false));
});

test('start over HTTP: 201 once, 200 on the replay, and the flow is readable', async (t) => {
  const h = bridge(t);
  const first = await h.call('POST', '/v1/flows', START);
  assert.equal(first.status, 201);
  assert.equal(first.data.created, true);
  const again = await h.call('POST', '/v1/flows', START);
  assert.deepEqual([again.status, again.data.created, again.data.flow.id], [200, false, first.data.flow.id]);
  const list = await h.call('GET', '/v1/flows?open=1');
  assert.deepEqual(list.data.items.map((item) => item.id), [first.data.flow.id]);
  const one = await h.call('GET', `/v1/flows/${first.data.flow.id}`);
  assert.equal(one.data.flow.request.title, START.title);
  await assert.rejects(h.call('GET', '/v1/flows/flw_ffffffffffff'), (error) => error.status === 404);
  await assert.rejects(h.call('POST', '/v1/monet/inbox/claim', { limit: 'all' }), (error) => error.code === 'payload_invalid');
  await assert.rejects(h.call('POST', `/v1/flows/${first.data.flow.id}/withdraw`, { reason: 'x' }), (error) => error.code === 'payload_invalid');
  await assert.rejects(h.call('POST', '/v1/monet/inbox/replay', {}), (error) => error.code === 'payload_invalid');
});

test('the commands carry one requirement from start to the report', async (t) => {
  const h = bridge(t);
  const io = { stateDir: h.dir, post: h.post };
  const start = await h.output(() => flowCommand(['start'], {}, { ...io, stdin: h.stdin(START) }));
  assert.equal(start.code, 0);
  const id = start.out.data.flow.id;
  await h.settle(); await h.settle(); await h.settle();
  assert.deepEqual(h.started, [`${id}:wp1`]);

  const status = await h.output(() => flowCommand(['status', id], {}, io));
  assert.equal(status.out.data.flow.state, 'verifying');
  assert.deepEqual(status.out.data.flow.steps.map((step) => step.state).slice(0, 2), ['intake', 'expanding']);
  const list = await h.output(() => flowCommand(['list'], { open: true }, io));
  assert.deepEqual(list.out.data.items.map((item) => [item.id, item.state, item.packages]), [[id, 'verifying', ['wp1:running']]]);

  // The session ends its turn.
  const sessionId = status.out.data.flow.packages[0].sessionId;
  h.clock.now += 1000;
  Object.assign(h.rows.get(sessionId), { phase: 'awaiting_review', attentionTimestamp: new Date(h.clock.now).toISOString() });
  h.flow.onTransition({ previous: 'running', current: structuredClone(h.rows.get(sessionId)) });

  const peek = await h.output(() => monetCommand(['inbox'], {}, io));
  assert.equal(peek.out.data.waiting, 1);
  assert.deepEqual(peek.out.data.events.map((event) => [event.kind, event.state, event.sessionId]), [['session.returned', 'new', sessionId]]);
  assert.equal(peek.out.data.events[0].packet, undefined);
  const claim = await h.output(() => monetCommand(['inbox'], { claim: true, limit: '2' }, io));
  const [event] = claim.out.data.events;
  assert.equal(event.packet.claimedResult, 'done');
  const accept = event.packet.acceptance.map((item) => ({ id: item.id, status: 'passed' }));

  const bad = await h.output(() => monetCommand(['ack', event.id], { 'verdict-file': '-' }, { ...io, stdin: h.stdin({ verdict: 'verified', note: '確認した' }) }));
  assert.deepEqual([bad.code, bad.out.ok, bad.out.error, bad.out.status], [1, false, 'acceptance_open', 422]);
  const file = join(h.dir, 'verdict.json');
  writeFileSync(file, JSON.stringify({ verdict: 'verified', note: '実物で確認した', acceptance: accept }));
  const ack = await h.output(() => monetCommand(['ack', event.id], { 'verdict-file': file }, io));
  assert.equal(ack.code, 0);
  assert.equal(ack.out.data.requirement, 'completed');
  assert.equal(ack.out.data.flow.state, 'reported');
  assert.deepEqual(h.reports, [`${P}:r1`]);

  const digest = await h.output(() => monetCommand(['digest'], {}, io));
  assert.match(digest.out.data.text, /^受信箱: 未照合0件/);
  const replay = await h.output(() => monetCommand(['replay', sessionId], {}, io));
  assert.equal(replay.out.data.event.kind, 'session.returned');
  const closed = await h.output(() => flowCommand(['list'], { state: 'reported' }, io));
  assert.equal(closed.out.data.items.length, 1);
  const withdrawn = await h.output(() => flowCommand(['withdraw', id], { 'with-requirements': true }, io));
  assert.equal(withdrawn.out.data.withdrawn, false);
  assert.equal(projectRequirements(h.projects.get(P))[0].status, 'completed');
});

test('malformed commands are refused before anything is sent', async (t) => {
  const h = bridge(t);
  const sent = [];
  const io = { stateDir: h.dir, post: async (path) => { sent.push(path); return {}; }, stdin: async () => Buffer.from('[1]') };
  const cases = [
    () => flowCommand(['start'], {}, io), () => flowCommand(['start', 'extra'], {}, io), () => flowCommand(['start'], { title: '要件' }, io),
    () => flowCommand(['start'], { file: join(h.dir, 'missing.json') }, io), () => flowCommand(['status', 'flw_1'], {}, io),
    () => flowCommand(['list'], { state: 'done' }, io), () => flowCommand(['withdraw'], {}, io), () => flowCommand(['nope'], {}, io),
    () => monetCommand(['ack', 'evt_000000000000'], {}, io), () => monetCommand(['ack', 'evt_1'], { 'verdict-file': '-' }, io),
    () => monetCommand(['inbox'], { claim: true, limit: '0' }, io), () => monetCommand(['replay', 'agent-1'], {}, io), () => monetCommand(['digest', 'x'], {}, io),
  ];
  for (const run of cases) {
    const { code, out } = await h.output(run);
    assert.equal(out.ok, false);
    assert.equal(code, 1);
  }
  assert.deepEqual(sent, []);
  const missing = await h.output(() => flowCommand(['status', 'flw_ffffffffffff'], {}, io));
  assert.deepEqual([missing.code, missing.out.error], [3, 'not_found']);
});

test('laa-bridge flow / monet from a shell: reads work on an empty state; mutations need the Monet runner credential', (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'cli-flow-shell-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const env = { ...process.env, LAA_BRIDGE_STATE_DIR: dir };
  delete env.LAA_BRIDGE_MONET_TOKEN;
  const run = (args, input) => spawnSync(process.execPath, [cli, ...args], { env, encoding: 'utf8', timeout: 10_000, input });
  const list = run(['flow', 'list', '--open']);
  assert.equal(list.status, 0, list.stderr);
  assert.deepEqual(JSON.parse(list.stdout), { ok: true, data: { items: [] } });
  const inbox = run(['monet', 'inbox']);
  assert.deepEqual(JSON.parse(inbox.stdout).data, { counts: { new: 0, claimed: 0, acked: 0, failed: 0 }, waiting: 0, events: [] });
  for (const [args, input] of [[['flow', 'start'], JSON.stringify(START)], [['flow', 'withdraw', 'flw_000000000000', '--with-requirements']], [['monet', 'inbox', '--claim']],
    [['monet', 'ack', 'evt_000000000000', '--verdict-file', '-'], '{"verdict":"noted"}'], [['monet', 'digest']], [['monet', 'replay', 'ses_0000000000000000']]]) {
    const out = run(args, input);
    assert.equal(out.status, 1, args.join(' '));
    assert.equal(JSON.parse(out.stdout).error, 'monet_caller_required', args.join(' '));
  }
  const help = run(['flow', '--help']);
  assert.equal(help.status, 0);
  assert.ok(help.stdout.includes('laa-bridge flow start') && help.stdout.includes('laa-bridge monet ack'));
});

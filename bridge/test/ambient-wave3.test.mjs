import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { daemonAdapter } from '../src/sessions/daemon.mjs';
import { readConversation } from '../src/sessions/history.mjs';
import { createOwnerNotifier } from '../src/notify/index.mjs';
import { createSessionStore } from '../src/sessions/store.mjs';
import { createSessionService } from '../src/sessions/service.mjs';
import { startBridge } from './helpers.mjs';

const cli = fileURLToPath(new URL('../bin/laa-bridge', import.meta.url));
const post = (body, token, key) => ({ method: 'POST', token, body, key });
const fields = ['sessions:read', 'sessions:write'];
const meta = (e) => JSON.parse(Buffer.from(e.session_id.split('#')[1], 'base64url'));

async function runCli(h, args, { input, token } = {}) {
  const env = { ...process.env, PASEO_AGENT_ID: '', LAA_BRIDGE_STATE_DIR: h.stateDir, LAA_BRIDGE_PORT: new URL(h.base).port };
  delete env.LAA_BRIDGE_MONET_TOKEN;
  if (token) env.LAA_BRIDGE_MONET_TOKEN = token;
  const p = spawn(cli, [...args, '--json'], { env, stdio: ['pipe', 'pipe', 'pipe'] });
  p.stdin.end(input === undefined ? undefined : JSON.stringify(input));
  const stdout = [], stderr = [];
  p.stdout.on('data', (b) => stdout.push(b)); p.stderr.on('data', (b) => stderr.push(b));
  const [status] = await once(p, 'close');
  let data;
  try { data = JSON.parse(Buffer.concat(stdout)); }
  catch { assert.fail(`CLI produced no JSON (exit ${status}): ${Buffer.concat(stderr).toString()}`); }
  return { status, data };
}

function fixtureDaemon(agents, sent = []) {
  return daemonAdapter({ connect: async () => ({
    fetchAgents: async () => ({ entries: agents.map((agent) => ({ agent })), pageInfo: {} }),
    fetchWorkspaces: async () => ({ entries: [] }),
    fetchAgent: async ({ agentId }) => ({ agent: agents.find((a) => a.id === agentId) }),
    sendMessage: async (id, message, options) => {
      sent.push({ id, message, options });
      Object.assign(agents.find((a) => a.id === id), { status: 'running', activeTurn: { id: 'proxy-turn' } });
    },
    close: async () => {},
  }) });
}

const agent = (id, title, labels = {}, status = 'running') => ({ id, title, status, labels,
  provider: 'claude', createdAt: '2026-11-25T00:00:00Z', updatedAt: '2026-11-25T00:00:00Z' });
const hash = (token) => createHash('sha256').update(token).digest('hex');
const credential = () => randomBytes(32).toString('base64url');
const addDecision = (h, key, extra = []) => runCli(h, ['decide', 'add', '--request-id', key, '--title', '進め方を選ぶ', '--summary', '次の方法を決めます', '--option', '案一', '--option', '案二', ...extra]);
const rpc = (h, input) => runCli(h, ['projects', 'rpc'], { input });

test('C-2/C-3: live verified Monet report, two parent finishes, one child finish, zero session pushes, replay inert', async (t) => {
  const serviceToken = credential(), agents = [], delivered = [], observed = [];
  let clock = Date.parse('2026-11-25T01:00:00Z'), sink;
  const now = () => clock;
  const notify = async (n) => { observed.push(n.kind); return sink(n); };
  const h = await startBridge({ now, sessions: { daemon: fixtureDaemon(agents), notify }, decisions: { notify }, monet: { tokenHash: hash(serviceToken), notify } });
  t.after(() => h.close());
  sink = createOwnerNotifier({ file: join(h.stateDir, 'rehearsal-outbox.json'), now,
    deliver: async (e) => { delivered.push(e); return { delivered: true }; } });
  const token = await h.token(fields);
  const create = await h.request('/v1/projects', post({ name: 'Owner-entered English' }, token, 'proj'));
  assert.equal(create.status, 201);
  const project = create.body.data.id, requestId = 'synthetic-request';
  let etag = create.body.data.etag;
  const current = () => h.request(`/v1/projects/${project}`, { token });
  assert.deepEqual((await current()).body.data.requirementSummary, { completed: 0, total: 0, rate: null });
  const badName = await rpc(h, { op: 'update', project, etag, body: { name: 'English agent name', nameSource: 'owner' } });
  assert.equal(badName.data.status, 422);
  assert.match(badName.data.message, /^name:/);
  const labels = { 'laa.bridge.project-id': project };
  agents.push(agent('a1', '通知の確認', labels), agent('a2', '要件の確認', labels),
    agent('a3', '子｜試験', { ...labels, 'paseo.parent-agent-id': 'a1' }));
  await h.request('/v1/sessions', { token });
  const report = () => runCli(h, ['projects', 'report', project, '--request-id', requestId], { token: serviceToken });
  const blocked = await h.request('/v1/monet/completion-report', post({ projectId: project, requestId, caller: 'monet' }, token));
  assert.equal(blocked.status, 403);
  const sameNameUntrusted = await runCli(h, ['projects', 'report', project, '--request-id', requestId]);
  assert.equal(sameNameUntrusted.status !== 0, true);
  const ids = [];
  for (const title of ['通知を照合', '検証を照合']) {
    const result = await rpc(h, { op: 'requirement_add', project, etag, body: { title, source: 'ai', requestId, reason: '依頼の範囲に追加' } });
    assert.equal(result.status, 0, JSON.stringify(result.data));
    etag = result.data.data.etag; ids.push(result.data.data.requirements.at(-1).id);
  }
  const update = (requirementId, body) => rpc(h, { op: 'requirement_update', project, requirementId, etag, body });
  const missing = await update(ids[0], { status: 'completed' });
  assert.equal(missing.data.status, 422);
  assert.equal(missing.data.error, 'requirement_verification_required');
  const tooEnglish = await update(ids[0], { status: 'completed', verifiedBy: 'monet', note: 'RESULT: 確認しました' });
  assert.match(tooEnglish.data.message, /^note:/);
  const incomplete = await report();
  assert.equal(incomplete.data.error, 'unverified');
  const priorEvents = delivered.length;
  agents.slice(0, 3).forEach((a) => { a.status = 'idle'; });
  clock += 1000;
  await h.request('/v1/sessions', { token });
  await sink.flush();
  assert.equal(delivered.length, priorEvents);
  assert.equal(observed.filter((k) => k === 'session.finished').length, 2);
  assert.equal((await current()).body.data.requirementSummary.rate, 0);
  const open = await addDecision(h, 'same-project', ['--agent', 'a1', '--impact', '【必ず社長：本人認証】ログインを確かめます']);
  assert.equal(open.status, 0);
  for (const [i, id] of ids.entries()) {
    const updated = await update(id, { status: 'completed', verifiedBy: 'monet', note: '実行結果を確認', evidence: 'raw fixture evidence\nsecond line' });
    assert.equal(updated.status, 0, JSON.stringify(updated.data));
    etag = updated.data.data.etag;
    assert.equal(updated.data.data.requirementSummary.rate, (i + 1) / ids.length);
  }
  assert.equal((await report()).data.error, 'decision_pending');
  assert.equal((await runCli(h, ['decide', 'withdraw', open.data.decision.id, '--reason', '別途確認'])).status, 0);
  const detail = (await current()).body.data;
  assert.equal(detail.requirements[0].note, '実行結果を確認');
  assert.equal(detail.requirements[0].evidence, undefined);
  assert.equal((await rpc(h, { op: 'get', project })).data.data.requirements[0].evidence, 'raw fixture evidence\nsecond line');
  assert.deepEqual(detail.requirementDenominatorLog.map(({ delta, reason }) => [delta, reason]), [[1, '依頼の範囲に追加'], [1, '依頼の範囲に追加']]);
  const reports = await Promise.all([report(), report()]);
  assert.ok(reports.every((r) => r.status === 0), JSON.stringify(reports));
  assert.equal(reports.filter((r) => r.data.data.sent).length, 1);
  await h.restart();
  assert.equal((await report()).data.data.reason, 'duplicate');
  assert.deepEqual(delivered.map((e) => meta(e).k), ['decision.new', 'monet.report']);
  assert.equal(delivered[1].session_id.split('#')[0], `laa-bridge:laa://work/projects/${project}`);
  assert.equal(meta(delivered[1]).lv, undefined);
  for (const kind of ['agent-notification', 'monet.proposal']) {
    const result = await notify({ kind, title: '通知', body: '作業の内部メモ', deepLink: 'laa://work', dedupeKey: kind });
    assert.equal(result.reason, 'muted');
  }
  assert.equal(delivered.length, 2);
  const captures = delivered.map((e) => meta(e).k);
  t.diagnostic(JSON.stringify({ fixture: 'in-process loopback-only', parentFinishes: 2, childFinishes: 1,
    observedParentCompletionAttempts: observed.filter((k) => k === 'session.finished').length,
    captures, sessionFinishedPushes: 0, monetReportPushes: 1, replay: 'no_op', projectLink: true }));
});

test('C-5: agent fields reject English and handoffs; owner text remains verbatim', async (t) => {
  const noop = async () => ({ delivered: false, reason: 'muted' });
  const h = await startBridge({ sessions: { daemon: fixtureDaemon([]), notify: noop }, decisions: { notify: noop } });
  t.after(() => h.close());
  for (const [title, field] of [['Select a plan', 'title'], ['{日本語}', 'title'], ['RESULT: 確認', 'title']]) {
    const r = await runCli(h, ['decide', 'add', '--title', title, '--summary', '内容です', '--option', '案一', '--option', '案二', '--request-id', 'bad']);
    assert.equal(r.data.error.status, 422);
    assert.ok(r.data.error.message.startsWith(`${field}:`));
  }
  const notify = createOwnerNotifier({ file: join(h.stateDir, 'c5-notify.json'), deliver: async () => ({ delivered: true }) });
  const payload = { kind: 'session.error', title: 'Owner title', body: 'Owner wording', deepLink: 'laa://work', dedupeKey: 'surface' };
  await assert.rejects(notify({ ...payload, author: 'agent' }), { code: 'owner_surface_language', status: 422 });
  await assert.rejects(notify({ ...payload, author: 'agent', title: '事故の通知' }), { code: 'owner_surface_language', status: 422 });
  assert.equal((await notify({ ...payload, author: 'owner' })).delivered, true);
  const sessionStore = createSessionStore({ file: join(h.stateDir, 'lint-sessions.json') });
  const service = createSessionService({ sessionStore, daemon: fixtureDaemon([]), daemonMode: false, adapter: {}, notify: noop });
  const raw = 'RESULT: internal\n\nRaw assistant text — keep UTF-8\n';
  await assert.rejects(service.createSession({ deviceId: 'automation', body: { requestId: 'agent-lint', profile: 'opus-medium', name: 'Agent title', prompt: raw }, owner: false }), { code: 'owner_surface_language', status: 422 });
  const history = await readConversation('lang-test-agent', async () => ({
    fetchAgentTimeline: async (agentId) => ({ agentId, entries: [{ item: { type: 'assistant_message', text: raw } }] }),
    close: async () => {},
  }));
  assert.deepEqual(Buffer.from(history.items[0].text), Buffer.from(raw));
});

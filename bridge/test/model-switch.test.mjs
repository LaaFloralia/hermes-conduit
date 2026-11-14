import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createSessionStore } from '../src/sessions/store.mjs';
import { createModelSwitcher, joinedHistory, handoffSections } from '../src/sessions/model-switch.mjs';
import { createSessionService } from '../src/sessions/service.mjs';
import { daemonAdapter } from '../src/sessions/daemon.mjs';
import { BridgeError } from '../src/errors.mjs';
import { startBridge } from './helpers.mjs';

const profiles = [
  { id: 'claude-opus-high', provider: 'claude', model: 'opus', effort: 'high' },
  { id: 'codex-sol-high', provider: 'codex', model: 'sol', effort: 'high' },
  { id: 'dsh-high', provider: 'dsh', model: '["opencode-go","deepseek-v4.1-flash"]', effort: 'high' },
  { id: 'api-fable-high', provider: 'hermes-claude-api', model: 'fable', effort: 'high' },
];
const choices = () => ({ profiles });
const iso = '2026-11-14T00:00:00.000Z';

test('handoff quotes decisions, changed paths, checks and remaining work outside the recent tail without inventing facts', () => {
  const old = { id: 'earlier', role: 'assistant', text: '決定: 既定値を保持する\n変更: feature.mjs\n試験: 3成功\n残件: 画面は未実施' };
  const text = handoffSections([old, ...Array.from({ length: 15 }, (_, i) => ({ id: `u${i}`, role: 'user', text: '近況' }))]);
  for (const line of old.text.split('\n')) assert.ok(text.includes(`[assistant / earlier] ${line}`));
  assert.match(handoffSections([]), /抜粋できません/);
});
function fixture(t, overrides = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'model-switch-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  let clock = Date.parse(iso);
  const store = createSessionStore({ file: join(dir, 'sessions.json'), now: () => clock });
  const record = { id: 'ses_0123456789abcdef', name: 'owner title', nameSource: 'owner', favorite: true,
    parentId: 'ses_1111111111111111', projectId: 'prj_111111111111', source: 'paseo',
    requested: profiles[0], observed: profiles[0], phase: 'awaiting_review', mode: 'bypass',
    delegate: { sessionId: 'old' }, createdAt: iso, version: 1,
    modelLog: [{ provider: 'claude', model: 'opus', from: iso, to: iso }] };
  store.create({ record });
  const pages = new Map([['old', { items: [{ id: 'u1', role: 'user', text: '目的は青い舟。残件は帆の確認。', timestamp: iso }] }]]);
  const calls = [];
  const daemon = {
    continuationSource: async () => ({ id: 'old', workspaceId: 'same-workspace', cwd: '/workspace', parentAgentId: 'parent' }),
    startContinuation: async (input) => {
      calls.push(['start', input]);
      pages.set(input.id, { items: [{ id: 'u1', role: 'user', text: input.prompt }, { id: 'a1', role: 'assistant', text: '青い舟の帆を確認する。', timestamp: iso }] });
    },
    status: async () => ({ phase: 'awaiting_review', daemonStatus: 'idle', modelCheck: { observed: profiles[1], runtimeVerified: true } }),
    archiveDelegate: async (id) => calls.push(['archive', id]),
    restoreDelegate: async (id) => calls.push(['restore', id]),
    ...overrides,
  };
  const history = async (id) => pages.get(id) ?? { items: [] };
  const args = { store, daemon, history, choices, now: () => clock, sleep: async () => { clock += 100; }, timeoutMs: 200, pollMs: 100 };
  return { ...args, record, pages, calls, switcher: createModelSwitcher(args) };
}

test('a session that asks before acting is never continued without prompts', async (t) => {
  for (const mode of ['default', undefined]) {
    const f = fixture(t);
    f.store.update(f.record.id, (row) => { row.mode = mode; return []; });
    await assert.rejects(f.switcher.switchProvider(f.record.id, profiles[1]), (error) => error.code === 'model_unsupported');
    assert.equal(f.calls.length, 0, 'nothing is started');
    assert.equal(f.store.get(f.record.id).modelSwitch ?? null, null);
    assert.equal(f.store.get(f.record.id).delegate.sessionId, 'old');
  }
});

test('verified owner switch keeps the logical row, metadata, old message IDs and linked history', async (t) => {
  const f = fixture(t);
  const result = await f.switcher.switchProvider(f.record.id, profiles[1]);
  for (const key of ['id', 'name', 'favorite', 'parentId', 'projectId', 'requested', 'createdAt']) assert.deepEqual(result[key], f.record[key]);
  assert.equal(result.delegateHistory[0].sessionId, 'old');
  assert.equal(result.ownerChanged.provider, 'codex');
  assert.equal(result.modelLog.at(-1).owner, true);
  assert.equal(f.calls.at(-1)[0], 'archive');
  assert.equal(f.calls.at(-1)[1], 'old');
  const input = f.calls[0][1];
  assert.equal(input.source.workspaceId, 'same-workspace');
  assert.equal(input.source.parentAgentId, 'parent');
  const transcriptPath = input.prompt.match(/元の会話の記録: ([^\n]+)/)[1];
  assert.equal(JSON.parse(readFileSync(transcriptPath)).items[0].text, f.pages.get('old').items[0].text);
  const joined = await joinedHistory(result, f.history);
  assert.deepEqual(joined.items.map((item) => item.role), ['user', 'assistant']);
  assert.equal(joined.items[0].id, 'u1');
  assert.match(joined.items[1].id, /:a1$/);
});

test('the turns before a provider change stay in the conversation when the archived agent reads back empty', async (t) => {
  const f = fixture(t);
  f.pages.get('old').items.push({ id: 'a0', role: 'assistant', text: '帆を確認する。', timestamp: iso });
  const first = await f.switcher.switchProvider(f.record.id, profiles[1]);
  // The daemon drops an archived agent's timeline: the old id now reads empty.
  f.pages.delete('old');
  const service = createSessionService({ sessionStore: f.store, adapter: {}, daemon: f.daemon, history: f.history, choices, notify: async () => {} });
  const shown = (await service.conversation(f.record.id)).items;
  assert.deepEqual(shown.map((item) => item.id), ['u1', 'a0', `${first.delegate.sessionId}:a1`]);
  assert.equal(shown[0].text, '目的は青い舟。残件は帆の確認。');
  assert.equal((await joinedHistory(first, f.history)).items.length, 1, 'reading the daemon alone loses the earlier turns');
  // A second change carries the first snapshot forward, so nothing before it is lost either.
  f.daemon.status = async () => ({ phase: 'awaiting_review', daemonStatus: 'idle', modelCheck: { observed: profiles[2], runtimeVerified: true } });
  const second = await f.switcher.switchProvider(f.record.id, profiles[2]);
  f.pages.delete(first.delegate.sessionId);
  const after = (await service.conversation(f.record.id)).items;
  assert.deepEqual(after.map((item) => item.id),
    ['u1', 'a0', `${first.delegate.sessionId}:a1`, `${second.delegate.sessionId}:a1`]);
});

for (const reason of ['wrong model', 'unverified runtime', 'no first reply', 'startup failure']) {
  test(`${reason}: source stays selected and candidate is archived`, async (t) => {
    const f = fixture(t);
    if (reason === 'wrong model') f.daemon.status = async () => ({ phase: 'awaiting_review', modelCheck: { observed: profiles[0], runtimeVerified: true } });
    if (reason === 'unverified runtime') f.daemon.status = async () => ({ phase: 'awaiting_review', modelCheck: { observed: profiles[1], runtimeVerified: false } });
    if (reason === 'no first reply') f.daemon.startContinuation = async ({ id }) => f.pages.set(id, { items: [] });
    if (reason === 'startup failure') f.daemon.startContinuation = async () => { throw new Error('not available'); };
    await assert.rejects(f.switcher.switchProvider(f.record.id, profiles[1]), { code: 'model_switch_failed' });
    assert.equal(f.store.get(f.record.id).delegate.sessionId, 'old');
    assert.equal(f.store.get(f.record.id).modelSwitch, null);
    assert.equal(f.calls.find((c) => c[0] === 'restore')[1], 'old');
    assert.notEqual(f.calls.find((c) => c[0] === 'archive')[1], 'old');
  });
}

test('restart retries cleanup and never selects an unverified delegate', async (t) => {
  const f = fixture(t);
  f.store.update(f.record.id, (r) => { r.modelSwitch = { old: r.delegate, nextId: 'candidate' }; return []; });
  await f.switcher.recover();
  assert.equal(f.store.get(f.record.id).delegate.sessionId, 'old');
  assert.equal(f.store.get(f.record.id).modelSwitch, null);
  assert.deepEqual(f.calls, [['restore', 'old'], ['archive', 'candidate']]);
});

test('concurrent sends, updates and stop are refused while provider preparation is outstanding', async (t) => {
  const f = fixture(t);
  let release;
  f.daemon.continuationSource = () => new Promise((resolve) => { release = resolve; });
  const service = createSessionService({ sessionStore: f.store, adapter: {}, daemon: f.daemon,
    choices, history: f.history, now: f.now, sleep: f.sleep, modelSwitchOptions: { timeoutMs: 200, pollMs: 100 } });
  const switching = service.updateSession({ id: f.record.id, body: { provider: 'codex', model: 'sol', effort: 'high' } });
  await Promise.resolve();
  for (const operation of [
    () => service.sendMessage({ id: f.record.id, body: { text: 'do not send' } }),
    () => service.updateSession({ id: f.record.id, body: { favorite: false } }),
    () => service.stopSession(f.record.id),
  ]) await assert.rejects(operation(), { code: 'model_switch_pending' });
  release({ id: 'old', workspaceId: 'same', cwd: '/workspace', parentAgentId: 'parent' });
  assert.equal((await switching).session.id, f.record.id, 'the route receives the usual {session} envelope');
});

test('off-catalog provider/model/effort and below-High continuation are rejected', async (t) => {
  const f = fixture(t);
  assert.throws(() => f.switcher.choice({ provider: 'unknown', model: 'sol' }, f.record), { code: 'model_choice_invalid' });
  assert.throws(() => f.switcher.choice({ provider: 'codex', model: 'sol', effort: 'low' }, f.record), { code: 'model_choice_invalid' });
  await assert.rejects(f.switcher.switchProvider(f.record.id, { ...profiles[1], effort: 'medium' }), { code: 'model_choice_invalid' });
  assert.equal(f.calls.length, 0);
});

function nativeFixture() {
  const rows = [{ id: 'old', provider: 'claude', model: 'opus', workspaceId: 'w', cwd: '/workspace', title: 'same', status: 'idle', labels: { 'paseo.parent-agent-id': 'parent' } }];
  const calls = [];
  const client = {
    fetchAgent: async ({ agentId }) => ({ agent: rows.find((r) => r.id === agentId) }),
    fetchAgents: async () => ({ entries: rows.map((agent) => ({ agent })), pageInfo: { nextCursor: null } }),
    fetchWorkspaces: async () => ({ entries: [{ id: 'w', title: 'same' }], pageInfo: {} }),
    createAgent: async (input) => { calls.push(input); const row = { ...input, id: input.agentId, status: 'idle', labels: input.labels }; rows.push(row); return row; },
    archiveAgent: async (id) => { rows.find((r) => r.id === id).archivedAt = iso; },
    refreshAgent: async (id) => { rows.find((r) => r.id === id).archivedAt = null; },
  };
  return { rows, calls, daemon: daemonAdapter({ connect: async () => client }) };
}
for (const target of profiles.slice(1)) {
  test(`native ${target.provider} continuation retains parent/workspace and launch policy without copying auth`, async () => {
    const f = nativeFixture();
    const source = await f.daemon.continuationSource('old');
    await f.daemon.startContinuation({ source, id: 'new', target, prompt: 'handoff only' });
    const call = f.calls[0];
    assert.equal(call.callerAgentId, 'parent'); assert.equal(call.workspaceId, 'w'); assert.equal(call.cwd, '/workspace');
    assert.equal(call.thinkingOptionId, 'high');
    assert.equal(call.provider, target.provider); assert.equal(call.model, target.model);
    assert.equal('auth' in call, false); assert.equal('env' in call, false);
    assert.deepEqual(call.featureValues, target.provider === 'codex' ? { service_tier: 'default' } : { auto_accept: true });
    f.rows.push({ id: 'idle-child', status: 'idle', labels: { 'paseo.parent-agent-id': 'old' } });
    await f.daemon.archiveDelegate('old');
    assert.equal(f.rows.find((r) => r.id === 'idle-child').archivedAt, undefined);
  });
}
for (const scenario of ['turn', 'decision', 'child', 'grandchild']) {
  test(`native rejects ${scenario} before creating another agent`, async () => {
    const f = nativeFixture();
    if (scenario === 'turn') f.rows[0].activeTurn = { id: 't' };
    if (scenario === 'decision') f.rows[0].pendingPermissions = [{ id: 'd' }];
    if (scenario === 'child' || scenario === 'grandchild') f.rows.push({ id: 'c', status: scenario === 'child' ? 'running' : 'idle', labels: { 'paseo.parent-agent-id': 'old' } });
    if (scenario === 'grandchild') f.rows.push({ id: 'g', status: 'running', labels: { 'paseo.parent-agent-id': 'c' } });
    await assert.rejects(f.daemon.continuationSource('old'), (e) => e instanceof BridgeError && e.status === 409);
    assert.equal(f.calls.length, 0);
  });
}

test('a child under a retired execution agent still blocks a later logical conversation switch', async () => {
  const f = nativeFixture();
  f.rows.push({ id: 'c', status: 'running', labels: { 'paseo.parent-agent-id': 'retired' } });
  await assert.rejects(f.daemon.continuationSource('old', { relatedIds: ['retired'] }), { code: 'model_switch_children_busy' });
});

test('a child starting during handoff preparation is checked again before native creation', async () => {
  const f = nativeFixture();
  const source = await f.daemon.continuationSource('old');
  f.rows.push({ id: 'c', status: 'running', labels: { 'paseo.parent-agent-id': 'old' } });
  await assert.rejects(f.daemon.startContinuation({ source, id: 'new', target: profiles[1], prompt: 'test' }), { code: 'model_switch_children_busy' });
  assert.equal(f.calls.length, 0);
});

test('pending cleanup remains visible and blocks sends until recovery succeeds', async (t) => {
  const f = fixture(t);
  f.daemon.startContinuation = async () => { throw new Error('failed after allocation'); };
  f.daemon.archiveDelegate = async () => { throw new BridgeError(409, 'model_switch_pending', 'still running'); };
  await assert.rejects(f.switcher.switchProvider(f.record.id, profiles[1]), { code: 'model_switch_failed' });
  assert.ok(f.store.get(f.record.id).modelSwitch);
  assert.throws(() => f.switcher.assertUnlocked(f.record.id), { code: 'model_switch_pending' });
  assert.equal(f.store.get(f.record.id).delegate.sessionId, 'old');
  f.daemon.archiveDelegate = async () => {};
  await f.switcher.recover();
  assert.equal(f.store.get(f.record.id).modelSwitch, null);
});

test('directory sync joins retired aliases to the original row and preserves child parentage', async (t) => {
  const f = fixture(t);
  const { delegate } = await f.switcher.switchProvider(f.record.id, profiles[1]);
  f.daemon.list = async () => [
    { id: 'old', provider: 'claude', model: 'opus', status: 'idle', archivedAt: iso, labels: {}, createdAt: iso, updatedAt: iso },
    { id: delegate.sessionId, provider: 'codex', model: 'sol', status: 'idle', thinkingOptionId: 'high', labels: { 'laa.bridge.model-continuation': 'old' }, createdAt: iso, updatedAt: iso },
    { id: 'child-of-original', provider: 'codex', status: 'idle', labels: { 'paseo.parent-agent-id': 'old' }, createdAt: iso, updatedAt: iso },
  ];
  f.daemon.workspacePins = async () => [];
  f.daemon.tidyWorkspaces = async () => {};
  f.daemon.exists = async () => true;
  const service = createSessionService({ sessionStore: f.store, adapter: {}, daemon: f.daemon, choices, notify: async () => {} });
  await service.syncDaemon();
  assert.equal(f.store.all().length, 2, 'one logical conversation and its child');
  assert.equal(f.store.all().find((r) => r.delegate.sessionId === 'child-of-original').parentId, f.record.id);
  const current = f.store.get(f.record.id);
  assert.equal(current.name, f.record.name); assert.equal(current.favorite, true);
  assert.equal(current.projectId, f.record.projectId);
  assert.equal(current.delegate.handoff, true);
  assert.equal(current.delegateHistory[0].sessionId, 'old');
});

test('project defaults persist with ETag, reject unlisted choices and feed new sessions while explicit choices win', async (t) => {
  const creates = [];
  const api = await startBridge({ sessions: { options: choices, adapter: {
    create: async (input) => { creates.push(input); return { sessionId: `a-${creates.length}`, requested: profiles.find((p) => p.id === input.profile), phase: 'created' }; },
  } } });
  t.after(() => api.close());
  const token = await api.token();
  const created = await api.request('/v1/projects', { method: 'POST', token, key: 'project-create', body: { name: 'default check', defaultProfile: profiles[0].id } });
  assert.equal(created.status, 201);
  const id = created.body.data.id;
  const path = `/v1/projects/${id}`;
  const patch = (body, etag, key) => api.request(path, { method: 'PATCH', token, key, headers: { 'if-match': etag }, body });
  const updated = await patch({ defaultProfile: profiles[1].id }, '"1"', 'default-update');
  assert.equal(updated.status, 200); assert.equal(updated.body.data.defaultProfile, profiles[1].id);
  assert.equal(updated.body.data.instructionVersion, 0);
  assert.equal((await patch({ defaultProfile: profiles[0].id }, '"1"', 'stale')).status, 412);
  assert.equal((await patch({ defaultProfile: 'unlisted' }, '"2"', 'unlisted')).status, 400);
  const make = (requestId, extra = {}) => api.request('/v1/sessions', { method: 'POST', token, key: requestId,
    body: { requestId, projectId: id, prompt: 'verify default', ...extra } });
  const inherited = await make('default-inherited');
  assert.equal(inherited.status, 201, JSON.stringify(inherited.body));
  assert.equal(creates.at(-1).profile, profiles[1].id);
  assert.equal((await make('default-explicit', { profile: profiles[0].id })).status, 201);
  assert.equal(creates.at(-1).profile, profiles[0].id);
  assert.equal((await patch({ defaultProfile: null }, '"2"', 'clear')).body.data.defaultProfile, null);
});

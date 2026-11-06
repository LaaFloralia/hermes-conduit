import assert from 'node:assert/strict';
import test from 'node:test';
import { appendFileSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, truncateSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { daemonAdapter, daemonSessionID, pendingHash } from '../src/sessions/daemon.mjs';
import { createSessionService, fastValue } from '../src/sessions/service.mjs';
import { createSessionStore } from '../src/sessions/store.mjs';
import { readConversation } from '../src/sessions/history.mjs';
import { sessionImageStore } from '../src/sessions/images.mjs';
import { inspectLocalImage, readLocalImage, settleLocalImages, splitLocalImages } from '../src/sessions/local-images.mjs';
import { startBridge } from './helpers.mjs';
import { createOwnerNotifier } from '../src/notify/index.mjs';

function fixture(options = {}) {
  const calls = [], rows = [{ id: 'parent', title: '親', workspaceId: options.workspaceId, provider: 'codex', model: 'gpt-6.1-sol', effectiveThinkingOptionId: 'high', createdAt: '2026-11-01T00:00:00Z', updatedAt: '2026-11-02T00:00:00Z', status: 'running', labels: {} },
    { id: 'child', title: '子', workspaceId: 'ws-child', provider: 'dsh', model: '["opencode-go","deepseek-v4.1-flash"]', createdAt: '2026-11-01T00:00:00Z', updatedAt: '2026-11-02T00:00:00Z', status: 'idle', labels: { 'paseo.parent-agent-id': 'parent' } }];
  const workspaces = options.workspaceTitle
    ? [{ id: options.workspaceId, title: options.workspaceTitle, pinnedAt: null }]
    : [];
  const client = { close: async () => {}, fetchAgent: async ({ agentId }) => ({ agent: rows.find((a) => a.id === agentId) }),
    getLastServerInfoMessage: () => ({ features: options.serverFeatures ?? { agentThinkingUpdate: true } }),
    fetchWorkspaces: async () => ({ entries: workspaces, pageInfo: { nextCursor: null } }),
    fetchAgents: async ({ page }) => { calls.push(['list', page.cursor]); return page.cursor ? { entries: [{ agent: rows[1] }], pageInfo: { nextCursor: null } } : { entries: [{ agent: rows[0] }], pageInfo: { nextCursor: 'next' } }; },
    sendMessage: async (...args) => calls.push(['send', ...args]), cancelAgent: async (id) => { calls.push(['cancel', id]); rows[0].status = 'idle'; },
    setAgentThinkingOption: async (id, effort) => {
      calls.push(['effort', id, effort]);
      if (options.effortRejected) throw new Error('provider refused');
      if (!options.effortNoop) rows.find((a) => a.id === id).effectiveThinkingOptionId = effort;
    },
    respondToPermissionAndWait: async (id, request, response) => { calls.push(['reply', id, request, response]); rows.find((a) => a.id === id).pendingPermissions = []; },
  };
  return { rows, calls, client, daemon: daemonAdapter({ connect: async () => client, now: () => 1000 }) };
}

test('directory follows every daemon page; running sends steer with stable ID and images', async () => {
  const f = fixture();
  assert.equal((await f.daemon.list()).length, 2);
  await f.daemon.send('parent', { text: '追加', messageId: 'm-1', images: [{ data: 'YWJj', mimeType: 'image/png' }] });
  const send = f.calls.find((c) => c[0] === 'send');
  assert.equal(send[3].activeTurnBehavior, 'steer');
  assert.equal(send[3].messageId, 'm-1');
  assert.equal(send[3].images.length, 1);
  f.rows[0].pendingPermissions = [{ id: 'p1' }];
  await assert.rejects(f.daemon.send('parent', { text: 'extra' }), { code: 'pending_decision_requires_reply' });
});

test('decision rejects changed hashes, expiry and incomplete answers; confirms actual consumption', async () => {
  const f = fixture();
  f.rows[0].pendingPermissions = [{ id: 'p1', kind: 'question', name: 'request_user_input_async', input: { questions: [{ question: 'どちら？', options: [{ label: 'A' }] }] } }];
  const d = await f.daemon.decision('parent');
  assert.equal(d.requests[0].questions[0].options[0], 'A');
  const body = { requestId: 'p1', requestHash: d.requestHash, expiresAt: d.expiresAt, decision: 'answer', answers: { 0: 'A' } };
  await assert.rejects(f.daemon.reply('parent', { ...body, requestHash: 'changed' }), { code: 'stale_decision' });
  await assert.rejects(f.daemon.reply('parent', { ...body, expiresAt: 0 }), { code: 'stale_decision' });
  await assert.rejects(f.daemon.reply('parent', { ...body, answers: {} }), { code: 'answer_required' });
  await f.daemon.reply('parent', body);
  assert.deepEqual(f.calls.find((c) => c[0] === 'reply')[3], { behavior: 'allow', updatedInput: { answers: { 'Question 1': 'A' } } });
});

test('directory imports external sessions and parent links; updates metadata and notifies a transition once', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'paseo-bridge-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
  const f = fixture(), pushes = [];
  const store = createSessionStore({ file: join(dir, 'sessions.json') });
  const service = createSessionService({ sessionStore: store, daemon: f.daemon, adapter: {}, findWorkspace: async () => null, notify: async (p) => pushes.push(p) });
  const list = await service.listSessions();
  assert.equal(list.items.length, 2);
  assert.equal(store.get(daemonSessionID('child')).parentId, daemonSessionID('parent'));
  assert.equal(pushes.length, 0);
  service.updateSession({ id: daemonSessionID('parent'), body: { favorite: true } });
  f.rows[0].status = 'idle'; f.rows[0].title = '新しい名前';
  await service.syncDaemon(); await service.syncDaemon();
  assert.equal(pushes.length, 1);
  assert.equal(pushes[0].deepLink, `laa://work/sessions/${daemonSessionID('parent')}`);
  assert.equal(store.get(daemonSessionID('parent')).favorite, true);
  assert.equal(store.get(daemonSessionID('parent')).name, '新しい名前');
  await service.stopSession(daemonSessionID('parent'));
  await service.getSession(daemonSessionID('parent'));
  assert.equal(store.get(daemonSessionID('parent')).phase, 'stopped');
});

test('conversation exposes message IDs and only tool name/status, never raw output or reasoning', async () => {
  const c = { close: async () => {}, fetchAgentTimeline: async () => ({ agentId: 'a', entries: [
    { item: { type: 'user_message', text: 'hello', clientMessageId: 'm1' } },
    { item: { type: 'reasoning', text: 'private reasoning' } },
    { item: { type: 'tool_call', callId: 't1', name: 'Read', status: 'completed', detail: { output: 'private output' } } },
  ] }) };
  const messages = await readConversation('a', async () => c);
  assert.equal(messages[0].id, 'm1');
  assert.equal(messages[1].role, 'tool');
  assert.doesNotMatch(JSON.stringify(messages), /private/);
});

test('owner notification reuses plugin event routing and durable dedupe; failures are not recorded as delivered', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'paseo-notify-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
  const file = join(dir, 'notify.json'), sent = [];
  const payload = { kind: 'session.finished', title: '終了', body: '確認してください', deepLink: 'laa://work/sessions/ses_0123456789abcdef', dedupeKey: 'one' };
  const notify = createOwnerNotifier({ file, deliver: async (p) => { sent.push(p); return { delivered: true }; } });
  assert.equal((await notify(payload)).delivered, true);
  assert.equal(sent[0].session_id, `laa-bridge:${payload.deepLink}`);
  assert.equal((await notify(payload)).reason, 'duplicate');
  const afterRestart = createOwnerNotifier({ file, deliver: async () => assert.fail('duplicate delivery') });
  assert.equal((await afterRestart(payload)).reason, 'duplicate');
  assert.equal((await notify({ ...payload, deepLink: 'https://example.com' })).reason, 'invalid_notification');
  let failures = 0;
  const retry = createOwnerNotifier({ file, deliver: async () => { failures++; return { delivered: false }; } });
  await retry({ ...payload, dedupeKey: 'two' }); await retry({ ...payload, dedupeKey: 'two' });
  assert.equal(failures, 2);
});


test('image attachments retain exact bytes and session isolation; malformed and oversized inputs fail before send', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'paseo-images-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
  const f = fixture(), store = createSessionStore({ file: join(dir, 'sessions.json') });
  const service = createSessionService({ sessionStore: store, daemon: f.daemon, adapter: {}, findWorkspace: async () => null,
    history: async () => [{ id: 'm1', role: 'user', text: '画像' }], notify: async () => {} });
  await service.syncDaemon();
  const id = daemonSessionID('parent');
  await service.sendMessage({ id, key: 'image-1', body: { message: '画像', messageId: 'm1', images: [{ data: 'YWJj', mimeType: 'image/png' }] } });
  const messages = await service.conversation(id), imageID = messages[0].images[0];
  assert.equal(service.image(id, imageID).data, 'YWJj');
  assert.throws(() => service.image(daemonSessionID('child'), imageID), { code: 'not_found' });
  await assert.rejects(service.sendMessage({ id, key: 'bad', body: { message: '画像', images: [{ data: 'YWJj', mimeType: 'text/html' }] } }), { status: 400 });
  assert.equal(f.calls.filter((x) => x[0] === 'send').length, 1);
});

test('undelivered owner notifications survive restart and keep the complete calendar link', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'paseo-notify-retry-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
  const file = join(dir, 'notify.json');
  const payload = { kind: 'calendar.reminder', title: '予定', body: '開始します', deepLink: 'laa://today/events/same-id?calendar=team%40example.com', dedupeKey: 'calendar-1' };
  const first = createOwnerNotifier({ file, deliver: async () => ({ delivered: false }) });
  await first(payload);
  const sent = [];
  const retry = createOwnerNotifier({ file, deliver: async (event) => { sent.push(event); return { delivered: true }; } });
  await retry.flush(); await retry.flush();
  assert.equal(sent.length, 1);
  assert.equal(sent[0].session_id, 'laa-bridge:' + payload.deepLink);
});


test('interrupt confirms cancellation and permits another instruction in the same conversation', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'paseo-interrupt-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
  const f = fixture(), service = createSessionService({ sessionStore: createSessionStore({ file: join(dir, 'sessions.json') }), daemon: f.daemon, adapter: {}, findWorkspace: async () => null, notify: async () => {} });
  await service.syncDaemon(); const id = daemonSessionID('parent');
  assert.equal((await service.interruptSession(id)).session.phase, 'awaiting_review');
  await service.sendMessage({ id, key: 'after-interrupt', body: { message: 'この会話で続けて' } });
  assert.equal(f.calls.filter(x => x[0] === 'cancel').length, 1);
  assert.equal(f.calls.filter(x => x[0] === 'send').length, 1);
});


test('owner scopes gate interruption, images and decisions, and a replay cannot answer twice', async (t) => {
  const f = fixture(), bridge = await startBridge({ sessions: { daemon: f.daemon, notify: async () => {} } });
  t.after(() => bridge.close());
  const token = await bridge.token(['sessions:read', 'sessions:write']);
  const readOnly = await bridge.token(['sessions:read']);
  const id = daemonSessionID('parent');
  await bridge.request('/v1/sessions', { token });
  f.rows[0].pendingPermissions = [{ id: 'permission-1', kind: 'tool', name: 'Read', input: { path: 'fixture.txt' } }];
  const decision = await bridge.request(`/v1/sessions/${id}/decision`, { token });
  const body = { requestId: 'permission-1', requestHash: decision.body.data.requestHash, expiresAt: decision.body.data.expiresAt, decision: 'allow' };
  assert.equal((await bridge.request(`/v1/sessions/${id}/reply`, { token: readOnly, method: 'POST', key: 'no-permission', body })).status, 403);
  assert.equal((await bridge.request(`/v1/sessions/${id}/interrupt`, { token: readOnly, method: 'POST', key: 'no-interrupt', body: {} })).status, 403);
  const options = { token, method: 'POST', key: 'answer-once', body };
  assert.equal((await bridge.request(`/v1/sessions/${id}/reply`, options)).status, 200);
  assert.equal((await bridge.request(`/v1/sessions/${id}/reply`, options)).status, 200);
  assert.equal(f.calls.filter(x => x[0] === 'reply').length, 1);
  assert.equal((await bridge.request(`/v1/sessions/${id}/images/${'a'.repeat(64)}`)).status, 401);
});

function archiveFixture() {
  const calls = [], agents = [
    { id: 'root', title: '親', provider: 'dsh', status: 'idle', workspaceId: 'wks_a', labels: {}, createdAt: '2026-11-01T00:00:00Z', updatedAt: '2026-11-02T00:00:00Z' },
    { id: 'kid', title: '子', provider: 'dsh', status: 'closed', workspaceId: 'wks_a', labels: { 'paseo.parent-agent-id': 'root' }, createdAt: '2026-11-01T00:00:00Z', updatedAt: '2026-11-02T00:00:00Z' },
    { id: 'other', title: '別', provider: 'dsh', status: 'idle', workspaceId: 'wks_b', labels: {}, createdAt: '2026-11-01T00:00:00Z', updatedAt: '2026-11-02T00:00:00Z' },
  ];
  const workspaces = [{ id: 'wks_a', workspaceKind: 'directory' }, { id: 'wks_b', workspaceKind: 'worktree' }];
  const client = { close: async () => {},
    fetchAgent: async ({ agentId }) => ({ agent: agents.find((a) => a.id === agentId) }),
    fetchAgents: async () => ({ entries: agents.map((agent) => ({ agent })), pageInfo: { nextCursor: null } }),
    fetchWorkspaces: async () => ({ entries: workspaces.filter((w) => !w.archived) }),
    archiveAgent: async (id) => { calls.push(['archive', id]); for (const a of agents) if (a.id === id || a.labels['paseo.parent-agent-id'] === id) a.archivedAt ??= '2026-11-05T00:00:00Z'; },
    archiveWorkspace: async (id) => { calls.push(['archiveWorkspace', id]); workspaces.find((w) => w.id === id).archived = true; return { error: null }; },
    restoreWorkspace: async (id) => { calls.push(['restoreWorkspace', id]); workspaces.find((w) => w.id === id).archived = false; },
    refreshAgent: async (id) => { calls.push(['refresh', id]); agents.find((a) => a.id === id).archivedAt = null; },
  };
  return { agents, calls, daemon: daemonAdapter({ connect: async () => client, now: () => 1000 }) };
}

test('a parent left on its sent title shows the title Paseo gave its workspace', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'paseo-bridge-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
  const agents = [
    { id: 'plain', title: '依頼の一行目', workspaceId: 'wks_a', labels: {} },
    { id: 'named', title: 'エージェントの命名', workspaceId: 'wks_b', labels: {} },
    { id: 'kid', title: '子｜作業', workspaceId: 'wks_a', labels: { 'paseo.parent-agent-id': 'plain' } },
    { id: 'owner', title: '社長の名前', workspaceId: 'wks_c', labels: {} },
    { id: 'native', title: 'Paseoで作成', workspaceId: 'wks_d', labels: {} },
    { id: 'shared-1', title: '共有一', workspaceId: 'wks_e', labels: {} },
    { id: 'shared-2', title: '共有二', workspaceId: 'wks_e', labels: {} },
  ].map((a) => ({ ...a, provider: 'dsh', status: 'idle', createdAt: '2026-11-01T00:00:00Z', updatedAt: '2026-11-02T00:00:00Z' }));
  const client = { close: async () => {}, fetchAgent: async ({ agentId }) => ({ agent: agents.find((a) => a.id === agentId) }),
    fetchAgents: async () => ({ entries: agents.map((agent) => ({ agent })), pageInfo: { nextCursor: null } }),
    fetchWorkspaces: async () => ({ entries: ['wks_a', 'wks_b', 'wks_c', 'wks_d', 'wks_e'].map((id) => ({ id, title: 'Paseoの題名' })) }) };
  const store = createSessionStore({ file: join(dir, 'sessions.json') });
  const service = createSessionService({ sessionStore: store, daemon: daemonAdapter({ connect: async () => client, now: () => 1000 }), adapter: {}, findWorkspace: async () => null, notify: async () => {} });
  await service.syncDaemon();
  store.update(daemonSessionID('plain'), (r) => { r.sentTitle = '依頼の一行目'; });
  store.update(daemonSessionID('named'), (r) => { r.sentTitle = '依頼'; });
  store.update(daemonSessionID('kid'), (r) => { r.sentTitle = '子｜作業'; });
  store.update(daemonSessionID('owner'), (r) => { r.sentTitle = '社長の名前'; r.name = '社長の名前'; r.nameSource = 'owner'; });
  await service.syncDaemon();
  assert.equal(store.get(daemonSessionID('plain')).name, 'Paseoの題名');
  assert.equal(store.get(daemonSessionID('named')).name, 'エージェントの命名');
  assert.equal(store.get(daemonSessionID('kid')).name, '子｜作業');
  assert.equal(store.get(daemonSessionID('owner')).name, '社長の名前');
  assert.equal(store.get(daemonSessionID('native')).name, 'Paseoの題名');
  assert.equal(store.get(daemonSessionID('shared-1')).name, '共有一');
});

test('archive reaches Paseo for the whole tree and clears the emptied workspace; restore brings back one row', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'paseo-bridge-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
  const f = archiveFixture();
  const store = createSessionStore({ file: join(dir, 'sessions.json') });
  const service = createSessionService({ sessionStore: store, daemon: f.daemon, adapter: {}, findWorkspace: async () => null, notify: async () => {} });
  await service.listSessions();
  const root = daemonSessionID('root'), kid = daemonSessionID('kid');

  const { session } = await service.updateSession({ id: root, body: { archived: true } });
  assert.ok(session.archivedAt);
  assert.ok(store.get(kid).archivedAt, 'the child follows its parent');
  assert.deepEqual(f.calls, [['archive', 'root'], ['archiveWorkspace', 'wks_a']]);
  assert.deepEqual((await service.listSessions()).items.map((r) => r.id), [daemonSessionID('other')]);
  assert.equal((await service.listSessions({ archived: 'only' })).items.length, 2);

  f.calls.length = 0;
  await service.updateSession({ id: root, body: { archived: false } });
  assert.deepEqual(f.calls, [['restoreWorkspace', 'wks_a'], ['refresh', 'root']]);
  assert.equal(store.get(root).archivedAt, null);
  assert.ok(store.get(kid).archivedAt, 'a restored parent leaves its children archived');
  await service.syncDaemon();
  assert.equal(store.get(root).daemonArchivedAt, null);
});

test('archive refuses a tree with a running or undecided agent and leaves everything as it was', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'paseo-bridge-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
  const f = archiveFixture();
  const store = createSessionStore({ file: join(dir, 'sessions.json') });
  const service = createSessionService({ sessionStore: store, daemon: f.daemon, adapter: {}, findWorkspace: async () => null, notify: async () => {} });
  await service.listSessions();
  const root = daemonSessionID('root');

  f.agents[1].status = 'running';
  await assert.rejects(service.updateSession({ id: root, body: { archived: true } }), { code: 'session_running' });
  f.agents[1].status = 'idle'; f.agents[1].pendingPermissions = [{ id: 'p' }];
  await assert.rejects(service.updateSession({ id: root, body: { archived: true } }), { code: 'session_running' });
  assert.deepEqual(f.calls, []);
  assert.equal(store.get(root).archivedAt ?? null, null);
});

test('a worktree workspace survives archiving its last agent', async () => {
  const f = archiveFixture();
  await f.daemon.archive(['other']);
  assert.deepEqual(f.calls, [['archive', 'other']]);
});

test('a session Paseo brought back leaves the LAA archive too', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'paseo-bridge-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
  const f = archiveFixture();
  const store = createSessionStore({ file: join(dir, 'sessions.json') });
  const service = createSessionService({ sessionStore: store, daemon: f.daemon, adapter: {}, findWorkspace: async () => null, notify: async () => {} });
  await service.listSessions();
  await service.updateSession({ id: daemonSessionID('other'), body: { archived: true } });
  await service.syncDaemon();
  f.agents[2].archivedAt = null;
  await service.syncDaemon();
  assert.equal(store.get(daemonSessionID('other')).archivedAt, null);
});

test('a list row and its detail use the same Paseo workspace title', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'paseo-name-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
  const f = fixture({ workspaceTitle: '短い題名', workspaceId: 'ws-parent' });
  f.rows[0].title = 'LAAアプリの各社員やっぱり人ではなく、とても長い依頼文';
  const store = createSessionStore({ file: join(dir, 'sessions.json') });
  const service = createSessionService({ sessionStore: store, daemon: f.daemon, adapter: {}, findWorkspace: async () => null, notify: async () => {}, observationTtlMs: 0 });
  await service.listSessions();
  const id = daemonSessionID('parent');
  assert.equal(store.get(id).name, '短い題名');
  // The detail read used to overwrite this with the agent's long prompt.
  const detail = await service.getSession(id);
  assert.equal(detail.session.name, '短い題名');
  assert.equal(store.get(id).name, '短い題名');

  // An agent that renamed itself after the Bridge's title wins in both places.
  store.update(id, (record) => { record.sentTitle = 'LAA｜送った題名'; return []; });
  f.rows[0].title = 'エージェントが付けた名前';
  assert.equal((await service.getSession(id)).session.name, 'エージェントが付けた名前');
  await service.syncDaemon();
  assert.equal(store.get(id).name, 'エージェントが付けた名前');
  assert.equal((await service.listSessions()).items.find((row) => row.id === id).name, 'エージェントが付けた名前');
});

test('a failed workspace lookup keeps the last confirmed title in list and detail', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'paseo-name-down-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
  const f = fixture({ workspaceTitle: '短い題名', workspaceId: 'ws-parent' });
  f.rows[0].title = 'LAAアプリの各社員やっぱり人ではなく、とても長い依頼文';
  const store = createSessionStore({ file: join(dir, 'sessions.json') });
  const service = createSessionService({ sessionStore: store, daemon: f.daemon, adapter: {}, findWorkspace: async () => null, notify: async () => {}, observationTtlMs: 0 });
  await service.listSessions();
  const id = daemonSessionID('parent');
  assert.equal(store.get(id).name, '短い題名');

  // The very first detail read cannot reach the workspace directory. The saved
  // name must stay; the long agent title must not come back.
  f.client.fetchWorkspaces = async () => { throw new Error('workspace directory down'); };
  assert.equal((await service.getSession(id)).session.name, '短い題名');
  await service.syncDaemon();
  assert.equal(store.get(id).name, '短い題名');
  assert.equal((await service.listSessions()).items.find((row) => row.id === id).name, '短い題名');

  // A later successful read with a new title replaces it everywhere.
  f.client.fetchWorkspaces = async () => ({ entries: [{ id: 'ws-parent', title: '新しい短名', pinnedAt: null }], pageInfo: { nextCursor: null } });
  await service.syncDaemon();
  assert.equal(store.get(id).name, '新しい短名');
  assert.equal((await service.getSession(id)).session.name, '新しい短名');
});

test('Fast is cleared when a later successful observation stops reporting it, and kept on failure', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'paseo-fast-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
  const f = fixture({ workspaceTitle: '短い題名', workspaceId: 'ws-parent' });
  // The shape Paseo actually returns for an Opus agent.
  f.rows[0].features = [{ type: 'toggle', id: 'fast_mode', label: 'Fast',
    description: 'Lower latency Opus responses at higher token cost', tooltip: 'Toggle fast mode', icon: 'zap', value: true }];
  const store = createSessionStore({ file: join(dir, 'sessions.json') });
  const service = createSessionService({ sessionStore: store, daemon: f.daemon, adapter: {}, findWorkspace: async () => null, notify: async () => {}, observationTtlMs: 0 });
  await service.listSessions();
  const id = daemonSessionID('parent');
  assert.equal(service.view(store.get(id)).observedFast, true);
  await service.getSession(id);
  assert.equal(service.view(store.get(id)).observedFast, true);

  // A normal observation with no toggle reported is "unknown now", not "on".
  f.rows[0].features = [];
  await service.getSession(id);
  assert.equal(service.view(store.get(id)).observedFast, null);

  f.rows[0].features = [{ id: 'fast_mode', value: false }];
  await service.getSession(id);
  assert.equal(service.view(store.get(id)).observedFast, false);

  // A failed observation says nothing about the setting: keep the last value.
  f.client.fetchAgent = async () => { throw new Error('daemon down'); };
  const failed = await service.getSession(id);
  assert.equal(failed.observation.available, false);
  assert.equal(service.view(store.get(id)).observedFast, false);

  assert.equal(fastValue([{ type: 'toggle', id: 'fast_mode', label: 'Fast', value: true }]), true);
  assert.equal(fastValue([{ id: 'fast_mode' }]), null);
  assert.equal(fastValue(null), null);
});

test('effort changes use the daemon, are verified by read-back, and are refused when unsupported', async (t) => {
  const make = async (options = {}, withDaemon = true) => {
    const dir = mkdtempSync(join(tmpdir(), 'paseo-effort-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
    const f = fixture(options);
    const store = createSessionStore({ file: join(dir, 'sessions.json') });
    const service = createSessionService({
      sessionStore: store, daemon: withDaemon ? f.daemon : null, adapter: {},
      findWorkspace: async () => null, notify: async () => {},
    });
    await service.listSessions();
    return { f, store, service, id: daemonSessionID('parent') };
  };

  const ok = await make();
  assert.equal(ok.service.view((await ok.service.getSession(ok.id)).session).capabilities.effort, true);
  assert.equal(ok.service.view((await ok.service.getSession(ok.id)).session).observed.effort, 'high');
  const updated = await ok.service.updateSession({ id: ok.id, body: { effort: 'low' } });
  assert.equal(ok.service.view(updated.session).observed.effort, 'low');
  assert.deepEqual(ok.f.calls.find((call) => call[0] === 'effort'), ['effort', 'parent', 'low']);

  const noop = await make({ effortNoop: true });
  await assert.rejects(noop.service.updateSession({ id: noop.id, body: { effort: 'low' } }), { code: 'effort_not_applied' });
  const refused = await make({ effortRejected: true });
  await assert.rejects(refused.service.updateSession({ id: refused.id, body: { effort: 'low' } }), { code: 'effort_rejected' });
  const unsupported = await make({ serverFeatures: {} });
  assert.equal(unsupported.service.view((await unsupported.service.getSession(unsupported.id)).session).capabilities.effort, false);
  await assert.rejects(unsupported.service.updateSession({ id: unsupported.id, body: { effort: 'low' } }), { code: 'effort_unsupported' });
  const adapterOnly = await make({}, false);
  adapterOnly.store.create({ record: {
    id: adapterOnly.id, requestId: 'paseo-parent', name: '親', nameSource: 'agent', parentId: null,
    projectId: null, workspaceId: 'home', cwd: '/Users/laa', profile: 'codex',
    requested: { provider: 'codex', model: 'gpt', effort: 'high' }, observed: null,
    phase: 'created', createdAt: '2026-11-01T00:00:00Z', updatedAt: '2026-11-01T00:00:00Z',
    delegate: { sessionId: 'parent' },
  } });
  await assert.rejects(adapterOnly.service.updateSession({ id: adapterOnly.id, body: { effort: 'low' } }), { code: 'effort_unsupported' });
  await assert.rejects(ok.service.updateSession({ id: ok.id, body: { effort: '../etc/passwd' } }), { status: 400 });
});

test("only a session's own checked Paseo attachment is served as its image", async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'paseo-local-images-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
  const root = realpathSync(dir);
  const attachments = join(root, 'paseo-attachments-fixture'); mkdirSync(attachments);
  const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0]);
  const okPath = join(attachments, 'ok.png'); writeFileSync(okPath, png);
  const outside = join(root, 'outside.png'); writeFileSync(outside, png);
  const wrongMagic = join(attachments, 'wrong.png'); writeFileSync(wrongMagic, Buffer.from('not an image'));
  const travel = join(attachments, '..', '..', 'outside.png');
  const linked = join(attachments, 'linked.png'); symlinkSync(okPath, linked);
  const big = join(attachments, 'big.png'); writeFileSync(big, png); truncateSync(big, 8 * 1024 * 1024 + 1);
  const nested = join(attachments, 'nested'); mkdirSync(nested);
  const nestedPath = join(nested, 'ok.png'); writeFileSync(nestedPath, png);
  const inspect = (path) => inspectLocalImage(path, { tempRoot: root });
  assert.equal(inspect(okPath)?.mimeType, 'image/png');
  assert.equal(inspect(outside), null);
  assert.equal(inspect(travel), null);
  assert.equal(inspect(linked), null);
  assert.equal(inspect(wrongMagic), null);
  assert.equal(inspect(big), null);
  assert.equal(inspect(nestedPath), null);
  assert.equal(inspect('/etc/passwd'), null);

  // The read is bounded by the checked size: growth between fstat and read is
  // refused, as is a file that shrinks during the read.
  assert.deepEqual(Buffer.from(readLocalImage(okPath, { tempRoot: root }).data), png);
  assert.equal(readLocalImage(okPath, {
    tempRoot: root,
    beforeRead: () => appendFileSync(okPath, Buffer.from([0])),
  }), null);
  writeFileSync(okPath, png);
  assert.equal(readLocalImage(okPath, {
    tempRoot: root,
    beforeRead: () => truncateSync(okPath, 2),
  }), null);
  writeFileSync(okPath, png);

  const split = splitLocalImages(`前\n\n![Image](file://${okPath})\n\n後`);
  assert.deepEqual(split.paths, [okPath]);
  assert.equal(settleLocalImages(split.text, split.paths, ['id']), '前\n\n\n\n後');
  assert.equal(settleLocalImages(split.text, split.paths, [null]), '前\n\n（画像を表示できません）\n\n後');
  // Text without an image marker is returned byte for byte: code fences,
  // trailing spaces and blank lines are the model's, not ours to normalise.
  const untouched = '```swift\nlet a = 1  \n\n\nlet b = 2\n```\n\n\n';
  assert.equal(settleLocalImages(untouched, [], []), untouched);
  const mixed = '```\n  x  \n\n\n```\n\u0000LAAIMG0\u0000\n\nend  ';
  assert.equal(settleLocalImages(mixed, ['p'], ['id']), '```\n  x  \n\n\n```\n\n\nend  ');
  assert.deepEqual(splitLocalImages('![Image](https://example.com/a.png)'), { text: '![Image](https://example.com/a.png)', paths: [] });

  const f = fixture();
  const store = createSessionStore({ file: join(dir, 'sessions.json') });
  const images = sessionImageStore(join(dir, 'images'), { inspect, inspectTtlMs: 0, readLocal: (path) => readLocalImage(path, { tempRoot: root }) });
  const plain = '```swift\nlet a = 1  \n\n\nlet b = 2\n```\n\n\n';
  const history = async () => [
    { id: 'm1', role: 'assistant', text: `できました。\u0000LAAIMG0\u0000`, localImages: [okPath] },
    { id: 'm2', role: 'user', text: 'ありがとう' },
    { id: 'm3', role: 'assistant', text: plain },
  ];
  const service = createSessionService({
    sessionStore: store, daemon: f.daemon, adapter: {}, findWorkspace: async () => null, notify: async () => {},
    images, history,
  });
  await service.syncDaemon();
  const id = daemonSessionID('parent');
  const messages = await service.conversation(id);
  assert.equal(messages[0].text, 'できました。');
  assert.equal(messages[1].text, 'ありがとう');
  assert.equal(messages[2].text, plain);
  assert.equal(messages[0].localImages, undefined);
  assert.equal(messages[0].images.length, 1);
  const image = service.image(id, messages[0].images[0]);
  assert.equal(image.mimeType, 'image/png');
  assert.deepEqual(Buffer.from(image.data, 'base64'), png);
  // Another session cannot read the id.
  assert.throws(() => service.image(daemonSessionID('child'), messages[0].images[0]), { code: 'not_found' });

  // A second poll with the same picture does not rewrite the index.
  const indexFile = join(dir, 'images', `${id}.json`);
  const indexBefore = readFileSync(indexFile, 'utf8');
  await service.conversation(id);
  assert.equal(readFileSync(indexFile, 'utf8'), indexBefore);

  // Bytes replaced after registration: refused at read time, and the text keeps
  // a visible fallback instead of silently dropping the picture.
  writeFileSync(okPath, Buffer.from('replaced'));
  assert.throws(() => service.image(id, messages[0].images[0]), { code: 'not_found' });
  const fallback = await service.conversation(id);
  assert.equal(fallback[0].images.length, 0);
  assert.equal(fallback[0].text, 'できました。（画像を表示できません）');

  // A symlink in the attachment directory is never served.
  rmSync(okPath); symlinkSync(outside, okPath);
  const linkedPoll = await service.conversation(id);
  assert.equal(linkedPoll[0].images.length, 0);
  assert.match(linkedPoll[0].text, /画像を表示できません/);

  // A parent directory swapped for a symlink to another directory is outside
  // the Paseo attachment root, even though the file name still looks right.
  rmSync(attachments, { recursive: true, force: true });
  const other = join(root, 'other-attachments'); mkdirSync(other);
  writeFileSync(join(other, 'ok.png'), png);
  symlinkSync(other, attachments);
  const swapped = await service.conversation(id);
  assert.equal(swapped[0].images.length, 0);
  assert.match(swapped[0].text, /画像を表示できません/);

  // Restored, then grown past the limit: the read checks the descriptor's size.
  rmSync(attachments); mkdirSync(attachments); writeFileSync(okPath, png);
  const restored = await service.conversation(id);
  assert.equal(restored[0].images.length, 1);
  truncateSync(okPath, 8 * 1024 * 1024 + 1);
  assert.throws(() => service.image(id, restored[0].images[0]), { code: 'not_found' });
  assert.deepEqual(readFileSync(outside), png);
});

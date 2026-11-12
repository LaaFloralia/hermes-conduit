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
    ...(options.noModelUpdate ? {} : { setAgentModel: async (id, model) => {
      calls.push(['model', id, model]);
      if (options.modelRejected) throw new Error('provider refused');
      if (!options.modelNoop) rows.find((a) => a.id === id).model = model;
    } }),
    setAgentFeature: async (id, featureId, value) => {
      calls.push(['feature', id, featureId, value]);
      if (options.featureRejected) throw new Error('provider refused');
      if (options.featureNoop) return;
      const feature = rows.find((a) => a.id === id).features?.find((f) => f.id === featureId);
      if (feature) feature.value = value;
    },
    respondToPermissionAndWait: async (id, request, response) => { calls.push(['reply', id, request, response]); rows.find((a) => a.id === id).pendingPermissions = []; },
  };
  return { rows, calls, client, daemon: daemonAdapter({ connect: async () => client, now: () => 1000 }) };
}

test('directory follows every daemon page; an idle send carries steer, a stable ID and images, and a working agent is never handed one', async () => {
  const f = fixture();
  assert.equal((await f.daemon.list()).length, 2);
  // The Bridge never hands a prompt to an agent with a turn running: the
  // provider replaced or refused that turn and the owner's message went with it
  // (2026-11-09). The message waits in the session's queue instead.
  await assert.rejects(f.daemon.send('parent', { text: '追加', messageId: 'm-1' }), { code: 'session_busy' });
  assert.equal(f.calls.filter((c) => c[0] === 'send').length, 0);
  f.rows[0].status = 'idle';
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

test('conversation exposes message IDs and never tool calls, raw output or reasoning', async () => {
  const c = { close: async () => {}, fetchAgentTimeline: async () => ({ agentId: 'a', entries: [
    { item: { type: 'user_message', text: 'hello', clientMessageId: 'm1' } },
    { item: { type: 'reasoning', text: 'private reasoning' } },
    { item: { type: 'tool_call', callId: 't1', name: 'Read', status: 'completed', detail: { output: 'private output' } } },
  ] }) };
  const { items: messages, compacting } = await readConversation('a', async () => c);
  assert.deepEqual(messages.map(({ id, role }) => ({ id, role })), [{ id: 'm1', role: 'user' }]);
  assert.equal(compacting, false);
  assert.doesNotMatch(JSON.stringify(messages), /private|Read/);
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
  // The fixture's parent is mid-turn; a send only goes out to an idle agent.
  f.rows[0].status = 'idle';
  const service = createSessionService({ sessionStore: store, daemon: f.daemon, adapter: {}, findWorkspace: async () => null,
    history: async () => ({ items: [{ id: 'm1', role: 'user', text: '画像' }], compacting: false }), notify: async () => {} });
  await service.syncDaemon();
  const id = daemonSessionID('parent');
  await service.sendMessage({ id, key: 'image-1', body: { message: '画像', messageId: 'm1', images: [{ data: 'YWJj', mimeType: 'image/png' }] } });
  const { items: messages } = await service.conversation(id), imageID = messages[0].images[0];
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
    setWorkspacePinned: async (id, pinned) => { calls.push(['unpin', id, pinned]); workspaces.find((w) => w.id === id).pinnedAt = null; return { pinnedAt: null }; },
    archiveWorkspace: async (id) => { calls.push(['archiveWorkspace', id]); workspaces.find((w) => w.id === id).archived = true; return { error: null }; },
    restoreWorkspace: async (id) => { calls.push(['restoreWorkspace', id]); workspaces.find((w) => w.id === id).archived = false; },
    refreshAgent: async (id) => { calls.push(['refresh', id]); agents.find((a) => a.id === id).archivedAt = null; },
  };
  return { agents, workspaces, calls, client, daemon: daemonAdapter({ connect: async () => client, now: () => 1000 }) };
}

function tidyFixture() {
  const calls = [], at = Date.parse('2026-11-09T12:00:00Z');
  const agents = [
    // Every conversation archived eleven minutes ago: this one is tidied, and
    // its pin goes first.
    { id: 'done', workspaceId: 'wks_done', status: 'closed', createdAt: '2026-11-09T11:40:00Z', archivedAt: '2026-11-09T11:45:00Z', labels: {} },
    // Two conversations, one still open: the workspace stays.
    { id: 'live-old', workspaceId: 'wks_live', status: 'closed', createdAt: '2026-11-09T10:00:00Z', archivedAt: '2026-11-09T10:05:00Z', labels: {} },
    { id: 'live', workspaceId: 'wks_live', status: 'idle', createdAt: '2026-11-09T11:40:00Z', labels: {} },
    // Archived five minutes ago: too soon to tell the owner is done with it.
    { id: 'fresh', workspaceId: 'wks_fresh', status: 'closed', createdAt: '2026-11-09T11:50:00Z', archivedAt: '2026-11-09T11:56:00Z', labels: {} },
    // Archived long enough, but archiving a worktree deletes files.
    { id: 'tree', workspaceId: 'wks_tree', status: 'closed', createdAt: '2026-11-09T11:40:00Z', archivedAt: '2026-11-09T11:45:00Z', labels: {} },
  ];
  const workspaces = [
    { id: 'wks_done', workspaceKind: 'directory', pinnedAt: '2026-11-01T00:00:00Z' },
    { id: 'wks_empty', workspaceKind: 'directory' }, // the owner may have just made it
    { id: 'wks_live', workspaceKind: 'directory' },
    { id: 'wks_fresh', workspaceKind: 'directory' },
    { id: 'wks_tree', workspaceKind: 'worktree' },
  ];
  const archived = new Set();
  const client = { close: async () => {},
    fetchAgents: async () => ({ entries: agents.map((agent) => ({ agent })), pageInfo: { nextCursor: null } }),
    fetchWorkspaces: async () => ({ entries: workspaces.filter((w) => !archived.has(w.id)) }),
    setWorkspacePinned: async (id, pinned) => { calls.push(['unpin', id, pinned]); workspaces.find((w) => w.id === id).pinnedAt = null; return { pinnedAt: null }; },
    archiveWorkspace: async (id) => { calls.push(['archiveWorkspace', id]); archived.add(id); return { error: null }; },
  };
  return { at, calls, workspaces, archived, client, daemon: daemonAdapter({ connect: async () => client, now: () => at }) };
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

test('archiving the last conversation unpins its workspace before archiving it', async () => {
  const f = archiveFixture();
  f.workspaces.find((w) => w.id === 'wks_a').pinnedAt = '2026-11-01T00:00:00Z';
  await f.daemon.archive(['root']);
  assert.deepEqual(f.calls, [['archive', 'root'], ['unpin', 'wks_a', false], ['archiveWorkspace', 'wks_a']]);
});

test('a workspace whose pin cannot be removed is not archived while still pinned', async () => {
  const f = archiveFixture();
  f.workspaces.find((w) => w.id === 'wks_a').pinnedAt = '2026-11-01T00:00:00Z';
  f.client.setWorkspacePinned = async () => { throw new Error('pin refused'); };
  await assert.rejects(f.daemon.archive(['root']), { code: 'paseo_unavailable' });
  assert.deepEqual(f.calls, [['archive', 'root']]);
  assert.equal(f.workspaces.find((w) => w.id === 'wks_a').archived, undefined);
});

test('tidy archives only workspaces every conversation has left, ten minutes on', async () => {
  const f = tidyFixture();
  const result = await f.daemon.tidyWorkspaces();
  assert.deepEqual(result.archived, ['wks_done']);
  assert.equal(result.skipped, 4);
  assert.equal(result.failed, undefined);
  assert.deepEqual(f.calls, [['unpin', 'wks_done', false], ['archiveWorkspace', 'wks_done']]);
  assert.ok(f.archived.has('wks_done'));
});

test('tidy with dryRun reports the targets and changes nothing', async () => {
  const f = tidyFixture();
  const result = await f.daemon.tidyWorkspaces({ dryRun: true });
  assert.deepEqual(result.archived, ['wks_done']);
  assert.equal(result.dryRun, true);
  assert.deepEqual(f.calls, []);
  assert.equal(f.archived.size, 0);
});

test('one workspace that will not archive does not stop tidy and stays visible', async () => {
  const f = tidyFixture();
  f.client.archiveWorkspace = async (id) => { f.calls.push(['archiveWorkspace', id]); if (id === 'wks_done') throw new Error('refused'); return { error: null }; };
  const result = await f.daemon.tidyWorkspaces();
  assert.deepEqual(result.archived, []);
  assert.deepEqual(result.failed, ['wks_done']);
  assert.equal(result.skipped, 5);
});

test('the regular sync tidies once per five minutes and a failure does not stop the sync', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'paseo-bridge-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
  let clock = 1_000_000, calls = 0, fail = true;
  const daemon = {
    list: async () => [], workspacePins: async () => [], exists: async () => true,
    tidyWorkspaces: async () => { calls += 1; if (fail) throw new Error('daemon down'); },
  };
  const service = createSessionService({ sessionStore: createSessionStore({ file: join(dir, 'sessions.json') }), daemon,
    adapter: {}, findWorkspace: async () => null, notify: async () => {}, now: () => clock });
  await service.syncDaemon();
  assert.equal(calls, 1, 'the first sync tidies, and its failure still resolves');
  clock += 4 * 60 * 1000;
  await service.syncDaemon();
  assert.equal(calls, 1, 'inside five minutes nothing is retried');
  clock += 60 * 1000;
  fail = false;
  await service.syncDaemon();
  assert.equal(calls, 2, 'five minutes later it runs again');
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

test('fastValue reads the Claude toggle and the Codex speed select, and nothing else', () => {
  assert.equal(fastValue([{ type: 'toggle', id: 'fast_mode', label: 'Fast', value: true }]), true);
  assert.equal(fastValue([{ type: 'toggle', id: 'fast_mode', label: 'Fast', value: false }]), false);
  assert.equal(fastValue([{ id: 'fast_mode' }]), null);
  const codex = (value, options) => [{ type: 'select', id: 'service_tier', label: 'Speed', value,
    options: options ?? [{ id: 'default', label: 'Normal', isDefault: true }, { id: 'priority', label: 'Fast' }] }];
  assert.equal(fastValue(codex('default')), false);
  assert.equal(fastValue(codex('priority')), true);
  assert.equal(fastValue(codex('flex')), null);
  assert.equal(fastValue(codex('priority', [{ id: 'default', label: 'Normal' }, { id: 'flex', label: 'Flex' }])), null);
  assert.equal(fastValue([{ type: 'select', id: 'service_tier' }]), null);
  assert.equal(fastValue([]), null);
  assert.equal(fastValue(null), null);
  assert.equal(fastValue(undefined), null);
});

test('Fast switches through the provider feature and is verified by read-back', async (t) => {
  const make = async (options = {}, { features, withDaemon = true } = {}) => {
    const dir = mkdtempSync(join(tmpdir(), 'paseo-fast-switch-'));
    t.after(() => rmSync(dir, { recursive: true, force: true }));
    const f = fixture(options);
    f.rows[0].features = features;
    const store = createSessionStore({ file: join(dir, 'sessions.json') });
    const service = createSessionService({ sessionStore: store, daemon: withDaemon ? f.daemon : null, adapter: {},
      findWorkspace: async () => null, notify: async () => {}, observationTtlMs: 0 });
    await service.listSessions();
    return { f, store, service, id: daemonSessionID('parent') };
  };
  const claude = (value) => [{ type: 'toggle', id: 'fast_mode', label: 'Fast', value }];
  const codex = (value) => [{ type: 'select', id: 'service_tier', label: 'Speed', value,
    options: [{ id: 'default', label: 'Normal', isDefault: true }, { id: 'priority', label: 'Fast' }] }];

  const claudeRun = await make({}, { features: claude(false) });
  const listed = claudeRun.service.view(claudeRun.store.get(claudeRun.id));
  assert.equal(listed.observedFast, false);
  assert.equal(listed.capabilities.fast, true);
  const switched = await claudeRun.service.updateSession({ id: claudeRun.id, body: { fast: true } });
  assert.equal(claudeRun.service.view(switched.session).observedFast, true);
  assert.deepEqual(claudeRun.f.calls.find((call) => call[0] === 'feature'), ['feature', 'parent', 'fast_mode', true]);
  // The same value again is idempotent and still reports the applied value.
  const again = await claudeRun.service.updateSession({ id: claudeRun.id, body: { fast: true } });
  assert.equal(claudeRun.service.view(again.session).observedFast, true);

  // Codex reports Normal/Fast as a speed select; observedFast is no longer null.
  const codexRun = await make({}, { features: codex('default') });
  assert.equal(codexRun.service.view(codexRun.store.get(codexRun.id)).observedFast, false);
  assert.equal(codexRun.service.view(codexRun.store.get(codexRun.id)).capabilities.fast, true);
  await codexRun.service.updateSession({ id: codexRun.id, body: { fast: true } });
  assert.deepEqual(codexRun.f.calls.find((call) => call[0] === 'feature'), ['feature', 'parent', 'service_tier', 'priority']);
  assert.equal(codexRun.service.view(codexRun.store.get(codexRun.id)).observedFast, true);
  await codexRun.service.updateSession({ id: codexRun.id, body: { fast: false } });
  assert.equal(codexRun.service.view(codexRun.store.get(codexRun.id)).observedFast, false);

  const unsupported = await make({}, { features: [] });
  assert.equal(unsupported.service.view(unsupported.store.get(unsupported.id)).capabilities.fast, false);
  await assert.rejects(unsupported.service.updateSession({ id: unsupported.id, body: { fast: true } }), { code: 'fast_unsupported' });

  // A provider that accepted the call but did not change the value is a failure.
  const noop = await make({ featureNoop: true }, { features: claude(false) });
  await assert.rejects(noop.service.updateSession({ id: noop.id, body: { fast: true } }), { code: 'fast_not_applied' });
  const refused = await make({ featureRejected: true }, { features: claude(false) });
  await assert.rejects(refused.service.updateSession({ id: refused.id, body: { fast: true } }), { code: 'fast_rejected' });

  const stopped = await make({}, { features: claude(false) });
  await stopped.service.stopSession(stopped.id);
  await assert.rejects(stopped.service.updateSession({ id: stopped.id, body: { fast: true } }), { code: 'session_stopped' });

  await assert.rejects(claudeRun.service.updateSession({ id: claudeRun.id, body: { fast: 'yes' } }), { status: 400 });

  // A delegation-only record has no Paseo agent to change.
  const noDaemon = await make({}, { withDaemon: false });
  noDaemon.store.create({ record: {
    id: noDaemon.id, requestId: 'paseo-parent', name: '親', nameSource: 'agent', parentId: null,
    projectId: null, workspaceId: 'home', cwd: '/Users/laa', profile: 'codex',
    requested: { provider: 'codex', model: 'gpt', effort: 'high' }, observed: null,
    phase: 'created', createdAt: '2026-11-01T00:00:00Z', updatedAt: '2026-11-01T00:00:00Z',
    delegate: { sessionId: 'parent' },
  } });
  await assert.rejects(noDaemon.service.updateSession({ id: noDaemon.id, body: { fast: true } }), { code: 'fast_unsupported' });
});

test('the session API exposes capabilities.fast and applies a Fast change over PATCH', async (t) => {
  const f = fixture();
  f.rows[0].features = [{ type: 'toggle', id: 'fast_mode', label: 'Fast', value: false }];
  const bridge = await startBridge({ sessions: { daemon: f.daemon, notify: async () => {} } });
  t.after(() => bridge.close());
  const token = await bridge.token();
  const id = daemonSessionID('parent');
  const list = await bridge.request('/v1/sessions', { token });
  const row = list.body.data.items.find((item) => item.id === id);
  assert.equal(row.capabilities.fast, true);
  assert.equal(row.observedFast, false);
  const patched = await bridge.request(`/v1/sessions/${id}`, { method: 'PATCH', token, key: 'fast-1', body: { fast: true } });
  assert.equal(patched.status, 200, JSON.stringify(patched.body));
  assert.equal(patched.body.data.observedFast, true);
  assert.equal(patched.body.data.capabilities.fast, true);
  // The route keeps the existing shape: a favorite-only PATCH still works.
  const favorite = await bridge.request(`/v1/sessions/${id}`, { method: 'PATCH', token, key: 'fast-2', body: { favorite: true } });
  assert.equal(favorite.status, 200, JSON.stringify(favorite.body));
  assert.equal(favorite.body.data.favorite, true);
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

test('model changes use the daemon, are verified by read-back, and are kept beside the request', async (t) => {
  const make = async (options = {}, withDaemon = true) => {
    const dir = mkdtempSync(join(tmpdir(), 'paseo-model-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
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
  assert.equal(ok.service.view((await ok.service.getSession(ok.id)).session).capabilities.model, true);
  const updated = await ok.service.updateSession({ id: ok.id, body: { model: 'gpt-6.1-terra' } });
  const view = ok.service.view(updated.session);
  assert.equal(view.observed.model, 'gpt-6.1-terra');
  assert.deepEqual(view.ownerChanged, { model: 'gpt-6.1-terra' });
  const effortToo = await ok.service.updateSession({ id: ok.id, body: { effort: 'low' } });
  assert.deepEqual(ok.service.view(effortToo.session).ownerChanged, { model: 'gpt-6.1-terra', effort: 'low' });
  assert.deepEqual(ok.f.calls.find((call) => call[0] === 'model'), ['model', 'parent', 'gpt-6.1-terra']);

  const noop = await make({ modelNoop: true });
  await assert.rejects(noop.service.updateSession({ id: noop.id, body: { model: 'gpt-6.1-terra' } }), { code: 'model_not_applied' });
  const refused = await make({ modelRejected: true });
  await assert.rejects(refused.service.updateSession({ id: refused.id, body: { model: 'gpt-6.1-terra' } }), { code: 'model_rejected' });
  const unsupported = await make({ noModelUpdate: true });
  assert.equal(unsupported.service.view((await unsupported.service.getSession(unsupported.id)).session).capabilities.model, false);
  await assert.rejects(unsupported.service.updateSession({ id: unsupported.id, body: { model: 'gpt-6.1-terra' } }), { code: 'model_unsupported' });
  const adapterOnly = await make({}, false);
  adapterOnly.store.create({ record: {
    id: adapterOnly.id, requestId: 'paseo-parent', name: '親', nameSource: 'agent', parentId: null,
    projectId: null, workspaceId: 'home', cwd: '/Users/laa', profile: 'codex',
    requested: { provider: 'codex', model: 'gpt', effort: 'high' }, observed: null,
    phase: 'created', createdAt: '2026-11-01T00:00:00Z', updatedAt: '2026-11-01T00:00:00Z',
    delegate: { sessionId: 'parent' },
  } });
  await assert.rejects(adapterOnly.service.updateSession({ id: adapterOnly.id, body: { model: 'gpt-6.1-terra' } }), { code: 'model_unsupported' });
  await assert.rejects(ok.service.updateSession({ id: ok.id, body: { model: 'bad model\n' } }), { status: 400 });
  await assert.rejects(ok.service.updateSession({ id: ok.id, body: { model: 7 } }), { status: 400 });
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
  const history = async () => ({ compacting: true, items: [
    { id: 'm1', role: 'assistant', text: `できました。\u0000LAAIMG0\u0000`, localImages: [okPath] },
    { id: 'm2', role: 'user', text: 'ありがとう' },
    { id: 'm3', role: 'assistant', text: plain },
  ] });
  const service = createSessionService({
    sessionStore: store, daemon: f.daemon, adapter: {}, findWorkspace: async () => null, notify: async () => {},
    images, history,
  });
  await service.syncDaemon();
  const id = daemonSessionID('parent');
  const { items: messages, compacting } = await service.conversation(id);
  assert.equal(compacting, true);
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
  const { items: fallback } = await service.conversation(id);
  assert.equal(fallback[0].images.length, 0);
  assert.equal(fallback[0].text, 'できました。（画像を表示できません）');

  // A symlink in the attachment directory is never served.
  rmSync(okPath); symlinkSync(outside, okPath);
  const { items: linkedPoll } = await service.conversation(id);
  assert.equal(linkedPoll[0].images.length, 0);
  assert.match(linkedPoll[0].text, /画像を表示できません/);

  // A parent directory swapped for a symlink to another directory is outside
  // the Paseo attachment root, even though the file name still looks right.
  rmSync(attachments, { recursive: true, force: true });
  const other = join(root, 'other-attachments'); mkdirSync(other);
  writeFileSync(join(other, 'ok.png'), png);
  symlinkSync(other, attachments);
  const { items: swapped } = await service.conversation(id);
  assert.equal(swapped[0].images.length, 0);
  assert.match(swapped[0].text, /画像を表示できません/);

  // Restored, then grown past the limit: the read checks the descriptor's size.
  rmSync(attachments); mkdirSync(attachments); writeFileSync(okPath, png);
  const { items: restored } = await service.conversation(id);
  assert.equal(restored[0].images.length, 1);
  truncateSync(okPath, 8 * 1024 * 1024 + 1);
  assert.throws(() => service.image(id, restored[0].images[0]), { code: 'not_found' });
  assert.deepEqual(readFileSync(outside), png);
});

test('each reply is named with the model the Bridge saw while it was written; a provider switch shows as a change', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'paseo-model-log-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
  const f = fixture(), store = createSessionStore({ file: join(dir, 'sessions.json') });
  const start = Date.parse('2026-11-11T07:00:00Z');
  const iso = (minute) => new Date(start + minute * 60_000).toISOString();
  let clock = start;
  const service = createSessionService({ sessionStore: store, daemon: f.daemon, adapter: {}, findWorkspace: async () => null,
    now: () => clock, notify: async () => {},
    history: async () => ({ compacting: false, items: [
      { id: 'early', role: 'assistant', text: 'before any observation', timestamp: iso(-5) },
      { id: 'u1', role: 'user', text: '1', timestamp: iso(1) },
      { id: 'a1', role: 'assistant', text: 'Sol', timestamp: iso(2) },
      { id: 'u2', role: 'user', text: '2', timestamp: iso(20) },
      { id: 'a2', role: 'assistant', text: 'Terra', timestamp: iso(22) },
    ] }) });
  await service.syncDaemon();
  clock = start + 10 * 60_000; await service.syncDaemon();
  const id = daemonSessionID('parent');
  // The provider switches by itself (no owner PATCH).
  f.rows[0].model = 'gpt-6.1-terra';
  clock = start + 21 * 60_000; await service.syncDaemon();
  clock = start + 23 * 60_000; await service.syncDaemon();
  const named = Object.fromEntries((await service.conversation(id)).items.map((m) => [m.id, m.model?.model ?? null]));
  // a1 sits inside the Sol span but in the turn before the unrequested switch,
  // so it is not named; a2 is inside the Terra span.
  assert.deepEqual(named, { early: null, u1: null, a1: null, u2: null, a2: 'gpt-6.1-terra' });
  assert.deepEqual(service.view(store.get(id)).modelChange, {
    from: { provider: 'codex', model: 'gpt-6.1-sol' }, to: { provider: 'codex', model: 'gpt-6.1-terra' },
    seenAt: iso(21), byOwner: false,
  });
});

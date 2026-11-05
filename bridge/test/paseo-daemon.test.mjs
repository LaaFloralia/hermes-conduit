import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { daemonAdapter, daemonSessionID, pendingHash } from '../src/sessions/daemon.mjs';
import { createSessionService } from '../src/sessions/service.mjs';
import { createSessionStore } from '../src/sessions/store.mjs';
import { readConversation } from '../src/sessions/history.mjs';
import { startBridge } from './helpers.mjs';
import { createOwnerNotifier } from '../src/notify/index.mjs';

function fixture() {
  const calls = [], rows = [{ id: 'parent', title: '親', provider: 'codex', model: 'gpt-6.1-sol', effectiveThinkingOptionId: 'high', createdAt: '2026-11-01T00:00:00Z', updatedAt: '2026-11-02T00:00:00Z', status: 'running', labels: {} },
    { id: 'child', title: '子', provider: 'dsh', model: '["opencode-go","deepseek-v4.1-flash"]', createdAt: '2026-11-01T00:00:00Z', updatedAt: '2026-11-02T00:00:00Z', status: 'idle', labels: { 'paseo.parent-agent-id': 'parent' } }];
  const client = { close: async () => {}, fetchAgent: async ({ agentId }) => ({ agent: rows.find((a) => a.id === agentId) }),
    fetchAgents: async ({ page }) => { calls.push(['list', page.cursor]); return page.cursor ? { entries: [{ agent: rows[1] }], pageInfo: { nextCursor: null } } : { entries: [{ agent: rows[0] }], pageInfo: { nextCursor: 'next' } }; },
    sendMessage: async (...args) => calls.push(['send', ...args]), cancelAgent: async (id) => { calls.push(['cancel', id]); rows[0].status = 'idle'; },
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

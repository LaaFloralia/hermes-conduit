import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, readFileSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { encodeNotificationSessionId, createOwnerNotifier } from '../src/notify/index.mjs';
import { createNotificationPreferences, DEFAULT_KINDS } from '../src/notify/preferences.mjs';
import { createDecisionStore } from '../src/decisions/store.mjs';
import { createDecisionService } from '../src/decisions/service.mjs';
import { createOwnerTaskNotificationPoller } from '../src/tasks/owner-notifications.mjs';
import { createCalendarReminders } from '../src/calendar/reminders.mjs';
import { daemonAdapter, daemonSessionID, pendingHash } from '../src/sessions/daemon.mjs';
import { approvalSummary, quickQuestion, sessionNotificationMeta, quickReply } from '../src/sessions/quick-reply.mjs';
import { BridgeError } from '../src/errors.mjs';
import { startBridge } from './helpers.mjs';
const decode = (s) => JSON.parse(Buffer.from(s.split('#')[1], 'base64url').toString());
const dirFor = (t) => { const dir = mkdtempSync(join(tmpdir(), 'laa-quick-')); t.after(() => rmSync(dir, { recursive: true, force: true })); return dir; };
const code = (c) => (e) => e.code === c;

test('metadata: all kinds carry version and kind; labels shrink evenly within 512 UTF-8 bytes', () => {
  for (const k of ['decision.new', 'decision.failed', 'session.question', 'session.approval', 'session.error', 'session.finished', 'task', 'calendar']) {
    assert.deepEqual(decode(encodeNotificationSessionId('laa://work', k)), { v: 1, k });
  }
  const meta = { sid: 'ses_0123456789abcdef', h: 'a'.repeat(64), o: Array(6).fill('選'.repeat(80)) };
  const s = encodeNotificationSessionId('laa://work/sessions/ses_0123456789abcdef', 'session.question', meta);
  assert(Buffer.byteLength(s) <= 512);
  const m = decode(s); assert.equal(m.o.length, 6); assert(m.o.every((o) => o.endsWith('…')));
  assert.equal(new Set(m.o.map((o) => Array.from(o).length)).size, 1);
  assert.equal(m.h, meta.h); assert.equal(meta.o[0].length, 80);
  let removed;
  for (let n = 120; n < 400; n++) {
    const value = encodeNotificationSessionId('laa://work/' + 'x'.repeat(n), 'session.question', meta);
    if (value.includes('#') && !decode(value).o) { removed = value; break; }
  }
  assert(removed); assert(Buffer.byteLength(removed) <= 512); assert.equal(decode(removed).h, meta.h);
  assert.equal(encodeNotificationSessionId('laa://work', 'task', { id: 'x'.repeat(1000) }), 'laa-bridge:laa://work');
});

test('preferences: defaults, partial updates, 0600, validation, quiet and muted delivery, stable flush', async (t) => {
  const dir = dirFor(t), file = join(dir, 'notification-preferences.json');
  const preferences = createNotificationPreferences({ file, now: () => 1000 });
  assert.deepEqual(preferences.get(), { kinds: DEFAULT_KINDS, updatedAt: null });
  preferences.update({ kinds: { task: 'off', error: 'quiet' } });
  assert.equal(preferences.get().kinds.question, 'alert'); assert.equal(preferences.get().updatedAt, new Date(1000).toISOString());
  assert.equal(statSync(file).mode & 0o777, 0o600);
  for (const kinds of [{ decision: 'off' }, { question: 'off' }, { approval: 'off' }, { other: 'alert' }, { task: 'loud' }, [], null]) assert.throws(() => preferences.update({ kinds }), code('notification_preferences_invalid'));
  const events = [];
  const notify = createOwnerNotifier({ file: join(dir, 'notifications.json'), preferences, deliver: async (e) => { events.push(e); return { delivered: false }; } });
  const payload = { title: '題', body: '本文', deepLink: 'laa://work', dedupeKey: 'one' };
  assert.equal((await notify({ ...payload, kind: 'task' })).reason, 'muted'); assert.equal(events.length, 0);
  await notify({ ...payload, kind: 'session.error' });
  assert.equal(decode(events[0].session_id).lv, 'p');
  await notify.flush(); assert.equal(events[0].session_id, events[1].session_id);
  await notify({ ...payload, kind: 'session.error', meta: { id: 'changed' } }); assert.equal(events[2].session_id, events[0].session_id);
  preferences.update({ kinds: { error: 'off' } });
  await notify.flush(); assert.equal(events.length, 3);
  assert.deepEqual(JSON.parse(readFileSync(join(dir, 'notifications.json'))).pending, {});
});

test('preferences API: scope, partial update, invalid and idempotent replay', async (t) => {
  const h = await startBridge(); t.after(() => h.close());
  const token = await h.token(), reader = await h.token(['sessions:read']);
  const path = '/v1/notifications/preferences';
  assert.equal((await h.request(path)).status, 401);
  assert.deepEqual((await h.request(path, { token: reader })).body.data.kinds, DEFAULT_KINDS);
  const request = { method: 'PUT', token, key: 'preferences', body: { kinds: { finished: 'off' } } };
  assert.equal((await h.request(path, { ...request, token: reader })).status, 403);
  const saved = await h.request(path, request); assert.equal(saved.status, 200);
  assert.deepEqual((await h.request(path, request)).body.data, saved.body.data);
  assert.equal((await h.request(path, { ...request, key: 'invalid', body: { kinds: { question: 'off' } } })).body.error.code, 'notification_preferences_invalid');
});

test('muted notifications are processed once by decisions, tasks and calendar', async (t) => {
  const dir = dirFor(t); let calls = 0;
  const notify = async () => { calls++; return { delivered: false, reason: 'muted' }; };
  const store = createDecisionStore({ dir });
  const service = createDecisionService({ store, notify });
  service.add({ title: '題', summary: '本文', options: [{ label: 'A' }, { label: 'B' }], requestId: 'new' });
  await service.sync(); await service.sync(); assert.equal(calls, 1);
  const poller = createOwnerTaskNotificationPoller({ notify, source: { ownerInboxAvailable: true, listCollection: async () => ({ items: [{ id: 'n', type: 'issueMention', updatedAt: 'v1', issue: { id: 'issue' } }], nextCursor: null }) } });
  await poller.poll(); await poller.poll(); assert.equal(calls, 2);
  const now = Date.now();
  const reminders = createCalendarReminders({ notify, now: () => now, file: join(dir, 'reminders.json'), service: {
    calendars: async () => ({ items: [{ id: 'c', selected: true }] }),
    list: async () => ({ items: [{ id: 'event', start: new Date(now).toISOString(), reminders: { overrides: [{ method: 'popup', minutes: 0 }] } }] }),
  } });
  await reminders.tick(); await reminders.tick(); assert.equal(calls, 3);
});

test('quick board: expiry is atomic, normal answers unchanged, closed and replay precede expiry', async (t) => {
  const dir = dirFor(t); let now = 100000;
  const store = createDecisionStore({ dir, now: () => now });
  const add = (requestId) => store.add({ title: '題', summary: '本文', options: [{ label: 'A' }, { label: 'B' }], deadline: new Date(now + 1000).toISOString(), requestId }).decision;
  const expired = add('expired'), accepted = add('accepted');
  const body = { requestId: 'reply', optionIndex: 1, quick: true };
  store.reserve(accepted.id, 'phone', body); now += 2000;
  const before = readFileSync(store.file, 'utf8');
  assert.throws(() => store.reserve(expired.id, 'phone', { ...body, requestId: 'expired-reply' }), code('decision_expired'));
  assert.equal(readFileSync(store.file, 'utf8'), before);
  assert.equal(store.reserve(accepted.id, 'phone', body).replayed, true);
  assert.equal(store.reserve(accepted.id, 'phone', { ...body, quick: false }).replayed, true);
  assert.throws(() => store.reserve(accepted.id, 'phone', { ...body, requestId: 'twice' }), code('decision_closed'));
  assert.throws(() => store.reserve(expired.id, 'phone', { ...body, quick: 'yes' }), code('decision_invalid'));
  assert.equal(store.reserve(expired.id, 'phone', { ...body, requestId: 'normal', quick: false }).decision.status, 'answered');
});

function nativeFixture() {
  const question = { id: 'q1', kind: 'question', name: 'request_user_input_async', input: { questions: [{ title: 'どちら', options: [{ label: 'A' }, { label: 'B' }] }] } };
  const agent = { id: 'native-agent', title: '質問の会話', status: 'idle', createdAt: '2026-11-08T00:00:00Z', updatedAt: '2026-11-08T00:00:00Z', pendingPermissions: [question] };
  const sent = [], notices = [];
  const daemon = daemonAdapter({ connect: async () => ({
    fetchAgents: async () => ({ entries: [{ agent }], pageInfo: {} }), fetchWorkspaces: async () => ({ entries: [] }),
    fetchAgent: async () => ({ agent }), close: async () => {},
    respondToPermissionAndWait: async (id, requestId, response) => { sent.push(response); agent.pendingPermissions = []; },
  }) });
  return { agent, question, sent, notices, daemon };
}

test('quick session HTTP: metadata hash matches decision; mismatch, invalid option, success, replay and double answer', async (t) => {
  const f = nativeFixture(); const h = await startBridge({ sessions: { daemon: f.daemon, notify: async (n) => f.notices.push(n) } }); t.after(() => h.close());
  const token = await h.token(), sid = daemonSessionID(f.agent.id), path = `/v1/sessions/${sid}`;
  await h.request('/v1/sessions', { token });
  const detail = (await h.request(`${path}/decision`, { token })).body.data;
  assert.equal(detail.requestHash, pendingHash([f.question]));
  assert.equal(f.notices[0].meta.h, detail.requestHash); assert.deepEqual(f.notices[0].meta.o, ['A', 'B']);
  const post = (body, key) => h.request(`${path}/quick-reply`, { token, method: 'POST', key, body });
  assert.equal((await post({ requestHash: 'a'.repeat(64), choice: 'deny' }, 'changed')).body.error.code, 'pending_request_changed');
  assert.equal((await post({ requestHash: detail.requestHash, choice: { optionIndex: 2 } }, 'invalid')).status, 400);
  assert.equal(f.sent.length, 0);
  const body = { requestHash: detail.requestHash, choice: { optionIndex: 1 } };
  const response = await post(body, 'answer'); assert.equal(response.status, 200); assert(response.body.data.session);
  assert.equal(f.sent[0].updatedInput.answers['Question 1'], 'B');
  assert.deepEqual((await post(body, 'answer')).body.data, response.body.data);
  assert.equal((await post(body, 'twice')).body.error.code, 'pending_request_changed'); assert.equal(f.sent.length, 1);
});

test('quick session: approval summary, allow/deny, unsupported and failed metadata read', async (t) => {
  const f = nativeFixture();
  f.agent.pendingPermissions = [{ id: 'tool', kind: 'tool', name: 'shell', input: { command: 'ls -la\n/tmp' } }];
  const h = await startBridge({ sessions: { daemon: f.daemon, notify: async (n) => f.notices.push(n) } }); t.after(() => h.close());
  const token = await h.token(), path = `/v1/sessions/${daemonSessionID(f.agent.id)}`;
  await h.request('/v1/sessions', { token });
  const detail = (await h.request(`${path}/decision`, { token })).body.data;
  assert.deepEqual(f.notices[0].meta, { sid: daemonSessionID(f.agent.id), h: detail.requestHash, a: 1 });
  // The whole request on one line, the newline visible as an escape.
  assert.equal(f.notices[0].body, '承認: shell {"command":"ls -la\\n/tmp"}');
  const post = (hash, choice, key) => h.request(`${path}/quick-reply`, { token, method: 'POST', key, body: { requestHash: hash, choice } });
  assert.equal((await post(detail.requestHash, 'allow', 'allow')).status, 200); assert.equal(f.sent[0].behavior, 'allow');
  f.agent.pendingPermissions = [f.question, { ...f.question, id: 'q2' }];
  let current = await f.daemon.decision(f.agent.id);
  assert.equal((await post(current.requestHash, 'deny', 'multiple')).body.error.code, 'quick_reply_unsupported');
  f.agent.pendingPermissions = [{ ...f.question, name: 'unknown' }]; current = await f.daemon.decision(f.agent.id);
  assert.equal((await post(current.requestHash, { optionIndex: 0 }, 'unsupported')).body.error.code, 'quick_reply_unsupported');
  assert.equal((await post(current.requestHash, 'deny', 'deny')).status, 200); assert.equal(f.sent[1].behavior, 'deny');
});

test('quick session: an approval that cannot be shown whole has no allow', async (t) => {
  const tool = (input, name = 'shell') => ({ id: 'tool', kind: 'tool', name, detail: JSON.stringify(input, null, 2) });
  assert.equal(approvalSummary(tool({})), '承認: shell');
  assert.equal(approvalSummary(tool({ command: 'git status' })), '承認: shell {"command":"git status"}');
  for (const input of [{ command: '文'.repeat(200) }, { command: 'curl -H "Authorization: x" https://example.com' },
    { command: 'export K=sk-abcdefgh' }, { env: 'A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6' }, { command: 'echo \u202eabc' }]) {
    assert.equal(approvalSummary(tool(input)), null, JSON.stringify(input));
  }
  assert.equal(approvalSummary({ kind: 'question', name: 'AskUserQuestion' }), null);

  const f = nativeFixture();
  f.agent.pendingPermissions = [{ id: 'tool', kind: 'tool', name: 'shell', input: { command: 'a\n' + '文'.repeat(200) } }];
  const h = await startBridge({ sessions: { daemon: f.daemon, notify: async (n) => f.notices.push(n) } }); t.after(() => h.close());
  const token = await h.token(), sid = daemonSessionID(f.agent.id), path = `/v1/sessions/${sid}`;
  await h.request('/v1/sessions', { token });
  const detail = (await h.request(`${path}/decision`, { token })).body.data;
  // No buttons and no tool text: the owner opens the conversation to read it.
  assert.deepEqual(f.notices[0].meta, { sid });
  assert.equal(f.notices[0].body, '操作の承認をお願いします。');
  const post = (choice, key) => h.request(`${path}/quick-reply`, { token, method: 'POST', key, body: { requestHash: detail.requestHash, choice } });
  assert.equal((await post('allow', 'allow')).body.error.code, 'quick_reply_unsupported'); assert.equal(f.sent.length, 0);
  assert.equal((await post('deny', 'deny')).status, 200); assert.equal(f.sent[0].behavior, 'deny');
});

test('quick board HTTP: 409 expired, accepted before expiry, replay after expiry and closed second answer', async (t) => {
  const dir = dirFor(t); let now = Date.now();
  const store = createDecisionStore({ dir, now: () => now });
  const service = createDecisionService({ store, now: () => now, notify: async () => ({ delivered: true }) });
  const add = (requestId) => service.add({ title: '題', summary: '本文', options: [{ label: 'A' }, { label: 'B' }], deadline: new Date(now + 1000).toISOString(), requestId }).decision;
  const a = add('a'), b = add('b');
  const h = await startBridge({ decisions: { service } }); t.after(() => h.close()); const token = await h.token();
  const post = (id, key, requestId = key) => h.request(`/v1/decisions/${id}/answer`, { token, method: 'POST', key, body: { requestId, optionIndex: 0, quick: true } });
  assert.equal((await post(a.id, 'first')).status, 200);
  now += 2000;
  const before = readFileSync(store.file, 'utf8');
  const expired = await post(b.id, 'expired'); assert.equal(expired.status, 409); assert.equal(expired.body.error.code, 'decision_expired');
  assert.equal(readFileSync(store.file, 'utf8'), before);
  assert.equal((await post(a.id, 'replay', 'first')).status, 200);
  assert.equal((await post(a.id, 'second')).body.error.code, 'decision_closed');
});


test('metadata lookup failure still delivers the ordinary question notification', async (t) => {
  const f = nativeFixture(); f.daemon.decision = async () => { throw new Error('unavailable'); };
  const h = await startBridge({ sessions: { daemon: f.daemon, notify: async (n) => f.notices.push(n) } }); t.after(() => h.close());
  const token = await h.token();
  assert.equal((await h.request('/v1/sessions', { token })).status, 200);
  assert.equal(f.notices[0].body, '質問への回答をお願いします。');
  assert.deepEqual(f.notices[0].meta, { sid: daemonSessionID(f.agent.id) });
});

test('an overlong UTF-8 link cannot produce an oversized plugin event', async (t) => {
  const file = join(dirFor(t), 'notify.json');
  const notify = createOwnerNotifier({ file, deliver: async () => assert.fail('oversized delivery') });
  const deepLink = 'laa://work/' + '文'.repeat(200);
  assert.equal(encodeNotificationSessionId(deepLink, 'task'), null);
  assert.equal((await notify({ kind: 'task', title: '題', body: '本文', deepLink, dedupeKey: 'large' })).reason, 'invalid_notification');
});


test('muting a queued legacy fallback also prevents its later delivery', async (t) => {
  const dir = dirFor(t), file = join(dir, 'notify.json');
  const preferences = createNotificationPreferences({ file: join(dir, 'preferences.json') });
  let sends = 0;
  const notify = createOwnerNotifier({ file, preferences, deliver: async () => { sends++; return { delivered: false }; } });
  await notify({ kind: 'task', title: '題', body: '本文', deepLink: 'laa://work/' + 'x'.repeat(350), dedupeKey: 'fallback', meta: { id: 'x'.repeat(1000) } });
  const pending = Object.values(JSON.parse(readFileSync(file)).pending)[0];
  assert(!pending.event.session_id.includes('#')); assert.equal(pending.kind, 'task');
  preferences.update({ kinds: { task: 'off' } });
  await notify.flush(); assert.equal(sends, 1); assert.deepEqual(JSON.parse(readFileSync(file)).pending, {});
});

test('quick question boundaries: both formats, 2–6 options and exactly one question/request', () => {
  const request = (name = 'request_user_input_async', count = 2) => ({ kind: 'question', name, questions: [{ question: '選択', options: Array.from({ length: count }, (_, i) => String(i)) }] });
  for (const name of ['request_user_input_async', 'AskUserQuestion']) for (const count of [2, 6]) {
    const requests = [request(name, count)];
    assert.equal(quickQuestion(requests).options.length, count);
    assert.deepEqual(sessionNotificationMeta('sid', 'question', { requests, requestHash: 'h' }), { sid: 'sid', h: 'h', o: requests[0].questions[0].options });
  }
  const q = request();
  for (const requests of [[], [q, q], [request('unknown')], [request('AskUserQuestion', 1)], [request('AskUserQuestion', 7)], [{ ...q, questions: [] }], [{ ...q, questions: [...q.questions, ...q.questions] }]]) {
    assert.equal(quickQuestion(requests), null);
    assert.deepEqual(sessionNotificationMeta('sid', 'question', { requests, requestHash: 'h' }), { sid: 'sid' });
  }
  assert.deepEqual(sessionNotificationMeta('sid', 'approval', { requests: [q] }), { sid: 'sid' });
  assert.deepEqual(sessionNotificationMeta('sid', 'approval', { requests: [{ kind: 'tool' }, { kind: 'tool' }] }), { sid: 'sid' });
});

test('quick reply preserves existing daemon and confirmation errors', async () => {
  const requestHash = 'a'.repeat(64);
  const detail = { requestHash, expiresAt: Date.now() + 300000, requests: [{ id: 'tool', kind: 'tool', name: 'shell' }] };
  for (const expected of ['stale_decision', 'pending_request_changed', 'reply_unconfirmed', 'paseo_unavailable']) {
    const error = new BridgeError(expected === 'paseo_unavailable' ? 503 : 409, expected, 'fixture');
    await assert.rejects(quickReply({ id: 'sid', body: { requestHash, choice: 'allow' }, decision: async () => detail, reply: async () => { throw error; } }), (e) => e === error);
  }
});

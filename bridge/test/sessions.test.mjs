import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdirSync, mkdtempSync, realpathSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { BridgeError } from '../src/errors.mjs';
import { startBridge } from './helpers.mjs';

// Fake delegation path. It mirrors the parts of laa-personal-agent the Bridge
// depends on: idempotent create by requestId, requested vs observed model,
// waiting decisions, send-while-running refusal and stop confirmation. The
// real CLI is exercised separately by scripts/verify-sessions.mjs.

function fakeDelegation() {
  const records = new Map();
  const calls = [];
  const adapter = {
    origin: 'laa-bridge',
    calls,
    unavailable: false,
    stopUnconfirmed: false,
    agent(requestId) {
      return records.get(requestId);
    },
    setBusy(requestId) {
      records.get(requestId).daemonStatus = 'running';
    },
    setIdle(requestId, { text } = {}) {
      const record = records.get(requestId);
      record.daemonStatus = 'idle';
      if (text !== undefined) {
        record.messageCount = (record.messageCount ?? 0) + 1;
        record.result = { text, messageId: `m-${record.messageCount}`, timestamp: new Date().toISOString() };
      }
    },
    setPending(requestId, pending) {
      records.get(requestId).pending = pending;
    },
    async create({ requestId, profile, cwd, task }) {
      calls.push({ op: 'create', requestId, profile, cwd, task });
      if (adapter.unavailable) throw new BridgeError(503, 'delegation_unavailable', 'down', { retryable: true });
      const digest = JSON.stringify({ profile, cwd, task });
      const existing = records.get(requestId);
      if (existing) {
        if (existing.digest !== digest) throw new BridgeError(409, 'request_id_conflict', 'conflict');
        return { sessionId: existing.sessionId, requested: existing.requested, phase: 'created', reused: true };
      }
      const requested = {
        profile,
        provider: profile.startsWith('deepseek') ? 'dsh' : 'claude',
        model: profile.startsWith('deepseek') ? '["opencode-go","deepseek-v4.1-flash"]' : 'claude-sonnet-5-5',
        effort: 'high',
      };
      const record = {
        sessionId: `agent-${records.size + 1}`,
        digest,
        requested,
        daemonStatus: 'starting',
        pending: [],
        result: null,
        stopRequestedAt: null,
        messages: [],
      };
      records.set(requestId, record);
      return { sessionId: record.sessionId, requested, phase: 'created', reused: false };
    },
    async status({ requestId }) {
      calls.push({ op: 'status', requestId });
      if (adapter.unavailable) throw new BridgeError(503, 'delegation_unavailable', 'down', { retryable: true });
      const record = records.get(requestId);
      if (!record) throw new BridgeError(503, 'delegation_session_missing', 'missing');
      const phase = record.stopRequestedAt
        ? 'stopped'
        : record.pending.length > 0
          ? 'awaiting_decision'
          : record.daemonStatus === 'idle' ? 'awaiting_review' : record.daemonStatus;
      return {
        phase,
        requested: record.requested,
        modelCheck: {
          requested: record.requested,
          observed: { ...record.requested, sources: { model: 'runtime', effort: 'runtime' } },
          runtimeVerified: true,
          matches: true,
        },
        daemonStatus: record.daemonStatus,
        pending: record.pending,
        result: record.result,
        stopRequestedAt: record.stopRequestedAt ?? undefined,
      };
    },
    async send({ requestId, messageId, text }) {
      calls.push({ op: 'send', requestId, messageId, text });
      if (adapter.unavailable) throw new BridgeError(503, 'delegation_unavailable', 'down', { retryable: true });
      const record = records.get(requestId);
      if (!record) throw new BridgeError(503, 'delegation_session_missing', 'missing');
      if (record.stopRequestedAt) throw new BridgeError(409, 'session_stopped', 'stopped');
      if (record.pending.length > 0) throw new BridgeError(409, 'pending_decision_requires_reply', 'pending');
      if (record.daemonStatus !== 'idle') throw new BridgeError(409, 'session_busy', 'busy');
      record.messages.push({ messageId, text });
      record.daemonStatus = 'running';
      return { sent: true };
    },
    async stop({ requestId }) {
      calls.push({ op: 'stop', requestId });
      if (adapter.unavailable) throw new BridgeError(503, 'delegation_unavailable', 'down', { retryable: true });
      const record = records.get(requestId);
      if (!record) throw new BridgeError(503, 'delegation_session_missing', 'missing');
      if (adapter.stopUnconfirmed) throw new BridgeError(409, 'stop_unconfirmed', 'not confirmed', { retryable: true });
      record.stopRequestedAt = Date.now();
      record.daemonStatus = 'idle';
      return { stopConfirmed: true, daemonStatus: 'idle' };
    },
  };
  return adapter;
}

function sessionFixture(t) {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), 'laa-bridge-sessions-')));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const root = join(dir, 'workspaces');
  mkdirSync(root, { recursive: true });
  const repo = join(root, 'repo');
  mkdirSync(join(repo, '.git'), { recursive: true });
  const realRepo = realpathSync(repo);
  const gitRun = async () => '';
  return { dir, root, repo: realRepo, gitRun, workspaceId: workspaceId(realRepo) };
}

function workspaceId(path) {
  return `ws_${createHash('sha256').update(path, 'utf8').digest('hex').slice(0, 16)}`;
}

async function boot(t, { adapter = fakeDelegation(), now, sessions = {} } = {}) {
  const fixture = sessionFixture(t);
  const bridge = await startBridge({
    now,
    workspace: { roots: [fixture.root], gitRun: fixture.gitRun },
    sessions: { adapter, pollMs: 25, ...sessions },
  });
  t.after(() => bridge.close());
  const token = await bridge.token();
  return { bridge, token, adapter, ...fixture };
}

function createBody(fixture, overrides = {}) {
  return {
    workspaceId: fixture.workspaceId,
    requestId: 'req-1',
    profile: 'deepseek-flash-high',
    prompt: 'Reply with the single word ok.',
    ...overrides,
  };
}

async function createSession(ctx, overrides = {}, key = 'k-create-1') {
  return ctx.bridge.request('/v1/sessions', {
    method: 'POST',
    token: ctx.token,
    key,
    body: createBody(ctx, overrides),
  });
}

test('a session records its request, workspace, parent and resolved model', async (t) => {
  const ctx = await boot(t);
  const created = await createSession(ctx);
  assert.equal(created.status, 201);
  const session = created.body.data;
  assert.match(session.id, /^ses_[0-9a-f]{16}$/);
  assert.equal(session.requestId, 'req-1');
  assert.equal(session.workspaceId, ctx.workspaceId);
  assert.equal(session.cwd, ctx.repo);
  assert.equal(session.profile, 'deepseek-flash-high');
  assert.deepEqual(session.requested, {
    profile: 'deepseek-flash-high',
    provider: 'dsh',
    model: '["opencode-go","deepseek-v4.1-flash"]',
    effort: 'high',
  });
  // The first observation records what the agent actually runs.
  assert.equal(session.runtimeVerified, true);
  assert.equal(session.observed.provider, 'dsh');
  assert.equal(session.observed.sources.model, 'runtime');
  assert.equal(session.nameSource, 'default');
  assert.equal(session.parentId, null);
  assert.ok(session.events.cursor.length > 0);

  const root = await ctx.bridge.request(`/v1/sessions/${session.id}`, { token: ctx.token });
  assert.equal(root.status, 200);
  assert.equal(root.body.data.phase, 'running');
  assert.equal(root.body.data.observation.available, true);
});

test('the same requestId reconciles instead of starting a second session', async (t) => {
  const ctx = await boot(t);
  const first = await createSession(ctx);
  assert.equal(first.status, 201);

  // A retry after an unknown outcome: new Idempotency-Key, same requestId.
  const retried = await createSession(ctx, {}, 'k-create-2');
  assert.equal(retried.status, 200);
  assert.equal(retried.body.data.id, first.body.data.id);

  // Same key and same body replays the stored response.
  const replayed = await createSession(ctx, {}, 'k-create-1');
  assert.equal(replayed.status, 201);
  assert.equal(replayed.headers.get('idempotency-replayed'), 'true');
  assert.equal(replayed.body.data.id, first.body.data.id);

  // Same key, different body is a conflict before the handler runs.
  const conflict = await createSession(ctx, { prompt: 'different prompt' }, 'k-create-1');
  assert.equal(conflict.status, 409);
  assert.equal(conflict.body.error.code, 'idempotency_key_conflict');

  // Same requestId, different content is a conflict at the session layer too.
  const changed = await createSession(ctx, { prompt: 'different prompt' }, 'k-create-3');
  assert.equal(changed.status, 409);
  assert.equal(changed.body.error.code, 'request_id_conflict');

  const creates = ctx.adapter.calls.filter((call) => call.op === 'create');
  assert.equal(creates.length, 1, 'the delegation path must create exactly one agent');
});

test('create requires an Idempotency-Key and known workspace, parent and profile shape', async (t) => {
  const ctx = await boot(t);
  const noKey = await ctx.bridge.request('/v1/sessions', { method: 'POST', token: ctx.token, body: createBody(ctx) });
  assert.equal(noKey.status, 400);
  assert.equal(noKey.body.error.code, 'idempotency_key_required');

  const missingProfile = await createSession(ctx, { profile: undefined }, 'k-2');
  assert.equal(missingProfile.status, 400);
  assert.equal(missingProfile.body.error.code, 'payload_invalid');

  const unknownWorkspace = await createSession(ctx, { workspaceId: 'ws_0000000000000000' }, 'k-3');
  assert.equal(unknownWorkspace.status, 404);

  const unknownParent = await createSession(ctx, { parentId: 'ses_0000000000000000' }, 'k-4');
  assert.equal(unknownParent.status, 404);

  const badWorkspace = await createSession(ctx, { workspaceId: 'not-a-workspace' }, 'k-5');
  assert.equal(badWorkspace.status, 400);
});

test('a child session keeps the 「子｜」 prefix on an owner name', async (t) => {
  const ctx = await boot(t);
  const parent = await createSession(ctx);
  const child = await createSession(ctx, { requestId: 'req-child', parentId: parent.body.data.id, name: '調査' }, 'k-child');
  assert.equal(child.status, 201);
  assert.equal(child.body.data.name, '子｜調査');
  assert.equal(child.body.data.nameSource, 'owner');
  assert.equal(child.body.data.parentId, parent.body.data.id);
});

test('send is refused while the agent is busy or waiting, and accepted when idle', async (t) => {
  const ctx = await boot(t);
  const created = await createSession(ctx);
  const id = created.body.data.id;
  const requestId = `laa-bridge-${createHash('sha256').update('req-1').digest('hex').slice(0, 40)}`;

  const busy = await ctx.bridge.request(`/v1/sessions/${id}/messages`, {
    method: 'POST', token: ctx.token, key: 'k-m1', body: { message: 'next' },
  });
  assert.equal(busy.status, 409);
  assert.equal(busy.body.error.code, 'session_busy');

  ctx.adapter.setPending(requestId, [{ id: 'p1', kind: 'question', name: 'AskUserQuestion' }]);
  const waiting = await ctx.bridge.request(`/v1/sessions/${id}/messages`, {
    method: 'POST', token: ctx.token, key: 'k-m2', body: { message: 'next' },
  });
  assert.equal(waiting.status, 409);
  assert.equal(waiting.body.error.code, 'pending_decision_requires_reply');
  // The refusal still records the waiting question for the client.
  const detail = await ctx.bridge.request(`/v1/sessions/${id}`, { token: ctx.token });
  assert.equal(detail.body.data.phase, 'awaiting_decision');
  assert.deepEqual(detail.body.data.pending.kinds, ['question']);

  ctx.adapter.setPending(requestId, []);
  ctx.adapter.setIdle(requestId, { text: 'ok' });
  const sent = await ctx.bridge.request(`/v1/sessions/${id}/messages`, {
    method: 'POST', token: ctx.token, key: 'k-m3', body: { message: 'and again' },
  });
  assert.equal(sent.status, 202);
  assert.equal(sent.body.data.phase, 'running');
  assert.equal(ctx.adapter.agent(requestId).messages.length, 1);

  const events = await ctx.bridge.request(`/v1/sessions/${id}/events?afterSeq=0`, { token: ctx.token });
  const types = events.body.data.items.map((event) => event.type);
  assert.ok(types.includes('session.message.sent'));
  assert.ok(types.includes('session.result'));
});

test('stop confirms, records an event, and refuses further sends', async (t) => {
  const ctx = await boot(t);
  const created = await createSession(ctx);
  const id = created.body.data.id;
  const requestId = `laa-bridge-${createHash('sha256').update('req-1').digest('hex').slice(0, 40)}`;

  const stopped = await ctx.bridge.request(`/v1/sessions/${id}/stop`, {
    method: 'POST', token: ctx.token, key: 'k-stop', body: {},
  });
  assert.equal(stopped.status, 200);
  assert.equal(stopped.body.data.phase, 'stopped');
  assert.equal(stopped.body.data.daemonStatus, 'idle');

  const sendAfterStop = await ctx.bridge.request(`/v1/sessions/${id}/messages`, {
    method: 'POST', token: ctx.token, key: 'k-after-stop', body: { message: 'hello' },
  });
  assert.equal(sendAfterStop.status, 409);
  assert.equal(sendAfterStop.body.error.code, 'session_stopped');

  const events = await ctx.bridge.request(`/v1/sessions/${id}/events?afterSeq=0`, { token: ctx.token });
  assert.ok(events.body.data.items.some((event) => event.type === 'session.stopped'));
  assert.equal(ctx.adapter.agent(requestId).stopRequestedAt > 0, true);
});

test('an unconfirmed stop is surfaced as such, not as stopped', async (t) => {
  const ctx = await boot(t);
  const created = await createSession(ctx);
  const id = created.body.data.id;
  ctx.adapter.stopUnconfirmed = true;

  const stopped = await ctx.bridge.request(`/v1/sessions/${id}/stop`, {
    method: 'POST', token: ctx.token, key: 'k-stop', body: {},
  });
  assert.equal(stopped.status, 409);
  assert.equal(stopped.body.error.code, 'stop_unconfirmed');
  const detail = await ctx.bridge.request(`/v1/sessions/${id}`, { token: ctx.token });
  assert.equal(detail.body.data.phase, 'stop_unconfirmed');
});

test('resume creates a linked successor with the same profile and never changes the model', async (t) => {
  const ctx = await boot(t);
  const created = await createSession(ctx);
  const id = created.body.data.id;

  const tooEarly = await ctx.bridge.request(`/v1/sessions/${id}/resume`, {
    method: 'POST', token: ctx.token, key: 'k-r0', body: { message: 'continue' },
  });
  assert.equal(tooEarly.status, 409);
  assert.equal(tooEarly.body.error.code, 'session_not_stopped');

  await ctx.bridge.request(`/v1/sessions/${id}/stop`, { method: 'POST', token: ctx.token, key: 'k-stop2', body: {} });

  const changedModel = await ctx.bridge.request(`/v1/sessions/${id}/resume`, {
    method: 'POST', token: ctx.token, key: 'k-r1', body: { message: 'continue', profile: 'opus-high' },
  });
  assert.equal(changedModel.status, 400);
  assert.equal(changedModel.body.error.code, 'model_change_rejected');

  const resumed = await ctx.bridge.request(`/v1/sessions/${id}/resume`, {
    method: 'POST', token: ctx.token, key: 'k-r2', body: { message: 'continue' },
  });
  assert.equal(resumed.status, 201);
  assert.equal(resumed.body.data.resumedFrom, id);
  assert.equal(resumed.body.data.profile, 'deepseek-flash-high');
  assert.equal(resumed.body.data.requested.effort, 'high');

  const original = await ctx.bridge.request(`/v1/sessions/${id}`, { token: ctx.token });
  assert.equal(original.body.data.resumedTo, resumed.body.data.id);
  const events = await ctx.bridge.request(`/v1/sessions/${id}/events?afterSeq=0`, { token: ctx.token });
  assert.ok(events.body.data.items.some((event) => event.type === 'session.resumed'));

  const replayed = await ctx.bridge.request(`/v1/sessions/${id}/resume`, {
    method: 'POST', token: ctx.token, key: 'k-r2', body: { message: 'continue' },
  });
  assert.equal(replayed.status, 201);
  assert.equal(replayed.headers.get('idempotency-replayed'), 'true');
  assert.equal(replayed.body.data.id, resumed.body.data.id);
});

test('events resume from a cursor and a long poll returns new events once', async (t) => {
  const ctx = await boot(t);
  const created = await createSession(ctx);
  const id = created.body.data.id;
  const requestId = `laa-bridge-${createHash('sha256').update('req-1').digest('hex').slice(0, 40)}`;

  const initial = await ctx.bridge.request(`/v1/sessions/${id}/events?afterSeq=0`, { token: ctx.token });
  assert.equal(initial.status, 200);
  const startTypes = initial.body.data.items.map((event) => event.type);
  assert.equal(startTypes[0], 'session.created');
  const seqs = initial.body.data.items.map((event) => event.seq);
  assert.deepEqual(seqs, [...seqs].sort((a, b) => a - b));
  assert.equal(new Set(seqs).size, seqs.length);
  const cursor = initial.body.data.nextCursor;

  // Nothing new yet: a plain poll returns no items and does not advance.
  const quiet = await ctx.bridge.request(`/v1/sessions/${id}/events?cursor=${cursor}`, { token: ctx.token });
  assert.equal(quiet.status, 200);
  assert.equal(quiet.body.data.items.length, 0);
  const decoded = JSON.parse(Buffer.from(quiet.body.data.nextCursor, 'base64url').toString('utf8'));
  assert.equal(decoded.q, seqs.at(-1), 'an empty poll must not advance the sequence');

  // The next change arrives during a long poll.
  setTimeout(() => ctx.adapter.setIdle(requestId, { text: 'ok' }), 60);
  const waited = await ctx.bridge.request(`/v1/sessions/${id}/events?cursor=${cursor}&wait=2`, { token: ctx.token });
  assert.equal(waited.status, 200);
  const waitedTypes = waited.body.data.items.map((event) => event.type);
  assert.ok(waitedTypes.includes('session.result'), `expected a result event, got ${waitedTypes.join(',')}`);
  assert.ok(waited.body.data.items.every((event) => event.seq > seqs.at(-1)));
  assert.equal(waited.body.data.resyncRequired, false);
});

test('an expired cursor and a pruned journal are 410, not silence', async (t) => {
  let clock = Date.now();
  const ctx = await boot(t, { now: () => clock, sessions: { eventRetentionMs: 1000 } });
  const created = await createSession(ctx);
  const id = created.body.data.id;
  const cursor = created.body.data.events.cursor;

  clock += 2000;
  const expired = await ctx.bridge.request(`/v1/sessions/${id}/events?cursor=${cursor}`, { token: ctx.token });
  assert.equal(expired.status, 410);
  assert.equal(expired.body.error.code, 'cursor_expired');

  const gap = await ctx.bridge.request(`/v1/sessions/${id}/events?afterSeq=0`, { token: ctx.token });
  assert.equal(gap.status, 410);
  assert.equal(gap.body.error.code, 'event_history_gap');
});

test('artifacts return the journal, the latest result and a waiting decision', async (t) => {
  const ctx = await boot(t);
  const created = await createSession(ctx);
  const id = created.body.data.id;
  const requestId = `laa-bridge-${createHash('sha256').update('req-1').digest('hex').slice(0, 40)}`;

  const logOnly = await ctx.bridge.request(`/v1/sessions/${id}/artifacts`, { token: ctx.token });
  assert.equal(logOnly.status, 200);
  const log = logOnly.body.data.items.find((item) => item.type === 'log');
  assert.ok(log.content.includes('session.created'));
  assert.ok(log.size > 0);

  ctx.adapter.setIdle(requestId, { text: 'the answer' });
  ctx.adapter.setPending(requestId, [{ id: 'p9', kind: 'tool', name: 'Bash' }]);
  const withResult = await ctx.bridge.request(`/v1/sessions/${id}/artifacts`, { token: ctx.token });
  const result = withResult.body.data.items.find((item) => item.type === 'message');
  assert.equal(result.content, 'the answer');
  const decision = withResult.body.data.items.find((item) => item.type === 'decision');
  assert.ok(decision.content.includes('"Bash"'));
});

test('a delegation outage still serves the session and the journal, but flags it', async (t) => {
  const ctx = await boot(t, { sessions: { observationTtlMs: 0 } });
  const created = await createSession(ctx);
  const id = created.body.data.id;
  ctx.adapter.unavailable = true;

  const detail = await ctx.bridge.request(`/v1/sessions/${id}`, { token: ctx.token });
  assert.equal(detail.status, 200);
  assert.equal(detail.body.data.observation.available, false);
  assert.equal(detail.body.data.observation.code, 'delegation_unavailable');

  const events = await ctx.bridge.request(`/v1/sessions/${id}/events?afterSeq=0`, { token: ctx.token });
  assert.equal(events.status, 200);
  assert.equal(events.body.data.resyncRequired, true);
  assert.ok(events.body.data.items.length > 0);

  const send = await ctx.bridge.request(`/v1/sessions/${id}/messages`, {
    method: 'POST', token: ctx.token, key: 'k-down', body: { message: 'hello' },
  });
  assert.equal(send.status, 503);
  assert.equal(send.body.error.code, 'delegation_unavailable');
});

test('scope, authentication, filters and 404s are enforced', async (t) => {
  const ctx = await boot(t);
  const created = await createSession(ctx);
  const id = created.body.data.id;

  const readOnly = await ctx.bridge.token(['sessions:read']);
  const forbidden = await ctx.bridge.request('/v1/sessions', {
    method: 'POST', token: readOnly, key: 'k-scope', body: createBody(ctx, { requestId: 'req-scope' }),
  });
  assert.equal(forbidden.status, 403);

  const anonymous = await ctx.bridge.request('/v1/sessions');
  assert.equal(anonymous.status, 401);

  const list = await ctx.bridge.request('/v1/sessions?requestId=req-1', { token: ctx.token });
  assert.equal(list.status, 200);
  assert.equal(list.body.data.items.length, 1);
  const byWorkspace = await ctx.bridge.request(`/v1/sessions?workspaceId=${ctx.workspaceId}&parentId=root`, { token: ctx.token });
  assert.equal(byWorkspace.body.data.items[0].id, id);
  const other = await ctx.bridge.request('/v1/sessions?requestId=req-none', { token: ctx.token });
  assert.equal(other.body.data.items.length, 0);

  const missing = await ctx.bridge.request('/v1/sessions/ses_0000000000000000', { token: ctx.token });
  assert.equal(missing.status, 404);

  const badLimit = await ctx.bridge.request('/v1/sessions?limit=1000', { token: ctx.token });
  assert.equal(badLimit.status, 400);
  assert.equal(badLimit.body.error.code, 'limit_invalid');
});

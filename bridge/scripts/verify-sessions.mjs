#!/usr/bin/env node
// End-to-end check of /v1/sessions against the real delegation path
// (laa-personal-agent -> Paseo daemon -> a cheap DSH agent).
//
//   LAA_BRIDGE_URL=http://127.0.0.1:9137 \
//   LAA_BRIDGE_TOKEN=… LAA_BRIDGE_VERIFY_WORKSPACE=ws_… \
//   node scripts/verify-sessions.mjs
//
// It creates one session, reconnects the event stream from a cursor, sends one
// follow-up, stops the session, reads the artifacts, and repeats the create
// with the same requestId to prove the duplicate is reconciled. The token and
// the prompt text are never printed; only ids, phases and sizes are.

import { randomUUID } from 'node:crypto';

const base = process.env.LAA_BRIDGE_URL ?? 'http://127.0.0.1:9137';
const token = process.env.LAA_BRIDGE_TOKEN;
const workspaceId = process.env.LAA_BRIDGE_VERIFY_WORKSPACE;
const profile = process.env.LAA_BRIDGE_VERIFY_PROFILE ?? 'deepseek-flash-high';
const firstPrompt = process.env.LAA_BRIDGE_VERIFY_PROMPT ?? 'Reply with exactly: ok';
const secondPrompt = process.env.LAA_BRIDGE_VERIFY_FOLLOW_UP ?? 'Reply with exactly: second';
const settleSeconds = Number(process.env.LAA_BRIDGE_VERIFY_TIMEOUT ?? 180);

if (!token) throw new Error('LAA_BRIDGE_TOKEN is required');
if (!workspaceId) throw new Error('LAA_BRIDGE_VERIFY_WORKSPACE is required');

async function call(method, path, { body, key } = {}) {
  const headers = { authorization: `Bearer ${token}` };
  if (body !== undefined) headers['content-type'] = 'application/json';
  if (key) headers['idempotency-key'] = key;
  const response = await fetch(`${base}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  const parsed = text === '' ? null : JSON.parse(text);
  if (!response.ok) {
    const code = parsed?.error?.code ?? 'request_failed';
    const error = new Error(`${method} ${path} -> ${response.status} ${code}`);
    error.status = response.status;
    error.code = code;
    throw error;
  }
  return { status: response.status, headers: response.headers, body: parsed, text: response.text };
}

async function detail(id) {
  return (await call('GET', `/v1/sessions/${id}`)).body.data;
}

async function waitFor(id, phases, { timeoutMs = settleSeconds * 1000, cursor } = {}) {
  const until = Date.now() + timeoutMs;
  let current = cursor;
  let last = null;
  while (Date.now() < until) {
    const page = await call('GET', `/v1/sessions/${id}/events?${current ? `cursor=${current}` : 'afterSeq=0'}`);
    current = page.body.data.nextCursor;
    last = await detail(id);
    if (phases.includes(last.phase)) return { session: last, cursor: current, events: page.body.data.items };
    await new Promise((resolve) => setTimeout(resolve, 2000));
  }
  throw new Error(`session ${id} did not reach ${phases.join('|')} (last phase ${last?.phase})`);
}

const summary = { steps: [] };
const requestId = `verify-${randomUUID()}`;
const workspace = workspaceId;

const created = await call('POST', '/v1/sessions', {
  key: `verify-create-${randomUUID()}`,
  body: { workspaceId: workspace, requestId, profile, prompt: firstPrompt },
});
const session = created.body.data;
summary.steps.push({ step: 'create', status: created.status, id: session.id, phase: session.phase, requested: session.requested });
if (!session.events?.cursor) throw new Error('create returned no event cursor');

// Reconnect the stream from the cursor the create response handed out.
let cursor = session.events.cursor;
const firstRun = await waitFor(session.id, ['awaiting_review', 'error', 'closed'], { cursor });
cursor = firstRun.cursor;
summary.steps.push({ step: 'events', events: firstRun.events.map((event) => event.type), cursorSeq: JSON.parse(Buffer.from(cursor, 'base64url').toString('utf8')).q });
if (firstRun.session.phase !== 'awaiting_review') throw new Error(`first turn ended in ${firstRun.session.phase}`);
summary.steps.push({ step: 'observed', observed: firstRun.session.observed, runtimeVerified: firstRun.session.runtimeVerified });

// Duplicate request: same requestId, a fresh Idempotency-Key.
const duplicate = await call('POST', '/v1/sessions', {
  key: `verify-create-${randomUUID()}`,
  body: { workspaceId: workspace, requestId, profile, prompt: firstPrompt },
});
summary.steps.push({ step: 'duplicate', status: duplicate.status, sameId: duplicate.body.data.id === session.id });
if (duplicate.status !== 200 || duplicate.body.data.id !== session.id) throw new Error('duplicate create was not reconciled');

const sent = await call('POST', `/v1/sessions/${session.id}/messages`, {
  key: `verify-send-${randomUUID()}`,
  body: { message: secondPrompt },
});
summary.steps.push({ step: 'send', status: sent.status, phase: sent.body.data.phase });

const secondRun = await waitFor(session.id, ['awaiting_review', 'error', 'closed'], { cursor });
cursor = secondRun.cursor;
summary.steps.push({ step: 'events-after-send', events: secondRun.events.map((event) => event.type) });
if (secondRun.session.phase !== 'awaiting_review') throw new Error(`second turn ended in ${secondRun.session.phase}`);

const stopped = await call('POST', `/v1/sessions/${session.id}/stop`, {
  key: `verify-stop-${randomUUID()}`,
  body: {},
});
summary.steps.push({ step: 'stop', status: stopped.status, phase: stopped.body.data.phase, daemonStatus: stopped.body.data.daemonStatus });
if (stopped.body.data.phase !== 'stopped') throw new Error(`stop ended in ${stopped.body.data.phase}`);

const artifacts = await call('GET', `/v1/sessions/${session.id}/artifacts`);
const items = artifacts.body.data.items.map((item) => ({ id: item.id, type: item.type, size: item.size, truncated: item.truncated }));
summary.steps.push({ step: 'artifacts', items });
const resultArtifact = artifacts.body.data.items.find((item) => item.type === 'message');
summary.steps.push({ step: 'result', excerpt: resultArtifact?.content?.slice(0, 80) ?? null, chars: resultArtifact?.content?.length ?? 0 });

const finalEvents = await call('GET', `/v1/sessions/${session.id}/events?cursor=${cursor}`);
summary.steps.push({ step: 'final-events', events: finalEvents.body.data.items.map((event) => event.type) });
if (!finalEvents.body.data.items.some((event) => event.type === 'session.stopped')) {
  throw new Error('the stop event was not delivered from the cursor');
}

summary.sessionId = session.id;
summary.phase = (await detail(session.id)).phase;
process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);

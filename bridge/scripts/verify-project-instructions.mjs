#!/usr/bin/env node
// End-to-end check of Project shared instructions against the running Bridge:
// store → version → 412 with both sides → apply to a real session.
//
//   LAA_BRIDGE_URL=http://127.0.0.1:9137 \
//   LAA_BRIDGE_TOKEN=… LAA_BRIDGE_VERIFY_WORKSPACE=ws_… \
//   node scripts/verify-project-instructions.mjs
//
// It creates a throwaway project, edits it once, sends a deliberately stale
// PATCH (expects 412 with the current body), reads the version history, starts
// one cheap session that is asked to echo the instruction header, and stops it.
// The token is never printed; the instruction body here is a test string, not
// the owner's material. Clean up the project record and the scratch worktree
// outside the Bridge afterwards (the Bridge has no delete API on purpose).

import { randomUUID } from 'node:crypto';

const base = process.env.LAA_BRIDGE_URL ?? 'http://127.0.0.1:9137';
const token = process.env.LAA_BRIDGE_TOKEN;
const workspaceId = process.env.LAA_BRIDGE_VERIFY_WORKSPACE;
const profile = process.env.LAA_BRIDGE_VERIFY_PROFILE ?? 'deepseek-flash-high';
const settleSeconds = Number(process.env.LAA_BRIDGE_VERIFY_TIMEOUT ?? 180);

if (!token) throw new Error('LAA_BRIDGE_TOKEN is required');
if (!workspaceId) throw new Error('LAA_BRIDGE_VERIFY_WORKSPACE is required');

async function call(method, path, { body, key, headers = {} } = {}) {
  const finalHeaders = { authorization: `Bearer ${token}`, ...headers };
  if (body !== undefined) finalHeaders['content-type'] = 'application/json';
  if (key) finalHeaders['idempotency-key'] = key;
  const response = await fetch(`${base}${path}`, {
    method,
    headers: finalHeaders,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  const parsed = text === '' ? null : JSON.parse(text);
  return { status: response.status, headers: response.headers, body: parsed };
}

async function ok(method, path, options) {
  const response = await call(method, path, options);
  if (response.status >= 400) {
    throw new Error(`${method} ${path} -> ${response.status} ${response.body?.error?.code ?? ''}`);
  }
  return response;
}

const V1 = 'Reply with exactly the hash shown in your instructions header, and nothing else.';
const V2 = 'Reply with exactly the version shown in your instructions header, and nothing else.';
const steps = [];

const created = await ok('POST', '/v1/projects', {
  key: `verify-project-${randomUUID()}`,
  body: { name: 'LAA｜指示版検証', instructions: V1 },
});
const project = created.body.data;
steps.push({ step: 'create', status: created.status, id: project.id, version: project.version, instructionVersion: project.instructionVersion, hash: project.instructionHash });
if (project.instructionVersion !== 1) throw new Error(`expected instructionVersion 1, got ${project.instructionVersion}`);

const edited = await ok('PATCH', `/v1/projects/${project.id}`, {
  key: `verify-project-edit-${randomUUID()}`,
  headers: { 'if-match': `"${project.version}"` },
  body: { instructions: V2 },
});
steps.push({ step: 'edit', status: edited.status, version: edited.body.data.version, instructionVersion: edited.body.data.instructionVersion, hash: edited.body.data.instructionHash });
if (edited.body.data.instructionVersion !== 2) throw new Error('the edit did not create instruction version 2');

const stale = await call('PATCH', `/v1/projects/${project.id}`, {
  key: `verify-project-stale-${randomUUID()}`,
  headers: { 'if-match': `"${project.version}"` },
  body: { instructions: 'This must never be stored.' },
});
const current = stale.body?.error?.details?.current;
if (stale.status !== 412) throw new Error(`expected 412 on a stale If-Match, got ${stale.status}`);
if (current?.instructions !== V2 || current?.instructionVersion !== 2 || current?.etag !== `"${edited.body.data.version}"`) {
  throw new Error('the 412 did not return the current version, ETag and body');
}
steps.push({ step: 'stale-edit', status: stale.status, currentVersion: current.version, currentInstructionVersion: current.instructionVersion, currentEtag: current.etag, bodyReturned: current.instructions === V2 });

const versions = await ok('GET', `/v1/projects/${project.id}/instructions/versions`);
const history = versions.body.data.items;
if (history.length !== 2 || history[0].version !== 2 || history[1].body !== V1) {
  throw new Error('the version history does not hold both revisions');
}
steps.push({ step: 'versions', status: versions.status, count: history.length, newest: history[0].version });

const session = await ok('POST', '/v1/sessions', {
  key: `verify-project-session-${randomUUID()}`,
  body: {
    workspaceId,
    requestId: `verify-project-${randomUUID()}`,
    profile,
    projectId: project.id,
    prompt: 'Reply with the instruction header values.',
  },
});
const record = session.body.data;
if (record.instructionVersion !== 2 || record.instructionHash !== edited.body.data.instructionHash) {
  throw new Error('the session did not record the applied instruction version and hash');
}
steps.push({ step: 'session', status: session.status, id: record.id, projectId: record.projectId, instructionVersion: record.instructionVersion, hash: record.instructionHash });

const until = Date.now() + settleSeconds * 1000;
let detail = record;
while (Date.now() < until && !['awaiting_review', 'error', 'closed', 'stopped'].includes(detail.phase)) {
  await new Promise((resolve) => setTimeout(resolve, 2000));
  detail = (await ok('GET', `/v1/sessions/${record.id}`)).body.data;
}
steps.push({ step: 'settle', phase: detail.phase });

const artifacts = (await ok('GET', `/v1/sessions/${record.id}/artifacts`)).body.data.items;
const result = artifacts.find((item) => item.type === 'message')?.content ?? '';
const hash = edited.body.data.instructionHash;
steps.push({
  step: 'artifacts',
  resultEchoesHash: result.includes(hash),
  resultEchoesVersion: /(^|\D)2(\D|$)/.test(result.trim()),
  resultChars: result.length,
});

const stopped = await ok('POST', `/v1/sessions/${record.id}/stop`, {
  key: `verify-project-stop-${randomUUID()}`,
  body: {},
});
steps.push({ step: 'stop', status: stopped.status, phase: stopped.body.data.phase });

const journal = (await ok('GET', `/v1/sessions/${record.id}/artifacts`)).body.data.items.find((item) => item.type === 'log')?.content ?? '';
steps.push({ step: 'journal', carriesBody: journal.includes(V2), carriesVersion: journal.includes('"instructionVersion":2') });

process.stdout.write(`${JSON.stringify({ ok: true, projectId: project.id, sessionId: record.id, steps }, null, 2)}\n`);

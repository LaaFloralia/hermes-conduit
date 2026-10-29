#!/usr/bin/env node
// End-to-end check of Project shared instructions against the running Bridge:
// store → version → 412 with both sides → apply to a real session → no leak.
//
//   LAA_BRIDGE_URL=http://127.0.0.1:9137 \
//   LAA_BRIDGE_TOKEN=… LAA_BRIDGE_VERIFY_WORKSPACE=ws_… \
//   node scripts/verify-project-instructions.mjs
//
// It creates a throwaway project, edits it once, sends a deliberately stale
// PATCH (expects 412 with the current body), reads the version history, starts
// one cheap session that is asked to echo the instruction hash, and stops it.
// The token is never printed; the instruction body here is a test string, not
// the owner's material. Clean up the project record and the scratch worktree
// outside the Bridge afterwards (the Bridge has no delete API on purpose).
//
// `ok` is true only when the apply check (the agent echoed the hash from its
// instructions header), the identity check (the session recorded the project's
// version and hash) and the no-leak check (the journal carries the version but
// not the body) all pass. A run that errors, answers nothing or leaks exits 1.

import { randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';

const V1 = 'Reply with exactly the hash shown in your instructions header, and nothing else.';
const V2 = 'Reply with exactly the hash shown in your instructions header, and nothing else. Use the current wording.';

// The journal artifact is JSONL. A line that does not parse is a failure, not
// something to skip: the rest of that line (possibly a leaked body) is unknown.
export function parseJournal(journal) {
  const events = [];
  const invalid = [];
  for (const line of String(journal ?? '').split('\n')) {
    if (line.trim() === '') continue;
    try {
      events.push(JSON.parse(line));
    } catch {
      invalid.push(line);
    }
  }
  return { events, invalid };
}

// Every string inside the parsed events, decoded. A body written into an event
// is JSON-escaped, so searching the raw line would miss it.
export function journalStrings(events) {
  const parts = [];
  const walk = (value) => {
    if (typeof value === 'string') parts.push(value);
    else if (Array.isArray(value)) value.forEach(walk);
    else if (value && typeof value === 'object') Object.values(value).forEach(walk);
  };
  walk(events);
  return parts.join('\n');
}

// `ok` requires all of: the session recorded the project's version and hash,
// the agent's answer is exactly the header hash (surrounding whitespace only),
// the journal is complete and parseable, it carries the version but not the
// body, and the agent answered without an error.
export function evaluateVerification({ project, session, result, journal, journalTruncated = false, hash, body }) {
  const { events, invalid } = parseJournal(journal);
  const intact = journalTruncated !== true && invalid.length === 0 && events.length > 0;
  const carriesVersion = events.some((event) => event?.payload?.instructionVersion === project?.instructionVersion);
  const checks = {
    identity: session?.instructionVersion === project?.instructionVersion
      && session?.instructionHash === hash,
    applied: typeof result === 'string' && result.trim() === hash,
    journalIntact: intact,
    noLeak: intact && carriesVersion && !journalStrings(events).includes(body),
    answered: typeof result === 'string' && result.trim() !== '' && session?.phase !== 'error',
  };
  return { ok: Object.values(checks).every(Boolean), checks };
}

async function run() {
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
      prompt: 'Reply with the value requested in your instructions.',
    },
  });
  const record = session.body.data;
  steps.push({
    step: 'session',
    status: session.status,
    id: record.id,
    delegateSessionId: record.delegateSessionId,
    projectId: record.projectId,
    instructionVersion: record.instructionVersion,
    hash: record.instructionHash,
    title: record.name,
  });

  const until = Date.now() + settleSeconds * 1000;
  let detail = record;
  while (Date.now() < until && !['awaiting_review', 'error', 'closed', 'stopped'].includes(detail.phase)) {
    await new Promise((resolve) => setTimeout(resolve, 2000));
    detail = (await ok('GET', `/v1/sessions/${record.id}`)).body.data;
  }
  steps.push({ step: 'settle', phase: detail.phase });

  const artifacts = (await ok('GET', `/v1/sessions/${record.id}/artifacts`)).body.data.items;
  const result = artifacts.find((item) => item.type === 'message')?.content ?? '';
  const log = artifacts.find((item) => item.type === 'log');
  const journal = log?.content ?? '';
  const journalTruncated = log?.truncated === true;

  const verdict = evaluateVerification({
    project: { instructionVersion: 2, instructionHash: edited.body.data.instructionHash },
    session: detail,
    result,
    journal,
    journalTruncated,
    hash: edited.body.data.instructionHash,
    body: V2,
  });
  steps.push({
    step: 'checks',
    ok: verdict.ok,
    ...verdict.checks,
    journalTruncated,
    resultChars: result.trim().length,
    journalChars: journal.length,
  });

  const stopped = await ok('POST', `/v1/sessions/${record.id}/stop`, {
    key: `verify-project-stop-${randomUUID()}`,
    body: {},
  });
  steps.push({ step: 'stop', status: stopped.status, phase: stopped.body.data.phase });

  return { ok: verdict.ok, projectId: project.id, sessionId: record.id, delegateSessionId: record.delegateSessionId, steps };
}

const isMain = process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  run()
    .then((result) => {
      process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
      if (!result.ok) process.exitCode = 1;
    })
    .catch((err) => {
      process.stderr.write(`${JSON.stringify({ ok: false, error: err?.message ?? String(err) })}\n`);
      process.exitCode = 1;
    });
}

// Session service: the Bridge's own session identity, mapped onto the existing
// `laa-personal-agent` delegation path.
//
// Division of responsibility:
//   * the delegation path owns the agent: creation idempotency, requested vs
//     observed model/effort, pending approvals, stop confirmation.
//   * the Bridge owns the LAA session: a stable id derived from the client's
//     requestId, the parent/workspace/project links, an append-only event
//     journal with resume cursors, and the artifact view.
//
// The Bridge never edits, upgrades or falls back on the requested profile: the
// profile string is passed through, and whatever the delegation path reports as
// `requested` / `observed` is recorded verbatim.
//
// Project instructions (BRIDGE.md §9) are applied here, once, at create time:
// the project's body (or the file its `instructionRef` points at, read now) is
// composed into a delimited block ahead of the owner's prompt, and only its
// version and hash are recorded on the session and its events. A retry of the
// same requestId after the instructions changed is therefore a conflict, not a
// second run under a prompt the owner never saw.

import { createHash } from 'node:crypto';
import { BridgeError, badRequest, conflict, notFound } from '../errors.mjs';
import { encodeEventCursor, parseEventCursor } from './cursor.mjs';
import { DELEGATION_ORIGIN } from './adapter.mjs';

export const CHILD_NAME_PREFIX = '子｜';
const REQUEST_ID_PATTERN = /^[A-Za-z0-9._:-]{1,200}$/;
const PROFILE_PATTERN = /^[a-z0-9][a-z0-9-]{0,63}$/;
const MAX_TEXT_BYTES = 16_384;
const MAX_NAME_LENGTH = 100;
const MAX_ARTIFACT_BYTES = 64 * 1024;
const INSTRUCTION_TAG = 'project_instructions';

const sha = (value) => createHash('sha256').update(value, 'utf8').digest('hex');
const count = (text) => [...text].length;

export function createSessionService({
  sessionStore,
  adapter,
  findWorkspace,
  findProject = () => null,
  resolveProjectInstructions = () => null,
  now = () => Date.now(),
  retentionMs = 24 * 60 * 60 * 1000,
  pollMs = 2500,
  observationTtlMs = 1500,
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
}) {
  // An observation cache keeps a detail read and an events long-poll from
  // spawning the delegation CLI twice in the same second.
  const observations = new Map();

  function sessionIdFor(requestId) {
    return `ses_${sha(`laa-bridge|${requestId}`).slice(0, 16)}`;
  }

  // Deterministic on purpose: a retry after an unknown outcome reaches the
  // delegation path with the same request id and gets the same agent back
  // instead of starting a second one.
  function delegateIdFor(requestId) {
    return `laa-bridge-${sha(requestId).slice(0, 40)}`;
  }

  function requireSession(id) {
    const record = sessionStore.get(id);
    if (!record) throw notFound('session not found');
    return record;
  }

  // A referenced instruction file is read here, at use time, so an edit in the
  // vault reaches the next session without another PATCH. An unreadable file
  // stops the session instead of running it without the shared instructions.
  function resolveInstructions(project) {
    let resolved;
    try {
      resolved = resolveProjectInstructions(project);
    } catch (err) {
      if (err instanceof BridgeError && err.status >= 500) throw err;
      const code = err instanceof BridgeError ? err.code : 'instruction_unavailable';
      throw new BridgeError(409, code, 'the project instructions cannot be read; fix the project or skip them for this session');
    }
    if (!resolved) return null;
    if (new RegExp(`</${INSTRUCTION_TAG}`, 'i').test(resolved.body)) {
      throw new BridgeError(409, 'instruction_invalid', `the project instructions contain the </${INSTRUCTION_TAG}> delimiter`);
    }
    return resolved;
  }

  async function createSession({ deviceId, body = {}, resumedFrom = null }) {
    const requestId = parseRequestId(body.requestId);
    const profile = parseProfile(body.profile);
    const prompt = asText(body.prompt, 'prompt');
    const workspaceId = parseWorkspaceId(body.workspaceId);
    const parentId = body.parentId === undefined || body.parentId === null ? null : parseSessionId(body.parentId);
    const projectId = body.projectId === undefined || body.projectId === null
      ? null
      : asText(body.projectId, 'projectId', { max: 100 });
    const applyProjectInstructions = parseApplyProjectInstructions(body);
    const id = sessionIdFor(requestId);

    // Resolve the project and its instructions before the request digest: a
    // retry of the same requestId after the owner edited the instructions must
    // be refused as a different request, not silently re-run under new text.
    const project = projectId ? findProject(projectId) : null;
    if (projectId && !project) throw notFound('project not found');
    const instructions = project && applyProjectInstructions ? resolveInstructions(project) : null;

    // The request identity is bound to its content: the same requestId with a
    // different profile, workspace, parent, prompt or instruction version is a
    // conflict, not a silent reconcile.
    const requestDigest = sha(JSON.stringify({
      profile,
      workspaceId,
      parentId,
      projectId,
      prompt,
      purpose: body.purpose ?? null,
      completion: body.completion ?? null,
      scope: body.scope ?? null,
      returnTo: body.returnTo ?? null,
      instructionVersion: instructions?.version ?? null,
      instructionHash: instructions?.hash ?? null,
    }));

    const existing = sessionStore.get(id);
    if (existing) {
      assertSameRequest(existing, { profile, workspaceId, parentId, projectId, requestDigest });
      return { session: existing, created: false };
    }

    const workspace = await findWorkspace(workspaceId);
    if (!workspace) throw notFound('workspace not found under an allowlisted root');
    if (parentId && !sessionStore.get(parentId)) throw notFound('parent session not found');

    let name = body.name === undefined || body.name === null ? null : asText(body.name, 'name', { max: MAX_NAME_LENGTH });
    const nameSource = name === null ? 'default' : 'owner';
    if (name === null) name = `セッション ${id.slice(4, 10)}`;
    if (parentId && !name.startsWith(CHILD_NAME_PREFIX)) name = `${CHILD_NAME_PREFIX}${name}`;

    // The delegation wrapper requires the task fields; a plain chat session
    // gets neutral defaults, an explicit body can describe the job properly.
    const task = {
      purpose: asText(body.purpose ?? 'LAA Bridge session', 'purpose', { max: 2000 }),
      completion: asText(body.completion ?? 'Answer the request and leave the result for the Bridge to collect.', 'completion', { max: 2000 }),
      scope: asText(body.scope ?? 'Only the assigned workspace and task; do not touch other conversations.', 'scope', { max: 2000 }),
      returnTo: asText(body.returnTo ?? 'The requesting Bridge device', 'returnTo', { max: 2000 }),
      prompt: instructions ? composePrompt(project.id, instructions, prompt) : prompt,
    };

    const delegateRequestId = delegateIdFor(requestId);
    const created = await adapter.create({ requestId: delegateRequestId, profile, cwd: workspace.path, task });
    if (typeof created?.sessionId !== 'string' || created.sessionId === '') {
      throw new BridgeError(503, 'delegation_inconsistent', 'the delegation path returned no session id');
    }

    const requested = normalizeRequested(created.requested, { profile });
    const record = {
      id,
      requestId,
      requestDigest,
      parentId,
      projectId,
      workspaceId,
      cwd: workspace.path,
      name,
      nameSource,
      profile,
      instructionVersion: instructions?.version ?? null,
      instructionHash: instructions?.hash ?? null,
      instructionsApplied: instructions !== null,
      requested,
      observed: null,
      modelCheck: null,
      phase: 'created',
      daemonStatus: null,
      version: 1,
      delegate: {
        origin: adapter.origin ?? DELEGATION_ORIGIN,
        requestId: delegateRequestId,
        sessionId: created.sessionId,
      },
      resumedFrom,
      resumedTo: null,
      pending: null,
      result: null,
      stopRequestedAt: null,
      createdAt: new Date(now()).toISOString(),
      updatedAt: new Date(now()).toISOString(),
      observedAt: null,
      createdBy: deviceId ?? null,
    };

    const stored = sessionStore.create({
      record,
      events: [{
        type: 'session.created',
        payload: {
          name,
          profile,
          requested,
          workspaceId,
          parentId,
          resumedFrom,
          delegateSessionId: created.sessionId,
          // Only the identity of the applied instructions: the body stays in
          // the project record and never enters the event journal.
          instructionVersion: instructions?.version ?? null,
          instructionHash: instructions?.hash ?? null,
        },
      }],
    });

    // Best effort: record the real provider/model/effort as soon as the agent
    // reports them. A failed observation must not fail the create.
    await observe(stored.record.id).catch(() => null);
    return { session: sessionStore.get(stored.record.id) ?? stored.record, created: stored.created };
  }

  async function listSessions(query = {}) {
    const limit = parseLimit(query.limit);
    const offset = parseOffset(query.cursor);
    const projectId = query.projectId ?? null;
    const workspaceId = query.workspaceId ? parseWorkspaceId(query.workspaceId) : null;
    const requestId = query.requestId ? parseRequestId(query.requestId) : null;
    const phase = query.phase ?? null;
    let parentId;
    if (query.parentId === 'root') parentId = null;
    else if (query.parentId !== undefined && query.parentId !== null && query.parentId !== '') parentId = parseSessionId(query.parentId);

    const filtered = sessionStore.all()
      .filter((record) => (projectId ? record.projectId === projectId : true))
      .filter((record) => (workspaceId ? record.workspaceId === workspaceId : true))
      .filter((record) => (requestId ? record.requestId === requestId : true))
      .filter((record) => (phase ? record.phase === phase : true))
      .filter((record) => (parentId === undefined ? true : (record.parentId ?? null) === parentId))
      .sort((a, b) => (b.createdAt ?? '').localeCompare(a.createdAt ?? '') || a.id.localeCompare(b.id));

    const page = filtered.slice(offset, offset + limit);
    return {
      items: page,
      nextCursor: offset + limit < filtered.length ? encodeOffset(offset + limit) : null,
    };
  }

  async function getSession(id) {
    const record = requireSession(id);
    const observation = await observe(id);
    return {
      session: sessionStore.get(id) ?? record,
      observation: {
        available: observation.available,
        code: observation.code ?? null,
        observedAt: (sessionStore.get(id) ?? record).observedAt ?? null,
      },
    };
  }

  async function sendMessage({ id, body = {}, key }) {
    const record = requireSession(id);
    if (record.stopRequestedAt || record.phase === 'stopped' || record.phase === 'stop_unconfirmed') {
      throw conflict('session_stopped', 'the session is stopped; resume it instead of sending');
    }
    const text = asText(body.message ?? body.text, 'message');
    const messageId = body.messageId === undefined || body.messageId === null
      ? `msg_${sha(`${id}|${key ?? ''}`).slice(0, 24)}`
      : asText(body.messageId, 'messageId', { max: 200 });

    try {
      await adapter.send({ requestId: record.delegate.requestId, messageId, text });
    } catch (err) {
      // The client needs the waiting question in the same breath as the 409.
      if (err instanceof BridgeError && err.code === 'pending_decision_requires_reply') {
        await observe(id, { force: true }).catch(() => null);
      }
      throw err;
    }

    const updated = sessionStore.update(id, (current) => {
      const events = [];
      if (current.phase !== 'running') {
        events.push({ type: 'session.phase', payload: { phase: 'running', previous: current.phase, daemonStatus: current.daemonStatus } });
        current.phase = 'running';
      }
      events.push({ type: 'session.message.sent', payload: { messageId, chars: count(text) } });
      return events;
    });
    return { session: updated?.record ?? requireSession(id) };
  }

  async function stopSession(id) {
    const record = requireSession(id);
    let result;
    try {
      result = await adapter.stop({ requestId: record.delegate.requestId });
    } catch (err) {
      if (err instanceof BridgeError && err.code === 'stop_unconfirmed') {
        sessionStore.update(id, (current) => {
          current.stopRequestedAt ??= new Date(now()).toISOString();
          if (current.phase === 'stop_unconfirmed') return [];
          current.phase = 'stop_unconfirmed';
          return [{ type: 'session.stop_unconfirmed', payload: { daemonStatus: current.daemonStatus } }];
        });
      }
      throw err;
    }
    const updated = sessionStore.update(id, (current) => {
      current.stopRequestedAt ??= new Date(now()).toISOString();
      current.daemonStatus = result.daemonStatus ?? current.daemonStatus;
      if (current.phase === 'stopped') return [];
      current.phase = 'stopped';
      return [{ type: 'session.stopped', payload: { daemonStatus: current.daemonStatus } }];
    });
    return { session: updated?.record ?? requireSession(id) };
  }

  // laa-personal-agent refuses `send` after a stop (`session_stopped`) and has
  // no resume operation, so a resume is a successor session through the same
  // create path: same profile, same workspace, linked by resumedFrom. Nothing
  // about a stopped agent is modified or restarted behind the wrapper's back.
  async function resumeSession({ id, body = {}, key, deviceId }) {
    const original = requireSession(id);
    if (original.phase === 'stop_unconfirmed') {
      throw conflict('stop_unconfirmed', 'the earlier stop is not confirmed; reconcile before resuming');
    }
    if (original.phase !== 'stopped') {
      throw conflict('session_not_stopped', 'only a stopped session can be resumed');
    }
    const message = asText(body.message ?? body.prompt, 'message');
    const profile = body.profile === undefined || body.profile === null ? original.profile : parseProfile(body.profile);
    if (profile !== original.profile) {
      throw badRequest('model_change_rejected', 'resume must keep the original profile; create a new session to change it');
    }
    const requestId = body.requestId === undefined || body.requestId === null
      ? `resume-${original.id}-${sha(key ?? '').slice(0, 16)}`
      : parseRequestId(body.requestId);
    // A resume is a new attempt and needs its own identity; reusing the
    // original requestId would resolve back to the stopped session itself.
    if (requestId === original.requestId) {
      throw conflict('request_id_conflict', 'resume needs its own requestId');
    }

    const result = await createSession({
      deviceId,
      resumedFrom: original.id,
      body: {
        requestId,
        profile,
        prompt: message,
        workspaceId: original.workspaceId,
        projectId: original.projectId,
        parentId: original.parentId,
        name: original.name,
      },
    });

    const successorId = result.session.id;
    if (original.resumedTo !== successorId) {
      sessionStore.update(id, (current) => {
        if (current.resumedTo === successorId) return [];
        current.resumedTo = successorId;
        return [{ type: 'session.resumed', payload: { successorId } }];
      });
    }
    return { session: sessionStore.get(successorId) ?? result.session, created: result.created, resumedFrom: id };
  }

  async function readEventPage({ id, cursor, afterSeq, limit, wait, res }) {
    const record = requireSession(id);
    const oldest = sessionStore.oldestSeq(id);
    const startSeq = cursor === null || cursor === undefined
      ? parseAfterSeq(afterSeq)
      : parseEventCursor(cursor, { sessionId: id, now: now(), retentionMs });
    if (startSeq < oldest - 1) {
      throw new BridgeError(410, 'event_history_gap', 'the journal no longer covers this cursor; re-read the session and its artifacts');
    }
    const pageLimit = parseEventLimit(limit);
    const waitSeconds = parseWait(wait);
    const deadline = Date.now() + waitSeconds * 1000;
    let resync = null;

    for (;;) {
      const observation = await observe(id, { force: true });
      if (!observation.available) resync = observation.code ?? 'delegation_unavailable';
      const page = sessionStore.readEvents(id, { afterSeq: startSeq, limit: pageLimit });
      // A down delegation path cannot produce new events; waiting would only
      // repeat the same failure. Hand back what the journal has and let the
      // client resync.
      if (page.items.length > 0 || waitSeconds === 0 || resync !== null) {
        return { record: record.id, page, startSeq, resync };
      }
      if (Date.now() >= deadline || res?.destroyed || res?.writableEnded) {
        return { record: record.id, page, startSeq, resync };
      }
      await sleep(Math.max(10, Math.min(pollMs, deadline - Date.now())));
    }
  }

  async function listArtifacts(id) {
    const record = requireSession(id);
    const observation = await observe(id, { force: true });
    const current = sessionStore.get(id) ?? record;
    const events = sessionStore.allEvents(id);
    const logText = events
      .map((event) => JSON.stringify({ seq: event.seq, type: event.type, version: event.version, occurredAt: event.occurredAt, payload: event.payload }))
      .join('\n');
    const items = [
      artifact(`${id}.log`, `${id}.events.jsonl`, 'log', logText === '' ? '' : `${logText}\n`, events.at(-1)?.occurredAt ?? current.updatedAt),
    ];
    if (observation.available) {
      const status = observation.status ?? {};
      if (typeof status.result?.text === 'string' && status.result.text !== '') {
        items.push(artifact(`${id}.result`, `${id}.result.md`, 'message', status.result.text, current.observedAt));
      }
      if (Array.isArray(status.pending) && status.pending.length > 0) {
        items.push(artifact(`${id}.pending`, `${id}.pending.json`, 'decision', `${JSON.stringify(status.pending, null, 2)}\n`, current.observedAt));
      }
    } else {
      items.push({
        id: `${id}.result`,
        name: `${id}.result.md`,
        type: 'message',
        size: null,
        truncated: false,
        content: null,
        available: false,
        reason: observation.code ?? 'delegation_unavailable',
        updatedAt: null,
      });
    }
    return { items };
  }

  // --- observation ---------------------------------------------------------

  async function observe(id, { force = false } = {}) {
    const cached = observations.get(id);
    if (!force && cached && Date.now() - cached.at < observationTtlMs) return cached.result;
    const record = sessionStore.get(id);
    if (!record) return { available: false, code: 'session_not_found' };

    let status;
    try {
      status = await adapter.status({ requestId: record.delegate.requestId });
    } catch (err) {
      const result = { available: false, code: err instanceof BridgeError ? err.code : 'delegation_failed' };
      observations.set(id, { at: Date.now(), result });
      return result;
    }

    applyObservation(id, status);
    const result = { available: true, status };
    observations.set(id, { at: Date.now(), result });
    return result;
  }

  function applyObservation(id, status) {
    const pending = summarizePending(status.pending);
    const result = summarizeResult(status.result);
    const phase = mapPhase(status);
    sessionStore.update(id, (record) => {
      const events = [];
      if (status.modelCheck) record.modelCheck = status.modelCheck;
      if (status.modelCheck?.observed) {
        record.observed = status.modelCheck.observed;
        record.runtimeVerified = status.modelCheck.runtimeVerified === true;
      }
      if (status.daemonStatus) record.daemonStatus = status.daemonStatus;
      if (status.stopRequestedAt) record.stopRequestedAt = new Date(status.stopRequestedAt).toISOString();
      if (phase !== record.phase) {
        events.push({ type: 'session.phase', payload: { phase, previous: record.phase, daemonStatus: record.daemonStatus } });
        record.phase = phase;
      }
      if (pending.hash !== record.pending?.hash) {
        events.push({ type: 'session.pending', payload: { count: pending.count, kinds: pending.kinds } });
        record.pending = pending;
      }
      if (result && result.key !== record.result?.key) {
        events.push({ type: 'session.result', payload: { messageId: result.messageId, timestamp: result.timestamp, chars: result.chars, textHash: result.textHash } });
        record.result = result;
      }
      record.observedAt = new Date(now()).toISOString();
      return events;
    });
  }

  function view(record) {
    // Cursor helpers stay in one place: the route module parses what the
    // service issues.
    const lastSeq = sessionStore.headSeq(record.id);
    return {
      id: record.id,
      name: record.name,
      nameSource: record.nameSource ?? 'default',
      requestId: record.requestId,
      parentId: record.parentId ?? null,
      projectId: record.projectId ?? null,
      workspaceId: record.workspaceId,
      cwd: record.cwd,
      profile: record.profile,
      instructionVersion: record.instructionVersion ?? null,
      instructionHash: record.instructionHash ?? null,
      instructionsApplied: record.instructionsApplied === true,
      requested: record.requested,
      observed: record.observed ?? null,
      modelCheck: record.modelCheck ?? null,
      runtimeVerified: record.runtimeVerified === true,
      phase: record.phase,
      daemonStatus: record.daemonStatus ?? null,
      version: record.version,
      delegateSessionId: record.delegate?.sessionId ?? null,
      resumedFrom: record.resumedFrom ?? null,
      resumedTo: record.resumedTo ?? null,
      pending: record.pending ?? null,
      result: record.result ?? null,
      stopRequestedAt: record.stopRequestedAt ?? null,
      createdAt: record.createdAt,
      updatedAt: record.updatedAt,
      observedAt: record.observedAt ?? null,
      events: {
        lastSeq,
        oldestSeq: sessionStore.oldestSeq(record.id),
        cursor: encodeEventCursor({ sessionId: record.id, seq: lastSeq, now: now() }),
      },
    };
  }

  // The route module owns the HTTP shape; the cursor stays opaque and is
  // always issued by this service so its retention window matches the journal.
  function eventCursor(id, seq) {
    return encodeEventCursor({ sessionId: id, seq, now: now() });
  }

  return {
    createSession,
    listSessions,
    getSession,
    sendMessage,
    stopSession,
    resumeSession,
    readEventPage,
    listArtifacts,
    eventCursor,
    observe,
    view,
    sessionIdFor,
  };
}

// --- pure helpers ----------------------------------------------------------

// The owner's override wins: `instructions: null` or
// `applyProjectInstructions: false` starts the session without the project
// body. Any other inline text is refused rather than silently ignored, so the
// app cannot believe it edited the project when it only changed one run.
function parseApplyProjectInstructions(body) {
  if (body.instructions !== undefined && body.instructions !== null) {
    throw badRequest('payload_invalid', 'inline instructions are not accepted on create; PATCH the project or pass instructions: null to skip');
  }
  if (body.applyProjectInstructions !== undefined && typeof body.applyProjectInstructions !== 'boolean') {
    throw badRequest('payload_invalid', 'applyProjectInstructions must be a boolean');
  }
  return body.applyProjectInstructions !== false && body.instructions !== null;
}

// One clearly delimited block, version and hash on the header line, then the
// owner's own request. The body is the project's shared text verbatim; it was
// refused at write time (or is refused above) if it could close the delimiter.
function composePrompt(projectId, instructions, prompt) {
  const header = `<${INSTRUCTION_TAG} project="${projectId}" version="${instructions.version}" hash="${instructions.hash}">`;
  return `${header}\n${instructions.body}\n</${INSTRUCTION_TAG}>\n\n<user_request>\n${prompt}\n</user_request>`;
}

function parseRequestId(raw) {
  if (typeof raw !== 'string' || !REQUEST_ID_PATTERN.test(raw.trim())) {
    throw badRequest('payload_invalid', 'requestId must be 1-200 of A-Z a-z 0-9 . _ : -');
  }
  return raw.trim();
}

function parseProfile(raw) {
  if (typeof raw !== 'string' || !PROFILE_PATTERN.test(raw.trim())) {
    throw badRequest('payload_invalid', 'profile must be a configured profile name');
  }
  return raw.trim();
}

function parseWorkspaceId(raw) {
  if (typeof raw !== 'string' || !/^ws_[0-9a-f]{16}$/.test(raw)) {
    throw badRequest('payload_invalid', 'workspaceId must be an existing workspace id');
  }
  return raw;
}

function parseSessionId(raw) {
  if (typeof raw !== 'string' || !/^ses_[0-9a-f]{16}$/.test(raw)) {
    throw badRequest('payload_invalid', 'session id must look like ses_<16 hex>');
  }
  return raw;
}

function asText(raw, field, { max = MAX_TEXT_BYTES } = {}) {
  if (typeof raw !== 'string') throw badRequest('payload_invalid', `${field} is required`);
  const value = raw.trim();
  if (value === '') throw badRequest('payload_invalid', `${field} is required`);
  if (Buffer.byteLength(value) > max) throw badRequest('payload_too_large', `${field} exceeds ${max} bytes`);
  return value;
}

function parseLimit(raw) {
  if (raw === undefined || raw === null || raw === '') return 50;
  const limit = Number(raw);
  if (!Number.isInteger(limit) || limit < 1 || limit > 100) throw badRequest('limit_invalid', 'limit must be an integer between 1 and 100');
  return limit;
}

function parseOffset(raw) {
  if (raw === undefined || raw === null || raw === '') return 0;
  try {
    const parsed = JSON.parse(Buffer.from(raw, 'base64url').toString('utf8'));
    if (Number.isInteger(parsed?.offset) && parsed.offset >= 0) return parsed.offset;
  } catch {
    // fall through
  }
  throw badRequest('cursor_invalid', 'cursor is not recognised');
}

function encodeOffset(offset) {
  return Buffer.from(JSON.stringify({ offset }), 'utf8').toString('base64url');
}

function parseAfterSeq(raw) {
  if (raw === undefined || raw === null || raw === '') return 0;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < 0) throw badRequest('payload_invalid', 'afterSeq must be a non-negative integer');
  return value;
}

function parseEventLimit(raw) {
  if (raw === undefined || raw === null || raw === '') return 100;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < 1 || value > 200) throw badRequest('limit_invalid', 'limit must be an integer between 1 and 200');
  return value;
}

function parseWait(raw) {
  if (raw === undefined || raw === null || raw === '') return 0;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < 0 || value > 25) throw badRequest('payload_invalid', 'wait must be an integer between 0 and 25 seconds');
  return value;
}

function assertSameRequest(record, { profile, workspaceId, parentId, projectId, requestDigest }) {
  if (record.profile !== profile || record.workspaceId !== workspaceId
    || (record.parentId ?? null) !== parentId || (record.projectId ?? null) !== projectId
    || record.requestDigest !== requestDigest) {
    throw conflict('request_id_conflict', 'requestId was already used for a different session request');
  }
}

function normalizeRequested(requested, { profile }) {
  const value = requested && typeof requested === 'object' ? requested : {};
  return {
    profile: typeof value.profile === 'string' ? value.profile : profile,
    provider: typeof value.provider === 'string' ? value.provider : null,
    model: typeof value.model === 'string' ? value.model : null,
    effort: typeof value.effort === 'string' ? value.effort : null,
  };
}

function summarizePending(pending) {
  const list = Array.isArray(pending) ? pending : [];
  const ids = list.map((item) => item?.id).filter((id) => typeof id === 'string');
  const kinds = [...new Set(list.map((item) => item?.kind).filter((kind) => typeof kind === 'string'))].sort();
  return {
    hash: sha(JSON.stringify(list.map((item) => ({ id: item?.id ?? null, kind: item?.kind ?? null, name: item?.name ?? null })))),
    count: list.length,
    kinds,
    ids,
  };
}

function summarizeResult(result) {
  if (!result || typeof result.text !== 'string' || result.text === '') return null;
  const key = result.messageId ? `id:${result.messageId}` : `t:${result.timestamp ?? ''}|c:${count(result.text)}`;
  return {
    key,
    messageId: result.messageId ?? null,
    timestamp: result.timestamp ?? null,
    chars: count(result.text),
    textHash: sha(result.text),
  };
}

function mapPhase(status) {
  switch (status.phase) {
    case 'stopped': return 'stopped';
    case 'stop_unconfirmed': return 'stop_unconfirmed';
    case 'awaiting_decision': return 'awaiting_decision';
    case 'awaiting_review': return 'awaiting_review';
    case 'error': return 'error';
    case 'closed': return 'closed';
    default: return status.daemonStatus === 'idle' ? 'awaiting_review' : 'running';
  }
}

function artifact(id, name, type, text, updatedAt) {
  const bytes = Buffer.from(text, 'utf8');
  const truncated = bytes.length > MAX_ARTIFACT_BYTES;
  const content = truncated
    ? bytes.subarray(0, MAX_ARTIFACT_BYTES).toString('utf8').replace(/\uFFFD$/, '')
    : text;
  return {
    id,
    name,
    type,
    size: bytes.length,
    truncated,
    content,
    updatedAt: updatedAt ?? null,
  };
}


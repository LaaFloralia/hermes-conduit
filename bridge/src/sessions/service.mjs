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
// the project's inline body is composed into a delimited block ahead of the
// owner's prompt, and only its version and hash are recorded on the session and
// its events. A retry of the same requestId after the instructions changed is
// therefore a conflict, not a second run under a prompt the owner never saw.
//
// The session's display name is also the Paseo agent title, so the daemon shows
// "Project｜Session" instead of "Origin / owner: laa-bridge". The title is not
// part of the request identity: renaming a session must not look like a new
// request.

import { createHash } from 'node:crypto';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { sessionImageStore } from './images.mjs';
import { BridgeError, badRequest, conflict, notFound } from '../errors.mjs';
import { encodeEventCursor, parseEventCursor } from './cursor.mjs';
import { DELEGATION_ORIGIN } from './adapter.mjs';
import { readConversation } from './history.mjs';
import { settleLocalImages } from './local-images.mjs';
import { daemonSessionID, snapshot } from './daemon.mjs';
import { fastAvailable, fastValue } from './features.mjs';
import { notifyOwner } from '../notify/index.mjs';

// Kept exported from here for callers and tests that read a feature list
// without the service; the shapes themselves live in features.mjs.
export { fastValue } from './features.mjs';

export const CHILD_NAME_PREFIX = '子｜';
const REQUEST_ID_PATTERN = /^[A-Za-z0-9._:-]{1,200}$/;
const PROFILE_PATTERN = /^[a-z0-9][a-z0-9-]{0,63}$/;
const MAX_TEXT_BYTES = 16_384;
const MAX_NAME_LENGTH = 100;
const TITLE_MAX_BYTES = 200;
const MAX_ARTIFACT_BYTES = 64 * 1024;
const INSTRUCTION_TAG = 'project_instructions';
const FILES_TAG = 'project_files';
const DEFAULT_NAME_GRAPHEMES = 24;
// A session that starts in the owner's home folder instead of a repo or worktree.
export const HOME_WORKSPACE_ID = 'home';
const MODES = new Set(['bypass', 'default']);
// How long a new session is exempt from the "gone from Paseo" check: Paseo's
// directory can lag its own creation by a moment.
const DELETED_GRACE_MS = 2 * 60 * 1000;
const MAX_DELETED_CHECKS = 20;
// An unlisted agent that Paseo confirmed it still holds is not asked again
// for this long, so the same rows cannot take every sync's checks.
const PRESENT_RECHECK_MS = 10 * 60 * 1000;

const sha = (value) => createHash('sha256').update(value, 'utf8').digest('hex');
const count = (text) => [...text].length;

export function createSessionService({
  sessionStore,
  adapter,
  daemon = null,
  notify = notifyOwner,
  decisions = null,
  history = readConversation,
  images = sessionImageStore(join(dirname(sessionStore.file), "session-images")),
  findWorkspace,
  findProject = () => null,
  resolveProjectInstructions = () => null,
  resolveProjectFiles = () => [],
  homeCwd = homedir(),
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

  // The project's inline body, resolved once per create. A store error stops the
  // session instead of running it without the shared instructions.
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
    const workspaceId = body.workspaceId === undefined || body.workspaceId === null || body.workspaceId === HOME_WORKSPACE_ID
      ? HOME_WORKSPACE_ID
      : parseWorkspaceId(body.workspaceId);
    const mode = parseMode(body.mode);
    const fast = parseFast(body.fast);
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
    const files = project ? (resolveProjectFiles(project) ?? []) : [];

    // The request identity is bound to its content: the same requestId with a
    // different profile, workspace, parent, prompt or instruction version is a
    // conflict, not a silent reconcile. `legacyRequestDigest` is the same value
    // without the two instruction fields, which is what records created before
    // instructions were applied carry; an identical retry of one of those must
    // still reconcile instead of turning into a 409.
    const requestBody = {
      profile,
      workspaceId,
      parentId,
      projectId,
      prompt,
      purpose: body.purpose ?? null,
      completion: body.completion ?? null,
      scope: body.scope ?? null,
      returnTo: body.returnTo ?? null,
    };
    const requestDigest = sha(JSON.stringify({
      ...requestBody,
      instructionVersion: instructions?.version ?? null,
      instructionHash: instructions?.hash ?? null,
      mode,
      fast,
      files: files.map((file) => file.sha256).sort(),
    }));
    const legacyRequestDigest = sha(JSON.stringify(requestBody));

    const existing = sessionStore.get(id);
    if (existing) {
      assertSameRequest(existing, { profile, workspaceId, parentId, projectId, requestDigest, legacyRequestDigest });
      return { session: existing, created: false };
    }

    const workspace = workspaceId === HOME_WORKSPACE_ID ? { path: homeCwd } : await findWorkspace(workspaceId);
    if (!workspace) throw notFound('workspace not found under an allowlisted root');
    if (parentId && !sessionStore.get(parentId)) throw notFound('parent session not found');

    let name = body.name === undefined || body.name === null ? null : asText(body.name, 'name', { max: MAX_NAME_LENGTH });
    const nameSource = name === null ? 'default' : 'owner';
    if (name === null) name = defaultName(prompt) ?? `セッション ${id.slice(4, 10)}`;
    if (parentId && !name.startsWith(CHILD_NAME_PREFIX)) name = `${CHILD_NAME_PREFIX}${name}`;

    // The delegation wrapper requires the task fields; a plain chat session
    // gets neutral defaults, an explicit body can describe the job properly.
    const plainPrompt = [body.purpose, body.completion, body.scope, body.returnTo].every((field) => field === undefined || field === null);
    const task = {
      purpose: asText(body.purpose ?? 'LAA Bridge session', 'purpose', { max: 2000 }),
      completion: asText(body.completion ?? 'Answer the request and leave the result for the Bridge to collect.', 'completion', { max: 2000 }),
      scope: asText(body.scope ?? 'Only the assigned workspace and task; do not touch other conversations.', 'scope', { max: 2000 }),
      returnTo: asText(body.returnTo ?? 'The requesting Bridge device', 'returnTo', { max: 2000 }),
      prompt: instructions || files.length > 0 ? composePrompt(project.id, instructions, files, prompt) : prompt,
    };

    // The Paseo agent title: the project is what the owner recognises in the
    // daemon, and the session name already carries the child prefix. It is not
    // part of the request identity (see the header comment). The wrapper takes
    // at most 200 UTF-8 bytes and refuses an empty title, so the composed value
    // is normalised and bounded here instead of failing as a 503 downstream.
    const title = sessionTitle(project ? `${project.name}｜${name}` : name);
    const delegateRequestId = delegateIdFor(requestId);
    const created = await adapter.create({
      requestId: delegateRequestId,
      profile,
      cwd: workspace.path,
      task,
      title,
      ...(mode === 'bypass' ? { mode } : {}),
      ...(fast ? { fast } : {}),
      ...(plainPrompt ? { plainPrompt } : {}),
    });
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
      sentTitle: title,
      profile,
      mode,
      fast,
      favorite: false,
      archivedAt: null,
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

  // A missing directory row is not proof: Paseo's directory leaves out many
  // old archived agents it still holds (2026-11-09: 191 of 193 unlisted rows).
  // Only rows still shown are checked, since an archived row holds no number
  // and is already hidden; each is re-read, and only Paseo's own 404 marks it
  // gone. A daemon error is "unknown" and changes nothing. A session that just
  // started is exempt because the directory can lag it.
  const presentCheckedAt = new Map();
  async function markDeletedAgents(agents) {
    const listed = new Set(agents.map((agent) => agent.id));
    const cutoff = now() - DELETED_GRACE_MS;
    const candidates = sessionStore.all().filter((record) => {
      const agentId = record.delegate?.sessionId;
      if (typeof agentId !== 'string' || record.daemonDeletedAt) return false;
      if (record.archivedAt || record.daemonArchivedAt || listed.has(agentId)) return false;
      if (now() - (presentCheckedAt.get(agentId) ?? -Infinity) < PRESENT_RECHECK_MS) return false;
      const created = Date.parse(record.createdAt ?? '');
      return Number.isFinite(created) && created <= cutoff;
    }).slice(0, MAX_DELETED_CHECKS);
    for (const record of candidates) {
      let exists;
      try {
        exists = await daemon.exists(record.delegate.sessionId);
      } catch {
        continue;
      }
      if (exists) {
        presentCheckedAt.set(record.delegate.sessionId, now());
        continue;
      }
      const deletedAt = new Date(now()).toISOString();
      sessionStore.update(record.id, (current) => {
        if (current.daemonDeletedAt) return [];
        current.daemonDeletedAt = deletedAt;
        return [];
      });
    }
  }

  let syncInFlight;
  async function syncDaemon() {
    await decisions?.sync();
    if (!daemon) return;
    if (syncInFlight) return syncInFlight;
    syncInFlight = (async () => {
      const agents = await daemon.list();
      // Paseo's pin belongs to the workspace. A failed read leaves every
      // local choice as it is rather than reading as "all unpinned".
      const workspaces = await daemon.workspacePins().catch(() => null);
      const pins = workspaces && new Map(workspaces.map((row) => [row.id, row.pinnedAt != null]));
      const workspaceTitles = new Map((workspaces ?? []).map((row) => [row.id, row.title]));
      const parents = new Map();
      for (const a of agents) if (!a.labels?.['paseo.parent-agent-id']) parents.set(a.workspaceId, (parents.get(a.workspaceId) ?? 0) + 1);
      const known = new Map(sessionStore.all().map((r) => [r.delegate?.sessionId, r]));
      const ids = new Map(agents.map((a) => [a.id, known.get(a.id)?.id ?? daemonSessionID(a.id)]));
      const rows = agents.map((a) => {
        const state = snapshot(a, now());
        const previous = known.get(a.id);
        const model = { provider: a.provider, model: a.model ?? null, effort: a.thinkingOptionId ?? a.effectiveThinkingOptionId ?? null };
        const workspaceId = previous?.workspaceId ?? a.workspaceId ?? HOME_WORKSPACE_ID;
        // A failed workspace read must not fall back to the agent's long prompt:
        // keep the title a previous successful read confirmed.
        const workspaceTitle = workspaceTitles.get(a.workspaceId) ?? previous?.workspaceTitle ?? null;
        const rootAgents = parents.get(a.workspaceId) ?? 0;
        // Paseo titles the workspace from the request but leaves the agent with
        // the title it was given, so the one parent in a workspace shows Paseo's
        // unless the agent named itself after a title the Bridge sent.
        const renamed = previous?.sentTitle !== undefined && previous.sentTitle !== a.title;
        const paseoTitle = !renamed && rootAgents === 1 && !a.labels?.['paseo.parent-agent-id'] ? workspaceTitle : null;
        return { id: ids.get(a.id), requestId: `paseo-${a.id}`, source: previous ? (previous.source ?? 'bridge') : 'paseo',
          parentId: ids.get(a.labels?.['paseo.parent-agent-id']) ?? previous?.parentId ?? null,
          projectId: null, workspaceId, cwd: a.cwd,
          name: paseoTitle || a.title || '名称未設定', nameSource: 'agent', profile: previous?.profile ?? a.provider,
          // The detail read (applyObservation) uses the same two fields to reach
          // the same name, so a list row and its detail cannot disagree.
          workspaceTitle, workspaceRootCount: rootAgents,
          requested: model, observed: state.modelCheck.observed, phase: state.phase,
          pending: summarizePending(state.pending), runtimeVerified: state.modelCheck.runtimeVerified,
          observedFast: fastValue(state.features), fastAvailable: fastAvailable(state.features),
          daemonStatus: a.status, // A pin promotes a row; an unpinned workspace says nothing, so a
          // favourite the owner set here survives a Paseo that has no pin yet.
          favorite: pins?.get(workspaceId) === true ? true : undefined, archivedAt: null, daemonArchivedAt: a.archivedAt ?? null,
          version: previous?.version ?? 1, delegate: { sessionId: a.id },
          createdAt: a.createdAt, updatedAt: a.updatedAt, sourceUpdatedAt: a.updatedAt,
          observedAt: new Date(now()).toISOString(), attentionTimestamp: a.attentionTimestamp ?? a.updatedAt, attentionReason: a.attentionReason, requiresAttention: a.requiresAttention };
      });
      const transitions = sessionStore.importDirectory(rows);
      await markDeletedAgents(agents);
      for (const { previous, current } of transitions) {
        const phase = current.phase;
        const kind = phase === 'awaiting_decision' ? (current.pending.kinds.includes('question') ? 'question' : 'approval')
          : phase === 'error' ? 'error' : phase === 'awaiting_review' && (previous === 'running' || current.attentionReason === 'finished') ? 'finished' : null;
        if (kind && !current.archivedAt && !current.daemonArchivedAt && !(kind === 'finished' && decisions?.hasOpen(current))) {
          void notify({ kind: `session.${kind}`, title: current.name,
            body: { question: '質問への回答をお願いします。', approval: '操作の承認をお願いします。', error: '実行中にエラーが発生しました。', finished: 'エージェントの手番が終了しました。' }[kind],
            deepLink: `laa://work/sessions/${current.id}`, dedupeKey: `${current.id}:${kind}:${current.attentionTimestamp}:${current.pending?.hash ?? ''}` }).catch(() => {});
        }
      }
    })().finally(() => { syncInFlight = null; });
    return syncInFlight;
  }

  async function decision(id) {
    if (!daemon) throw new BridgeError(503, 'paseo_unavailable', 'Paseo decision support is unavailable');
    return daemon.decision(requireSession(id).delegate.sessionId);
  }
  async function reply({ id, body }) {
    if (!daemon) throw new BridgeError(503, 'paseo_unavailable', 'Paseo decision support is unavailable');
    await daemon.reply(requireSession(id).delegate.sessionId, body);
    await observe(id, { force: true });
    return { session: requireSession(id) };
  }

  // The default list's live set without syncDaemon or pagination: the refs
  // reconcile needs a local, complete read, and the visibility rule must stay
  // the same one `listSessions` applies to an unfiltered list.
  function visibleRecords() {
    return sessionStore.all().filter((record) =>
      (daemon !== null || !isWorktree(record))
      && !record.daemonDeletedAt && !record.archivedAt && !record.daemonArchivedAt);
  }

  async function listSessions(query = {}) {
    await syncDaemon();
    const limit = parseLimit(query.limit);
    const offset = parseOffset(query.cursor);
    const projectId = query.projectId ?? null;
    const workspaceId = query.workspaceId
      ? (query.workspaceId === HOME_WORKSPACE_ID ? HOME_WORKSPACE_ID : parseWorkspaceId(query.workspaceId))
      : null;
    const requestId = query.requestId ? parseRequestId(query.requestId) : null;
    const phase = query.phase ?? null;
    // The app's list hides archived sessions and the older worktree sessions;
    // a requestId lookup (reconcile after an unknown outcome) sees everything.
    const scopeAll = query.scope === 'all' || requestId !== null;
    const archivedOnly = query.archived === 'only';
    let parentId;
    if (query.parentId === 'root') parentId = null;
    else if (query.parentId !== undefined && query.parentId !== null && query.parentId !== '') parentId = parseSessionId(query.parentId);

    const filtered = sessionStore.all()
      .filter((record) => (projectId ? record.projectId === projectId : true))
      .filter((record) => (workspaceId ? record.workspaceId === workspaceId : true))
      .filter((record) => (requestId ? record.requestId === requestId : true))
      .filter((record) => (phase ? record.phase === phase : true))
      .filter((record) => (parentId === undefined ? true : (record.parentId ?? null) === parentId))
      .filter((record) => scopeAll || (!record.daemonDeletedAt && (daemon || !isWorktree(record))
        && Boolean(record.archivedAt || record.daemonArchivedAt) === archivedOnly))
      .sort((a, b) => (b.sourceUpdatedAt ?? b.updatedAt ?? '').localeCompare(a.sourceUpdatedAt ?? a.updatedAt ?? '') || a.id.localeCompare(b.id));

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

  async function conversation(id) {
    const record = requireSession(id);
    const messages = await history(record.delegate.sessionId);
    const references = images.references(id);
    // One batch for the whole page: a poll naming the same 215 pictures must
    // not open or rewrite the index 215 times.
    const paths = messages.flatMap((message) => (Array.isArray(message.localImages) ? message.localImages : []));
    const resolved = images.registerLocalBatch?.(id, paths) ?? [];
    let cursor = 0;
    return messages.map((message) => {
      const local = Array.isArray(message.localImages) ? message.localImages : [];
      const localIDs = local.map(() => resolved[cursor++] ?? null);
      const { localImages: _localImages, ...visible } = message;
      const text = settleLocalImages(visible.text, local, localIDs);
      const ids = [...new Set([...localIDs.filter(Boolean), ...(references[message.id] ?? [])])];
      return { ...visible, text, images: ids };
    });
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

    const attachments = parseImages(body.images);
    images.stage(id, messageId, attachments);
    try {
      if (daemon) await daemon.send(record.delegate.sessionId, { text, messageId, images: attachments });
      else await adapter.send({ requestId: record.delegate.requestId, messageId, text });
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

  // A session with everything started under it, parent first.
  function sessionTree(root) {
    const all = sessionStore.all();
    const tree = [root];
    for (const row of tree) tree.push(...all.filter((r) => r.parentId === row.id && !tree.includes(r)));
    return tree;
  }

  // Archive goes through Paseo, so both lists agree, and takes the session's
  // children with it; restoring brings back only the chosen row, because each
  // restored agent loads again in Paseo. Owner rename stays Bridge-side and
  // favourites mirror a Paseo workspace pin when one is available. None of
  // these actions stops a turn: the adapter refuses a tree with a turn running.
  async function updateSession({ id, body = {} }) {
    const existing = requireSession(id);
    const favorite = body.favorite === undefined ? undefined : parseBoolean(body.favorite, 'favorite');
    const archived = body.archived === undefined ? undefined : parseBoolean(body.archived, 'archived');
    const name = body.name === undefined ? undefined : asText(body.name, 'name', { max: MAX_NAME_LENGTH });
    const effort = body.effort === undefined ? undefined : parseEffort(body.effort);
    const fast = body.fast === undefined ? undefined : parseBoolean(body.fast, 'fast');
    if (favorite === undefined && archived === undefined && name === undefined && effort === undefined && fast === undefined) {
      throw badRequest('payload_invalid', 'favorite, archived, name, effort or fast is required');
    }
    if (effort !== undefined) {
      if (!daemon || typeof existing.delegate?.sessionId !== 'string') {
        throw new BridgeError(409, 'effort_unsupported', 'effort can only be changed for a Paseo session');
      }
      if (existing.stopRequestedAt || ['stopped', 'stop_unconfirmed'].includes(existing.phase)) {
        throw conflict('session_stopped', 'the session is stopped; change effort after it is running again');
      }
      // Do it before any local field so a refused provider change cannot leave
      // a half-applied PATCH. The read-back inside setThinking is the proof.
      const status = await daemon.setThinking(existing.delegate.sessionId, effort);
      applyObservation(id, status);
    }
    if (fast !== undefined) {
      if (!daemon || typeof existing.delegate?.sessionId !== 'string') {
        throw new BridgeError(409, 'fast_unsupported', 'Fast can only be changed for a Paseo session');
      }
      if (existing.stopRequestedAt || ['stopped', 'stop_unconfirmed'].includes(existing.phase)) {
        throw conflict('session_stopped', 'the session is stopped; change Fast after it is running again');
      }
      // The provider's own read-back inside setFast is the proof it applied.
      const status = await daemon.setFast(existing.delegate.sessionId, fast);
      applyObservation(id, status);
    }
    // A workspace's pin is where Paseo keeps the same choice. Sessions in the
    // home workspace, and a daemon that is not connected, keep the Bridge-only
    // behaviour they had.
    const mirror = favorite !== undefined && Boolean(existing.favorite) !== favorite
      && existing.workspaceId && existing.workspaceId !== HOME_WORKSPACE_ID ? favorite : null;
    const archiving = archived !== undefined && Boolean(existing.archivedAt || existing.daemonArchivedAt) !== archived;
    const tree = archiving && archived ? sessionTree(existing) : [existing];
    if (archiving && daemon) {
      if (archived) await daemon.archive(tree.map((row) => row.delegate?.sessionId).filter(Boolean));
      else if (existing.daemonArchivedAt) await daemon.unarchive(existing.delegate.sessionId);
    }
    const setArchived = (current) => {
      if (Boolean(current.archivedAt || current.daemonArchivedAt) === archived) return [];
      current.archivedAt = archived ? new Date(now()).toISOString() : null;
      if (!archived) current.daemonArchivedAt = null;
      return [{ type: 'session.archived', payload: { archived } }];
    };
    if (archiving) for (const row of tree.slice(1)) sessionStore.update(row.id, setArchived);
    const updated = sessionStore.update(id, (current) => {
      const events = [];
      if (favorite !== undefined && Boolean(current.favorite) !== favorite) {
        current.favorite = favorite;
        events.push({ type: 'session.favorite', payload: { favorite } });
      }
      if (archiving) events.push(...setArchived(current));
      if (name !== undefined && (current.name !== name || current.nameSource !== 'owner')) {
        current.name = name;
        current.nameSource = 'owner';
        events.push({ type: 'session.renamed', payload: { name, nameSource: 'owner' } });
      }
      return events;
    });
    if (mirror !== null && daemon) {
      try {
        await daemon.setWorkspacePinned(existing.workspaceId, mirror);
      } catch {
        // The list must not claim a pin Paseo refused: put the row back.
        sessionStore.update(id, (row) => {
          if (Boolean(row.favorite) !== mirror) return [];
          row.favorite = !mirror;
          return [{ type: 'session.favorite', payload: { favorite: !mirror } }];
        });
        throw new BridgeError(503, 'paseo_unavailable', 'Paseo could not record the pin', { retryable: true });
      }
    }
    return { session: updated?.record ?? requireSession(id) };
  }

  async function interruptSession(id) {
    const record = requireSession(id);
    if (!daemon) throw new BridgeError(503, 'paseo_unavailable', 'Paseo interruption is unavailable');
    const result = await daemon.stop(record.delegate.sessionId);
    const updated = sessionStore.update(id, (current) => {
      current.daemonStatus = result.daemonStatus;
      current.phase = 'awaiting_review';
      return [{ type: 'session.interrupted', payload: { daemonStatus: result.daemonStatus } }];
    });
    observations.delete(id);
    return { session: updated.record };
  }

  async function stopSession(id) {
    const record = requireSession(id);
    let result;
    try {
      result = record.source === 'paseo' && daemon ? await daemon.stop(record.delegate.sessionId) : await adapter.stop({ requestId: record.delegate.requestId });
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
        mode: MODES.has(original.mode) ? original.mode : 'default',
        fast: original.fast === true,
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
      status = daemon ? await daemon.status(record.delegate.sessionId) : await adapter.status({ requestId: record.delegate.requestId });
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
    const stored = sessionStore.get(id);
    const phase = stored?.stopRequestedAt ? stored.phase : mapPhase(status);
    sessionStore.update(id, (record) => {
      const events = [];
      if (status.modelCheck) record.modelCheck = status.modelCheck;
      if (status.modelCheck?.observed) {
        record.observed = status.modelCheck.observed;
        record.runtimeVerified = status.modelCheck.runtimeVerified === true;
      }
      if (status.daemonStatus) record.daemonStatus = status.daemonStatus;
      // A successful observation that does not report the provider toggle
      // clears the remembered value: "unknown now" must not stay "was on".
      // Sources that never report features (no key) and failed observations
      // leave it alone.
      if (Object.hasOwn(status, 'features')) {
        record.observedFast = fastValue(status.features);
        // A read without a feature list (null) keeps the last confirmed answer.
        if (Array.isArray(status.features)) record.fastAvailable = fastAvailable(status.features);
      }
      // The list row and the detail header must show one name. Paseo names the
      // workspace from the request, so the single root agent in a workspace
      // takes that title; an agent that renamed itself (HQ PASEO-HERMES.md) or
      // the owner's own name wins. syncDaemon applies the same rule.
      const title = typeof status.title === 'string' ? status.title.trim() : '';
      const freshWorkspaceTitle = typeof status.workspaceTitle === 'string' ? status.workspaceTitle.trim() : '';
      // A workspace lookup that failed says nothing about the name. Keep the
      // last confirmed title instead of reverting to the agent's long prompt;
      // only a successful, non-empty read replaces it.
      if (freshWorkspaceTitle !== '') record.workspaceTitle = freshWorkspaceTitle;
      const workspaceTitle = freshWorkspaceTitle || record.workspaceTitle || '';
      const renamed = record.sentTitle !== undefined && record.sentTitle !== title;
      const useWorkspaceTitle = record.nameSource !== 'owner'
        && record.parentId == null
        && record.workspaceRootCount === 1
        && workspaceTitle !== ''
        && !renamed;
      const nextName = useWorkspaceTitle ? workspaceTitle : title;
      if (nextName !== '' && nextName !== record.name && record.nameSource !== 'owner') {
        record.name = nextName.length > MAX_NAME_LENGTH ? [...nextName].slice(0, MAX_NAME_LENGTH).join('') : nextName;
        record.nameSource = 'agent';
        events.push({ type: 'session.renamed', payload: { name: record.name, nameSource: 'agent' } });
      }
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
      if (status.updatedAt) record.sourceUpdatedAt = status.updatedAt;
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
      mode: MODES.has(record.mode) ? record.mode : 'default',
      fast: record.fast === true,
      favorite: record.favorite === true,
      archivedAt: record.archivedAt ?? record.daemonArchivedAt ?? null,
      worktree: isWorktree(record),
      instructionVersion: record.instructionVersion ?? null,
      instructionHash: record.instructionHash ?? null,
      instructionsApplied: record.instructionsApplied === true,
      requested: record.requested,
      observed: record.observed ?? null,
      modelCheck: record.modelCheck ?? null,
      runtimeVerified: record.runtimeVerified === true,
      // Only the provider's own toggle value is exposed; the Bridge's request
      // (`fast`) is not proof that Fast is on now.
      observedFast: typeof record.observedFast === 'boolean' ? record.observedFast : null,
      // Offered only when the daemon advertises the operation and this session
      // runs through the daemon (the delegation adapter cannot change effort).
      capabilities: {
        effort: daemon !== null && typeof record.delegate?.sessionId === 'string'
          && daemon.capabilities?.().effortUpdate === true,
        // The provider must have said it has a Fast setting; a session without
        // one is offered no switch rather than a 409 on tap.
        fast: daemon !== null && typeof record.delegate?.sessionId === 'string' && record.fastAvailable === true,
      },
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
      updatedAt: record.sourceUpdatedAt ?? record.updatedAt,
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
    syncDaemon,
    decision,
    reply,
    listSessions,
    visibleRecords,
    getSession,
    conversation,
    image: (id, imageID) => { requireSession(id); return images.read(id, imageID); },
    sendMessage,
    updateSession,
    stopSession,
    interruptSession,
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

// laa-personal-agent rejects a title longer than 200 UTF-8 bytes or one that is
// empty after its own normalisation (`title_invalid`), and the Bridge has no
// mapping for that code, so a long project name would surface as a 503. Apply
// the same normalisation (control, format and whitespace runs become one space)
// and cut on *grapheme* boundaries: cutting per code point would leave a lone
// combining mark ("か" + U+3099 losing its dakuten) or half of a ZWJ emoji.
const TITLE_SEGMENTER = new Intl.Segmenter('ja', { granularity: 'grapheme' });

export function sessionTitle(raw) {
  // A ZWJ (U+200D) is a format character but it *joins* one grapheme; replacing
  // it with a space would split an emoji before the cut. Every other control,
  // format and whitespace run becomes one space.
  const oneLine = raw
    .replace(/[\p{Cc}\s]+/gu, ' ')
    .replace(/\p{Cf}/gu, (character) => (character === '\u200D' ? character : ' '))
    .replace(/\s+/gu, ' ')
    .trim();
  if (oneLine === '') throw badRequest('payload_invalid', 'the session title is empty after removing control characters');
  let title = '';
  for (const { segment } of TITLE_SEGMENTER.segment(oneLine)) {
    if (Buffer.byteLength(title + segment, 'utf8') > TITLE_MAX_BYTES) break;
    title += segment;
  }
  // A single grapheme can be larger than the whole budget (a base character
  // with many combining marks). Truncating to nothing would hand the wrapper an
  // empty title, which it rejects as `title_invalid` and the Bridge cannot map,
  // so refuse the request here with a 400 instead of a 503.
  if (title === '') throw badRequest('payload_invalid', `the session title does not fit in ${TITLE_MAX_BYTES} bytes`);
  return title;
}

// One clearly delimited block, version and hash on the header line, then the
// owner's own request. The body is the project's shared text verbatim; it was
// refused at write time (or is refused above) if it could close the delimiter.
function composePrompt(projectId, instructions, files, prompt) {
  const blocks = [];
  if (instructions) {
    const header = `<${INSTRUCTION_TAG} project="${projectId}" version="${instructions.version}" hash="${instructions.hash}">`;
    blocks.push(`${header}\n${instructions.body}\n</${INSTRUCTION_TAG}>`);
  }
  if (files.length > 0) {
    // Paths only: the agent reads what it needs, so large files never inflate the prompt.
    const lines = files.map((file) => `- ${file.name}: ${file.path}`).join('\n');
    blocks.push(`<${FILES_TAG} project="${projectId}">\nProject reference files. Read them as needed.\n${lines}\n</${FILES_TAG}>`);
  }
  blocks.push(`<user_request>\n${prompt}\n</user_request>`);
  return blocks.join('\n\n');
}

// The prompt's first line, short enough for a list row, until the agent renames
// the session after its first answer.
export function defaultName(prompt) {
  const line = prompt.split('\n').map((item) => item.replace(/[\p{Cc}\p{Cf}\s]+/gu, ' ').trim()).find((item) => item !== '');
  if (!line) return null;
  const graphemes = [...TITLE_SEGMENTER.segment(line)].map((item) => item.segment);
  return graphemes.length > DEFAULT_NAME_GRAPHEMES ? `${graphemes.slice(0, DEFAULT_NAME_GRAPHEMES).join('')}…` : line;
}

export function isWorktree(record) {
  return typeof record.cwd === 'string' && record.cwd.includes('/.paseo/worktrees/');
}

function parseMode(raw) {
  // Bypass is always an explicit request (the app sends it as its default).
  if (raw === undefined || raw === null) return 'default';
  if (!MODES.has(raw)) throw badRequest('payload_invalid', 'mode must be "bypass" or "default"');
  return raw;
}

function parseFast(raw) {
  if (raw === undefined || raw === null) return false;
  return parseBoolean(raw, 'fast');
}

function parseBoolean(raw, field) {
  if (typeof raw !== 'boolean') throw badRequest('payload_invalid', `${field} must be a boolean`);
  return raw;
}

// A Paseo thinking option id (`low`…`max`). The daemon validates it against the
// provider; this only keeps an arbitrary string out of the daemon request.
function parseEffort(raw) {
  if (typeof raw !== 'string' || !/^[a-z0-9][a-z0-9-]{0,31}$/.test(raw)) {
    throw badRequest('payload_invalid', 'effort must be a thinking option id');
  }
  return raw;
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

function assertSameRequest(record, { profile, workspaceId, parentId, projectId, requestDigest, legacyRequestDigest }) {
  if (record.profile !== profile || record.workspaceId !== workspaceId
    || (record.parentId ?? null) !== parentId || (record.projectId ?? null) !== projectId
    || (record.requestDigest !== requestDigest && record.requestDigest !== legacyRequestDigest)) {
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


function parseImages(images) {
  if (images === undefined) return undefined;
  if (!Array.isArray(images) || images.length > 4) throw badRequest('payload_invalid', 'at most four images are supported');
  let bytes = 0;
  return images.map((image) => {
    if (!['image/jpeg', 'image/png', 'image/webp', 'image/gif'].includes(image?.mimeType)
      || typeof image.data !== 'string' || !/^[A-Za-z0-9+/]+={0,2}$/.test(image.data)) throw badRequest('payload_invalid', 'invalid image');
    bytes += Buffer.byteLength(image.data, 'base64');
    if (bytes > 4 * 1024 * 1024) throw badRequest('payload_too_large', 'images must fit in four MiB');
    return { data: image.data, mimeType: image.mimeType };
  });
}

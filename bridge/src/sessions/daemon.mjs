// Paseo is the execution and conversation authority, including sessions created
// outside the Bridge. No configuration, credentials or conversation bodies are
// needed to enumerate it. Mutations are reached only from authenticated routes.
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { resolveWorkClient, resolveWorkHome } from '../config.mjs';
import { BridgeError, badRequest, conflict } from '../errors.mjs';
import { fastTarget, fastValue } from './features.mjs';

export async function connectDaemon() {
  const { connectToDaemon } = await import(pathToFileURL(resolveWorkClient()).href);
  return connectToDaemon({ target: { kind: 'instance', home: resolveWorkHome() }, timeout: 15_000 });
}
export const pendingHash = (pending) => createHash('sha256').update(JSON.stringify(pending)).digest('hex');
export const daemonSessionID = (id) => `ses_${createHash('sha256').update(`paseo|${id}`).digest('hex').slice(0, 16)}`;
const PARENT_LABEL = 'paseo.parent-agent-id';
// A workspace is tidied only once its last conversation has been archived for
// this long, so a quick unarchive-and-continue does not lose it.
const TIDY_IDLE_MS = 10 * 60 * 1000;
const isBusy = (a) => Boolean(a.activeTurn || a.pendingPermissions?.length) || !['idle', 'closed', 'error'].includes(a.status);

export function daemonAdapter({ connect = connectDaemon, now = () => Date.now(), idleCloseMs = 30_000 } = {}) {
  const decisions = new Map();
  const effortCache = new Map();
  const effortLoads = new Map();
  // What the running daemon advertises. A hard-coded capability would offer an
  // operation this daemon cannot perform.
  let serverFeatures = {};
  // Whether the connected client can change a running agent's model.
  let modelUpdate = false;
  // Paseo titles the workspace, not the agent; the detail read needs the same
  // title its list row uses (see syncDaemon and applyObservation).
  let workspaceCache = { at: -Infinity, titles: new Map() };
  // The daemon handshake costs about as much as the RPC it carries (one
  // /v1/sessions sync makes two calls), so one connection serves the calls of
  // this process until it fails or sits idle. A connection that is not
  // confirmed alive is never handed to a request: Paseo's client does not
  // reconnect on its own.
  let pooled = null;
  let connecting = null;
  let idleTimer = null;
  let inflight = 0;
  const alive = (client) => Boolean(client) && client.isConnected !== false;
  function dropConnection() {
    clearTimeout(idleTimer);
    idleTimer = null;
    const client = pooled;
    pooled = null;
    if (client && typeof client.close === 'function') void Promise.resolve(client.close()).catch(() => {});
  }
  function keepConnection() {
    clearTimeout(idleTimer);
    idleTimer = setTimeout(() => {
      // A call may still be using it; ask again after that one is done.
      if (inflight > 0) keepConnection();
      else dropConnection();
    }, idleCloseMs);
    idleTimer.unref?.();
  }
  function acquire() {
    if (alive(pooled)) return Promise.resolve(pooled);
    if (pooled) dropConnection();
    if (connecting) return connecting;
    connecting = (async () => {
      const client = await connect();
      pooled = client;
      return client;
    })().finally(() => { connecting = null; });
    return connecting;
  }
  async function call(fn) {
    let client;
    inflight += 1;
    try {
      client = await acquire();
      try {
        const features = client.getLastServerInfoMessage?.()?.features;
        if (features && typeof features === 'object') serverFeatures = features;
        modelUpdate = typeof client.setAgentModel === 'function';
      } catch {}
      return await fn(client);
    }
    catch (error) {
      // A transport failure leaves the connection suspect; our own refusals
      // (404, 409) do not.
      if (!(error instanceof BridgeError)) dropConnection();
      if (error instanceof BridgeError) throw error;
      throw new BridgeError(503, 'paseo_unavailable', 'Paseo could not confirm the operation', { retryable: true });
    }
    finally {
      inflight -= 1;
      if (inflight === 0 && pooled) keepConnection();
    }
  }
  async function agent(client, id) {
    const a = (await client.fetchAgent({ agentId: id }))?.agent;
    if (!a || a.id !== id) throw new BridgeError(404, 'not_found', 'Paseo agent not found');
    return a;
  }
  async function directory(c) {
    const items = [], seen = new Set();
    let cursor;
    do {
      const page = await c.fetchAgents({ filter: { includeArchived: true }, page: { limit: 200, ...(cursor ? { cursor } : {}) } });
      if (!Array.isArray(page.entries)) throw new Error('invalid directory');
      items.push(...page.entries.map((e) => e.agent));
      cursor = page.pageInfo?.nextCursor;
      if (cursor && seen.has(cursor)) throw new Error('repeated directory cursor');
      if (cursor) seen.add(cursor);
    } while (cursor);
    return items;
  }
  async function activeWorkspaces(c) {
    const page = await c.fetchWorkspaces({ page: { limit: 200 } });
    if (!Array.isArray(page?.entries)) throw new Error('invalid workspace directory');
    return page.entries;
  }
  async function workspaceTitles(c) {
    if (now() - workspaceCache.at < 30_000) return workspaceCache.titles;
    const rows = await activeWorkspaces(c);
    workspaceCache = {
      at: now(),
      titles: new Map(rows
        .map((entry) => [entry?.id ?? entry?.workspace?.id, entry?.title ?? entry?.workspace?.title ?? null])
        .filter(([id]) => typeof id === 'string')),
    };
    return workspaceCache.titles;
  }
  async function assertChildrenIdle(c, ids) {
    const agents = await directory(c);
    const tree = new Set(ids);
    for (let pass = 0, size = -1; size !== tree.size && pass < agents.length; pass += 1) {
      size = tree.size;
      for (const row of agents) if (tree.has(row.labels?.[PARENT_LABEL])) tree.add(row.id);
    }
    if (agents.some((row) => !ids.includes(row.id) && tree.has(row.id) && !row.archivedAt && isBusy(row))) {
      throw conflict('model_switch_children_busy', 'wait for the child sessions and their decisions to finish');
    }
  }
  async function statusOf(client, a) {
    const title = await workspaceTitles(client)
      .then((titles) => titles.get(a.workspaceId) ?? null)
      .catch(() => null);
    return { ...snapshot(a, now()), workspaceTitle: title };
  }
  return {
    /// The daemon's own feature flags, so the Bridge can tell "not supported"
    /// from "failed" instead of offering an operation that cannot work.
    // Paseo has changed a running agent's model since before thinking updates,
    // so any connected daemon can; a client without the call cannot.
    capabilities: () => ({ effortUpdate: serverFeatures.agentThinkingUpdate === true, modelUpdate: modelUpdate === true }),
    /// The thinking options Paseo lists for each model of a provider, as
    /// [{ model, efforts }]: what a running session's effort menu can offer.
    /// The HQ table names the profiles a new session may start with, which is
    /// fewer (Fable and Mythos at High only).
    efforts: (provider) => {
      const cached = effortCache.get(provider);
      if (cached && now() - cached.at < 60_000) return Promise.resolve(cached.rows);
      let load = effortLoads.get(provider);
      if (!load) {
        load = call(async (c) => {
          if (typeof c.listProviderModels !== 'function') return [];
          const listed = await c.listProviderModels(provider);
          return (Array.isArray(listed?.models) ? listed.models : [])
            .map((m) => ({ model: m?.id, efforts: (Array.isArray(m?.thinkingOptions) ? m.thinkingOptions : [])
              .map((o) => o?.id).filter((id) => typeof id === 'string' && id !== '') }))
            .filter((row) => typeof row.model === 'string' && row.efforts.length > 0);
        }).then((rows) => {
          effortCache.set(provider, { at: now(), rows });
          return rows;
        }).catch(() => {
          // Keep the last successful answer and back off failed discovery.
          const rows = cached?.rows ?? [];
          effortCache.set(provider, { at: now(), rows });
          return rows;
        }).finally(() => effortLoads.delete(provider));
        effortLoads.set(provider, load);
      }
      // A refresh must not hold up a menu that already has usable choices.
      return cached ? Promise.resolve(cached.rows) : load;
    },
    list: () => call(directory),
    /// Whether Paseo still holds this agent. Only Paseo's own 404 is "gone";
    /// every other failure is "unknown" and must leave the record alone.
    exists: (id) => call(async (c) => {
      try {
        await agent(c, id);
        return true;
      } catch (error) {
        if (error instanceof BridgeError && error.status === 404) return false;
        throw error;
      }
    }),
    /// Paseo's own pins, so a workspace pinned in Paseo reads as a favourite
    /// here. Nothing is invented when the read fails: the caller sees null.
    workspacePins: () => call(async (c) => {
      return (await activeWorkspaces(c)).map((entry) => ({
        id: entry?.id ?? entry?.workspace?.id,
        pinnedAt: entry?.pinnedAt ?? entry?.workspace?.pinnedAt ?? null,
        title: entry?.title ?? entry?.workspace?.title ?? null,
      })).filter((row) => typeof row.id === 'string');
    }),
    /// A favourite the owner set in LAA is the workspace's pin in Paseo.
    setWorkspacePinned: (workspaceId, pinned) => call(async (c) => {
      const result = await c.setWorkspacePinned(workspaceId, pinned);
      return { pinnedAt: result?.pinnedAt ?? null };
    }),
    /// Archive these agents in Paseo. Paseo interrupts a running turn and
    /// closes labelled children with their parent, so a tree with anything at
    /// work is refused whole. A workspace left empty goes too, or Paseo's
    /// sidebar keeps it; a worktree stays because archiving one deletes files.
    /// A pinned workspace is unpinned first: an archived workspace keeps its
    /// pin otherwise, and Paseo still lists it at the top.
    archive: (ids) => call(async (c) => {
      const agents = await directory(c);
      const tree = new Set(ids.filter((id) => agents.some((a) => a.id === id)));
      for (let grew = true; grew;) {
        grew = false;
        for (const a of agents) {
          if (tree.has(a.id) || !tree.has(a.labels?.[PARENT_LABEL])) continue;
          tree.add(a.id);
          grew = true;
        }
      }
      const rows = agents.filter((a) => tree.has(a.id));
      if (rows.some((a) => !a.archivedAt && isBusy(a))) throw conflict('session_running', 'a session in this tree is still running');
      for (const a of rows) {
        if (!a.archivedAt && !(await agent(c, a.id)).archivedAt) await c.archiveAgent(a.id);
      }
      const remaining = await directory(c);
      const emptied = new Set(rows.map((a) => a.workspaceId).filter((id) => id && !remaining.some((a) => a.workspaceId === id && !a.archivedAt)));
      for (const entry of await activeWorkspaces(c)) {
        if (!emptied.has(entry.id) || entry.workspaceKind === 'worktree') continue;
        // The pin goes first, and a failure there leaves the workspace visible
        // rather than archived while still pinned.
        if (entry.pinnedAt != null) await c.setWorkspacePinned(entry.id, false);
        const result = await c.archiveWorkspace(entry.id);
        if (result?.error) throw new Error(result.error);
      }
    }),
    /// Archive workspaces no conversation is left in. Paseo archives the
    /// agents but keeps their workspaces, so the two counts drift apart.
    /// Only a workspace whose every agent is archived, ten minutes after the
    /// newest of them was created or archived, is touched; one with no agent
    /// at all is left alone because the owner may have just made it.
    tidyWorkspaces: ({ now: at = now(), dryRun = false } = {}) => call(async (c) => {
      const workspaces = await activeWorkspaces(c);
      const agents = await directory(c);
      const archived = [], failed = [];
      for (const entry of workspaces) {
        const id = entry?.id ?? entry?.workspace?.id;
        if (typeof id !== 'string' || entry.workspaceKind === 'worktree') continue;
        const own = agents.filter((a) => a.workspaceId === id);
        if (!own.length || own.some((a) => !a.archivedAt)) continue;
        const newest = Math.max(...own.map((a) => Math.max(Date.parse(a.createdAt ?? ''), Date.parse(a.archivedAt ?? ''))));
        if (!Number.isFinite(newest) || at - newest < TIDY_IDLE_MS) continue;
        if (dryRun) { archived.push(id); continue; }
        try {
          if (entry.pinnedAt != null) await c.setWorkspacePinned(id, false);
          const result = await c.archiveWorkspace(id);
          if (result?.error) throw new Error(result.error);
          archived.push(id);
        } catch {
          // One workspace that will not archive must not stop the rest; the
          // caller gets the ids so a failure stays visible.
          failed.push(id);
        }
      }
      return { archived, skipped: workspaces.length - archived.length, ...(dryRun ? { dryRun } : {}), ...(failed.length ? { failed } : {}) };
    }),
    /// Bring one agent back, with its workspace if that was archived. Paseo
    /// has no bare unarchive: refresh unarchives and loads it without a turn.
    unarchive: (id) => call(async (c) => {
      const a = await agent(c, id);
      if (!a.archivedAt) return;
      const active = await activeWorkspaces(c);
      if (a.workspaceId && !active.some((entry) => entry.id === a.workspaceId)) await c.restoreWorkspace(a.workspaceId);
      await c.refreshAgent(id);
    }),
    status: (id) => call(async (c) => statusOf(c, await agent(c, id))),
    continuationSource: (id, { requireWorkspace = true, relatedIds = [] } = {}) => call(async (c) => {
      const source = await agent(c, id);
      if (requireWorkspace && (!source.workspaceId || !source.cwd)) throw conflict('model_switch_workspace', 'the original workspace is unavailable');
      if (source.archivedAt) throw conflict('session_stopped', 'restore the session before switching provider');
      if (source.pendingPermissions?.length) throw conflict('model_switch_pending', 'answer the pending decision before switching provider');
      if (isBusy(source)) throw conflict('model_switch_busy', 'wait for the current turn to finish');
      await assertChildrenIdle(c, [id, ...relatedIds]);
      return { id, workspaceId: source.workspaceId, cwd: source.cwd, title: source.title,
        parentAgentId: source.labels?.[PARENT_LABEL] ?? null, relatedIds };
    }),
    startContinuation: ({ source, id, target, prompt }) => call(async (c) => {
      const before = await agent(c, source.id);
      if (isBusy(before) || before.archivedAt || before.workspaceId !== source.workspaceId
        || (before.labels?.[PARENT_LABEL] ?? null) !== source.parentAgentId) {
        throw conflict('model_switch_busy', 'the source changed while preparing the switch');
      }
      await assertChildrenIdle(c, [source.id, ...(source.relatedIds ?? [])]);
      const modeId = target.provider === 'claude' ? 'bypassPermissions'
        : target.provider === 'codex' ? 'full-access' : target.provider === 'hermes-claude-api' ? 'dont_ask' : null;
      const featureValues = target.provider === 'claude' ? { fast_mode: false }
        : target.provider === 'codex' ? { service_tier: 'default' } : { auto_accept: true };
      const created = await c.createAgent({ agentId: id, provider: target.provider, model: target.model,
        thinkingOptionId: target.effort, cwd: source.cwd, workspaceId: source.workspaceId,
        ...(source.parentAgentId ? { callerAgentId: source.parentAgentId } : {}),
        ...(modeId ? { modeId } : {}), featureValues, title: source.title,
        initialPrompt: prompt, idempotencyKey: `bridge-model-${id}`,
        labels: { ...(source.parentAgentId ? { [PARENT_LABEL]: source.parentAgentId } : {}),
          'laa.bridge.model-continuation': source.id } });
      const after = await agent(c, created.id ?? id);
      if (after.id !== id || after.workspaceId !== source.workspaceId || after.cwd !== source.cwd
        || (after.labels?.[PARENT_LABEL] ?? null) !== source.parentAgentId) {
        throw conflict('model_switch_failed', 'the continuation did not retain the workspace and parent');
      }
      return statusOf(c, after);
    }),
    // Switching an execution agent never archives its idle children or workspace.
    archiveDelegate: (id, { missingOK = false } = {}) => call(async (c) => {
      let row;
      try { row = await agent(c, id); } catch (error) { if (missingOK && error.status === 404) return; throw error; }
      if (row.archivedAt) return;
      if (isBusy(row)) throw conflict('model_switch_pending', 'the continuation has not finished settling');
      await c.archiveAgent(id);
      if (!(await agent(c, id)).archivedAt) throw conflict('model_switch_failed', 'the agent archive could not be verified');
    }),
    restoreDelegate: (id) => call(async (c) => {
      const row = await agent(c, id);
      if (!row.archivedAt) return;
      await c.refreshAgent(id);
      if ((await agent(c, id)).archivedAt) throw conflict('model_switch_failed', 'the source could not be restored');
    }),
    /// Change the reasoning effort of a running session. The daemon applies the
    /// provider's thinking option; the read-back is the only proof it did.
    setThinking: (id, effort) => call(async (c) => {
      if (c.getLastServerInfoMessage?.()?.features?.agentThinkingUpdate !== true) {
        throw new BridgeError(409, 'effort_unsupported', 'this Paseo daemon cannot change effort');
      }
      await agent(c, id);
      try {
        await c.setAgentThinkingOption(id, effort);
      } catch (error) {
        if (error instanceof BridgeError) throw error;
        throw new BridgeError(409, 'effort_rejected', 'Paseo rejected the effort change');
      }
      const after = await agent(c, id);
      const applied = after.effectiveThinkingOptionId ?? after.thinkingOptionId ?? null;
      if (applied !== effort) throw new BridgeError(409, 'effort_not_applied', 'Paseo did not apply the effort');
      return statusOf(c, after);
    }),
    /// Change the model of a running session, within its provider. The read-back
    /// of the runtime model is the only proof it applied.
    setModel: (id, model) => call(async (c) => {
      if (typeof c.setAgentModel !== 'function') {
        throw new BridgeError(409, 'model_unsupported', 'this Paseo client cannot change the model');
      }
      await agent(c, id);
      try {
        await c.setAgentModel(id, model);
      } catch (error) {
        if (error instanceof BridgeError) throw error;
        throw new BridgeError(409, 'model_rejected', 'Paseo rejected the model change');
      }
      const after = await agent(c, id);
      const applied = runningModel(after);
      if (applied !== model) throw new BridgeError(409, 'model_not_applied', 'Paseo did not apply the model');
      return statusOf(c, after);
    }),
    /// Change Fast on a running session. Claude has a boolean toggle and Codex a
    /// speed select; the provider's own read-back is the only proof it applied.
    setFast: (id, value) => call(async (c) => {
      const before = await agent(c, id);
      const target = fastTarget(before.features);
      if (!target) throw new BridgeError(409, 'fast_unsupported', 'this provider has no Fast setting');
      const next = target.featureId === 'service_tier' ? (value ? target.fastId : 'default') : value;
      try {
        await c.setAgentFeature(id, target.featureId, next);
      } catch (error) {
        if (error instanceof BridgeError) throw error;
        throw new BridgeError(409, 'fast_rejected', 'Paseo rejected the Fast change');
      }
      const after = await agent(c, id);
      if (fastValue(after.features) !== value) throw new BridgeError(409, 'fast_not_applied', 'Paseo did not apply the Fast change');
      return statusOf(c, after);
    }),
    send: (id, { text, messageId, images }) => call(async (c) => {
      const a = await agent(c, id);
      if (a.pendingPermissions?.length) throw conflict('pending_decision_requires_reply', 'answer the pending decision first');
      // One foreground turn per agent. A prompt handed to a working agent makes
      // the provider replace that turn — and an agent without autonomous
      // steering refuses the start instead, which loses the owner's message and
      // stops the turn (2026-11-09). The caller holds the message until idle.
      if (isBusy(a)) throw conflict('session_busy', 'the session is still working; the message waits for the turn to end');
      try {
        // Explicit steering preserves the currently running turn. The daemon
        // owns exactly-once message acceptance for this stable client message id.
        await c.sendMessage(id, text, { messageId, activeTurnBehavior: 'steer', images });
      } catch (error) {
        if (error instanceof BridgeError) throw error;
        if (/already active|is busy|is running/i.test(String(error?.message ?? error))) {
          throw conflict('session_busy', 'the session started working before the message was accepted');
        }
        throw error;
      }
    }),
    stop: (id) => call(async (c) => {
      await agent(c, id);
      await c.cancelAgent(id);
      const a = await agent(c, id);
      if (a.activeTurn || !['idle', 'closed', 'error'].includes(a.status)) throw conflict('stop_unconfirmed', 'Paseo has not finished stopping');
      return { daemonStatus: a.status };
    }),
    decision: (id) => call(async (c) => {
      const pending = (await agent(c, id)).pendingPermissions ?? [];
      const ticket = { requestHash: pendingHash(pending), expiresAt: now() + 300_000 };
      decisions.set(id, ticket);
      return { requests: pending.map(decisionView), ...ticket };
    }),
    reply: (id, body) => call(async (c) => {
      const ticket = decisions.get(id);
      if (!ticket || ticket.requestHash !== body.requestHash || ticket.expiresAt !== body.expiresAt) throw conflict('stale_decision', 'refresh the decision');
      if (!Number.isFinite(body.expiresAt) || body.expiresAt < now() || body.expiresAt > now() + 300_000) throw conflict('stale_decision', 'refresh the decision');
      const pending = (await agent(c, id)).pendingPermissions ?? [];
      if (pendingHash(pending) !== body.requestHash) throw conflict('pending_request_changed', 'the pending decision changed');
      const request = pending.find((p) => p.id === body.requestId);
      if (!request) throw conflict('pending_request_changed', 'the pending decision changed');
      let response;
      if (body.decision === 'deny') response = { behavior: 'deny', message: 'Declined by the owner in the LAA app.', interrupt: false };
      else if (body.decision === 'allow' && request.kind === 'tool') response = { behavior: 'allow' };
      else if (body.decision === 'answer' && request.kind === 'question') {
        const questions = request.input?.questions;
        if (!['request_user_input_async', 'AskUserQuestion'].includes(request.name) || !Array.isArray(questions) || !questions.length) throw badRequest('question_unsupported', 'this question format is not supported');
        const answers = {};
        questions.forEach((q, index) => {
          const value = body.answers?.[String(index)];
          if (typeof value !== 'string' || !value.trim() || value.length > 8192) throw badRequest('answer_required', 'answer every question');
          answers[request.name === 'request_user_input_async' ? `Question ${index + 1}` : q.question] = value;
        });
        response = { behavior: 'allow', updatedInput: { answers } };
      } else throw badRequest('decision_invalid', 'choose an appropriate decision');
      await c.respondToPermissionAndWait(id, request.id, response, 15_000);
      if ((await agent(c, id)).pendingPermissions?.some((p) => p.id === request.id)) throw conflict('reply_unconfirmed', 'the decision is not confirmed');
      decisions.delete(id);
      return { replied: true };
    }),
  };
}
// Paseo maps the model Claude Code reports onto its own list, and a version
// that list does not know yet loses its minor part: "claude-fable-5-2" comes
// back as "claude-fable-5". The unmapped value sits beside it, so it wins when
// it is the mapped model plus a minor version.
export function runningModel(a) {
  const mapped = a.runtimeInfo?.model ?? a.model ?? null;
  const raw = a.runtimeInfo?.extra?.runtimeModel;
  if (typeof mapped !== 'string' || typeof raw !== 'string') return mapped;
  const reported = raw.trim().replace(/\[1m\]$/i, '');
  return reported.startsWith(`${mapped}-`) && /^-\d{1,2}$/.test(reported.slice(mapped.length)) ? reported : mapped;
}
export function snapshot(a, now) {
  const pending = a.pendingPermissions ?? [];
  const effort = a.effectiveThinkingOptionId ?? a.thinkingOptionId ?? null;
  const observed = { provider: a.provider, model: runningModel(a), effort };
  return { title: a.title, daemonStatus: a.status, activeTurn: Boolean(a.activeTurn), archivedAt: a.archivedAt ?? null,
    phase: pending.length ? 'awaiting_decision' : a.status === 'idle' && !a.activeTurn ? 'awaiting_review' : a.status,
    pending,
    // The runtime reports model/mode in `runtimeInfo` and the applied thinking
    // option separately; checking `runtimeInfo.effort` alone could never verify.
    modelCheck: { observed, runtimeVerified: Boolean(a.runtimeInfo?.model && effort) },
    // Toggle/select features (Fast) carry their actual provider value, and a
    // select also names its options. Nothing here is derived from the Bridge's
    // request.
    features: Array.isArray(a.features) ? a.features.map((f) => ({
      id: f?.id ?? null, type: f?.type ?? null, label: f?.label ?? null, value: f?.value,
      options: Array.isArray(f?.options) ? f.options.map((o) => ({ id: o?.id ?? null, label: o?.label ?? null })) : undefined,
    })) : null,
    updatedAt: a.updatedAt, observedAt: now };
}
function decisionView(p) {
  return { id: p.id, kind: p.kind, name: p.name,
    // Show the complete request before a tool can be approved. Tool results
    // and reasoning are never added to conversation history.
    detail: JSON.stringify(p.input ?? {}, null, 2),
    questions: p.kind === 'question' && Array.isArray(p.input?.questions) ? p.input.questions.map((q) => ({
      question: q.question ?? q.title ?? '', options: (q.options ?? []).map((o) => typeof o === 'string' ? o : o.label),
    })) : [] };
}

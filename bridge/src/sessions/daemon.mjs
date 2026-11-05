// Paseo is the execution and conversation authority, including sessions created
// outside the Bridge. No configuration, credentials or conversation bodies are
// needed to enumerate it. Mutations are reached only from authenticated routes.
import { createHash } from 'node:crypto';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { BridgeError, badRequest, conflict } from '../errors.mjs';

export async function connectDaemon() {
  const { connectToDaemon } = await import('/opt/homebrew/lib/node_modules/@getpaseo/cli/dist/utils/client.js');
  return connectToDaemon({ target: { kind: 'instance', home: join(homedir(), '.paseo') }, timeout: 15_000 });
}
export const pendingHash = (pending) => createHash('sha256').update(JSON.stringify(pending)).digest('hex');
export const daemonSessionID = (id) => `ses_${createHash('sha256').update(`paseo|${id}`).digest('hex').slice(0, 16)}`;
const PARENT_LABEL = 'paseo.parent-agent-id';
const isBusy = (a) => Boolean(a.activeTurn || a.pendingPermissions?.length) || !['idle', 'closed', 'error'].includes(a.status);

export function daemonAdapter({ connect = connectDaemon, now = () => Date.now() } = {}) {
  const decisions = new Map();
  async function call(fn) {
    let client;
    try { client = await connect(); return await fn(client); }
    catch (error) {
      if (error instanceof BridgeError) throw error;
      throw new BridgeError(503, 'paseo_unavailable', 'Paseo could not confirm the operation', { retryable: true });
    } finally { await client?.close().catch(() => {}); }
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
  return {
    list: () => call(directory),
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
        const result = await c.archiveWorkspace(entry.id);
        if (result?.error) throw new Error(result.error);
      }
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
    status: (id) => call(async (c) => snapshot(await agent(c, id), now())),
    send: (id, { text, messageId, images }) => call(async (c) => {
      const a = await agent(c, id);
      if (a.pendingPermissions?.length) throw conflict('pending_decision_requires_reply', 'answer the pending decision first');
      // Explicit steering preserves the currently running turn. The daemon
      // owns exactly-once message acceptance for this stable client message id.
      await c.sendMessage(id, text, { messageId, activeTurnBehavior: 'steer', images });
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
export function snapshot(a, now) {
  const pending = a.pendingPermissions ?? [];
  const observed = { provider: a.provider, model: a.runtimeInfo?.model ?? a.model ?? null, effort: a.effectiveThinkingOptionId ?? a.thinkingOptionId ?? null };
  return { title: a.title, daemonStatus: a.status,
    phase: pending.length ? 'awaiting_decision' : a.status === 'idle' && !a.activeTurn ? 'awaiting_review' : a.status,
    pending, modelCheck: { observed, runtimeVerified: Boolean(a.runtimeInfo?.model && a.runtimeInfo?.effort) },
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

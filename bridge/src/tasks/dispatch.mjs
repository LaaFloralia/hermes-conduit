// Owner-created tasks are the only source of automatic work. Linear remains
// the task record; this locked file records who accepted it and resumable work.
import { createHash, randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { join } from 'node:path';
import { createJsonFile } from '../routes/state-file.mjs';
import { BridgeError, badRequest, conflict } from '../errors.mjs';
import { normalizeRefInput } from '../refs/registry.mjs';
import { sessionRefItem } from '../refs/items.mjs';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const SESSION = /^ses_[0-9a-f]{16}$/;
const RETENTION = 30 * 86400_000;
const BACKOFF = [60_000, 300_000, 900_000, 3600_000];
const PHASES = ['owner', 'queued', 'started', 'failed', 'reported', 'completed'];
const PARENT = 'paseo.parent-agent-id';
export const TASK_STAFF = Object.freeze({
  monet: { role: 'Monet', name: 'Monet' }, argus: { role: 'Argus', name: 'Argus' },
  cfo: { role: 'CFO', name: 'Morgan' }, cio: { role: 'CIO', name: 'Sherlock' },
  cos: { role: 'COS', name: 'Merlin' }, cso: { role: 'CSO', name: 'Talos' }, cto: { role: 'CTO', name: 'Ada' },
});
const object = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const time = (v) => typeof v === 'string' && Number.isFinite(Date.parse(v));
const nullableTime = (v) => v === null || time(v);
const bounded = (v, max) => typeof v === 'string' && v.length > 0 && [...v].length <= max;
const code = (v) => typeof v === 'string' && /^[a-z][a-z0-9_]{0,79}$/.test(v);
const digest = (v) => createHash('sha256').update(v).digest('hex');
const unavailable = () => new BridgeError(503, 'task_runs_store_unavailable', 'タスクの実行記録を読み書きできません。', { retryable: true });
const missing = () => new BridgeError(404, 'task_run_not_found', 'タスクの実行記録がありません。');
const assigneeValid = (a) => object(a) && (a.kind === 'owner' ? Object.keys(a).length === 1
  : a.kind === 'staff' && Object.hasOwn(TASK_STAFF, a.staff) && a.name === TASK_STAFF[a.staff].name && Object.keys(a).length === 3);
const reportValid = (r) => r === null || (object(r) && bounded(r.summary, 600) && time(r.at));

export function taskAssignee(body = {}, options) {
  const a = body.assignee === undefined ? { kind: 'owner' } : body.assignee;
  if (!object(a)) throw badRequest('task_assignee_invalid', 'assignee must be owner or staff');
  if (a.kind === 'owner' && Object.keys(a).every((k) => k === 'kind')) {
    if (Object.hasOwn(body, 'profile')) throw badRequest('task_profile_invalid', 'profile is only accepted for staff');
    return { assignee: { kind: 'owner' }, profile: null };
  }
  if (a.kind !== 'staff' || !Object.hasOwn(TASK_STAFF, a.staff) || Object.keys(a).some((k) => !['kind', 'staff'].includes(k))) {
    throw badRequest('task_assignee_invalid', 'choose a listed AI employee');
  }
  if (typeof body.profile !== 'string' || !options?.profiles?.some((p) => p.id === body.profile)) {
    throw badRequest('task_profile_invalid', 'choose a profile from session-options');
  }
  return { assignee: { kind: 'staff', staff: a.staff, name: TASK_STAFF[a.staff].name }, profile: body.profile };
}

export function createTaskRunStore({ dir, now = () => Date.now() }) {
  const file = createJsonFile({ file: join(dir, 'task-runs.json'), initial: () => ({ records: [], pickups: {}, completions: {}, operations: {} }) });
  const stamp = () => new Date(now()).toISOString();
  function checked(s) {
    const validRecord = (r) => object(r) && UUID.test(r.taskId) && typeof r.identifier === 'string' && r.creator === 'owner'
      && bounded(r.deviceId, 200) && assigneeValid(r.assignee) && PHASES.includes(r.phase)
      && (r.assignee.kind === 'owner' ? r.profile === null && r.sessionId === null && ['owner', 'completed'].includes(r.phase) && r.report === null : bounded(r.profile, 64) && r.phase !== 'owner')
      && (r.sessionId === null || SESSION.test(r.sessionId)) && Number.isSafeInteger(r.attempts) && r.attempts >= 0
      && nullableTime(r.nextAttemptAt) && (r.lastError === null || code(r.lastError)) && reportValid(r.report)
      && nullableTime(r.pickedUpAt) && nullableTime(r.completedAt) && time(r.createdAt) && time(r.updatedAt)
      && (r.phase !== 'completed' || time(r.completedAt)) && (r.phase !== 'reported' || r.report !== null)
      && (!['started', 'reported'].includes(r.phase) || r.sessionId !== null);
    const validPickup = ([id, p]) => UUID.test(id) && object(p) && object(p.body)
      && p.body.requestId === `task-${id}` && typeof p.body.prompt === 'string' && bounded(p.body.profile, 64)
      && p.body.workspaceId === 'home' && p.body.mode === 'bypass' && UUID.test(p.commentId)
      && bounded(p.label, 200) && typeof p.commentDone === 'boolean' && (p.commentBody === null || bounded(p.commentBody, 1000));
    const validCompletion = ([id, c]) => UUID.test(id) && object(c) && c.taskId === id && typeof c.expected === 'string'
      && Number.isInteger(c.stage) && c.stage >= 0 && c.stage <= 7 && time(c.createdAt) && time(c.updatedAt)
      && UUID.test(c.commentId) && object(c.snapshot) && typeof c.snapshot.comment === 'string'
      && (c.snapshot.sessionId === null || SESSION.test(c.snapshot.sessionId))
      && Array.isArray(c.snapshot.sessionIds) && c.snapshot.sessionIds.every((v) => SESSION.test(v))
      && typeof c.sessionArchived === 'boolean' && (c.response === null || (object(c.response) && c.response.id === id
        && c.response.completed === true && typeof c.response.sessionArchived === 'boolean' && c.response.archive === 'queued'))
      && (c.stage !== 7 || c.response !== null);
    if (!object(s) || !Array.isArray(s.records) || s.records.some((r) => !validRecord(r))
      || new Set(s.records.map((r) => r.taskId)).size !== s.records.length
      || !object(s.pickups) || Object.entries(s.pickups).some((e) => !validPickup(e))
      || !object(s.completions) || Object.entries(s.completions).some((e) => !validCompletion(e))
      || !object(s.operations) || Object.values(s.operations).some((o) => !object(o) || !UUID.test(o.taskId)
        || !/^[0-9a-f]{64}$/.test(o.digest) || !s.completions[o.taskId])) throw unavailable();
    return s;
  }
  function prune(s) {
    const expired = new Set(s.records.filter((r) => r.completedAt && now() - Date.parse(r.completedAt) >= RETENTION).map((r) => r.taskId));
    for (const [id, c] of Object.entries(s.completions)) if (c.stage === 7 && now() - Date.parse(c.updatedAt) >= RETENTION) expired.add(id);
    s.records = s.records.filter((r) => !expired.has(r.taskId));
    for (const id of expired) { delete s.pickups[id]; delete s.completions[id]; }
    for (const [key, o] of Object.entries(s.operations)) if (expired.has(o.taskId)) delete s.operations[key];
  }
  const access = (fn) => { try { return fn(); } catch (e) { if (e instanceof BridgeError) throw e; throw unavailable(); } };
  const read = (fn) => access(() => { const s = checked(file.read()); prune(s); return structuredClone(fn(s)); });
  const mutate = (fn) => access(() => file.mutate((s) => { checked(s); prune(s); const result = fn(s); checked(s); return structuredClone(result); }));
  const find = (s, id) => { const r = s.records.find((r) => r.taskId === id); if (!r) throw missing(); return r; };
  const opKey = (deviceId, key) => JSON.stringify([deviceId, key]);
  return {
    file: file.file,
    all: () => read((s) => s.records),
    get: (id) => read((s) => s.records.find((r) => r.taskId === id) ?? null),
    record({ task, deviceId, assignee, profile }) {
      return mutate((s) => {
        const existing = s.records.find((r) => r.taskId === task.id.toLowerCase());
        if (existing) {
          if (JSON.stringify(existing.assignee) !== JSON.stringify(assignee) || existing.profile !== profile) throw conflict('task_assignment_conflict', 'the task already has a different assignee or profile');
          return existing;
        }
        const r = { taskId: task.id.toLowerCase(), identifier: task.identifier, creator: 'owner', deviceId, assignee, profile,
          phase: assignee.kind === 'staff' ? 'queued' : 'owner', sessionId: null, attempts: 0,
          nextAttemptAt: assignee.kind === 'staff' ? stamp() : null, lastError: null, report: null,
          pickedUpAt: null, completedAt: null, createdAt: stamp(), updatedAt: stamp() };
        s.records.push(r); return r;
      });
    },
    update(id, fn) { return mutate((s) => { const r = find(s, id); fn(r); r.updatedAt = stamp(); return r; }); },
    pickup: (id) => read((s) => s.pickups[id] ?? null),
    preparePickup(id, body, label) { return mutate((s) => { find(s, id); return s.pickups[id] ??= { body, label, commentId: randomUUID(), commentDone: false, commentBody: null }; }); },
    prepareComment(id, body) { return mutate((s) => { s.pickups[id].commentBody ??= body; return s.pickups[id]; }); },
    commentDone(id) { mutate((s) => { s.pickups[id].commentDone = true; }); },
    completion: (id) => read((s) => s.completions[id] ?? null),
    operation(deviceId, key, hash) {
      return read((s) => { const o = s.operations[opKey(deviceId, key)]; if (!o) return null;
        if (o.digest !== hash) throw conflict('idempotency_key_conflict', 'Idempotency-Key was used for a different request');
        return s.completions[o.taskId]; });
    },
    beginCompletion({ taskId, deviceId, key, hash, expected, snapshot }) {
      return mutate((s) => {
        const k = opKey(deviceId, key), prior = s.operations[k];
        if (prior && prior.digest !== hash) throw conflict('idempotency_key_conflict', 'Idempotency-Key was used for a different request');
        let c = s.completions[taskId];
        if (c && c.expected !== expected) throw conflict('task_completion_in_progress', 'retry the original completion request');
        c ??= { taskId, expected, snapshot, commentId: randomUUID(), stage: 0, sessionArchived: false, response: null, createdAt: stamp(), updatedAt: stamp() };
        s.completions[taskId] = c; s.operations[k] = { taskId, digest: hash }; return c;
      });
    },
    advance(id, stage, patch = {}) { return mutate((s) => { const c = s.completions[id]; if (!c) throw missing(); Object.assign(c, patch, { stage, updatedAt: stamp() }); return c; }); },
    prune: () => mutate(() => null),
  };
}

export function taskSessionTree(sessionId, records) {
  const root = records.find((r) => r.id === sessionId);
  if (!root) return [];
  const tree = [root], ids = new Set([root.id]), agents = new Set([root.delegate?.sessionId].filter(Boolean));
  for (let changed = true; changed;) {
    changed = false;
    for (const r of records) if (!ids.has(r.id) && (ids.has(r.parentId) || (r.labels?.[PARENT] && agents.has(r.labels[PARENT])))) {
      tree.push(r); ids.add(r.id); if (r.delegate?.sessionId) agents.add(r.delegate.sessionId); changed = true;
    }
  }
  return tree;
}

function relatedDecision(d, tree) {
  return d.status === 'open' && tree.some((r) => d.source?.sessionId === r.id || (r.delegate?.sessionId && d.source?.paseoAgentId === r.delegate.sessionId));
}
const profileLabel = (p) => `${p.label} · ${p.effort.slice(0, 1).toUpperCase()}${p.effort.slice(1)}`;
const safeError = (e) => code(e?.code) ? e.code : 'task_dispatch_unavailable';

export function taskSessionRequest(task, run, label, taskRef) {
  const who = TASK_STAFF[run.assignee.staff];
  return {
    requestId: `task-${run.taskId}`, profile: run.profile, workspaceId: 'home', mode: 'bypass', name: [...task.title].slice(0, 40).join(''),
    purpose: `社長のタスク ${taskRef ?? '番号未割当'}（${task.identifier}）「${task.title}」を完了させる`,
    completion: `説明に完了条件があればそれ、なければ題名の目的を実物で満たす。検証・統合・配信・後始末（AGENTS.md【毎回の後始末】）まで終え、最後に laa-bridge tasks report ${run.taskId} --summary '<結果・検証・残件>' を実行して手番を終える`,
    scope: 'このタスクの目的に必要な範囲。AGENTS.mdの継続承認の範囲で自律して進め、社長へ戻すのは【自律実行と社長へ戻す時】の条件の時だけ。その時は判断ボード（laa-bridge decide add）へ1件登録して手番を終える。会話をアーカイブしない（社長が完了を押すと片付く）',
    returnTo: 'LAAアプリのタスク一覧（laa-bridge tasks report）',
    prompt: ['LAAの作業。cwdは /Users/laa。最初に /Users/laa/AGENTS.md と関係する PROJECT-RULES.md を読む。社長がLAAアプリで作成したタスクを、Monetが社長の代理として引き受けた。/Users/laa/hq/roles/Monet/SOUL.md の「社長のタスクを引き受けた時」に従い、社長に頼らず完了まで進める。',
      ...(run.assignee.staff === 'monet' ? [] : [`担当は ${who.name}（${who.role}）。/Users/laa/hq/roles/${who.role}/SOUL.md と /Users/laa/hq/roles/PROTOCOL.md を読み、その社員として動く。`]),
      `モデル: ${label}（この設定を保つ。分担は hq/guide/models.md）`,
      `タスク番号: ${taskRef ?? '未割当'}（${task.identifier}）\n課題ID: ${run.taskId}\n社長がLAAアプリで作成した時の本文（後からLinearで変わっても、この控えが正）\n題名: ${task.title}\n説明:\n${task.description || '（説明なし）'}\n期限: ${task.dueDate ?? '未設定'}\n優先度: ${task.priority}`].join('\n\n'),
  };
}

// Only aggregate summary lines leave cleanup's pipes. Never log its arbitrary
// output: a future CLI version might print the issue body or an error echo.
export function taskCleanup({ log = null, spawnImpl = spawn } = {}) {
  let child;
  const emit = (entry) => { try { log?.({ event: 'task_cleanup', ...entry }); } catch {} };
  try { child = spawnImpl('/Users/laa/.local/bin/laa-agent', ['cleanup', '--done-only'], { stdio: ['ignore', 'pipe', 'pipe'] }); }
  catch { emit({ level: 'error', exitCode: null, summary: 'cleanup_spawn_failed' }); return; }
  let output = '', ended = false;
  for (const stream of [child.stdout, child.stderr]) stream?.on('data', (chunk) => { if (output.length < 16_384) output += String(chunk).slice(0, 16_384 - output.length); });
  child.once('error', () => { if (!ended) { ended = true; emit({ level: 'error', exitCode: null, summary: 'cleanup_spawn_failed' }); } });
  child.once('close', (exitCode) => {
    if (ended) return; ended = true;
    // Count-only lines are safe even when every other line contains private text.
    let summary = output.split(/\r?\n/).filter((s) => /^(?:archived|cleaned|deleted|saved|skipped|failed|total|完了|保存|削除|対象|件数)[:： ]+[0-9]+(?:[ 件]*|(?:[,; ]+(?:archived|cleaned|deleted|saved|skipped|failed|total)[: ]+[0-9]+)*)$/i.test(s.trim())).map((s) => s.trim()).slice(-3).join('; ') || 'cleanup_finished';
    try {
      const notes = JSON.parse(output).notes;
      if (Array.isArray(notes) && notes.every((v) => typeof v === 'string')) summary = `saved: ${notes.filter((v) => v.endsWith(': logged')).length}; deleted: ${notes.filter((v) => v.endsWith(': deleted')).length}; kept: ${notes.filter((v) => v.endsWith('kept')).length}`;
    } catch { /* Arbitrary output is never copied into the log. */ }
    emit({ level: exitCode === 0 ? 'info' : 'error', exitCode, summary });
  });
  child.unref?.();
}

export function createTaskDispatchService({ store, tasks, sessions = null, sessionStore = null, decisionStore = null,
  sessionOptions = () => ({ profiles: [] }), refs = null, daemon = null, now = () => Date.now(), cleanup = () => taskCleanup(), log = null } = {}) {
  const picking = new Map(), completing = new Map();
  const stamp = () => new Date(now()).toISOString();
  const records = () => sessionStore?.all() ?? [];
  const treeFor = (r) => r?.sessionId ? taskSessionTree(r.sessionId, records()) : [];
  function labelFor(r) {
    if (!r.profile) return null;
    const frozen = store.pickup(r.taskId)?.label;
    if (frozen) return frozen;
    const p = sessionOptions().profiles.find((p) => p.id === r.profile);
    return p ? profileLabel(p) : null;
  }
  function view(taskId) {
    const r = store.get(taskId.toLowerCase());
    if (!r) return null;
    const tree = treeFor(r), root = tree[0];
    const decision = decisionStore?.all().find((d) => relatedDecision(d, tree));
    let state = null;
    if (r.assignee.kind === 'staff') {
      state = r.report || r.phase === 'completed' ? 'done' : r.phase === 'failed' ? 'failed' : !r.sessionId ? 'queued'
        : decision || tree.some((s) => s.phase === 'awaiting_decision') ? 'awaiting_decision'
          : !root || root.daemonDeletedAt || ['error', 'failed', 'stopped', 'stop_unconfirmed', 'closed'].includes(root.phase) ? 'stopped' : 'running';
    }
    return { creator: 'owner', assignee: r.assignee, profile: r.profile, profileLabel: labelFor(r), state,
      sessionId: r.sessionId, sessionRef: r.sessionId ? refs?.refFor('session', r.sessionId) ?? null : null,
      decisionRef: decision ? refs?.refFor('decision', decision.id) ?? null : null, report: r.report, error: r.lastError };
  }
  async function pick(id) {
    let r = store.get(id);
    if (!r || r.assignee.kind !== 'staff' || !['queued', 'started', 'reported'].includes(r.phase) || store.completion(id)
      || (r.nextAttemptAt && Date.parse(r.nextAttemptAt) > now())) return;
    if (r.sessionId && store.pickup(id)?.commentDone) return;
    r = store.update(id, (v) => { v.attempts += 1; });
    try {
      const task = await tasks.readOwnerTask(id);
      if (!task || task.archivedAt || ['done', 'canceled'].includes(task.status)) throw new BridgeError(409, 'task_no_longer_open', 'the task is no longer open');
      let p = store.pickup(id);
      if (!r.sessionId) {
        const existing = records().find((s) => s.requestId === `task-${id}`);
        let result;
        if (existing && p) result = { session: existing };
        else {
          if (!p) throw conflict('task_brief_missing', 'the task has no brief frozen from its create request');
          if (!sessionOptions().profiles.some((v) => v.id === r.profile)) throw badRequest('task_profile_unknown', 'the selected profile is no longer listed');
          result = await sessions.createSession({ deviceId: r.deviceId, body: p.body });
        }
        r = store.update(id, (v) => { v.sessionId = result.session.id; v.phase = v.report ? 'reported' : 'started'; v.pickedUpAt ??= stamp(); v.lastError = null; v.nextAttemptAt = null; });
        if (refs) { const item = sessionRefItem(result.session, refs.refFor); refs.assign('session', item.key, item.title, item.external); }
      }
      if (p && !p.commentDone) {
        p = store.prepareComment(id, `[laa-bridge] Monetが取得（${refs?.refFor('session', r.sessionId) ?? '番号未割当'}・${r.assignee.name}・${p.label}）`);
        await tasks.commentOwnerTask(id, { id: p.commentId, body: p.commentBody });
        store.commentDone(id);
      }
      store.update(id, (v) => { v.lastError = null; v.nextAttemptAt = null; });
    } catch (e) {
      const permanent = !r.sessionId && (e instanceof BridgeError && e.status < 500 && !e.retryable
        && !['creation_outcome_unknown', 'session_busy'].includes(e.code));
      store.update(id, (v) => { if (permanent) v.phase = 'failed'; v.lastError = safeError(e);
        v.nextAttemptAt = permanent ? null : new Date(now() + BACKOFF[Math.min(v.attempts - 1, BACKOFF.length - 1)]).toISOString(); });
    }
  }
  // The owner's own create request is the only brief a bypass-mode session
  // receives: an issue edit made in Linear before the pickup never reaches it.
  function accept({ task, deviceId, assignee, profile }) {
    const r = store.record({ task, deviceId, assignee, profile });
    const p = r.assignee.kind === 'staff' && sessionOptions().profiles.find((v) => v.id === r.profile);
    if (p && !store.pickup(r.taskId)) store.preparePickup(r.taskId, taskSessionRequest(task, r, profileLabel(p), refs?.refFor('task', r.taskId)), profileLabel(p));
    return r;
  }
  function pickup(id) {
    if (picking.has(id)) return picking.get(id);
    const work = pick(id).finally(() => picking.delete(id)); picking.set(id, work); return work;
  }
  function schedule(id) { void pickup(id).catch(() => { try { log?.({ level: 'error', event: 'task_pickup', code: 'task_runs_store_unavailable' }); } catch {} }); }
  async function tick() { store.prune(); for (const r of store.all()) await pickup(r.taskId); }

  async function report(given, summary, agentId = null) {
    if (typeof summary !== 'string') throw badRequest('task_report_invalid', 'summary is required');
    summary = summary.replace(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/gu, ' ').trim();
    if (!summary || [...summary].length > 600) throw badRequest('task_report_invalid', 'summary must contain 1..600 characters');
    let id = String(given ?? '').toLowerCase();
    const asRef = normalizeRefInput(String(given ?? ''));
    if (asRef?.kind === 'task') id = refs?.resolve(asRef.ref).holder?.key ?? '';
    else if (/^BUS-[1-9][0-9]*$/i.test(String(given))) id = store.all().find((r) => r.identifier.toLowerCase() === id)?.taskId ?? '';
    const r = store.get(id);
    if (!r) throw missing();
    if (!r.sessionId || r.assignee.kind !== 'staff' || r.completedAt) throw conflict('task_report_closed', 'the task has no active execution record');
    if (agentId) {
      const rootAgent = treeFor(r)[0]?.delegate?.sessionId;
      let authorized = treeFor(r).some((s) => s.delegate?.sessionId === agentId);
      if (!authorized && rootAgent && daemon) {
        const agents = await daemon.list(), visited = new Set();
        let current = agentId;
        while (current && !visited.has(current)) {
          if (current === rootAgent) { authorized = true; break; }
          visited.add(current); current = agents.find((a) => a.id === current)?.labels?.[PARENT];
        }
      }
      if (!authorized) throw new BridgeError(403, 'task_report_forbidden', 'このタスクの会話またはその子から報告してください。');
    }
    return store.update(id, (v) => { if (v.report?.summary !== summary) v.report = { summary, at: stamp() }; v.phase = 'reported'; });
  }

  async function idleTree(r) {
    if (picking.has(r?.taskId)) throw conflict('session_running', 'the task session is being started');
    if (!r?.sessionId) {
      if (r?.phase === 'queued' && r.attempts > 0 && store.pickup(r.taskId)) throw conflict('task_pickup_unconfirmed', 'wait for the pending session creation to reconcile');
      return [];
    }
    await sessions.syncDaemon();
    const tree = treeFor(r);
    if (!tree.length) throw new BridgeError(503, 'task_session_unavailable', 'the task session cannot be read', { retryable: true });
    for (const s of tree) {
      if (s.archivedAt || s.daemonArchivedAt || s.daemonDeletedAt) continue;
      if (daemon && s.delegate?.sessionId) {
        const status = await daemon.status(s.delegate.sessionId);
        if (status.activeTurn || status.pending?.length || !['idle', 'closed', 'error', 'stopped'].includes(status.daemonStatus)) throw conflict('session_running', 'a session in this tree is still running');
      } else if (s.pending?.count || !['idle', 'awaiting_review', 'error', 'stopped', 'closed', 'done', 'completed'].includes(s.phase)) throw conflict('session_running', 'a session in this tree is still running');
    }
    return tree;
  }
  async function finish({ id, deviceId, key, expected, rawBody = Buffer.alloc(0) }) {
    const hash = digest(`${id}\n${expected}\n${rawBody.toString('utf8')}`);
    let c = store.operation(deviceId, key, hash);
    if (c?.stage === 7) return { data: c.response, replayed: true };
    const r = store.get(id);
    if (!c) {
      const task = await tasks.readOwnerTask(id);
      if (!task) throw new BridgeError(404, 'linear_owner_task_not_found', 'no such owner task');
      if (task.updatedAt !== expected) throw new BridgeError(412, 'precondition_failed', 'the task changed since it was read');
      const tree = await idleTree(r);
      decisionStore?.all(); // Prove the decision file is readable before changing anything.
      await tasks.prepareCompletion?.();
      const sessionRef = r?.sessionId ? refs?.refFor('session', r.sessionId) ?? null : null;
      const detail = [sessionRef, tree[0]?.name, r?.assignee.name ?? '社長', r ? labelFor(r) : null].filter(Boolean).join('・');
      const snapshot = { sessionId: r?.sessionId ?? null, sessionIds: tree.map((s) => s.id), comment: `[laa-bridge] 完了（${detail}）\n${r?.report?.summary ?? '報告なし'}` };
      c = store.beginCompletion({ taskId: id, deviceId, key, hash, expected, snapshot });
    }
    if (c.stage < 1) {
      const tree = await idleTree(r);
      for (const d of decisionStore?.all() ?? []) if (relatedDecision(d, tree)) {
        decisionStore.withdraw(d.id, 'タスク完了'); refs?.release('decision', d.id);
      }
      c = store.advance(id, 1);
    }
    if (c.stage < 2) {
      if (c.snapshot.sessionId) {
        const tree = await idleTree(r);
        for (const s of tree) if (s.favorite) await sessions.updateSession({ id: s.id, body: { favorite: false } });
        await sessions.updateSession({ id: c.snapshot.sessionId, body: { archived: true, favorite: false } });
        for (const s of tree) refs?.release('session', s.id);
      }
      c = store.advance(id, 2, { sessionArchived: Boolean(c.snapshot.sessionId) });
    }
    if (c.stage < 3) { await tasks.commentOwnerTask(id, { id: c.commentId, body: c.snapshot.comment }); c = store.advance(id, 3); }
    if (c.stage < 4) { await tasks.completeOwnerTask(id); c = store.advance(id, 4); }
    if (c.stage < 5) { refs?.release('task', id); c = store.advance(id, 5); }
    if (c.stage < 6) {
      // At most once. A process dying after reservation leaves the issue Done;
      // the weekly cleanup is the recovery path for the unscheduled command.
      c = store.advance(id, 6);
      try { cleanup(); } catch { try { log?.({ level: 'error', event: 'task_cleanup', exitCode: null, summary: 'cleanup_spawn_failed' }); } catch {} }
    }
    if (r && !r.completedAt) store.update(id, (v) => { v.phase = 'completed'; v.completedAt = stamp(); v.nextAttemptAt = null; });
    c = store.advance(id, 7, { response: { id, completed: true, sessionArchived: c.sessionArchived, archive: 'queued' } });
    return { data: c.response, replayed: false };
  }
  async function complete(input) {
    if (completing.has(input.id)) throw conflict('idempotency_key_in_flight', 'the task completion is still executing');
    const work = finish(input).finally(() => completing.delete(input.id)); completing.set(input.id, work); return work;
  }
  return { store, view, accept, pickup, schedule, tick, report, complete,
    validateAssignment: (body) => taskAssignee(body, body.assignee?.kind === 'staff' && typeof body.profile === 'string' ? sessionOptions() : null) };
}

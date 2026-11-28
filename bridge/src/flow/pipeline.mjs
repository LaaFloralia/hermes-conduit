// The requirement flow: owner requirement → staff expansion → design adviser →
// designed requirement with acceptance criteria and briefs → implementation
// sessions → Monet's verification → one report.
//
// Principle: code moves the state, models only produce bounded text. Every
// step reads the flow record, performs at most one side effect guarded by an
// idempotency key (a requestId, a decision requestId, a message id) and writes
// the next state with a compare-and-set, so a step can be retried or run twice
// without doing its work twice. A step that fails twice in a row with the same
// error stops the flow and tells Monet once; nothing loops.

import { BridgeError, badRequest, conflict, notFound } from '../errors.mjs';
import { isOwnerSurface } from '../owner-surface.mjs';
import { REQUEST_ID_PATTERN } from '../routes/project-requirements.mjs';
import { isVerified } from '../notify/completion-report.mjs';
import { decisionEvents, findingEvents, sessionEvent } from '../monet/events.mjs';
import { monetDigest } from '../monet/inbox.mjs';
import { packetFor } from '../monet/evidence.mjs';
import { needsAdvisor, pickAdvisor, RISKS, SIZES } from './config.mjs';
import { parseDesign, parseVerdict } from './parse.mjs';
import { advisorRepair, advisorTask, clipBytes, packageTask, staffPrompt, synthesizeDesign, verifyPrompt } from './prompts.mjs';
import { mergeAcceptance } from './requirements.mjs';
import { pickStaff, readRoster } from './staffing.mjs';
import { CLOSED_STATES } from './store.mjs';

const ROOT = '/Users/laa';
const ACTIVE = ['dispatching', 'verifying'];
const STAFF_DONE = ['done', 'absent', 'timeout'];
const PACKAGE_BUSY = ['running', 'returned', 'blocked'];
const NO_RETRY = ['model_choice_invalid', 'profile_unsupported', 'payload_invalid', 'project_default_unavailable'];
const chars = (value, max) => { const all = [...String(value ?? '')]; return all.length > max ? `${all.slice(0, max - 1).join('')}…` : all.join(''); };
const codeOf = (error) => (error instanceof BridgeError ? error.code : error?.message && /^[a-z0-9_:.-]{1,80}$/i.test(error.message) ? error.message : 'internal_error');

export function createFlowPipeline({ flows, inbox, requirements, projects, sessionStore, decisionStore, decisions = null, findingStore = null,
  runners, config, reporter = null, now = () => Date.now(), log = null }) {
  const stamp = () => new Date(now()).toISOString();
  const busy = new Set();
  const background = new Set();
  const report = (event, fields = {}) => { try { log?.({ level: 'info', event, ...fields }); } catch { /* Logging never fails a step. */ } };
  const track = (promise) => { const p = promise.catch(() => {}).finally(() => background.delete(p)); background.add(p); return p; };

  // --- failure rule ----------------------------------------------------------

  // First failure of a step: remember it and try again after `retryMs`. The same
  // error a second time: the flow stops and Monet is told once.
  function fail(flowId, step, error, { final = false } = {}) {
    const code = codeOf(error);
    let stopped = false;
    const flow = flows.update(flowId, (draft) => {
      if (CLOSED_STATES.includes(draft.state)) return;
      const same = draft.failure?.step === step && draft.failure.code === code;
      draft.failure = { step, code, count: same ? draft.failure.count + 1 : 1, at: stamp() };
      draft.retryAt = new Date(now() + config().retryMs).toISOString();
      if (final || draft.failure.count >= 2 || NO_RETRY.includes(code)) stopped = true;
    });
    report('flow_step_failed', { flowId, step, code });
    if (!stopped) return flow;
    const closed = flows.advance(flowId, flow.state, 'failed', { retryAt: null }, { note: `${step}: ${code}` }).flow;
    inbox.offer({ kind: 'flow.step', key: `${flowId}:failed`, handler: 'monet', flowId, projectId: closed.projectId,
      requirementId: closed.requirementIds[0] ?? null, origin: 'laa-bridge',
      packet: { title: closed.request.title, step, code, state: 'failed' } });
    return closed;
  }
  const ok = { failure: null, retryAt: null };

  // --- intake ----------------------------------------------------------------

  function parseStart(input) {
    if (!input || typeof input !== 'object' || Array.isArray(input)) throw badRequest('flow_invalid', 'expected a JSON object');
    const allowed = ['projectId', 'requestId', 'title', 'details', 'ownerText', 'size', 'risk', 'repo', 'refs', 'dryStaff'];
    if (Object.keys(input).some((key) => !allowed.includes(key))) throw badRequest('flow_invalid', `expected fields: ${allowed.join(', ')}`);
    const text = (value, field, bytes, optional) => {
      if (value == null || value === '') { if (optional) return null; throw badRequest('flow_invalid', `${field} is required`); }
      if (typeof value !== 'string' || value.includes('\0') || Buffer.byteLength(value) > bytes) throw badRequest('flow_invalid', `${field} must be text up to ${bytes} bytes`);
      return value.trim();
    };
    if (typeof input.projectId !== 'string' || !/^prj_[0-9a-f]{12}$/.test(input.projectId)) throw badRequest('flow_invalid', 'projectId is required');
    if (typeof input.requestId !== 'string' || !REQUEST_ID_PATTERN.test(input.requestId)) throw badRequest('flow_invalid', 'requestId is required (letters, digits, . _ : -)');
    const size = input.size ?? 'M';
    if (!SIZES.includes(size)) throw badRequest('flow_invalid', 'size is S, M or L');
    const risk = input.risk ?? [];
    if (!Array.isArray(risk) || !risk.every((item) => RISKS.includes(item))) throw badRequest('flow_invalid', `risk lists any of: ${RISKS.join(', ')}`);
    const repo = text(input.repo, 'repo', 400, true);
    if (repo !== null && (!(repo === ROOT || repo.startsWith(`${ROOT}/`)) || repo.split('/').includes('..'))) throw badRequest('flow_invalid', `repo must be an absolute path under ${ROOT}`);
    const refs = input.refs ?? [];
    if (!Array.isArray(refs) || refs.length > 20 || !refs.every((item) => typeof item === 'string' && item.length <= 40)) throw badRequest('flow_invalid', 'refs lists up to 20 short references');
    const title = text(input.title, 'title', 600, false);
    // The title becomes the owner's requirement, shown to the owner as written.
    if (!isOwnerSurface(title)) throw new BridgeError(422, 'owner_surface_language', 'title: 社長の言葉（日本語）で入力してください。');
    return { projectId: input.projectId, requestId: input.requestId, size, risk: [...new Set(risk)], dryStaff: input.dryStaff === true,
      request: { title, details: text(input.details, 'details', 8192, true), ownerText: text(input.ownerText, 'ownerText', 8192, true), repo, refs } };
  }

  async function start(input, { by = 'monet' } = {}) {
    const parsed = parseStart(input);
    const project = projects.get(parsed.projectId);
    if (!project) throw notFound('project not found');
    if (project.archivedAt) throw conflict('project_archived', 'choose an active project');
    const { flow, created } = flows.create({ ...parsed, by });
    if (flow.state === 'intake') await run(flow.id);
    // The consults start now, not at the next tick; the caller already has its answer.
    void run_(flow.id);
    return { flow: flows.get(flow.id), created };
  }

  function stepIntake(flow) {
    // A retry after a crash finds the requirement it already added by its flowId.
    let requirement = requirements.list(flow.projectId).find((item) => item.flowId === flow.id) ?? null;
    requirement ??= requirements.add(flow.projectId, { title: flow.request.title, details: flow.request.details, source: 'owner',
      status: 'in_progress', requestId: flow.requestId, flowId: flow.id, reason: '要件フローで受付' });
    const cfg = config();
    const staff = pickStaff({ request: flow.request, size: flow.size, risk: flow.risk, roster: readRoster(cfg.staff.rosterFile), max: cfg.staff.max, min: cfg.staff.min })
      .map((member) => ({ ...member, state: flow.dryStaff ? 'absent' : 'pending', reason: flow.dryStaff ? 'dry' : null, attempts: 0, startedAt: null, ms: 0 }));
    flows.advance(flow.id, 'intake', 'expanding', { requirementIds: [requirement.id], staff, ...ok }, { note: staff.map((row) => row.role).join(', ') || 'no staff' });
  }

  // --- staff expansion --------------------------------------------------------

  const staffRuns = new Map();
  function stepExpanding(flow) {
    const cfg = config();
    for (const row of flow.staff) {
      const key = `${flow.id}:${row.role}`;
      if (STAFF_DONE.includes(row.state) || staffRuns.has(key)) continue;
      // `running` without a live run means the Bridge restarted mid-consult.
      if (row.attempts >= 2) { flows.setStaff(flow.id, row.role, { state: row.state === 'running' ? 'timeout' : 'absent', reason: 'attempts_exhausted' }); continue; }
      flows.setStaff(flow.id, row.role, { state: 'running', attempts: row.attempts + 1, startedAt: stamp() });
      const consult = runners.runStaff({ member: row, prompt: staffPrompt({ member: row, flow }) })
        .then((result) => { flows.setStaff(flow.id, row.role, { ...result, startedAt: null }); }, () => { flows.setStaff(flow.id, row.role, { state: 'absent', reason: 'runner_failed' }); })
        .finally(() => { staffRuns.delete(key); void run_(flow.id); });
      staffRuns.set(key, consult);
      track(consult);
    }
    const current = flows.get(flow.id);
    if (!current.staff.every((row) => STAFF_DONE.includes(row.state))) return;
    if (needsAdvisor(cfg, current)) {
      const profile = pickAdvisor(cfg);
      flows.advance(flow.id, 'expanding', 'advising', { advisor: { profile, sessionId: null, state: 'pending', attempt: 0, repairs: 0, reason: null }, ...ok }, { note: profile });
    } else {
      applyDesign(current, synthesizeDesign({ flow: current, config: cfg }), { from: 'expanding', advisor: { profile: null, sessionId: null, state: 'skipped', reason: `size_${current.size}` } });
    }
  }

  // --- adviser ----------------------------------------------------------------

  function sessionName(prefix, title) {
    const base = /｜/.test(title) && isOwnerSurface(title) ? title : `${prefix}｜${title}`;
    return clipBytes(base.replace(/\s+/gu, ' ').trim(), 96);
  }

  async function stepAdvising(flow) {
    const advisor = flow.advisor;
    if (advisor.state === 'pending') {
      try {
        const { sessionId } = await runners.startSession({ requestId: `${flow.id}:advise${advisor.attempt ? `:${advisor.attempt}` : ''}`, projectId: flow.projectId,
          profile: advisor.profile, name: sessionName('設計', chars(flow.request.title, 24)), task: advisorTask({ flow, config: config() }) });
        flows.advance(flow.id, 'advising', 'advising', { advisor: { ...advisor, sessionId, state: 'running', startedAt: stamp() }, ...ok });
      } catch (error) {
        const next = NO_RETRY.includes(codeOf(error)) ? pickAdvisor(config(), { after: advisor.profile }) : null;
        // This adviser cannot take a session now: the next enabled one is the configured fallback.
        if (next) flows.advance(flow.id, 'advising', 'advising', { advisor: { ...advisor, profile: next, attempt: advisor.attempt + 1, reason: `${advisor.profile}:${codeOf(error)}` } });
        else fail(flow.id, 'advise', error);
      }
      return;
    }
    if (advisor.state === 'running') reconcileSession(flow, advisor.sessionId);
  }

  // A design must read as owner text where it reaches the owner.
  function ownerTextProblem(design) {
    const owner = [...design.requirements.slice(1).map((item) => item.title), ...design.requirements.flatMap((item) => item.acceptance.map((entry) => entry.text)),
      ...design.ownerDecisions.flatMap((item) => [item.title, ...item.options])];
    return owner.every(isOwnerSurface) ? null : 'owner_facing_text_must_be_japanese (requirement titles, acceptance text, decision titles and options)';
  }

  async function consumeAdvisor(flow, event) {
    const advisor = flow.advisor;
    if (flow.state !== 'advising' || advisor?.sessionId !== event.sessionId) return 'stale';
    const cfg = config();
    let parsed;
    if (event.kind === 'session.error') parsed = { ok: false, error: 'advisor_session_error', fatal: true };
    else {
      const text = await runners.lastReply(advisor.sessionId);
      parsed = parseDesign(text, { allowedProfiles: cfg.implementation.allowedProfiles, defaultProfile: cfg.implementation.defaultProfile, root: ROOT });
      if (parsed.ok) { const problem = ownerTextProblem(parsed.design); if (problem) parsed = { ok: false, error: problem }; }
    }
    if (parsed.ok) {
      applyDesign(flow, parsed.design, { from: 'advising', advisor: { ...advisor, state: 'done' } });
      return 'designed';
    }
    if (!parsed.fatal && advisor.repairs < 1) {
      // One repair: tell the adviser what was unusable and wait for its next return.
      await runners.send({ sessionId: advisor.sessionId, messageId: `${flow.id}:advise:repair`, text: advisorRepair(parsed.error) });
      flows.advance(flow.id, 'advising', 'advising', { advisor: { ...advisor, repairs: advisor.repairs + 1, reason: parsed.error, resumedAt: stamp() } });
      return 'repair';
    }
    const next = parsed.fatal ? pickAdvisor(cfg, { after: advisor.profile }) : null;
    if (next) {
      flows.advance(flow.id, 'advising', 'advising', { advisor: { profile: next, sessionId: null, state: 'pending', attempt: advisor.attempt + 1, repairs: 0, reason: `${advisor.profile}:${parsed.error}` } });
      return 'next_advisor';
    }
    // The repair was already this step's second chance.
    flows.update(flow.id, (draft) => { draft.advisor = { ...advisor, state: 'failed', reason: chars(parsed.error, 200) }; });
    fail(flow.id, 'design', new Error(parsed.error.replace(/[^a-z0-9_:.-]/gi, '_').slice(0, 80)), { final: true });
    return 'failed';
  }

  // --- design → requirements, packages, decisions ------------------------------

  function applyDesign(flow, design, { from, advisor }) {
    const staffRoles = flow.staff.filter((row) => row.state === 'done').map((row) => row.role);
    const meta = { flowId: flow.id, summary: design.summary, advisedBy: advisor.state === 'done' ? advisor.profile : null, staff: staffRoles };
    const open = (items) => items.map((item) => ({ id: item.id, text: item.text, check: item.check ?? null, status: 'open' }));
    const existing = requirements.list(flow.projectId).filter((item) => item.flowId === flow.id);
    const ids = [];
    design.requirements.forEach((item, index) => {
      if (index === 0) {
        // The owner's words stay as the title; the design adds what "done" means.
        const id = flow.requirementIds[0];
        requirements.update(flow.projectId, id, { ...(item.details ? { details: item.details } : {}), acceptance: open(item.acceptance), design: meta, flowId: flow.id });
        ids.push(id);
        return;
      }
      const found = existing.find((row) => row.title === item.title && row.id !== flow.requirementIds[0]);
      ids.push((found ?? requirements.add(flow.projectId, { title: item.title, details: item.details, source: 'ai', requestId: flow.requestId, flowId: flow.id,
        acceptance: open(item.acceptance), design: meta, reason: '設計で要件を分けました' })).id);
    });
    const packages = design.packages.map((item) => ({
      id: item.id, requirementId: ids[item.requirement], title: item.title, profile: item.profile, requestedProfile: item.requestedProfile ?? null,
      repo: item.repo, owns: item.owns, after: item.after, purpose: item.purpose, completion: item.completion, scope: item.scope,
      verification: item.verification ?? '', prompt: item.prompt, task: null, sessionId: null, state: 'waiting', rework: 0, startedAt: null,
    }));
    const pending = design.ownerDecisions.map((item, index) => ({ key: `design:${index}`, purpose: 'design', packageId: null, id: null, title: item.title,
      summary: item.summary || item.title, options: item.options, recommended: item.recommended, impact: item.impact, answer: null }));
    flows.advance(flow.id, from, 'designed', { advisor, requirementIds: ids, packages, decisions: [...(flow.decisions ?? []), ...pending],
      design: { schema: design.schema, summary: design.summary, risks: design.risks, source: advisor.state === 'done' ? 'advisor' : 'synthesized' }, ...ok },
    { note: `${ids.length} requirement(s), ${packages.length} package(s)` });
  }

  // The board's own limits (title 60, summary 600, label 80, detail 200, impact 200 characters).
  function raiseDecision({ requestId, title, summary, options, recommended, impact, sessionId = null, name = null }) {
    const marked = /^【(?:必ず社長：[^】]+|任せられる)】/u.test(impact ?? '') ? impact : `【任せられる】${impact || '要件フローでの選択'}`;
    const body = { title: chars(title, 60), summary: chars(summary || title, 600), impact: chars(marked, 200), allowOther: true, requestId,
      options: options.map((label, index) => ({ label: chars(label, 80), detail: [...label].length > 80 ? chars(label, 200) : null, recommended: index === recommended })),
      source: { paseoAgentId: null, sessionId, name: name ? chars(name, 200) : null } };
    return decisionStore.add(body).decision;
  }

  function stepDesigned(flow) {
    const pending = flow.decisions.filter((item) => item.purpose === 'design' && !item.id);
    if (pending.length) {
      const made = new Map();
      for (const item of pending) {
        const decision = raiseDecision({ requestId: `${flow.id}:${item.key}`, title: item.title, summary: item.summary, options: item.options,
          recommended: item.recommended, impact: item.impact, name: `要件フロー｜${chars(flow.request.title, 40)}` });
        made.set(item.key, decision.id);
      }
      flows.advance(flow.id, 'designed', 'awaiting_decision', (draft) => {
        for (const item of draft.decisions) if (made.has(item.key)) item.id = made.get(item.key);
        return { resume: 'dispatching', ...ok };
      }, { note: `${pending.length} decision(s)` });
      return;
    }
    flows.advance(flow.id, 'designed', 'dispatching', ok);
  }

  // --- decisions ----------------------------------------------------------------

  function answerText(record) {
    const a = record.answer;
    const who = a.answeredBy === 'monet' ? `Monetが回答しました。理由: ${a.reason}` : record.overturned ? '社長がMonetの回答を変更しました。こちらを優先してください。' : '社長が判断ボードで選びました。';
    return `【判断ボードの回答】「${record.title}」\n選択: ${a.label}${a.note ? `\n補足: ${a.note}` : ''}\n（${who}この判断で作業を続け、最後に返却票で返してください。）`;
  }

  // Record a board answer on the flow and act on it. Idempotent per delivery attempt.
  async function consumeDecision(flow, record) {
    const entry = flow.decisions.find((item) => item.id === record.id);
    if (!entry) return 'stale';
    const answered = record.status === 'answered' && record.answer;
    // A withdrawn design decision falls back to the recommended option.
    const label = answered ? record.answer.label : record.status === 'withdrawn' ? entry.options[entry.recommended] : null;
    if (label === null) return 'open';
    const mark = `${record.id}:${record.delivery?.attempts ?? 0}`;
    if (entry.applied === mark) return 'replayed';
    if (entry.purpose === 'verdict') {
      // The session is waiting on this answer; a withdrawn item continues on the recommended option.
      const pkg = flow.packages.find((item) => item.id === entry.packageId);
      const text = answered ? answerText(record) : `【判断ボード】「${record.title}」は取り下げられました。推奨案「${label}」で作業を続け、最後に返却票で返してください。`;
      if (pkg?.sessionId) await runners.send({ sessionId: pkg.sessionId, messageId: `${mark}:flow`, text });
      if (pkg) requirements.update(flow.projectId, pkg.requirementId, { status: 'in_progress' });
    }
    flows.update(flow.id, (draft) => {
      const item = draft.decisions.find((row) => row.id === record.id);
      Object.assign(item, { answer: label, answeredBy: answered ? record.answer.answeredBy ?? 'owner' : 'withdrawn', applied: mark });
      if (item.purpose === 'verdict') { const pkg = draft.packages.find((row) => row.id === item.packageId); if (pkg && pkg.state === 'blocked') Object.assign(pkg, { state: 'running', resumedAt: stamp() }); }
    });
    const current = flows.get(flow.id);
    if (current.state === 'awaiting_decision' && current.decisions.every((item) => !item.id || item.answer !== null)) {
      flows.advance(flow.id, 'awaiting_decision', current.resume ?? 'verifying', { resume: null, ...ok });
    }
    return 'applied';
  }

  function stepAwaitingDecision(flow) {
    // The scan normally delivers answers as events; this read covers a missed one.
    return Promise.all(flow.decisions.filter((item) => item.id && item.answer === null).map(async (item) => {
      let record = null;
      try { record = decisionStore.get(item.id); } catch { /* Pruned or unreadable: a later tick retries. */ }
      if (record && record.status !== 'open') await consumeDecision(flows.get(flow.id), record);
    }));
  }

  // --- dispatch and verification ---------------------------------------------------

  // A session whose return the transition hook missed (a restart, an observation
  // that changed the phase first) is offered from its stored row, under the same key.
  function reconcileSession(flow, sessionId) {
    const row = sessionId ? sessionStore.get(sessionId) : null;
    if (!row) return;
    const input = sessionEvent({ current: row, reconciled: true, hasOpenDecision: false });
    if (input) offerSession(input, row);
  }

  async function stepActive(flow) {
    const cfg = config();
    for (const pkg of flow.packages) if (pkg.state === 'running') reconcileSession(flow, pkg.sessionId);
    const current = flows.get(flow.id);
    const verified = new Set(current.packages.filter((item) => item.state === 'verified').map((item) => item.id));
    const running = current.packages.filter((item) => PACKAGE_BUSY.includes(item.state)).length;
    const ready = current.packages.find((item) => item.state === 'waiting' && item.after.every((id) => verified.has(id)));
    if (ready && running < cfg.maxRunningPackages) {
      try {
        // The brief is fixed before the first attempt, so a retry sends the same request.
        let task = ready.task;
        if (!task) {
          task = packageTask({ pkg: ready, design: current.design, requirement: requirements.get(current.projectId, ready.requirementId),
            decisions: current.decisions.filter((item) => item.purpose === 'design') });
          flows.setPackage(flow.id, ready.id, (draft) => { draft.task = task; });
        }
        const { sessionId } = await runners.startSession({ requestId: `${flow.id}:${ready.id}`, projectId: current.projectId, requirementId: ready.requirementId,
          profile: ready.profile, name: sessionName('実装', chars(ready.title, 28)), task });
        flows.setPackage(flow.id, ready.id, (draft, whole) => { Object.assign(draft, { sessionId, state: 'running', startedAt: stamp() }); Object.assign(whole, ok); });
      } catch (error) {
        fail(flow.id, `dispatch:${ready.id}`, error);
        return;
      }
    }
    const after = flows.get(flow.id);
    if (!ACTIVE.includes(after.state)) return;
    const next = after.packages.some((item) => item.state === 'waiting') ? 'dispatching' : 'verifying';
    if (next !== after.state) flows.advance(flow.id, after.state, next, {});
  }

  // --- the step loop ------------------------------------------------------------

  async function step(flow) {
    switch (flow.state) {
      case 'intake': return stepIntake(flow);
      case 'expanding': return stepExpanding(flow);
      case 'advising': return stepAdvising(flow);
      case 'designed': return stepDesigned(flow);
      case 'awaiting_decision': return stepAwaitingDecision(flow);
      case 'dispatching': case 'verifying': return stepActive(flow);
      default: return undefined;
    }
  }

  // One step of one flow at a time. A call that arrives while a step is running
  // (a staff consult finishing, an event) asks for one more pass instead of overlapping it.
  const again = new Set();
  async function run(flowId) {
    if (busy.has(flowId)) { again.add(flowId); return; }
    busy.add(flowId);
    try {
      do {
        again.delete(flowId);
        const flow = flows.get(flowId);
        if (!flow || CLOSED_STATES.includes(flow.state)) return;
        if (flow.retryAt && Date.parse(flow.retryAt) > now()) return;
        try { await step(flow); } catch (error) { fail(flowId, 'step', error); }
      } while (again.has(flowId));
    } finally { busy.delete(flowId); again.delete(flowId); }
  }
  const run_ = (flowId) => track(run(flowId));

  // --- inbox feeding ----------------------------------------------------------------

  function findBySession(sessionId) {
    for (const flow of flows.list({ open: true })) {
      if (flow.advisor?.sessionId === sessionId) return { flow, role: 'advisor' };
      const pkg = flow.packages.find((item) => item.sessionId === sessionId);
      if (pkg) return { flow, role: 'package', pkg };
    }
    return null;
  }

  // A flow's session has returned only if the row changed after the flow last set
  // it to work. Without this, a row the sync has not refreshed yet (still showing
  // the turn before a rework or a repair message) would read as a second return.
  const fresh = (row, since) => !since || (Date.parse(row?.attentionTimestamp ?? row?.sourceUpdatedAt ?? row?.updatedAt ?? '') || 0) > Date.parse(since);

  // Decide who consumes a session event and attach what links it to a requirement.
  function offerSession(input, row) {
    const hit = findBySession(input.sessionId);
    const working = hit?.role === 'advisor' ? hit.flow.advisor : hit?.pkg;
    if (working && input.kind === 'session.returned' && !fresh(row, working.resumedAt ?? working.startedAt)) return { event: null, created: false };
    let linked;
    if (hit?.role === 'advisor') linked = { flowId: hit.flow.id, projectId: hit.flow.projectId, handler: 'pipeline', packet: { ...input.packet, role: 'advisor' } };
    else if (hit) linked = { flowId: hit.flow.id, projectId: hit.flow.projectId, packageId: hit.pkg.id, requirementId: hit.pkg.requirementId, handler: 'monet' };
    else {
      const requirement = input.projectId ? requirements.forSession(input.projectId, input.sessionId) : null;
      const verify = requirement || config().inbox.verifyOrigins.includes(input.origin);
      linked = { requirementId: requirement?.id ?? null, handler: verify ? 'monet' : 'digest' };
    }
    const { event, created } = inbox.offer({ ...input, ...linked });
    if (created && hit?.role === 'package') {
      flows.setPackage(hit.flow.id, hit.pkg.id, (draft) => { if (draft.state === 'running') Object.assign(draft, { state: 'returned', returnedAt: stamp() }); });
    }
    return { event, created };
  }

  // Called by the session service for every phase change it sees, any origin.
  function onTransition({ previous, current, child = false, labels = null }) {
    try {
      const hasOpenDecision = decisions?.hasOpen?.(current) ?? false;
      const input = sessionEvent({ previous, current, child, labels, hasOpenDecision });
      if (!input) return null;
      const offered = offerSession(input, current);
      if (offered.created && offered.event.handler === 'pipeline') track(consume());
      return offered.event;
    } catch (error) {
      report('monet_inbox_offer_failed', { code: codeOf(error) });
      return null;
    }
  }

  // The decision board and the findings list, read from their stores so that a
  // record written by the CLI (another process) is seen too.
  function scan() {
    const since = inbox.since();
    const open = flows.list({ open: true });
    const byDecision = new Map(open.flatMap((flow) => flow.decisions.filter((item) => item.id).map((item) => [item.id, { flow, item }])));
    // Decisions an inbox event raised itself: an unverifiable return, or a verdict on a session outside any flow.
    const raised = new Map(inbox.list({ limit: 500 }).filter((event) => event.decisionId && event.kind !== 'decision.answered' && event.kind !== 'decision.opened')
      .map((event) => [event.decisionId, event]));
    const link = (record) => {
      const hit = byDecision.get(record.id);
      if (hit) return { fields: { flowId: hit.flow.id, projectId: hit.flow.projectId, packageId: hit.item.packageId ?? null }, answered: 'pipeline', skipOpen: hit.item.purpose === 'verdict' && hit.item.auto === true };
      const event = raised.get(record.id);
      if (event) return { answered: 'pipeline', skipOpen: event.packet?.autoAnswer === true };
      return null;
    };
    let offered = 0;
    for (const input of decisionEvents(decisionStore.all(), { since, link, offerOpen: config().inbox.offerOpenDecisions })) if (inbox.offer(input).created) offered += 1;
    if (findingStore) for (const input of findingEvents(findingStore.all(), { since })) if (inbox.offer(input).created) offered += 1;
    return offered;
  }

  // Events Bridge code consumes itself: adviser returns and answers to the flow's own decisions.
  let consuming = null;
  function consume() {
    consuming ??= (async () => {
      for (const event of inbox.list({ state: 'new', handler: 'pipeline', limit: 100 })) {
        try {
          let outcome = 'noted';
          if (event.kind.startsWith('session.')) {
            const flow = event.flowId ? flows.get(event.flowId) : null;
            outcome = flow ? await consumeAdvisor(flow, event) : 'stale';
          } else if (event.kind === 'decision.answered') {
            const record = decisionStore.get(event.decisionId);
            const flow = event.flowId ? flows.get(event.flowId) : null;
            if (flow) outcome = await consumeDecision(flow, record);
            else outcome = await consumeRaised(record);
          }
          inbox.ack(event.id, { verdict: 'noted', note: chars(outcome, 80) }, { by: 'bridge' });
          if (event.flowId) await run(event.flowId);
        } catch (error) {
          report('flow_event_failed', { event: event.id, code: codeOf(error) });
          // Leave the event new; it is retried on the next pass, and its flow's failure rule bounds the retries.
          if (event.flowId) fail(event.flowId, `event:${event.kind}`, error);
          if (!event.flowId || CLOSED_STATES.includes(flows.get(event.flowId)?.state)) inbox.fail(event.id, codeOf(error));
        }
      }
    })().finally(() => { consuming = null; });
    return consuming;
  }

  // --- what Monet could not verify ----------------------------------------------------

  const RECHECK = 'もう一度照合する', CLOSE = '記録だけ残して閉じる';
  function raiseUnverified(event) {
    // Asked once per event: a second exhaustion leaves it failed without another board item.
    if (event.packet?.rearmed || event.decisionId) return null;
    const decision = raiseDecision({ requestId: `monet-inbox:${event.id}`, title: 'Monetが照合できなかった返却',
      summary: `「${chars(event.packet?.title ?? event.kind, 80)}」の照合が${event.attempts}回とも完了しませんでした（${event.kind}）。`, options: [RECHECK, CLOSE], recommended: 0,
      impact: '【任せられる】返却の照合が止まっています', sessionId: event.sessionId, name: '要件フロー｜受信箱' });
    inbox.annotate(event.id, { decisionId: decision.id, packet: { unverified: true } });
    return decision.id;
  }
  // The answer to a decision an inbox event raised: re-arm an unverifiable return,
  // or hand the answer to the session whose verdict asked for it.
  async function consumeRaised(record) {
    const event = inbox.list({ limit: 500 }).find((row) => row.decisionId === record.id && !row.kind.startsWith('decision.'));
    if (!event || record.status !== 'answered') return 'stale';
    if (event.packet?.unverified) {
      if (record.answer.label !== RECHECK) return 'closed';
      inbox.annotate(event.id, { packet: { rearmed: true } });
      inbox.rearm(event.id);
      return 'rearmed';
    }
    const sessionId = event.packet?.forwardTo ?? null;
    if (!sessionId || !sessionStore.get(sessionId)) return 'no_session';
    await runners.send({ sessionId, messageId: `${record.id}:answer:${record.delivery.attempts}:flow`, text: answerText(record) });
    if (event.requirementId && event.projectId) requirements.update(event.projectId, event.requirementId, { status: 'in_progress' });
    return 'forwarded';
  }

  // --- Monet's side: claim, verdict, report ----------------------------------------------

  async function packet(event) {
    const session = event.sessionId ? sessionStore.get(event.sessionId) : null;
    const flow = event.flowId ? flows.get(event.flowId) : null;
    const pkg = flow && event.packageId ? flow.packages.find((item) => item.id === event.packageId) ?? null : null;
    const projectId = event.projectId ?? session?.projectId ?? null;
    const requirement = event.requirementId && projectId ? requirements.get(projectId, event.requirementId) : null;
    let lastMessage = null, unavailable = null;
    if (session && event.kind.startsWith('session.')) {
      try { lastMessage = await runners.lastReply(session.id); } catch (error) { unavailable = codeOf(error); }
    }
    const built = packetFor({ event, session, requirement, pkg, lastMessage, unavailable });
    return { ...event, packet: built, prompt: verifyPrompt({ event, packet: built }) };
  }

  async function claim({ limit = 3, caller = null } = {}) {
    await settle({ caller });
    const { events, exhausted } = inbox.claim({ limit });
    const raised = exhausted.map((event) => ({ id: event.id, decisionId: raiseUnverified(event) }));
    return { events: await Promise.all(events.map(packet)), exhausted: raised };
  }

  function requireVerdictTarget(event) {
    if (event.handler !== 'monet') throw conflict('monet_event_not_claimable', 'this event is not verified by Monet');
  }

  async function applyVerdict(eventId, raw, { caller = null } = {}) {
    const event = inbox.get(eventId);
    requireVerdictTarget(event);
    if (event.state === 'acked') return { event, replayed: true };
    if (event.state === 'failed') throw conflict('monet_event_closed', 'the event already failed; re-arm it first');
    let verdict;
    try { verdict = parseVerdict(raw); } catch (error) { throw new BridgeError(422, 'verdict_invalid', `verdict: ${chars(error.message, 80)}`); }
    if (verdict.note !== null && !isOwnerSurface(verdict.note)) throw new BridgeError(422, 'owner_surface_language', 'note: 日本語で入力してください。');
    const iso = stamp();
    const flow = event.flowId ? flows.get(event.flowId) : null;
    const pkg = flow && event.packageId ? flow.packages.find((item) => item.id === event.packageId) ?? null : null;
    const session = event.sessionId ? sessionStore.get(event.sessionId) : null;
    const projectId = event.projectId ?? session?.projectId ?? null;
    const requirement = event.requirementId && projectId ? requirements.get(projectId, event.requirementId) : null;
    const isSession = event.kind.startsWith('session.');
    const merged = () => {
      try { return mergeAcceptance(requirement?.acceptance ?? [], verdict.acceptance, iso); }
      catch (error) { throw new BridgeError(422, 'verdict_acceptance_unknown', `unknown acceptance ids: ${(error.ids ?? []).join(', ')}`); }
    };
    const result = { applied: verdict.verdict };
    let effective = verdict.verdict;
    // A second event for a return that is already verified (one turn seen twice) changes nothing.
    if (isSession && pkg?.state === 'verified') { effective = 'noted'; result.applied = 'superseded'; }

    // A package that has used its rework allowance is not sent back again: it becomes a board item.
    if (effective === 'rework' && pkg && pkg.rework >= config().maxRework) {
      effective = 'needs_owner';
      verdict.decision = { title: '手直しが収束しません', summary: `「${chars(pkg.title, 60)}」は手直しを${pkg.rework}回行っても照合を通りませんでした。${verdict.note ?? ''}`,
        options: ['直す範囲を絞ってもう一度手直しする', 'この作業を止めて要件を見直す'], recommended: 1, impact: '【任せられる】手直しの上限に達しました', auto: false };
      result.escalated = 'rework_limit';
    }

    if (isSession && effective === 'verified') {
      if (requirement) {
        const acceptance = merged();
        // With several packages on one requirement, only the last one's verdict completes it.
        const others = flow && pkg ? flow.packages.filter((item) => item.requirementId === pkg.requirementId && item.id !== pkg.id && item.state !== 'verified') : [];
        const complete = others.length === 0;
        const body = { ...(requirement.acceptance ? { acceptance } : {}), ...(complete ? { status: 'completed', verifiedBy: 'monet', note: verdict.note } : {}) };
        if (Object.keys(body).length) requirements.update(projectId, requirement.id, body, 'monet');
        result.requirement = complete ? 'completed' : 'in_progress';
      }
      if (pkg) flows.setPackage(flow.id, pkg.id, (draft) => Object.assign(draft, { state: 'verified', verifiedAt: iso, note: verdict.note }));
    } else if (isSession && effective === 'rework') {
      if (!session) throw conflict('session_missing', 'the session of this event no longer exists');
      await runners.send({ sessionId: session.id, messageId: `${event.id}:rework`, text: verdict.followup });
      if (requirement?.acceptance && verdict.acceptance.length) requirements.update(projectId, requirement.id, { acceptance: merged() }, 'monet');
      if (pkg) flows.setPackage(flow.id, pkg.id, (draft) => Object.assign(draft, { state: 'running', rework: draft.rework + 1, returnedAt: null, resumedAt: iso }));
    } else if (effective === 'needs_owner') {
      const d = verdict.decision;
      const decision = raiseDecision({ requestId: `${event.id}:decision`, title: d.title, summary: d.summary, options: d.options, recommended: d.recommended, impact: d.impact,
        sessionId: session?.id ?? null, name: session?.name ?? (flow ? `要件フロー｜${chars(flow.request.title, 40)}` : null) });
      result.decisionId = decision.id;
      if (requirement && requirement.status !== 'completed') requirements.update(projectId, requirement.id, { status: 'awaiting_decision' }, 'monet');
      // Monet filed its own recommendation on a choice it may make: that is its answer
      // (AGENTS, 2026-11-28). The owner can still overturn it on the board.
      const auto = d.auto !== false && decision.category === 'delegable' && decision.status === 'open' && Boolean(decisions?.answerAsMonet);
      if (flow && pkg) {
        flows.update(flow.id, (draft) => {
          if (!draft.decisions.some((item) => item.id === decision.id)) {
            draft.decisions.push({ key: `verdict:${event.id}`, purpose: 'verdict', packageId: pkg.id, id: decision.id, title: d.title, options: d.options, recommended: d.recommended, answer: null, auto });
          }
          const row = draft.packages.find((item) => item.id === pkg.id);
          if (row && row.state !== 'verified') row.state = 'blocked';
        });
        flows.advance(flow.id, ACTIVE, 'awaiting_decision', { resume: 'verifying' }, { by: 'monet', note: chars(d.title, 80) });
      } else {
        // Outside a flow the event itself remembers where the answer goes.
        inbox.annotate(event.id, { decisionId: decision.id, projectId, packet: { forwardTo: isSession ? session?.id ?? null : null, autoAnswer: auto } });
      }
      if (auto) {
        const index = decision.options.findIndex((option) => option.recommended);
        await decisions.answerAsMonet({ id: decision.id, body: { optionIndex: Math.max(index, 0) }, reason: chars(`照合時の推奨案です。${verdict.note ?? ''}`.replace(/\s+/gu, ' '), 200) });
        result.answeredBy = 'monet';
      }
    } else if (isSession && pkg && ['noted', 'not_mine'].includes(effective)) {
      // Nothing to verify yet: the session goes on, and its next return is a new event.
      flows.setPackage(flow.id, pkg.id, (draft) => { if (draft.state === 'returned') Object.assign(draft, { state: 'running', resumedAt: iso }); });
    }

    if (verdict.report && flow) flows.update(flow.id, (draft) => { draft.report = verdict.report; });
    const acked = inbox.ack(event.id, { verdict: effective, note: verdict.note, ...(result.decisionId ? { decisionId: result.decisionId } : {}) }, { by: 'monet' });
    if (result.decisionId) { scan(); await consume(); }
    if (flow) await run(flow.id);
    const reports = await settle({ caller });
    return { event: acked.event, replayed: false, ...result, flow: flow ? summary(flows.get(flow.id)) : null, reports };
  }

  // The single report: when every requirement of the flow's request is verified,
  // the existing completion reporter sends one `monet.report` (deduplicated per
  // project and request). It needs the authenticated Monet caller, so it runs
  // inside Monet's own calls (verdict, claim) and never from a timer.
  async function settle({ caller = null } = {}) {
    if (!reporter || !caller) return [];
    const out = [];
    for (const flow of flows.list({ state: 'verifying' })) {
      if (!flow.packages.length || !flow.packages.every((item) => item.state === 'verified')) continue;
      const rows = requirements.list(flow.projectId).filter((item) => flow.requirementIds.includes(item.id));
      if (!rows.length || !rows.every(isVerified)) continue;
      let outcome;
      try { outcome = await reporter({ caller, projectId: flow.projectId, requestId: flow.requestId }); } catch (error) { outcome = { sent: false, reason: codeOf(error) }; }
      const done = outcome.sent || outcome.queued || ['duplicate', 'muted'].includes(outcome.reason);
      if (done) {
        const lines = flow.report ?? { result: `要件${rows.length}件を完了`, verification: chars(rows.map((item) => item.note).filter(Boolean).join(' / '), 200), residual: 'なし' };
        flows.advance(flow.id, 'verifying', 'reported', { reportedAt: stamp(), report: lines, ...ok }, { by: 'monet', note: outcome.reason ?? 'sent' });
      }
      out.push({ flowId: flow.id, reported: done, reason: outcome.reason ?? null });
    }
    return out;
  }

  // --- withdraw, tick, views ----------------------------------------------------------

  async function withdraw(flowId, { withRequirements = false, by = 'monet' } = {}) {
    const flow = flows.get(flowId);
    if (!flow) throw notFound('flow not found');
    if (CLOSED_STATES.includes(flow.state)) return { flow, withdrawn: flow.state === 'withdrawn' };
    const moved = flows.advance(flowId, flow.state, 'withdrawn', { retryAt: null }, { by }).flow;
    const stopped = [];
    const sessionsToStop = [moved.advisor?.state === 'running' ? moved.advisor.sessionId : null, ...moved.packages.filter((item) => PACKAGE_BUSY.includes(item.state)).map((item) => item.sessionId)].filter(Boolean);
    for (const id of sessionsToStop) { try { await runners.stop(id); stopped.push(id); } catch { /* A session that already ended needs no stop. */ } }
    for (const item of moved.decisions) if (item.id && item.answer === null) { try { decisionStore.withdraw(item.id, 'flow_withdrawn', { ifOpen: true }); } catch { /* Already closed. */ } }
    if (withRequirements) for (const id of moved.requirementIds) { try { requirements.withdraw(moved.projectId, id, '要件フローを取下げ'); } catch { /* Already withdrawn. */ } }
    return { flow: flows.get(flowId), withdrawn: true, stopped };
  }

  let ticking = null;
  function tick() {
    ticking ??= (async () => {
      try { scan(); } catch (error) { report('monet_inbox_scan_failed', { code: codeOf(error) }); }
      await consume();
      for (const flow of flows.list({ open: true })) await run(flow.id);
    })().finally(() => { ticking = null; });
    return ticking;
  }

  const summary = (flow) => ({ id: flow.id, state: flow.state, projectId: flow.projectId, requestId: flow.requestId, title: flow.request.title, size: flow.size,
    requirementIds: flow.requirementIds, staff: flow.staff.map((row) => ({ role: row.role, state: row.state })), advisor: flow.advisor ? { profile: flow.advisor.profile, state: flow.advisor.state, sessionId: flow.advisor.sessionId } : null,
    packages: flow.packages.map((item) => ({ id: item.id, title: item.title, profile: item.profile, state: item.state, sessionId: item.sessionId, rework: item.rework })),
    decisions: flow.decisions.map((item) => ({ id: item.id, purpose: item.purpose, title: item.title, answer: item.answer })),
    failure: flow.failure, report: flow.report, createdAt: flow.createdAt, updatedAt: flow.updatedAt, reportedAt: flow.reportedAt });

  return {
    start, tick, run, onTransition, scan, consume, claim, applyVerdict, settle, withdraw, summary,
    // A synthetic return for one session, to exercise the verification path on a real conversation.
    replay(sessionId) {
      const row = sessionStore.get(sessionId);
      if (!row) throw notFound('session not found');
      const input = sessionEvent({ current: { ...row, phase: 'awaiting_review' }, reconciled: true });
      if (!input) throw conflict('session_not_replayable', 'child, routine and archived sessions are not verified');
      const hit = findBySession(sessionId);
      const requirement = !hit && row.projectId ? requirements.forSession(row.projectId, sessionId) : null;
      return inbox.offer({ ...input, key: `${sessionId}:replay:${now()}`, handler: 'monet', flowId: hit?.flow.id ?? null, projectId: hit?.flow.projectId ?? row.projectId ?? null,
        packageId: hit?.pkg?.id ?? null, requirementId: hit?.pkg?.requirementId ?? requirement?.id ?? null }).event;
    },
    digest: () => monetDigest({ events: inbox.list({ limit: 40 }), flows: flows.list() }),
    // Everything started in the background (staff consults, event handling) has finished.
    async idle() { while (background.size || ticking || consuming) await Promise.allSettled([...background, ticking, consuming].filter(Boolean)); },
  };
}

// C-3 → C-2: only a verified owner request and an authenticated Monet trigger
// can enqueue a completion report. The default resolver refuses all callers.
import { isVerifier, projectRequirements, REQUEST_ID_PATTERN, validVerificationNote } from '../routes/project-requirements.mjs';

export const REPORT_KIND = 'monet.report';
const PROJECT_ID = /^prj_[0-9a-f]{12}$/;

const validIso = (v) => typeof v === 'string' && Number.isFinite(Date.parse(v));

// C-3.1/3.2: verified = completed + verifiedAt + verifiedBy (monet | Work session id) + note ≤200.
export function isVerified(req) {
  return req?.status === 'completed' && validIso(req.verifiedAt)
    && isVerifier(req.verifiedBy) && validVerificationNote(req.note);
}

// Open decisions are linked to a project only through their source session (decision records carry no projectId).
// Any open decision from a session of this project suppresses the report; suppression is the safe side.
export function hasPendingDecision({ project, requirements, openDecisions = [], sessions = [] }) {
  if (requirements.some((r) => r.status === 'awaiting_decision')) return true;
  const projectSessions = new Set(sessions.filter((s) => s.projectId === project.id).map((s) => s.id));
  for (const r of requirements) for (const id of r.sessionIds ?? []) projectSessions.add(id);
  const live = sessions.filter((s) => projectSessions.has(s.id) && !s.archivedAt && !s.daemonArchivedAt && !s.daemonDeletedAt);
  const agents = new Set(live.map((s) => s.delegate?.sessionId).filter(Boolean));
  return live.some((s) => s.phase === 'awaiting_decision') || openDecisions.some((d) => d?.status === 'open'
    && (projectSessions.has(d.source?.sessionId) || agents.has(d.source?.paseoAgentId)));
}

// Returns { ready:false, reason } or { ready:true, notification }. Never reads evidence/details/note into the payload.
export function evaluateCompletion({ project, requestId, openDecisions = [], sessions = [] }) {
  if (!project || typeof project !== 'object' || !PROJECT_ID.test(project.id ?? '')) return { ready: false, reason: 'unknown_project' };
  if (project.archivedAt) return { ready: false, reason: 'project_archived' };
  if (typeof requestId !== 'string' || !REQUEST_ID_PATTERN.test(requestId)) return { ready: false, reason: 'invalid_request' };
  const requirements = projectRequirements(project).filter((r) => r.requestId === requestId); // non-withdrawn, same request only
  if (!requirements.length) return { ready: false, reason: 'no_requirements' };
  if (hasPendingDecision({ project, requirements, openDecisions, sessions })) return { ready: false, reason: 'decision_pending' };
  const unverified = requirements.filter((r) => !isVerified(r));
  if (unverified.length) return { ready: false, reason: 'unverified', unverified: unverified.map((r) => r.id) };
  return {
    ready: true,
    notification: {
      kind: REPORT_KIND,
      title: 'Monetの報告',
      body: `「${String(project.name ?? '').slice(0, 60)}」の要件${requirements.length}件をすべて確認しました。`,
      deepLink: `laa://work/projects/${project.id}`,
      dedupeKey: `${REPORT_KIND}:${project.id}:${requestId}`,
      meta: { projectId: project.id, requestId },
    },
  };
}

// Trust is passed in by the authenticated route, never read from the request fields.
export const refuseAllCallers = () => null;

// Seam. `resolveCaller(caller)` must return { kind:'monet' } only for an already-authenticated Monet caller.
// Children / Work sessions / devices / anything else are refused before any store is read.
export function createCompletionReporter({ notify, readProject, readOpenDecisions = () => [], readSessions = () => [], resolveCaller = refuseAllCallers }) {
  if (typeof notify !== 'function' || typeof readProject !== 'function') throw new TypeError('notify and readProject are required');
  return async function trigger({ caller, projectId, requestId } = {}) {
    let identity = null;
    try { identity = await resolveCaller(caller); } catch { identity = null; }
    if (!identity || identity.kind !== 'monet' || identity.parentId) return { sent: false, reason: 'caller_unauthorized' };
    if (typeof projectId !== 'string' || !PROJECT_ID.test(projectId)) return { sent: false, reason: 'unknown_project' };
    const project = await readProject(projectId);
    const verdict = evaluateCompletion({ project, requestId, openDecisions: await readOpenDecisions(), sessions: await readSessions() });
    if (!verdict.ready) return { sent: false, reason: verdict.reason, ...(verdict.unverified ? { unverified: verdict.unverified } : {}) };
    const result = await notify(verdict.notification);
    return { sent: result.delivered === true, reason: result.reason ?? null, queued: result.queued === true, dedupeKey: verdict.notification.dedupeKey };
  };
}

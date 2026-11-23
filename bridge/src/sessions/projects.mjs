import { DEFAULT_PROJECT_ID } from '../routes/projects.mjs';
import { changeRequirement, projectRequirements } from '../routes/project-requirements.mjs';
import { badRequest, conflict, notFound } from '../errors.mjs';

export function resolveProject(projects, target) {
  if (typeof target !== 'string' || !target.trim() || target.length > 100) {
    throw badRequest('project_required', 'specify a project ID or name');
  }
  const name = target.trim().replace(/\s+/g, ' ');
  const matches = /^prj_[0-9a-f]{12}$/.test(name) ? [projects.get(name)].filter(Boolean)
    : projects.list().filter((item) => item.name === name && !item.archivedAt);
  if (matches.length > 1) throw conflict('project_ambiguous', 'several projects have that name; use the ID');
  if (!matches.length) throw notFound('project not found');
  return matches[0];
}

// Serialize moves and requirement edits on the project lock, then take the
// session lock. Directory imports take only the session lock.
export function assignSessionProject({ projects, sessionStore, projectId, sessionId, requirementId = null }) {
  return projects.mutate((all) => {
    const target = all[projectId];
    if (!target) throw notFound('project not found');
    if (target.archivedAt) throw conflict('project_archived', 'choose an active project');
    const now = projects.now;
    return sessionStore.moveProject(sessionId, projectId, ({ root, moving, rows }) => {
      for (const old of new Set(moving.map((row) => row.projectId ?? DEFAULT_PROJECT_ID))) {
        if (old === projectId) continue;
        const linked = projectRequirements(all[old] ?? {}).some((req) => req.sessionIds.some((id) => rows.has(id)));
        if (linked) throw conflict('session_linked_to_requirement', 'unlink the session from the old project’s requirements before moving it');
      }
      if (requirementId) {
        const iso = new Date(now()).toISOString();
        const membership = new Map(sessionStore.all().map((row) => [row.id, row.projectId ?? DEFAULT_PROJECT_ID]));
        if (changeRequirement(target, { action: 'attach', id: requirementId, body: { sessionId: root.id }, iso,
          belongs: (id) => rows.has(id) || membership.get(id) === projectId })) {
          target.version += 1;
          target.updatedAt = iso;
        }
      }
    });
  });
}

export function projectSessionViews(sessionStore, projectId, openDecisions = []) {
  const sessionIds = new Set(openDecisions.map((row) => row.source?.sessionId).filter(Boolean));
  const agentIds = new Set(openDecisions.map((row) => row.source?.paseoAgentId).filter(Boolean));
  return sessionStore.all().filter((row) => row.projectId === projectId && !row.daemonDeletedAt && !row.routine).map((row) => {
    const archivedAt = row.archivedAt ?? row.daemonArchivedAt ?? null;
    const status = archivedAt || row.phase === 'closed' ? 'completed'
      : row.phase === 'awaiting_decision' || sessionIds.has(row.id) || agentIds.has(row.delegate?.sessionId) ? 'awaiting_decision'
      : ['running', 'created'].includes(row.phase) ? 'running' : 'waiting';
    return { id: row.id, name: row.name, status, model: row.observed?.model ?? row.requested?.model ?? null,
      updatedAt: row.sourceUpdatedAt ?? row.updatedAt, parentId: row.parentId ?? null, archivedAt };
  }).sort((a, b) => (b.updatedAt ?? '').localeCompare(a.updatedAt ?? '') || a.id.localeCompare(b.id));
}

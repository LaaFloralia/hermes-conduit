// The flow's access to a Project's requirements: the same locked records and
// validators the HTTP routes use (changeRequirement), written as the flow's own
// authors — `bridge` for the pipeline, `monet` for an applied verdict.

import { changeRequirement, projectRequirements } from '../routes/project-requirements.mjs';
import { conflict, notFound } from '../errors.mjs';

export function createFlowRequirements({ projects, now = () => Date.now() }) {
  function change(projectId, action, { id = null, body, author }) {
    const iso = new Date(now()).toISOString();
    return projects.mutate((all) => {
      const record = all[projectId];
      if (!record) throw notFound('project not found');
      if (record.archivedAt) throw conflict('project_archived', 'restore the project before changing requirements');
      const before = new Set((record.requirements ?? []).map((item) => item.id));
      if (changeRequirement(record, { action, id, body, iso, author, belongs: () => true })) {
        record.version = (record.version ?? 1) + 1;
        record.updatedAt = iso;
      }
      const row = action === 'add' ? record.requirements.find((item) => !before.has(item.id)) : record.requirements.find((item) => item.id === id);
      return structuredClone(row ?? null);
    });
  }
  const list = (projectId) => { const project = projects.get(projectId); return project ? projectRequirements(project) : []; };
  return {
    list,
    get: (projectId, id) => list(projectId).find((item) => item.id === id) ?? null,
    // The requirement a session is linked to, if any.
    forSession(projectId, sessionId) {
      return list(projectId).find((item) => (item.sessionIds ?? []).includes(sessionId)) ?? null;
    },
    add: (projectId, body, author = 'bridge') => change(projectId, 'add', { body, author }),
    update: (projectId, id, body, author = 'bridge') => change(projectId, 'update', { id, body, author }),
    withdraw: (projectId, id, reason, author = 'bridge') => change(projectId, 'withdraw', { id, body: { reason }, author }),
  };
}

// Merge a verdict's item results into a requirement's acceptance list. Returns
// the new list, or throws with the ids the verdict named but the requirement lacks.
export function mergeAcceptance(current = [], results = [], iso) {
  const known = new Set(current.map((item) => item.id));
  const unknown = results.filter((item) => !known.has(item.id)).map((item) => item.id);
  if (unknown.length) { const error = new Error('verdict_acceptance_unknown'); error.ids = unknown; throw error; }
  const byId = new Map(results.map((item) => [item.id, item]));
  return current.map((item) => {
    const result = byId.get(item.id);
    return result ? { ...item, status: result.status, note: result.note ?? null, checkedAt: iso } : item;
  });
}

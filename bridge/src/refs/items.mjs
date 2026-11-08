// Kind-shaped rows handed to the registry. Titles only: a task description, a
// session prompt or a skill body must never reach refs.json.

export function taskRefItem(task) {
  return {
    key: String(task.id).toLowerCase(),
    title: task.title,
    external: { linear: task.identifier ?? null, url: task.url ?? null },
  };
}

export function sessionRefItem(record, refFor) {
  const external = { paseoAgentId: record.delegate?.sessionId ?? null };
  if (record.parentId && typeof refFor === 'function') {
    const parentRef = refFor('session', record.parentId);
    if (parentRef) external.parentRef = parentRef;
  }
  return { key: record.id, title: record.name, createdAt: record.createdAt, external };
}

export function projectRefItem(project) {
  return { key: project.id, title: project.name, createdAt: project.createdAt, external: {} };
}

export function routineRefItem(routine) {
  return { key: routine.id, title: routine.name, external: {} };
}

// The same skill installed for Claude and Hermes is one skill: the frontmatter
// name, lowercased, is the key and both sources are recorded on one ref.
export function skillRefItems(rows) {
  const byKey = new Map();
  for (const row of rows) {
    const title = typeof row?.name === 'string' ? row.name.trim() : '';
    const key = title.toLowerCase();
    if (key === '') continue;
    const entry = byKey.get(key) ?? { key, title, sources: new Set() };
    if (typeof row.source === 'string' && row.source !== '') entry.sources.add(row.source);
    byKey.set(key, entry);
  }
  return [...byKey.values()].map((entry) => ({
    key: entry.key,
    title: entry.title,
    external: { sources: [...entry.sources].sort() },
  }));
}

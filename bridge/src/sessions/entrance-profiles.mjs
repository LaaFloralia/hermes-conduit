// A Work entrance's route: `work` once Paseo is gone, `paseo` in entries written before.
export function workRoute(entry) {
  if (entry?.kind === 'work') return entry.work ?? null;
  if (entry?.kind === 'paseo') return entry.paseo ?? null;
  return null;
}

// Owner switches use named Work entrances and explicit HQ manual choices. Keep the older launch catalog
// and its automatic default separate; a profile by itself is not an entrance.
export function entranceProfiles(table, profiles) {
  const expand = (text) => typeof text === 'string' ? text.replace(/\{\{id:([^{}]+)\}\}/g,
    (written, key) => table.models?.[key]?.modelId ?? written) : text;
  return profiles.filter((profile) => (table.dispatch?.manual_profiles ?? []).includes(profile.id) || (table.entrances ?? []).some((entry) => {
    const route = workRoute(entry);
    return route && ['active', 'manual'].includes(entry.status)
      && route.provider === profile.provider
      && expand(route.model) === profile.model
      && (route.thinking == null || route.thinking === profile.effort);
  }));
}

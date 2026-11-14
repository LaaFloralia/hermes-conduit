// Owner switches use named Work entrances and explicit HQ manual choices. Keep the older launch catalog
// and its automatic default separate; a profile by itself is not an entrance.
export function entranceProfiles(table, profiles) {
  const expand = (text) => typeof text === 'string' ? text.replace(/\{\{id:([^{}]+)\}\}/g,
    (written, key) => table.models?.[key]?.modelId ?? written) : text;
  return profiles.filter((profile) => (table.dispatch?.manual_profiles ?? []).includes(profile.id) || (table.entrances ?? []).some((entry) =>
    entry.kind === 'paseo' && ['active', 'manual'].includes(entry.status)
      && entry.paseo?.provider === profile.provider
      && expand(entry.paseo?.model) === profile.model
      && (entry.paseo.thinking == null || entry.paseo.thinking === profile.effort)));
}

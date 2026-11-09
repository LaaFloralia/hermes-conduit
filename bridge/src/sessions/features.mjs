// Paseo reports provider features (Fast) with the value the provider is
// actually using. Claude exposes a `fast_mode` toggle; Codex exposes a
// `service_tier` select whose `default` option is the normal speed. Everything
// here reads those shapes; nothing is derived from the Bridge's own request.

export function fastOption(feature) {
  const options = Array.isArray(feature?.options) ? feature.options : [];
  return options.find((option) => typeof option?.label === 'string' && /^fast$/i.test(option.label.trim())) ?? null;
}

// Absent or unrecognised means unknown (null): never report "Fast is off" for a
// provider that does not say.
export function fastValue(features) {
  if (!Array.isArray(features)) return null;
  const toggle = features.find((feature) => feature?.id === 'fast_mode');
  if (toggle && typeof toggle.value === 'boolean') return toggle.value;
  const select = features.find((feature) => feature?.id === 'service_tier');
  if (!select) return null;
  const value = select.value;
  if (typeof value !== 'string') return null;
  if (value === 'default') return false;
  const fast = fastOption(select);
  return fast && fast.id === value ? true : null;
}

// Whether the provider offers a Fast setting at all. `undefined` means the read
// carried no feature list, so the caller keeps what it last confirmed.
export function fastAvailable(features) {
  if (!Array.isArray(features)) return undefined;
  if (features.some((feature) => feature?.id === 'fast_mode')) return true;
  const select = features.find((feature) => feature?.id === 'service_tier');
  return select !== undefined && fastOption(select) !== null;
}

// The provider call that turns Fast on or off: the toggle takes the boolean,
// the select takes the Fast option id or `default`. Null means the provider has
// no Fast setting to change.
export function fastTarget(features) {
  const list = Array.isArray(features) ? features : [];
  if (list.some((feature) => feature?.id === 'fast_mode')) return { featureId: 'fast_mode' };
  const select = list.find((feature) => feature?.id === 'service_tier');
  const option = fastOption(select);
  return option ? { featureId: 'service_tier', fastId: option.id } : null;
}

// Brain areas, read from the same policy.json the `laa-brain` search CLI uses
// (hq/tools/BRAIN-SEARCH.md). The Bridge keeps no area list of its own: a note
// the CLI would not search must not appear in the Bridge's list either, and a
// restricted area (old, Inbox, Sources, Journal, Trading research/reviews,
// Attachments, Templates) stays out unless the request names it.
//
// Classification mirrors laa_brain.py `zone_of`: paths are compared in NFC,
// the longest matching prefix wins, a non-default area's README.md is the
// searchable guide, and a top-level file belongs to the root area.

import { readFileSync } from 'node:fs';

export class PolicyError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'PolicyError';
    this.code = code;
  }
}

function zone(raw, { guide = true } = {}) {
  return {
    zone: String(raw.zone),
    label: String(raw.label ?? raw.zone),
    default: Boolean(raw.default),
    jev: Boolean(raw.jev),
    guide: Boolean(raw.guide ?? guide),
    prefix: raw.prefix === undefined ? '' : String(raw.prefix).normalize('NFC'),
  };
}

export function loadPolicy(file, { readFile = readFileSync } = {}) {
  let raw;
  try {
    raw = JSON.parse(readFile(file, 'utf8'));
  } catch (err) {
    throw new PolicyError('policy_unavailable', `cannot read Brain policy ${file}: ${err.code ?? 'invalid'}`);
  }
  if (!raw || !Array.isArray(raw.zones)) {
    throw new PolicyError('policy_corrupt', `Brain policy has no zones: ${file}`);
  }
  return {
    file,
    root: typeof raw.root === 'string' ? raw.root : null,
    excludeDirs: Array.isArray(raw.exclude_dirs) ? raw.exclude_dirs.map(String) : [],
    // Longest prefix first, exactly like the CLI.
    zones: raw.zones.map((entry) => zone(entry)).sort((a, b) => b.prefix.length - a.prefix.length),
    rootZone: zone(raw.root_zone ?? { zone: 'root', label: 'root', default: true, jev: true }),
    guideZone: zone(raw.guide_zone ?? { zone: 'guide', label: 'guide', default: true, jev: true }),
    unclassifiedZone: zone(raw.unclassified_zone ?? { zone: 'unclassified', label: 'unclassified', default: false, jev: false }),
  };
}

export function allZones(policy) {
  const out = new Map();
  for (const entry of [policy.rootZone, policy.guideZone, ...policy.zones, policy.unclassifiedZone]) {
    if (!out.has(entry.zone)) out.set(entry.zone, entry);
  }
  return out;
}

export function defaultAreas(policy) {
  return [...allZones(policy).values()].filter((entry) => entry.default).map((entry) => entry.zone);
}

export function optionalAreas(policy) {
  return [...allZones(policy).values()].filter((entry) => !entry.default).map((entry) => entry.zone).sort();
}

export function zoneOf(policy, relPath) {
  const rel = String(relPath).normalize('NFC');
  if (!rel.includes('/')) return policy.rootZone;
  for (const entry of policy.zones) {
    if (rel.startsWith(entry.prefix)) {
      if (!entry.default && entry.guide && rel === `${entry.prefix}README.md`) return policy.guideZone;
      return entry;
    }
  }
  return policy.unclassifiedZone;
}

// Requested area names are validated against the policy, so a typo cannot
// silently widen or narrow what the device is allowed to see.
export function resolveAreas(policy, requested = []) {
  const known = allZones(policy);
  const extra = new Set();
  const unknown = [];
  for (const raw of requested) {
    const name = String(raw ?? '').trim().toLowerCase();
    if (name === '') continue;
    if (known.has(name)) extra.add(name);
    else unknown.push(name);
  }
  return {
    allowed: [...new Set([...defaultAreas(policy), ...extra])].sort(),
    unknown: [...new Set(unknown)].sort(),
    optional: optionalAreas(policy),
  };
}

export function isAreaAllowed(area, allowed) {
  return allowed.includes(area);
}

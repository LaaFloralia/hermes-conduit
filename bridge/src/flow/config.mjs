// Reads the requirement flow's routing. The file next to this module is the
// shipped default; an HQ file (hq/harness/requirement-flow.json, or the path in
// LAA_BRIDGE_FLOW_CONFIG) overrides it key by key, so the adviser or an
// implementation model is switched by configuration. The file is re-read when
// it changes; a broken override is ignored (the defaults keep the flow running)
// and reported through `problems`.

import { readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const DEFAULT_FILE = join(dirname(fileURLToPath(import.meta.url)), 'requirement-flow.json');
const PROFILE = /^[a-z0-9][a-z0-9._-]{0,62}$/;
// Routes the owner retired (2026-11-28): GPT in every form and Devin as a default.
// A profile that names one is refused wherever it appears in this configuration.
const RETIRED = /^(?:astra|sol|luna|terra|gpt|codex|swe|devin|pi-openai)/;
export const SIZES = ['S', 'M', 'L'];
export const RISKS = ['money', 'auth', 'delete', 'external_send', 'architecture', 'trade'];

export function resolveFlowConfigFile(env = process.env) {
  return env.LAA_BRIDGE_FLOW_CONFIG || join(homedir(), 'hq', 'harness', 'requirement-flow.json');
}

const isObject = (value) => Boolean(value) && typeof value === 'object' && !Array.isArray(value);
function merge(base, over) {
  if (!isObject(base) || !isObject(over)) return over === undefined ? base : over;
  const out = { ...base };
  for (const [key, value] of Object.entries(over)) out[key] = merge(base[key], value);
  return out;
}

// Returns a normalized config or throws an Error whose message is a short code.
export function validateFlowConfig(raw) {
  if (!isObject(raw)) throw new Error('config_not_object');
  const usable = (profile) => typeof profile === 'string' && PROFILE.test(profile) && !RETIRED.test(profile);
  if (!Array.isArray(raw.advisorProfiles) || !raw.advisorProfiles.length) throw new Error('advisorProfiles_required');
  const advisorProfiles = raw.advisorProfiles.map((entry) => {
    const item = typeof entry === 'string' ? { profile: entry, enabled: true } : entry;
    if (!isObject(item) || !usable(item.profile)) throw new Error('advisorProfile_invalid');
    const enabled = item.enabled !== false;
    // An option that is switched off must say why, so nobody presents it as working.
    if (!enabled && (typeof item.reason !== 'string' || !item.reason.trim())) throw new Error(`advisorProfile_${item.profile}_reason_required`);
    return { profile: item.profile, enabled, reason: enabled ? null : item.reason.trim() };
  });
  if (!advisorProfiles.some((item) => item.enabled)) throw new Error('advisorProfiles_none_enabled');
  const impl = raw.implementation ?? {};
  const allowedProfiles = Array.isArray(impl.allowedProfiles) ? impl.allowedProfiles : [];
  if (!allowedProfiles.length || !allowedProfiles.every(usable)) throw new Error('implementation_allowedProfiles_invalid');
  if (!allowedProfiles.includes(impl.defaultProfile)) throw new Error('implementation_defaultProfile_invalid');
  const when = raw.advisorWhen ?? {};
  if (!SIZES.includes(when.minSize) || !Array.isArray(when.risk) || !when.risk.every((risk) => RISKS.includes(risk))) throw new Error('advisorWhen_invalid');
  const int = (value, field, min, max) => { if (!Number.isInteger(value) || value < min || value > max) throw new Error(`${field}_invalid`); return value; };
  const staff = raw.staff ?? {};
  const inbox = raw.inbox ?? {};
  return {
    advisorProfiles,
    advisorWhen: { minSize: when.minSize, risk: [...when.risk] },
    implementation: { defaultProfile: impl.defaultProfile, allowedProfiles: [...allowedProfiles] },
    session: { mode: raw.session?.mode === 'default' ? 'default' : 'bypass' },
    staff: {
      max: int(staff.max ?? 4, 'staff_max', 1, 4), min: int(staff.min ?? 2, 'staff_min', 1, 4),
      timeoutMs: int(staff.timeoutMs ?? 180_000, 'staff_timeoutMs', 1000, 900_000),
      outputLimitBytes: int(staff.outputLimitBytes ?? 65_536, 'staff_outputLimitBytes', 1024, 1_048_576),
      hermesBin: typeof staff.hermesBin === 'string' && staff.hermesBin.startsWith('/') ? staff.hermesBin : null,
      toolsets: typeof staff.toolsets === 'string' && staff.toolsets ? staff.toolsets : null,
      rosterFile: typeof staff.rosterFile === 'string' && staff.rosterFile.startsWith('/') ? staff.rosterFile : join(homedir(), 'hq', 'roles', 'roster.yaml'),
    },
    maxRunningPackages: int(raw.maxRunningPackages ?? 3, 'maxRunningPackages', 1, 8),
    maxRework: int(raw.maxRework ?? 2, 'maxRework', 0, 5),
    tickMs: int(raw.tickMs ?? 15_000, 'tickMs', 1000, 600_000),
    retryMs: int(raw.retryMs ?? 30_000, 'retryMs', 0, 3_600_000),
    inbox: {
      leaseMs: int(inbox.leaseMs ?? 600_000, 'inbox_leaseMs', 1000, 86_400_000),
      maxAttempts: int(inbox.maxAttempts ?? 3, 'inbox_maxAttempts', 1, 10),
      verifyOrigins: Array.isArray(inbox.verifyOrigins) ? inbox.verifyOrigins.filter((origin) => typeof origin === 'string') : [],
      offerOpenDecisions: inbox.offerOpenDecisions !== false,
    },
    verifier: isObject(raw.verifier) ? { ...raw.verifier } : {},
  };
}

function readJson(file) {
  return JSON.parse(readFileSync(file, 'utf8'));
}

export function loadFlowConfig({ file = resolveFlowConfigFile(), defaults = DEFAULT_FILE } = {}) {
  const base = readJson(defaults);
  const problems = [];
  let merged = base;
  let override = null;
  try { override = readJson(file); } catch (error) { if (error.code !== 'ENOENT') problems.push('override_unreadable'); }
  if (override) {
    try { validateFlowConfig(merge(base, override)); merged = merge(base, override); } catch (error) { problems.push(`override_ignored:${error.message}`); }
  }
  return { ...validateFlowConfig(merged), problems, source: override && !problems.length ? file : defaults };
}

// A reader that reloads when either file's mtime changes.
export function flowConfigReader(options = {}) {
  const file = options.file ?? resolveFlowConfigFile();
  let cached = null, mark = '';
  const mtime = (path) => { try { return statSync(path).mtimeMs; } catch { return 0; } };
  return () => {
    const next = `${mtime(file)}:${mtime(options.defaults ?? DEFAULT_FILE)}`;
    if (!cached || next !== mark) { cached = loadFlowConfig({ ...options, file }); mark = next; }
    return cached;
  };
}

// The adviser to use now: the first enabled entry. `after` skips to the next
// one when a profile could not start a session.
export function pickAdvisor(config, { after = null } = {}) {
  const enabled = config.advisorProfiles.filter((item) => item.enabled).map((item) => item.profile);
  if (after === null) return enabled[0] ?? null;
  const index = enabled.indexOf(after);
  return index >= 0 ? enabled[index + 1] ?? null : enabled[0] ?? null;
}

export function needsAdvisor(config, { size, risk = [] }) {
  return SIZES.indexOf(size) >= SIZES.indexOf(config.advisorWhen.minSize) || risk.some((item) => config.advisorWhen.risk.includes(item));
}

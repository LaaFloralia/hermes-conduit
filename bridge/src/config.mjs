// Static configuration for the LAA Bridge. Values that an operator or a test
// needs to change come from the environment; everything else is fixed here.

import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));

export const BRIDGE_DIR = resolve(here, '..');
export const VERSION = JSON.parse(readFileSync(join(BRIDGE_DIR, 'package.json'), 'utf8')).version;

// Loopback only. The tailnet reaches the service through Tailscale Serve
// (see scripts/tailscale-serve-add.sh); nothing binds a LAN or tailnet address.
export const HOST = '127.0.0.1';
export const DEFAULT_PORT = 9137;

export const BODY_LIMIT_BYTES = 64 * 1024;
export const PAIRING_TTL_MS = 10 * 60 * 1000;
export const IDEMPOTENCY_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;
export const IDEMPOTENCY_INFLIGHT_GRACE_MS = 60 * 1000;

// BRIDGE.md section 9: the owner's device starts with these and nothing else.
// brain:write, gui:operate, archives:restore and devices:admin stay ungranted
// until their own gates are met.
export const SCOPE_GROUPS = {
  'sessions:*': ['sessions:read', 'sessions:write', 'sessions:reply'],
  'tasks:*': ['tasks:read', 'tasks:write'],
};

export const DEFAULT_SCOPES = Object.freeze([
  ...SCOPE_GROUPS['sessions:*'],
  ...SCOPE_GROUPS['tasks:*'],
  'brain:read',
  'media:read',
  'photos:select',
  'usage:read',
  'archives:read',
  'archives:create',
]);

export const STUDIO_SCOPES = Object.freeze(['studio:read', 'studio:request']);

// The only scopes an operator may add to an enrolled device with
// `laa-bridge grant`. All are opt-in and independent of the default set:
// `calendar:read`/`calendar:write` and `media:write` reach the owner's Google
// account, `brain:create` creates new Brain notes without touching existing
// ones, and `brain:owner` permits the owner's UI to browse all non-hidden notes
// without invoking models.
export const OPERATOR_GRANT_SCOPES = Object.freeze(['brain:create', 'brain:owner', 'calendar:read', 'calendar:write', 'media:write', 'voice:transcribe']);

// `brain:create` (new files only) is deliberately NOT in DEFAULT_SCOPES: BRIDGE
// §9 fixes the initial grant set, and docs/laa/BRAIN-WRITE.md §7 only establishes
// that creating a new path is safe, not that every device should be granted it.
// It stays opt-in per device: `laa-bridge pair --scopes brain:read,brain:create`.
export const ALL_SCOPES = Object.freeze([
  ...DEFAULT_SCOPES,
  // Voice is opt-in per device and never part of the default grant. A device
  // gets it only when an operator pairs it with `--scopes voice:polish` or
  // `--scopes voice:transcribe`. Adding the names here makes that grant
  // possible; devices that already exist keep the scopes they were paired with.
  'voice:polish',
  'voice:transcribe',
  ...STUDIO_SCOPES,
  'calendar:read',
  'calendar:write',
  'media:write',
  'brain:create',
  'brain:owner',
  'instructions:read',
  'instructions:write',
  'brain:write',
  'gui:operate',
  'archives:restore',
  'devices:admin',
]);

export function defaultStateDir() {
  return join(homedir(), '.local', 'state', 'laa-bridge');
}

export function resolveStateDir(env = process.env) {
  return env.LAA_BRIDGE_STATE_DIR ? resolve(env.LAA_BRIDGE_STATE_DIR) : defaultStateDir();
}

export function resolvePort(env = process.env) {
  const raw = env.LAA_BRIDGE_PORT;
  if (raw === undefined || raw === '') return DEFAULT_PORT;
  const port = Number(raw);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`LAA_BRIDGE_PORT is not a valid port: ${raw}`);
  }
  return port;
}

export function testEndpointsEnabled(env = process.env) {
  return env.LAA_BRIDGE_TEST_ENDPOINTS === '1';
}

// --- voice -----------------------------------------------------------------
//
// One polish request is one short utterance: 4,000 characters is far beyond a
// dictation and still bounds the model's prompt and the response body.
export const VOICE_POLISH_MAX_CHARS = 4000;

// One transcribe request carries at most 25 s of 16 kHz mono PCM16LE audio:
// 16,000 samples/s x 2 bytes x 25 s. The base64 body is ~1.07 MB, so the route
// raises the HTTP limit instead of accepting a truncated recording.
export const VOICE_TRANSCRIBE_SAMPLE_RATE = 16_000;
export const VOICE_TRANSCRIBE_MAX_SECONDS = 25;
export const VOICE_TRANSCRIBE_MAX_BYTES = VOICE_TRANSCRIBE_SAMPLE_RATE * 2 * VOICE_TRANSCRIBE_MAX_SECONDS;
export const VOICE_TRANSCRIBE_BODY_LIMIT_BYTES = 1_200_000;

// The worker holds the model in its own process and loads it on the first
// request of a child. A dictation after speech recognition pays that load
// again, so warm requests also allow loading. The client allows 135 s,
// covering the cold budget and network margin.
export const VOICE_REQUEST_TIMEOUT_MS = 90_000;
export const VOICE_COLD_TIMEOUT_MS = 120_000;

// Absolute path to the voice worker. Empty means the feature is off and both
// routes answer 503: installing the worker is an explicit deployment step, not
// something a running Bridge discovers on its own.
export function resolveVoiceWorkerPath(env = process.env) {
  const raw = env.LAA_VOICE_WORKER;
  if (typeof raw !== 'string' || raw.trim() === '') return '';
  return resolve(raw.trim());
}

// Expands "sessions:*" style groups and rejects unknown names. Used by the CLI
// so a typo can never silently narrow or widen a device's grant.
export function expandScopes(names) {
  const out = new Set();
  for (const raw of names) {
    const name = raw.trim();
    if (name === '') continue;
    if (SCOPE_GROUPS[name]) {
      for (const scope of SCOPE_GROUPS[name]) out.add(scope);
      continue;
    }
    if (!ALL_SCOPES.includes(name)) {
      throw new Error(`unknown scope: ${name}`);
    }
    out.add(name);
  }
  return [...out].sort();
}

// Workspace roots the Bridge may inventory and create worktrees under. A path
// outside these roots is refused even though the process could read it, so a
// device cannot turn the Bridge into a filesystem browser.
export const DEFAULT_WORKSPACE_ROOTS = Object.freeze([
  join(homedir(), 'dev'),
  join(homedir(), '.paseo', 'worktrees'),
]);

export function resolveWorkspaceRoots(env = process.env) {
  const raw = env.LAA_BRIDGE_WORKSPACE_ROOTS;
  const values = raw === undefined || raw.trim() === ''
    ? [...DEFAULT_WORKSPACE_ROOTS]
    : raw.split(/[:,]/).map((value) => value.trim()).filter((value) => value !== '');
  return values.map((value) => resolve(value));
}

// The Paseo CLI lives outside launchd's minimal PATH, and its shebang runs
// `node` through env. Resolve the binary once and prepend the running Node's
// bin directory when the adapter spawns it (see workspaces.mjs).
export function resolvePaseoBin(env = process.env) {
  if (env.LAA_BRIDGE_PASEO_BIN) return env.LAA_BRIDGE_PASEO_BIN;
  for (const candidate of ['/opt/homebrew/bin/paseo', '/usr/local/bin/paseo']) {
    if (existsSync(candidate)) return candidate;
  }
  return 'paseo';
}

// --- Brain (ROADMAP 25, docs/laa/BRAIN-WRITE.md) ---------------------------
//
// Everything below points at material that already exists on this Mac: the
// Syncthing vault, the area policy owned by the `laa-brain` search CLI, and that
// CLI itself. The Bridge keeps no copy of the Brain and no extra credential; it
// reads the Syncthing API key out of Syncthing's own config file for the gate
// query only (§4-2) and never logs or returns it.

export function resolveBrainRoot(env = process.env) {
  return resolve(env.LAA_BRIDGE_BRAIN_ROOT || join(homedir(), 'Brain'));
}

// The installed plugin checkout is what `laa-brain` itself reads
// (~/.local/share/laa-plugins/dev-main/laa-jev/brain/policy.json).
export function resolveBrainPolicyPath(env = process.env) {
  return resolve(env.LAA_BRIDGE_BRAIN_POLICY
    || join(homedir(), '.local', 'share', 'laa-plugins', 'dev-main', 'laa-jev', 'brain', 'policy.json'));
}

export function resolveBrainSearchBin(env = process.env) {
  return resolve(env.LAA_BRIDGE_BRAIN_SEARCH_BIN || join(homedir(), '.local', 'bin', 'laa-brain'));
}

// New notes are only created under these vault-relative prefixes. The default is
// the vault's own convention for new notes (Obsidian `newFileFolderPath`), so a
// phone can add material without being able to edit existing knowledge.
export function resolveBrainCreatePrefixes(env = process.env) {
  const raw = env.LAA_BRIDGE_BRAIN_CREATE_PREFIXES;
  const values = raw === undefined || raw.trim() === ''
    ? ['Inbox/']
    : raw.split(',').map((value) => value.trim()).filter((value) => value !== '');
  return values.map((value) => (value.endsWith('/') ? value : `${value}/`));
}

export function resolveSyncthingConfigPath(env = process.env) {
  return resolve(env.LAA_BRIDGE_BRAIN_SYNCTHING_CONFIG
    || join(homedir(), 'Library', 'Application Support', 'Syncthing', 'config.xml'));
}

export function resolveSyncthingUrl(env = process.env) {
  return (env.LAA_BRIDGE_BRAIN_SYNCTHING_URL || 'http://127.0.0.1:8384').replace(/\/+$/, '');
}

export function resolveBrainFolderId(env = process.env) {
  return env.LAA_BRIDGE_BRAIN_FOLDER || 'brain';
}

// --- Usage and Mac status (ROADMAP 09, docs/laa/USAGE.md) -------------------
//
// Both sources already exist on this Mac and are read, not started: the
// CodexBar usage proxy on loopback, and the status file the daily
// `laa-storage-guard` launchd job writes. The Bridge never runs the guard's
// full scan and never adds a credential for the dashboard (USAGE.md §6).

export function resolveUsageFeedUrl(env = process.env) {
  return env.LAA_BRIDGE_USAGE_FEED_URL || 'http://127.0.0.1:8081/widget';
}

// USAGE.md §4: live/local readings go stale after at most 10 minutes.
export function resolveUsageAutoStaleMs(env = process.env) {
  const raw = env.LAA_BRIDGE_USAGE_AUTO_STALE_MS;
  if (raw === undefined || raw === '') return 10 * 60 * 1000;
  const value = Number(raw);
  return Number.isFinite(value) && value > 0 ? Math.min(value, 10 * 60 * 1000) : 10 * 60 * 1000;
}

// The proxy answers from its own 30 s upstream budget; the Bridge caps the wait
// so a slow CodexBar never holds the app. The existing Console collector also
// uses 5 s. Raise it only to diagnose the proxy.
export function resolveUsageFeedTimeoutMs(env = process.env) {
  const raw = env.LAA_BRIDGE_USAGE_FEED_TIMEOUT_MS;
  if (raw === undefined || raw === '') return 5000;
  const value = Number(raw);
  return Number.isFinite(value) && value >= 100 && value <= 60000 ? value : 5000;
}

// The read that missed the cap above keeps running up to this bound, so the next
// request can answer from that same attempt instead of starting another one.
export function resolveUsageRefreshTimeoutMs(env = process.env) {
  const raw = env.LAA_BRIDGE_USAGE_REFRESH_TIMEOUT_MS;
  if (raw === undefined || raw === '') return 30000;
  const value = Number(raw);
  return Number.isFinite(value) && value >= 1000 && value <= 60000 ? value : 30000;
}

export function resolveStorageStatusFile(env = process.env) {
  return resolve(env.LAA_BRIDGE_STORAGE_STATUS
    || join(homedir(), '.local', 'state', 'laa-storage-guard', 'status.json'));
}

// Static configuration for the LAA Bridge. Values that an operator or a test
// needs to change come from the environment; everything else is fixed here.

import { readFileSync } from 'node:fs';
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

export const ALL_SCOPES = Object.freeze([
  ...DEFAULT_SCOPES,
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

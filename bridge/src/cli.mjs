#!/usr/bin/env node
// `laa-bridge` operator CLI: pair, devices, revoke, status, serve, version.
//
// Pairing codes are printed to this terminal only. They are never written to a
// log, never passed as an argument to another process, and never sent to a
// model: the state file keeps the hash, this process prints the plaintext once.

import { spawn } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  DEFAULT_SCOPES,
  IDEMPOTENCY_RETENTION_MS,
  PAIRING_TTL_MS,
  VERSION,
  resolvePort,
  resolveStateDir,
  expandScopes,
} from './config.mjs';
import { createStore } from './store.mjs';
import { issuePairing, revokeDevice } from './pairing.mjs';

const here = dirname(fileURLToPath(import.meta.url));

const USAGE = `laa-bridge ${VERSION}

Usage:
  laa-bridge serve                         run the HTTP service (used by launchd)
  laa-bridge pair [options]                issue a one-time pairing code (10 minutes)
      --name <name>       device name recorded on the Mac (default: iPhone)
      --scopes <list>     comma list or groups (default: BRIDGE.md section 9 set)
      --ttl-minutes <n>   code lifetime (default 10, max 60)
      --json              machine-readable output
  laa-bridge devices [--json]              list paired devices
  laa-bridge revoke <device-id|prefix>     revoke one device (--reason <text>)
  laa-bridge status [--json]               local health check of the running service
  laa-bridge version

State directory: ${resolveStateDir()} (override with LAA_BRIDGE_STATE_DIR)
Loopback port:   ${resolvePort()} (override with LAA_BRIDGE_PORT)
`;

function fail(message, code = 1) {
  process.stderr.write(`laa-bridge: ${message}\n`);
  process.exit(code);
}

function parseArgs(argv) {
  const positional = [];
  const flags = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg.startsWith('--')) {
      const name = arg.slice(2);
      if (['json'].includes(name)) {
        flags[name] = true;
        continue;
      }
      const value = argv[i + 1];
      if (value === undefined || value.startsWith('--')) fail(`missing value for --${name}`, 2);
      flags[name] = value;
      i += 1;
      continue;
    }
    positional.push(arg);
  }
  return { positional, flags };
}

function openStore() {
  return createStore({ dir: resolveStateDir(), idempotencyRetentionMs: IDEMPOTENCY_RETENTION_MS });
}

function commandPair(flags) {
  const name = (flags.name ?? 'iPhone').trim();
  if (name.length === 0 || name.length > 64) fail('--name must be 1-64 characters', 2);
  const scopes = flags.scopes ? expandScopes(flags.scopes.split(',')) : [...DEFAULT_SCOPES];
  if (scopes.length === 0) fail('--scopes must grant at least one scope', 2);
  const ttlMinutes = flags['ttl-minutes'] === undefined ? 10 : Number(flags['ttl-minutes']);
  if (!Number.isFinite(ttlMinutes) || ttlMinutes <= 0 || ttlMinutes > 60) fail('--ttl-minutes must be 1-60', 2);

  const { code, expiresAt } = issuePairing(openStore(), {
    name,
    scopes,
    ttlMs: Math.round(ttlMinutes * 60 * 1000),
  });

  if (flags.json) {
    process.stdout.write(`${JSON.stringify({ code, name, scopes, expiresAt: new Date(expiresAt).toISOString() })}\n`);
    return;
  }
  process.stdout.write([
    '',
    `  Pairing code : ${code}`,
    `  Device name  : ${name}`,
    `  Expires      : ${new Date(expiresAt).toISOString()} (${ttlMinutes} minutes)`,
    `  Scopes       : ${scopes.join(', ')}`,
    '',
    '  Enter the code in the LAA app (or the app\'s pairing screen) now.',
    '  It works once, is stored only as a hash, and is not written to any log.',
    '',
  ].join('\n'));
}

function commandDevices(flags) {
  const state = openStore().read();
  const devices = Object.values(state.devices).sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  if (flags.json) {
    process.stdout.write(`${JSON.stringify(devices.map((d) => ({
      id: d.id,
      name: d.name,
      scopes: d.scopes,
      platform: d.platform,
      createdAt: d.createdAt,
      status: d.revokedAt ? 'revoked' : 'active',
      revokedAt: d.revokedAt,
    })))}\n`);
    return;
  }
  if (devices.length === 0) {
    process.stdout.write('No devices paired. Run `laa-bridge pair`.\n');
    return;
  }
  for (const device of devices) {
    process.stdout.write([
      `${device.id}  ${device.revokedAt ? 'revoked' : 'active '}  ${device.name}`,
      `  created ${device.createdAt}${device.revokedAt ? `  revoked ${device.revokedAt}` : ''}`,
      `  scopes  ${device.scopes.join(', ')}`,
    ].join('\n') + '\n');
  }
}

function commandRevoke(positional, flags) {
  const target = positional[0];
  if (!target) fail('revoke needs a device id (or an unambiguous prefix of 4+ characters)', 2);
  const result = revokeDevice(openStore(), { target, reason: flags.reason });

  if (result.error) fail(result.error);
  if (flags.json) {
    process.stdout.write(`${JSON.stringify({
      deviceId: result.device.id,
      name: result.device.name,
      status: 'revoked',
      alreadyRevoked: result.alreadyRevoked,
      revokedAt: result.device.revokedAt,
    })}\n`);
    return;
  }
  process.stdout.write(
    result.alreadyRevoked
      ? `${result.device.id} (${result.device.name}) was already revoked at ${result.device.revokedAt}.\n`
      : `Revoked ${result.device.id} (${result.device.name}). Its token is rejected from the next request on.\n`,
  );
}

async function commandStatus(flags) {
  const port = resolvePort();
  const url = `http://127.0.0.1:${port}/v1/health`;
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(3000) });
    const body = await response.json();
    if (flags.json) {
      process.stdout.write(`${JSON.stringify({ reachable: true, port, status: response.status, ...body.data })}\n`);
      return;
    }
    process.stdout.write(`reachable on 127.0.0.1:${port}  version ${body.data.version}  uptime ${body.data.uptimeSeconds}s\n`);
  } catch (err) {
    if (flags.json) {
      process.stdout.write(`${JSON.stringify({ reachable: false, port, error: err?.code ?? err?.name ?? 'unreachable' })}\n`);
      process.exit(1);
    }
    fail(`not reachable on 127.0.0.1:${port} (${err?.cause?.code ?? err?.name ?? 'error'})`);
  }
}

function commandServe() {
  const child = spawn(process.execPath, [join(here, 'main.mjs')], { stdio: 'inherit', env: process.env });
  child.on('exit', (code, signal) => process.exit(code ?? (signal ? 1 : 0)));
}

const { positional, flags } = parseArgs(process.argv.slice(2));
const command = positional.shift();

switch (command) {
  case 'serve':
    commandServe();
    break;
  case 'pair':
    commandPair(flags);
    break;
  case 'devices':
    commandDevices(flags);
    break;
  case 'revoke':
    commandRevoke(positional, flags);
    break;
  case 'status':
    await commandStatus(flags);
    break;
  case 'version':
    process.stdout.write(`${VERSION}\n`);
    break;
  case undefined:
  case 'help':
  case '--help':
    process.stdout.write(USAGE);
    break;
  default:
    fail(`unknown command: ${command}\n\n${USAGE}`, 2);
}

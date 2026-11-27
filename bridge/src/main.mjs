#!/usr/bin/env node
// Entry point used by launchd: reads the environment, opens the state store and
// serves the loopback listener until SIGTERM.

import { homedir } from 'node:os';
import { join } from 'node:path';
import {
  HOST,
  IDEMPOTENCY_RETENTION_MS,
  VERSION,
  VOICE_COLD_TIMEOUT_MS,
  VOICE_REQUEST_TIMEOUT_MS,
  resolvePort,
  resolveStateDir,
  resolveVoiceWorkerPath,
  testEndpointsEnabled,
} from './config.mjs';
import { laneEnabled, validateLane } from './lane/guard.mjs';

let bridge;
let voiceWorker;
let stopWorkReports = () => {};
const isLane = laneEnabled();
try {
  const port = resolvePort();
  const stateDir = resolveStateDir();
  // Static ESM imports run before this point. Keep the HTTP graph (all
  // routes/adapters) and state store behind the startup boundary.
  validateLane(process.env, { stateDir, port });
  const [{ createStore }, { createBridge }] = await Promise.all([import('./store.mjs'), import('./http.mjs')]);
  const startWorkReports = isLane ? null : (await import('./routines/work-reports.mjs')).startWorkReports;
  const store = createStore({ dir: stateDir, idempotencyRetentionMs: IDEMPOTENCY_RETENTION_MS });

  // Voice stays off unless the operator names the worker binary, and a lane
  // never constructs the production worker.
  const voiceWorkerPath = isLane ? '' : resolveVoiceWorkerPath();
  voiceWorker = voiceWorkerPath === '' ? null : (await import('./voice/worker.mjs')).createVoiceWorker({
    command: voiceWorkerPath,
    requestTimeoutMs: VOICE_REQUEST_TIMEOUT_MS,
    coldTimeoutMs: VOICE_COLD_TIMEOUT_MS,
  });
  // Fail before listening if the state file is unreadable or corrupt: serving
  // with a lost device or ledger row would be worse than being down.
  store.read();
  bridge = createBridge({
    store,
    version: VERSION,
    testEndpoints: testEndpointsEnabled(),
    routeOptions: {
      sessions: { live: true }, voice: { worker: voiceWorker },
      supervisorFile: isLane ? null : join(homedir(), '.local', 'state', 'laa-orchestrate', 'supervisor-status.json'),
    },
  });
  const address = await bridge.listen({ port, host: HOST });
  if (startWorkReports) {
    stopWorkReports = startWorkReports({ stateDir, log: (event) => process.stderr.write(JSON.stringify({ event }) + '\n') });
  }
  process.stdout.write(`${JSON.stringify({
    event: 'listening',
    version: VERSION,
    host: HOST,
    port: address.port,
    pid: process.pid,
    stateDir,
    testEndpoints: testEndpointsEnabled(),
  })}\n`);
} catch (err) {
  process.stderr.write(`${JSON.stringify({
    event: 'fatal',
    version: VERSION,
    code: err?.code ?? 'startup_failed',
    message: err?.message ?? String(err),
  })}\n`);
  process.exit(1);
}

let shuttingDown = false;
async function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  process.stdout.write(`${JSON.stringify({ event: 'shutdown', signal })}\n`);
  try {
    stopWorkReports();
    await bridge.close();
    await voiceWorker?.stop();
  } finally {
    process.exit(0);
  }
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

#!/usr/bin/env node
// Entry point used by launchd: reads the environment, opens the state store and
// serves the loopback listener until SIGTERM.

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
import { createStore } from './store.mjs';
import { createBridge } from './http.mjs';
import { createVoiceWorker } from './voice/worker.mjs';

const port = resolvePort();
const stateDir = resolveStateDir();
const store = createStore({ dir: stateDir, idempotencyRetentionMs: IDEMPOTENCY_RETENTION_MS });

// Voice stays off unless the operator names the worker binary. The Bridge
// starts it on the first request and never passes the transcript or the audio
// as an argument: both go over the child's stdin only.
const voiceWorkerPath = resolveVoiceWorkerPath();
const voiceWorker = voiceWorkerPath === '' ? null : createVoiceWorker({
  command: voiceWorkerPath,
  requestTimeoutMs: VOICE_REQUEST_TIMEOUT_MS,
  coldTimeoutMs: VOICE_COLD_TIMEOUT_MS,
});

let bridge;
try {
  // Fail before listening if the state file is unreadable or corrupt: serving
  // with a lost device or ledger row would be worse than being down.
  store.read();
  bridge = createBridge({
    store,
    version: VERSION,
    testEndpoints: testEndpointsEnabled(),
    routeOptions: { sessions: { live: true }, voice: { worker: voiceWorker } },
  });
  const address = await bridge.listen({ port, host: HOST });
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
    await bridge.close();
    await voiceWorker?.stop();
  } finally {
    process.exit(0);
  }
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

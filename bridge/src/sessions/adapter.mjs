// Adapter for the existing Mac delegation path: `laa-personal-agent`
// (hq/harness/personal_agent_bridge.mjs).
//
// The Bridge deliberately goes through that CLI instead of the Paseo SDK: the
// wrapper already owns request idempotency (`origin` + `requestId`), verifies
// that the running agent still uses the requested provider/model/effort, and
// refuses to send into a stopped or waiting session. Re-implementing those
// rules here would duplicate the contract the owner's Ciel path already uses.
//
// The CLI reads one JSON object on stdin and writes one JSON object on stdout.
// Failures still print `{"ok":false,"error":"<code>"}` (exit code 1), so the
// process exit is not the error signal. Nothing from stderr or the payload is
// echoed to clients: only mapped Bridge errors leave this module.

import { spawn } from 'node:child_process';
import { existsSync, realpathSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { BridgeError } from '../errors.mjs';

export const DELEGATION_ORIGIN = 'laa-bridge';
const OUTPUT_LIMIT = 1024 * 1024;

// code -> [status, bridge code, retryable]
const ERROR_MAP = new Map(Object.entries({
  profile_required: [400, 'payload_invalid'],
  unsupported_profile: [400, 'profile_unsupported'],
  profile_alias_cycle: [400, 'profile_unsupported'],
  dsh_model_mapping_ambiguous: [400, 'profile_unsupported'],
  absolute_cwd_required: [400, 'payload_invalid'],
  task_required: [400, 'payload_invalid'],
  task_purpose_required: [400, 'payload_invalid'],
  task_completion_required: [400, 'payload_invalid'],
  task_scope_required: [400, 'payload_invalid'],
  task_returnTo_required: [400, 'payload_invalid'],
  task_prompt_required: [400, 'payload_invalid'],
  text_required: [400, 'payload_invalid'],
  message_id_required: [400, 'payload_invalid'],
  request_id_required: [400, 'payload_invalid'],
  origin_required: [400, 'payload_invalid'],
  invalid_json: [400, 'payload_invalid'],
  json_object_required: [400, 'payload_invalid'],
  input_oversize: [400, 'payload_too_large'],
  invalid_wait_seconds: [400, 'payload_invalid'],
  unknown_operation: [400, 'payload_invalid'],
  duplicate_request_conflict: [409, 'request_id_conflict'],
  creation_key_conflict: [409, 'request_id_conflict'],
  creation_outcome_unknown: [409, 'creation_outcome_unknown', true],
  send_delivery_unknown: [409, 'send_outcome_unknown', true],
  duplicate_message_conflict: [409, 'message_id_conflict'],
  model_effort_mismatch: [409, 'model_effort_mismatch'],
  session_stopped: [409, 'session_stopped'],
  session_not_idle: [409, 'session_busy'],
  session_message_limit: [409, 'message_limit_reached'],
  pending_decision_requires_reply: [409, 'pending_decision_requires_reply'],
  stop_unconfirmed: [409, 'stop_unconfirmed', true],
  owned_session_not_found: [503, 'delegation_session_missing'],
  session_not_owned: [503, 'delegation_session_missing'],
  session_identity_mismatch: [503, 'delegation_inconsistent'],
  caller_context_unavailable: [503, 'delegation_unavailable', true],
  worker_reply_forbidden: [403, 'worker_reply_forbidden'],
  operation_failed: [503, 'delegation_failed', true],
}));

export function delegationError(code) {
  const entry = ERROR_MAP.get(code);
  if (!entry) {
    return new BridgeError(503, 'delegation_failed', 'the delegation path returned an unrecognised error', { retryable: true });
  }
  const [status, bridgeCode, retryable = false] = entry;
  return new BridgeError(status, bridgeCode, `the delegation path reported ${code}`, { retryable });
}

export function resolvePersonalAgentBin(env = process.env) {
  if (env.LAA_BRIDGE_PERSONAL_AGENT_BIN) return env.LAA_BRIDGE_PERSONAL_AGENT_BIN;
  return join(homedir(), '.local', 'bin', 'laa-personal-agent');
}

// The default launcher is a symlink to an .mjs script whose shebang needs
// `node`; launchd's PATH has no node, so run the script with the current
// interpreter explicitly.
function commandFor(bin) {
  let script = bin;
  try {
    script = realpathSync(bin);
  } catch {
    // Let spawn report the missing binary.
  }
  return script.endsWith('.mjs') ? { command: process.execPath, prefix: [script] } : { command: bin, prefix: [] };
}

export function runCli({ bin, input, timeoutMs }) {
  return new Promise((resolvePromise, reject) => {
    if (!existsSync(bin)) {
      reject(new BridgeError(503, 'delegation_unavailable', 'laa-personal-agent is not installed', { retryable: true }));
      return;
    }
    const { command, prefix } = commandFor(bin);
    const child = spawn(command, [...prefix], {
      stdio: ['pipe', 'pipe', 'pipe'],
      env: { ...process.env, HOME: process.env.HOME },
    });
    let stdout = '';
    let stderr = '';
    let settled = false;
    const finish = (fn) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      fn();
    };
    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      finish(() => reject(new BridgeError(503, 'delegation_timeout', 'laa-personal-agent did not answer in time', { retryable: true })));
    }, timeoutMs);
    child.on('error', (err) => finish(() => reject(new BridgeError(503, 'delegation_unavailable', `laa-personal-agent could not start: ${err.code ?? 'spawn_failed'}`, { retryable: true }))));
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
      if (Buffer.byteLength(stdout) > OUTPUT_LIMIT) {
        child.kill('SIGKILL');
        finish(() => reject(new BridgeError(503, 'delegation_failed', 'laa-personal-agent returned too much output', { retryable: true })));
      }
    });
    child.stderr.on('data', (chunk) => {
      // Kept only to keep the pipe drained; never logged or returned.
      if (stderr.length < OUTPUT_LIMIT) stderr += chunk;
    });
    child.on('close', () => finish(() => resolvePromise({ stdout, stderr })));
    child.stdin.on('error', () => {});
    child.stdin.end(`${JSON.stringify(input)}\n`);
  });
}

export function personalAgentAdapter({
  bin = resolvePersonalAgentBin(),
  origin = DELEGATION_ORIGIN,
  run = runCli,
  timeoutMs = { create: 60_000, status: 30_000, send: 30_000, stop: 30_000 },
} = {}) {
  async function call(op, payload) {
    const { stdout } = await run({ bin, input: { op, origin, ...payload }, timeoutMs: timeoutMs[op] ?? 30_000 });
    const lines = stdout.trim().split('\n').filter((line) => line !== '');
    let parsed;
    try {
      parsed = JSON.parse(lines[lines.length - 1] ?? '');
    } catch {
      throw new BridgeError(503, 'delegation_failed', 'laa-personal-agent returned no JSON result', { retryable: true });
    }
    if (parsed?.ok !== true) throw delegationError(parsed?.error ?? 'operation_failed');
    return parsed;
  }

  return {
    origin,
    create({ requestId, profile, cwd, task }) {
      return call('create', { requestId, profile, cwd, task });
    },
    status({ requestId }) {
      return call('status', { requestId });
    },
    send({ requestId, messageId, text }) {
      return call('send', { requestId, messageId, text });
    },
    stop({ requestId }) {
      return call('stop', { requestId });
    },
    list() {
      return call('list', {});
    },
  };
}

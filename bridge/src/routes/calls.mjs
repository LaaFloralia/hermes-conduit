// Which engine an AI-employee call runs on. The choice lives on this Mac so
// the apps switch engines without a rebuild: they read it before each call.
//
//   local_live   The host's speech server hears and speaks, and the turn runs
//                in the employee's own Hermes chat. No external voice model.
//   gemini_live  Gemini Live over WebSocket. The key stays on the Hermes host,
//                which mints a single-use ephemeral token per connection; the
//                apps never hold it. Off until the contract and the key exist.
//
// This route returns configuration only. It never reads a secret: the key
// check looks for the *reference line* in the Hermes host's env template
// (an `op://` pointer resolved at run time by op-run-batch), not its value.
// Whether the host can actually mint a token is the Hermes plugin's status
// (`/api/plugins/conduit_push/gemini-live/status`), which the app asks next.

import { readFile, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { lanePath } from '../lane/guard.mjs';

export const CALL_ENGINES = Object.freeze(['gemini_live', 'local_live']);
// Gemini first once it is switched on; Local Live is what answers until then.
export const DEFAULT_CALL_ENGINE_ORDER = Object.freeze(['gemini_live', 'local_live']);

const WAITING_FOR_CONTRACT = Object.freeze({
  code: 'waiting_for_contract',
  reason: 'waiting for the Google AI Ultra contract / Gemini API key',
  reasonJa: 'Google AI Ultraの契約とGemini APIキーを待っています',
});
const KEY_REFERENCE_MISSING = Object.freeze({
  code: 'key_reference_missing',
  reason: 'gemini_live is switched on, but the Hermes host env template has no GEMINI_API_KEY reference',
  reasonJa: 'Gemini Liveは有効ですが、HermesホストにGemini APIキーの参照がありません',
});
const SWITCHED_OFF = Object.freeze({
  code: 'switched_off',
  reason: 'switched off in the staff call engine file',
  reasonJa: '設定で無効になっています',
});

// Only the key's name and that something follows it. The value is an `op://`
// reference in this template, and it is never returned or logged either way.
const KEY_REFERENCE = /^[ \t]*(?:export[ \t]+)?(?:GEMINI_API_KEY|GOOGLE_API_KEY)[ \t]*=[ \t]*\S/m;
const MAX_CONFIG_BYTES = 16 * 1024;
const MAX_TEMPLATE_BYTES = 64 * 1024;

const defaultConfigFile = () => join(homedir(), '.config/laa/staff-call-engine.json');
const defaultHermesEnvFile = () => join(homedir(), '.config/laa/hermes-personal.env.tpl');

// A malformed or partial file changes only what it states clearly: an unknown
// engine name is dropped, a missing one keeps its place in the default order.
export function resolveCallEngines(config, { keyReference = false } = {}) {
  const stated = config !== null && typeof config === 'object' && !Array.isArray(config) ? config : {};
  const listed = Array.isArray(stated.order)
    ? stated.order.filter((name, index, all) => CALL_ENGINES.includes(name) && all.indexOf(name) === index)
    : [];
  const order = [...listed, ...DEFAULT_CALL_ENGINE_ORDER.filter((name) => !listed.includes(name))];
  const flag = (name) => (stated[name] !== null && typeof stated[name] === 'object' ? stated[name].enabled : undefined);

  const engines = {};
  // Local Live needs nothing outside this Mac: on unless the file says off.
  engines.local_live = flag('local_live') === false ? { enabled: false, ...SWITCHED_OFF } : { enabled: true };
  // Gemini Live is on only when the file says so *and* the key reference
  // exists. Absent, null or malformed all read as "not switched on yet".
  if (flag('gemini_live') !== true) engines.gemini_live = { enabled: false, ...WAITING_FOR_CONTRACT };
  else if (!keyReference) engines.gemini_live = { enabled: false, ...KEY_REFERENCE_MISSING };
  else engines.gemini_live = { enabled: true };

  return { engine: order.find((name) => engines[name].enabled) ?? null, order, engines };
}

async function readBounded(file, limit) {
  const info = await stat(file);
  if (!info.isFile() || info.size > limit) throw new Error('unreadable');
  return readFile(file, 'utf8');
}

export function callEngineRoutes({
  file = process.env.LAA_STAFF_CALL_ENGINE_FILE,
  hermesEnvFile = process.env.LAA_HERMES_ENV_TEMPLATE,
  log,
  lane,
} = {}) {
  // A lab lane reads only inside its own root, never the owner's live files.
  const inLane = (path, name, edge) => (lane ? lanePath(lane.root, path || join(lane.root, name), edge) : path);
  async function read() {
    let config = null;
    let source = 'default';
    try {
      const path = inLane(file, 'staff-call-engine.json', 'LAA_STAFF_CALL_ENGINE_FILE') || defaultConfigFile();
      config = JSON.parse(await readBounded(path, MAX_CONFIG_BYTES));
      source = 'file';
    } catch (error) {
      // No file is the normal state before the switch; anything else is worth a line.
      if (error?.code !== 'ENOENT') log?.({ level: 'warn', event: 'staff_call_engine_unreadable' });
    }
    let keyReference = false;
    try {
      const path = inLane(hermesEnvFile, 'hermes-personal.env.tpl', 'LAA_HERMES_ENV_TEMPLATE') || defaultHermesEnvFile();
      keyReference = KEY_REFERENCE.test(await readBounded(path, MAX_TEMPLATE_BYTES));
    } catch { /* No template reads as no key reference. */ }
    return { ...resolveCallEngines(config, { keyReference }), source };
  }
  return [{
    method: 'GET', path: '/v1/calls/engine', auth: true, scope: 'sessions:read',
    handler: async () => ({ status: 200, data: await read() }),
  }];
}

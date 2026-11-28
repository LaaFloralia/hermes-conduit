import { lstatSync, readdirSync, realpathSync } from 'node:fs';
import { homedir, userInfo } from 'node:os';
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { BridgeError } from '../errors.mjs';

export const LANE_HEADER = 'x-laa-lane';
export const laneEnabled = (env = process.env) => env.LAA_LANE_ID !== undefined;
export const productionStateDir = () => join(userInfo().homedir, '.local/state/laa-bridge');
export const PRODUCTION_PORTS = Object.freeze([9137, 9119, 8443, 8444, 8445, 8384, 8081]);

export function laneMissing(edge) {
  return new BridgeError(503, 'lane_adapter_missing', `${edge}: no external adapter in a lab lane`);
}

function invalid(edge, reason) {
  throw new BridgeError(503, 'lane_config_unsafe', `${edge}: ${reason}`);
}

function within(root, path) {
  const suffix = relative(root, path);
  return suffix !== '..' && !suffix.startsWith(`..${sep}`) && !isAbsolute(suffix);
}

// Check missing leaves through their nearest existing parent, but reject a
// broken symlink instead of treating it as a missing leaf.
function canonical(path) {
  try { return realpathSync(path); }
  catch (error) {
    if (!['ENOENT', 'ENOTDIR'].includes(error.code)) throw error;
    try { lstatSync(path); } catch (missing) {
      if (['ENOENT', 'ENOTDIR'].includes(missing.code) && dirname(path) !== path) {
        return join(canonical(dirname(path)), basename(path));
      }
      throw missing;
    }
    throw error;
  }
}

// A custom scratch parent must not cause the launcher to create its private
// directory inside one of the accounts it is meant to isolate.
export function assertLaneParent(path) {
  const real = canonical(path);
  const home = userInfo().homedir;
  const forbidden = [productionStateDir(), ...['.local/state/laa-work', '.local/share/laa-work',
    '.local/share/hermes-agent', '.hermes', '.paseo', 'Brain', 'Library/Application Support'].map((name) => join(home, name))];
  if (forbidden.some((dir) => within(canonical(dir), real))) {
    invalid('LAA_LANE_PARENT', 'lane must not be inside production state');
  }
  return real;
}

export function lanePath(root, path, edge) {
  if (typeof path !== 'string' || !isAbsolute(path)) invalid(edge, 'requires an absolute path inside the lane root');
  let real;
  try { real = canonical(resolve(path)); } catch { invalid(edge, 'cannot resolve path safely'); }
  if (!within(canonical(root), real)) invalid(edge, 'path escapes the lane root');
  return real;
}

function rootFor(env) {
  const root = env.LAA_LANE_ROOT;
  if (!root || !isAbsolute(root)) invalid('LAA_LANE_ROOT', 'requires an absolute private lane directory');
  let stat;
  try { stat = lstatSync(root); } catch { invalid('LAA_LANE_ROOT', 'lane root does not exist'); }
  if (!stat.isDirectory() || stat.uid !== process.getuid() || (stat.mode & 0o077) !== 0) {
    invalid('LAA_LANE_ROOT', 'requires a real, owner-only lane directory');
  }
  const real = realpathSync(root);
  if (!/^laa-lane-[A-Za-z0-9]{6}$/.test(basename(real)) || within(real, canonical(userInfo().homedir))) {
    invalid('LAA_LANE_ROOT', 'requires a dedicated mkdtemp lane, not an account home or production state');
  }
  assertLaneParent(real);
  return resolve(root);
}

export function assertTestStateDir(dir, env = process.env, files = [join(dir, 'state.json'), join(dir, 'state.lock')]) {
  if (!laneEnabled(env) && env.NODE_TEST_CONTEXT === undefined) return;
  const paths = [dir, ...files];
  for (const home of [userInfo().homedir, homedir()]) {
    const live = join(home, '.local/state/laa-bridge');
    if (paths.some((path) => within(resolve(live), resolve(path)) || within(canonical(live), canonical(resolve(path))))) {
      invalid('LAA_BRIDGE_STATE_DIR', 'production state is forbidden in tests');
    }
  }
  if (laneEnabled(env)) {
    const root = rootFor(env);
    for (const path of paths) lanePath(root, path, 'LAA_BRIDGE_STATE_DIR');
  }
}

const ADAPTER_ENV = /^(?:LAA_(?:BRIDGE_|GOOGLE_|LINEAR_|OWNER_TASKS_|CAMPAIGN_|PHONE_USE_|VOICE_|WORK_|SESSION_NAMING_|USAGE_UI_REAL_STATE$)|PASEO_|APNS_)/;
const ALLOWED = new Set(['LAA_BRIDGE_STATE_DIR', 'LAA_BRIDGE_PORT', 'LAA_BRIDGE_BRAIN_ROOT',
  'LAA_BRIDGE_QUIET', 'LAA_BRIDGE_TEST_ENDPOINTS', 'LAA_WORK_SOCKET']);

/// Whether a lane must refuse this env key: a wiring override, not a path or a port.
/// Exported so a test that builds a lane inside an agent's environment can clear
/// exactly what `validateLane` refuses instead of repeating the pattern.
export function isAdapterEnvKey(key) {
  return ADAPTER_ENV.test(key) && !ALLOWED.has(key);
}

export function validateLane(env, { stateDir, port }) {
  if (!laneEnabled(env)) return null;
  const id = env.LAA_LANE_ID;
  if (!/^[A-Za-z0-9_-]{1,96}$/.test(id)) invalid('LAA_LANE_ID', 'invalid lane id');
  const root = rootFor(env);
  for (const [edge, path] of Object.entries({
    HOME: env.HOME, TMPDIR: env.TMPDIR, LAA_BRIDGE_STATE_DIR: stateDir,
    LAA_BRIDGE_BRAIN_ROOT: env.LAA_BRIDGE_BRAIN_ROOT,
  })) lanePath(root, path, edge);
  assertTestStateDir(stateDir, env);
  if (!Number.isInteger(port) || port < 0 || port > 65535 || PRODUCTION_PORTS.includes(port)) {
    invalid('LAA_BRIDGE_PORT', 'requires a non-production loopback port');
  }
  // No env-supplied adapters, not even an in-root executable: wiring is fixed.
  for (const key of Object.keys(env)) {
    if (isAdapterEnvKey(key)) invalid(key, 'adapter override is not permitted in a lane');
  }
  const work = env.LAA_WORK_SOCKET === undefined ? null : lanePath(root, env.LAA_WORK_SOCKET, 'LAA_WORK_SOCKET');
  if (work !== null && work !== join(realpathSync(root), 'w.sock')) invalid('LAA_WORK_SOCKET', 'must be the lane engine socket');
  const sink = lanePath(root, join(root, 'sink'), 'notification sink');
  const client = work === null ? null : lanePath(root, join(root, 'runtime/client/engine-client.mjs'), 'Work client');
  // Do not follow pre-existing redirects, device files or hard links in a
  // reused lane. Launcher roots are private and freshly created.
  for (const dir of [env.HOME, stateDir, env.LAA_BRIDGE_BRAIN_ROOT, env.TMPDIR, sink, ...(client ? [join(root, 'runtime')] : [])]) {
    function check(path) {
      let stat;
      try { stat = lstatSync(path); } catch (error) { if (error.code === 'ENOENT') return; throw error; }
      if (stat.isDirectory()) for (const name of readdirSync(path)) check(join(path, name));
      else if (!stat.isFile() || stat.nlink !== 1) invalid(dir === stateDir ? 'LAA_BRIDGE_STATE_DIR' : basename(dir), 'links and special files are forbidden');
    }
    check(dir);
  }
  return { id, root, work, client, sink, home: env.HOME, brain: env.LAA_BRIDGE_BRAIN_ROOT };
}

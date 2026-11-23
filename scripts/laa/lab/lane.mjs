#!/usr/bin/env node
import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { chmodSync, closeSync, copyFileSync, cpSync, existsSync, lstatSync, mkdirSync, mkdtempSync,
  openSync, readFileSync, realpathSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { createServer, connect } from 'node:net';
import { createInterface } from 'node:readline';
import { tmpdir, userInfo } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { hashToken, newDevice, randomDeviceId, randomToken } from '../../../bridge/src/auth.mjs';
import { ALL_SCOPES, IDEMPOTENCY_RETENTION_MS } from '../../../bridge/src/config.mjs';
import { createStore } from '../../../bridge/src/store.mjs';
import { laneClient } from '../../../bridge/src/lane/client.mjs';
import { assertLaneParent, PRODUCTION_PORTS, validateLane } from '../../../bridge/src/lane/guard.mjs';

const self = fileURLToPath(import.meta.url);
const repo = resolve(dirname(self), '../../..');
const workInstall = join(userInfo().homedir, '.local/share/laa-work/engine/current');
const fixtures = new Map([
  ['habits', ['bridge/test/habits-ui-fixture.mjs', ['habits']]],
  ...['work', 'studio', 'usage', 'phone-use'].map((name) => [name, [`scripts/laa/${name}-ui-fixture.mjs`, [name, `${name}-control`]]]),
  ['paseo', ['scripts/laa/paseo-ui-fixture.mjs', ['paseo']]],
]);
const json = (path) => JSON.parse(readFileSync(path, 'utf8'));
const write = (path, value) => writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
const hex = () => randomBytes(16).toString('hex');
const at = (port) => `http://127.0.0.1:${port}`;
const privateEnv = (root) => ({ HOME: join(root, 'home'), TMPDIR: join(root, 'tmp'), PATH: `${dirname(process.execPath)}:/usr/bin:/bin`, LANG: 'C' });
const layout = (root, id) => ({ ...privateEnv(root), LAA_LANE_ID: id, LAA_LANE_ROOT: root,
  LAA_BRIDGE_STATE_DIR: join(root, 'state'), LAA_BRIDGE_BRAIN_ROOT: join(root, 'brain'), LAA_BRIDGE_PORT: '0' });

function load(root) {
  const stat = lstatSync(root);
  if (!stat.isDirectory() || stat.uid !== process.getuid() || (stat.mode & 0o077) !== 0 || !/^laa-lane-[A-Za-z0-9]{6}$/.test(basename(root))) {
    throw new Error('not a private lane root');
  }
  const file = join(root, 'lane.json');
  if (!lstatSync(file).isFile()) throw new Error('invalid lane manifest');
  const lane = json(file);
  if (lane.root !== root || !/^[a-f0-9]{32}$/.test(lane.control ?? '')) throw new Error('invalid lane manifest');
  return lane;
}

const publicLane = ({ id, root, ports, pids, device }) => ({ id, root, ports, pids, device, bridge: at(ports.bridge) });

function child(script, args, env, root, name, { ipc = false, pipe = false } = {}) {
  const fd = openSync(join(root, 'logs', `${name}.log`), 'a', 0o600);
  try {
    return spawn(process.execPath, [script, ...args], { cwd: root, env, stdio: ['ignore', pipe ? 'pipe' : fd, fd, ...(ipc ? ['ipc'] : [])] });
  } finally { closeSync(fd); }
}

async function until(check, message, alive = () => true) {
  const end = Date.now() + 15_000;
  while (Date.now() < end && alive()) {
    if (await check()) return;
    await sleep(40);
  }
  throw new Error(message);
}

function stopChild(proc) {
  return new Promise((done) => {
    if (proc.exitCode !== null || proc.signalCode !== null || !proc.pid) return done();
    const deadline = setTimeout(() => proc.kill('SIGKILL'), 2500);
    proc.once('exit', () => { clearTimeout(deadline); done(); });
    proc.kill('SIGTERM');
  });
}

async function supervise(root, names) {
  const owned = [];
  let closing;
  let control;
  const teardown = () => closing ??= (async () => {
    // Stop Bridge/fixtures before their private engine. Never signal a PID
    // read back from a manifest (which may have been recycled by the OS).
    for (const proc of [...owned].reverse()) await stopChild(proc);
  })();
  for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => void teardown().finally(() => process.exit(0)));
  try {
    const id = hex();
    const env = layout(root, id);
    validateLane(env, { stateDir: env.LAA_BRIDGE_STATE_DIR, port: 0 });
    const runtime = join(root, 'runtime');
    const socket = join(root, 'w.sock');
    const controlPath = join(root, 'ctl.sock');
    if (Buffer.byteLength(controlPath) > (process.platform === 'darwin' ? 103 : 107)) throw new Error('lane path is too long for a local socket; set LAA_LANE_PARENT to a shorter directory');
    const installed = realpathSync(workInstall);
    // Copy only executable source needed by the built-in engine/client. No
    // provider dependencies, CLI router, user config, credentials or agents.
    for (const path of ['engine', 'client']) cpSync(join(installed, path), join(runtime, path), { recursive: true });
    const provider = join(runtime, 'lane-provider.mjs');
    copyFileSync(join(dirname(self), 'lane-provider.mjs'), provider);
    const config = join(runtime, 'config.json');
    const catalog = join(runtime, 'catalog.json');
    write(config, { newSessions: 'laa-work', defaultCwd: env.HOME, bridgeUrl: null, periodic: [], cli: null, shim: null });
    write(catalog, { lab: { kind: `module:${provider}`, label: 'Lab Echo', models: [{ id: 'echo', isDefault: true,
      thinkingOptions: [{ id: 'low', isDefault: true }] }] } });
    const work = child(join(runtime, 'engine/main.mjs'), [], { ...privateEnv(root), LAA_WORK_SOCKET: socket,
      LAA_WORK_STATE: join(root, 'work'), LAA_WORK_CONFIG: config, LAA_WORK_CATALOG: catalog }, root, 'work-engine');
    owned.push(work);
    await until(() => existsSync(join(root, 'work/engine.pid')), 'isolated Work engine did not start', () => work.exitCode === null);

    const device = randomDeviceId();
    const token = randomToken();
    const store = createStore({ dir: env.LAA_BRIDGE_STATE_DIR, idempotencyRetentionMs: IDEMPOTENCY_RETENTION_MS });
    store.mutate((s) => { s.devices[device] = { ...newDevice({ id: device, name: 'Lab runner', scopes: [...ALL_SCOPES], platform: 'lab', now: Date.now() }), tokenHash: hashToken(token) }; });
    const ports = {};
    const pids = { supervisor: process.pid, work: work.pid };
    const bridge = child(join(repo, 'bridge/src/main.mjs'), ['serve'], { ...env, LAA_WORK_SOCKET: socket }, root, 'bridge', { pipe: true });
    owned.push(bridge);
    pids.bridge = bridge.pid;
    const bridgeLog = join(root, 'logs/bridge.log');
    const lines = createInterface({ input: bridge.stdout });
    lines.on('line', (line) => {
      // Bridge logs contain no bearer/token; only the listen event is parsed.
      try {
        const event = JSON.parse(line);
        if (event.event === 'listening') ports.bridge = event.port;
      } catch {}
      writeLog(bridgeLog, line);
    });
    await until(() => ports.bridge, 'real lane Bridge did not start', () => bridge.exitCode === null);
    const api = laneClient(at(ports.bridge), id);
    const health = await (await api('/v1/health')).json();
    if (health.data.lane !== id) throw new Error('lane Bridge health disagrees with its header');

    for (const name of names) {
      const [path, expected] = fixtures.get(name);
      const args = name === 'phone-use' ? [join(root, 'phone-state')] : [];
      const fixtureEnv = { ...env, ...(name === 'usage' ? { LAA_USAGE_UI_REAL_STATE: env.LAA_BRIDGE_STATE_DIR } : {}) };
      const proc = child(join(repo, path), args, fixtureEnv, root, `fixture-${name}`, { ipc: true });
      owned.push(proc);
      pids[`fixture-${name}`] = proc.pid;
      proc.on('message', (message) => {
        if (expected.includes(message?.fixture) && Number.isInteger(message.port) && message.port > 0 && !PRODUCTION_PORTS.includes(message.port)) {
          ports[message.fixture] = message.port;
        }
      });
      await until(() => expected.every((key) => ports[key]), `${name} fixture did not bind`, () => proc.exitCode === null);
      proc.disconnect();
    }
    const secret = hex();
    control = createServer((conn) => {
      let input = '';
      conn.setEncoding('utf8');
      conn.setTimeout(5000, () => conn.destroy());
      conn.on('error', () => {});
      conn.on('data', (chunk) => {
        input += chunk;
        if (input.length > 128) return conn.destroy();
        if (!input.endsWith('\n')) return;
        conn.removeAllListeners('data');
        if (input === `${secret} status\n`) return conn.end('running\n');
        if (input !== `${secret} down\n`) return conn.destroy();
        conn.setTimeout(0);
        void teardown().then(() => conn.end('stopped\n', () => control.close(() => process.exit(0))));
      });
    });
    await new Promise((ok, fail) => { control.once('error', fail); control.listen(controlPath, ok); });
    chmodSync(controlPath, 0o600);
    write(join(root, 'ready.json'), { root, id, token, control: secret, device, ports, pids });
    renameSync(join(root, 'ready.json'), join(root, 'lane.json'));
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    await teardown();
    control?.close();
    process.exitCode = 1;
  }
}

function writeLog(file, line) {
  const fd = openSync(file, 'a', 0o600);
  try { writeFileSync(fd, `${line}\n`); } finally { closeSync(fd); }
}

async function command(lane, word) {
  return new Promise((ok, fail) => {
    const conn = connect(join(lane.root, 'ctl.sock'));
    const chunks = [];
    conn.setTimeout(20_000, () => conn.destroy(new Error('lane supervisor did not answer')));
    conn.once('error', fail);
    conn.once('connect', () => conn.write(`${lane.control} ${word}\n`));
    conn.on('data', (part) => chunks.push(part));
    conn.once('end', () => ok(Buffer.concat(chunks).toString().trim()));
  });
}

const quote = (value) => `'${String(value).replaceAll("'", "'\\''")}'`;
function envScript(lane) {
  const values = { LAA_LANE_ID: lane.id, LAA_LANE_ROOT: lane.root, LAA_LANE_BRIDGE: at(lane.ports.bridge),
    LAA_LANE_TOKEN: lane.token, LAA_LANE_DEVICE_ID: lane.device,
    LAA_BRIDGE_PORT: lane.ports.bridge, LAA_BRIDGE_STATE_DIR: join(lane.root, 'state'), LAA_BRIDGE_DEFAULT_ADDRESS: at(lane.ports.bridge) };
  for (const [name, port] of Object.entries(lane.ports)) {
    if (name !== 'bridge') values[`LAA_LANE_FIXTURE_${name.toUpperCase().replaceAll('-', '_')}`] = at(port);
  }
  return Object.entries(values).map(([key, value]) => `export ${key}=${quote(value)}\nexport TEST_RUNNER_${key}=${quote(value)}\n`).join('');
}

async function main([verb, ...args]) {
  if (verb === '_supervise') return supervise(args[0], args.slice(1));
  if (verb === 'up') {
    const names = new Set();
    let asJson = false;
    while (args.length) {
      const flag = args.shift();
      if (flag === '--json') asJson = true;
      else if (flag === '--fixture' && fixtures.has(args[0])) names.add(args.shift());
      else throw new Error('usage: lane.mjs up [--json] [--fixture work|paseo|phone-use|studio|usage|habits]');
    }
    const root = mkdtempSync(join(assertLaneParent(realpathSync(process.env.LAA_LANE_PARENT ?? tmpdir())), 'laa-lane-'));
    for (const dir of ['home', 'tmp', 'state', 'brain', 'logs', 'sink']) mkdirSync(join(root, dir), { mode: 0o700 });
    const log = openSync(join(root, 'logs/supervisor.log'), 'a', 0o600);
    let proc;
    try { proc = spawn(process.execPath, [self, '_supervise', root, ...names], { cwd: root, detached: true, env: privateEnv(root), stdio: ['ignore', log, log] }); }
    finally { closeSync(log); }
    try { await until(() => existsSync(join(root, 'lane.json')), 'lane did not start', () => proc.exitCode === null); }
    catch (error) {
      await stopChild(proc);
      throw new Error(`${error.message}; see ${root}/logs (failed lane is not running)`);
    }
    proc.unref();
    const lane = publicLane(load(root));
    process.stdout.write(`${asJson ? JSON.stringify(lane) : root}\n`);
    return;
  }
  if (!['env', 'status', 'down'].includes(verb) || args.length !== 1) throw new Error('usage: lane.mjs up [--json] | env <root> | status <root> | down <root>');
  const lane = load(realpathSync(resolve(args[0])));
  if (verb === 'env') {
    if (await command(lane, 'status') !== 'running') throw new Error('lane is not running');
    process.stdout.write(envScript(lane));
  } else if (verb === 'status') {
    if (await command(lane, 'status') !== 'running') throw new Error('lane is not running');
    const proof = await laneClient(at(lane.ports.bridge), lane.id)('/v1/health');
    await proof.body?.cancel();
    if (!proof.ok) throw new Error('Bridge is not healthy');
    process.stdout.write(`${JSON.stringify({ status: 'running', ...publicLane(lane) })}\n`);
  } else {
    if (await command(lane, 'down') !== 'stopped') throw new Error('supervisor did not confirm lane stopped; root preserved');
    rmSync(lane.root, { recursive: true });
  }
}

main(process.argv.slice(2)).catch((error) => { process.stderr.write(`lane: ${error.message}\n`); process.exitCode = 1; });

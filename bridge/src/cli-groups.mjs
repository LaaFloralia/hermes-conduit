import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { homedir, userInfo } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';

const DASHBOARD = 'http://127.0.0.1:9119';
const VIEWER = 'laa-monet';
const PROTOCOL = 'hermes-gateway-v1';
const INJECTED = 'LAA_BRIDGE_GROUPS_AUTH_INJECTED';
const execute = promisify(execFile);

export const GROUPS_USAGE = `  laa-bridge groups list
  laa-bridge groups state <id>
  laa-bridge groups log <id>
  laa-bridge groups create --id <id> --name <name> --members <profile,profile,...> --chair <member_id> [--policy <json>]
  laa-bridge groups send <id> <text>
  laa-bridge groups disband <id> --confirm <id>
    Uses the local Hermes dashboard (Node 22+). Each member's id and handle equal its profile name.
    Log returns the first gateway page. Send posts to the main thread.`;

class GroupsError extends Error {
  constructor(code, message, details = {}) {
    super(message);
    this.body = { code, message, ...details };
  }
}

function usage(message) {
  throw new GroupsError('usage_error', message);
}

const validId = (value) => /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(value ?? '');

export function groupsRequest([action, ...args]) {
  const [id, value, confirm] = args;
  const make = (params) => ({ method: `groups.${action}`, params });
  switch (action) {
    case 'list':
      if (args.length) usage('list accepts no arguments');
      return make({ profile: VIEWER });
    case 'state':
    case 'log':
      if (args.length !== 1 || !validId(id)) usage(`${action} requires a room id`);
      return make(action === 'state'
        ? { room_id: id, profile: VIEWER, include_disbanded: true }
        : { room_id: id, profile: VIEWER, since_seq: 0 });
    case 'send':
      if (args.length !== 2 || !validId(id) || !value.trim()) usage('send requires a room id and nonempty text');
      return make({ room_id: id, event_id: randomUUID(), payload: { text: value, thread_id: 'main' } });
    case 'disband':
      if (args.length !== 3 || !validId(id) || value !== '--confirm' || confirm !== id) {
        usage('disband requires --confirm with the exact room id');
      }
      return make({ room_id: id });
    case 'create': {
      const flags = new Map();
      for (let i = 0; i < args.length; i += 2) {
        const key = args[i];
        const val = args[i + 1];
        if (!['--id', '--name', '--members', '--chair', '--policy'].includes(key)
            || flags.has(key) || !val?.trim() || val.startsWith('--')) usage('invalid or repeated create option');
        flags.set(key, val);
      }
      const roomId = flags.get('--id');
      const name = flags.get('--name');
      const profiles = flags.get('--members')?.split(',').map((part) => part.trim());
      const chair = flags.get('--chair');
      if (!validId(roomId) || !name || !profiles || profiles.length < 2 || profiles.length > 7
          || !profiles.every(validId) || new Set(profiles.map((profile) => profile.toLowerCase())).size !== profiles.length
          || !profiles.includes(chair)) usage('create needs --id, --name, 2–7 distinct member profiles, and a matching --chair');
      const options = { chair };
      if (flags.has('--policy')) {
        try { options.policy = JSON.parse(flags.get('--policy')); } catch { usage('--policy must be a JSON object'); }
        if (!options.policy || typeof options.policy !== 'object' || Array.isArray(options.policy)) usage('--policy must be a JSON object');
      }
      return make({ room_id: roomId, name, members: profiles.map((profile) => ({
        member_id: profile, profile, handle: profile,
      })), ...options });
    }
    default:
      usage('expected groups list, state, log, create, send, or disband');
  }
}

export async function gatewayGroupRequest(request, { username, password }, {
  fetcher = fetch, Socket = globalThis.WebSocket, timeoutMs = 10_000,
} = {}) {
  if (typeof Socket !== 'function') throw new GroupsError('node_version', 'groups requires Node 22 or newer');
  const signal = AbortSignal.timeout(timeoutMs);
  let ticket;
  try {
    const login = await fetcher(`${DASHBOARD}/auth/password-login`, {
      method: 'POST', redirect: 'error', signal,
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ provider: 'basic', username, password }),
    });
    if (!login.ok) throw new GroupsError('dashboard_auth', `dashboard password login rejected (HTTP ${login.status})`);
    const cookie = login.headers.getSetCookie().map((header) => header.split(';', 1)[0])
      .find((value) => value.startsWith('hermes_session_at='));
    if (!cookie) throw new GroupsError('dashboard_auth', 'dashboard did not issue a session cookie');
    const response = await fetcher(`${DASHBOARD}/api/auth/ws-ticket`, {
      method: 'POST', redirect: 'error', signal, headers: { Cookie: cookie },
    });
    if (!response.ok) throw new GroupsError('dashboard_auth', `dashboard ticket request rejected (HTTP ${response.status})`);
    ({ ticket } = await response.json());
    if (typeof ticket !== 'string' || !/^[A-Za-z0-9_-]+$/.test(ticket)) {
      throw new GroupsError('dashboard_auth', 'dashboard did not issue a valid WebSocket ticket');
    }
  } catch (err) {
    if (err instanceof GroupsError) throw err;
    throw new GroupsError('dashboard_auth', 'could not complete dashboard authentication');
  }

  return new Promise((resolve, reject) => {
    // The ticket-bearing protocol is consumed server-side; no credentials in the URL or argv.
    const socket = new Socket(DASHBOARD.replace('http:', 'ws:') + '/api/ws', [PROTOCOL, `hermes-gateway-ticket.${ticket}`]);
    const id = randomUUID();
    let sent = false;
    let finished = false;
    const finish = (callback, result) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      if (socket.readyState < 2) socket.close();
      callback(result);
    };
    const lost = () => {
      const code = sent ? 'response_unconfirmed' : 'dashboard_connection';
      const message = sent ? 'gateway response not confirmed; check room state or log before retrying a mutation'
        : 'could not connect to the dashboard gateway';
      finish(reject, new GroupsError(code, message, request.params.event_id ? { event_id: request.params.event_id } : {}));
    };
    const timer = setTimeout(lost, timeoutMs);
    socket.addEventListener('open', () => {
      if (socket.protocol !== PROTOCOL) return lost();
      try {
        socket.send(JSON.stringify({ jsonrpc: '2.0', id, ...request }));
        sent = true;
      } catch { lost(); }
    });
    socket.addEventListener('message', ({ data }) => {
      let response;
      try { response = JSON.parse(data); } catch { return lost(); }
      if (response?.id !== id) return; // ignore gateway events
      if (response.jsonrpc !== '2.0') return lost();
      if (Number.isInteger(response.error?.code)) {
        finish(reject, new GroupsError('gateway_rpc_error', 'dashboard rejected the Group RPC', { rpc_code: response.error.code }));
      } else if (Object.hasOwn(response, 'result')) {
        finish(resolve, response.result);
      } else lost();
    });
    socket.addEventListener('error', lost);
    socket.addEventListener('close', lost);
  });
}

export async function groupsCommand(args) {
  const output = (json) => process.stdout.write(`${JSON.stringify(json)}\n`);
  try {
    const request = groupsRequest(args);
    if (process.env.NODE_TEST_CONTEXT !== undefined || process.env.LAA_LANE_ID !== undefined) {
      throw new GroupsError('lane_config_unsafe', 'groups is unavailable inside the Bridge test lane');
    }
    if (process.env[INJECTED] !== '1') {
      const home = homedir();
      const config = join(home, '.config', 'laa');
      const env = { HOME: home, USER: userInfo().username, PATH: '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin', [INJECTED]: '1' };
      try {
        const { stdout } = await execute(join(config, 'op-run-batch.sh'), [
          join(config, 'hermes-personal.env.tpl'), process.execPath, process.argv[1], 'groups', ...args,
        ], { env, timeout: 45_000, maxBuffer: 32 * 1024 * 1024 });
        output(JSON.parse(stdout));
        return 0;
      } catch (err) {
        // Never print the wrapper's stderr or exception (which can contain child argv).
        try {
          const json = JSON.parse(err.stdout);
          if (json.ok === false && typeof json.error?.code === 'string') {
            output(json);
            return 1;
          }
        } catch { /* no valid child response */ }
        throw new GroupsError('groups_runner_failed', 'credential runner did not return a result; verify 1Password and check room state or log before retrying a mutation');
      }
    }
    const username = process.env.HERMES_DASHBOARD_BASIC_AUTH_USERNAME;
    const password = process.env.HERMES_DASHBOARD_BASIC_AUTH_PASSWORD;
    if (!username || !password) throw new GroupsError('dashboard_auth', 'dashboard credentials were not injected');
    output(await gatewayGroupRequest(request, { username, password }));
    return 0;
  } catch (err) {
    output({ ok: false, error: err instanceof GroupsError ? err.body : { code: 'groups_failed', message: 'Group request failed' } });
    return err.body?.code === 'usage_error' ? 2 : 1;
  }
}

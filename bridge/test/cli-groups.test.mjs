import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { gatewayGroupRequest, groupsRequest } from '../src/cli-groups.mjs';

const cli = fileURLToPath(new URL('../src/cli.mjs', import.meta.url));

const credentials = { username: 'fixture-user', password: 'fixture-password' };

function fakeGateway(onSend) {
  const calls = [];
  const fetcher = async (url, options) => {
    calls.push([url, options]);
    const headers = new Headers();
    if (calls.length === 1) {
      headers.append('Set-Cookie', 'unrelated=discard; Path=/');
      headers.append('Set-Cookie', 'hermes_session_at=fixture-session; HttpOnly; Path=/');
    }
    return new Response(JSON.stringify({ ticket: 'fixture-ticket' }), { headers });
  };
  class Socket extends EventTarget {
    readyState = 0;
    protocol = 'hermes-gateway-v1';
    constructor(url, protocols) {
      super();
      assert.equal(url, 'ws://127.0.0.1:9119/api/ws');
      assert.deepEqual(protocols, ['hermes-gateway-v1', 'hermes-gateway-ticket.fixture-ticket']);
      queueMicrotask(() => {
        this.readyState = 1;
        this.dispatchEvent(new Event('open'));
      });
    }
    send(data) { onSend(this, JSON.parse(data)); }
    reply(data) { this.dispatchEvent(new MessageEvent('message', { data: JSON.stringify(data) })); }
    close() { this.readyState = 3; this.dispatchEvent(new Event('close')); }
  }
  return { calls, fetcher, Socket };
}

test('groups requests match the hosted-room RPC wire shapes', () => {
  assert.deepEqual(groupsRequest(['list']), { method: 'groups.list', params: { profile: 'laa-monet' } });
  assert.deepEqual(groupsRequest(['state', 'room-1']).params, {
    room_id: 'room-1', include_disbanded: true, profile: 'laa-monet',
  });
  assert.deepEqual(groupsRequest(['log', 'room-1']).params, { room_id: 'room-1', since_seq: 0, profile: 'laa-monet' });

  const profiles = ['laa-monet', 'laa-cto', 'laa-cfo', 'laa-cos', 'laa-cio', 'laa-argus', 'laa-cso'];
  const policy = { staff_rounds: 1, max_messages: 10 };
  const input = ['create', '--id', 'all-hands', '--name', 'All Hands', '--members', profiles.join(','), '--chair', 'laa-monet'];
  assert.deepEqual(groupsRequest([...input, '--policy', JSON.stringify(policy)]), {
    method: 'groups.create', params: {
      room_id: 'all-hands', name: 'All Hands', chair: 'laa-monet', policy,
      members: profiles.map((profile) => ({ member_id: profile, profile, handle: profile })),
    },
  });
  assert.equal(Object.hasOwn(groupsRequest(input).params, 'policy'), false);
  assert.throws(() => groupsRequest([...input, '--policy', 'null']), /JSON object/);
  assert.throws(() => groupsRequest([...input, '--id', 'another-room']), /repeated/);
  const send = groupsRequest(['send', 'room-1', '--literal text\nsecond line']);
  assert.deepEqual(send.params.payload, { text: '--literal text\nsecond line', thread_id: 'main' });
  assert.match(send.params.event_id, /^[0-9a-f-]{36}$/);
  assert.deepEqual(groupsRequest(['disband', 'room-1', '--confirm', 'room-1']), {
    method: 'groups.disband', params: { room_id: 'room-1' },
  });
});

test('CLI rejects mismatched disband confirmation and refuses live groups in a test process', (t) => {
  const state = mkdtempSync(join(tmpdir(), 'bridge-groups-test-'));
  t.after(() => rmSync(state, { recursive: true, force: true }));
  for (const [args, status, code] of [
    [['disband', 'room-1', '--confirm', 'room-2'], 2, 'usage_error'],
    [['list'], 1, 'lane_config_unsafe'],
  ]) {
    const child = spawnSync(process.execPath, [cli, 'groups', ...args], {
      encoding: 'utf8', env: { ...process.env, LAA_BRIDGE_STATE_DIR: state },
    });
    assert.equal(child.status, status, child.stderr);
    assert.equal(JSON.parse(child.stdout).error.code, code);
  }
});

test('trades a password session for a ticket, then reads the matching JSON-RPC result', async () => {
  const expected = { rooms: [{ room_id: 'sample', name: 'Sample' }], next_offset: null };
  const request = groupsRequest(['list']);
  const fake = fakeGateway((socket, { id, ...rpc }) => {
    assert.deepEqual(rpc, { jsonrpc: '2.0', ...request });
    socket.reply({ jsonrpc: '2.0', method: 'event', params: {} });
    socket.reply({ jsonrpc: '2.0', id: 'other-request', result: null });
    socket.reply({ jsonrpc: '2.0', id, result: expected });
  });
  assert.deepEqual(await gatewayGroupRequest(request, credentials, fake), expected);
  assert.deepEqual(fake.calls.map(([url]) => url), [
    'http://127.0.0.1:9119/auth/password-login', 'http://127.0.0.1:9119/api/auth/ws-ticket',
  ]);
  assert.deepEqual(JSON.parse(fake.calls[0][1].body), { provider: 'basic', ...credentials });
  assert.equal(fake.calls[1][1].headers.Cookie, 'hermes_session_at=fixture-session');
  assert.ok(fake.calls.every(([, { redirect }]) => redirect === 'error'));
});

test('mutation is never retried on connection loss and returns its event id', async () => {
  const request = groupsRequest(['send', 'room-1', 'sample']);
  let sends = 0;
  const fake = fakeGateway((socket) => { sends += 1; queueMicrotask(() => socket.close()); });
  await assert.rejects(gatewayGroupRequest(request, credentials, fake), ({ body }) => {
    assert.equal(body.code, 'response_unconfirmed');
    assert.equal(body.event_id, request.params.event_id);
    return true;
  });
  assert.equal(sends, 1);
});

test('auth and RPC failure bodies do not repeat remote error text', async () => {
  const request = groupsRequest(['list']);
  const fake = fakeGateway((socket, { id }) => socket.reply({
    id, jsonrpc: '2.0', error: { code: 5110, message: credentials.password },
  }));
  await assert.rejects(gatewayGroupRequest(request, credentials, fake), ({ body }) => {
    assert.equal(body.rpc_code, 5110);
    assert.doesNotMatch(JSON.stringify(body), /fixture-password/);
    return true;
  });
  const fetcher = async () => { throw new Error(credentials.password); };
  await assert.rejects(gatewayGroupRequest(request, credentials, { ...fake, fetcher }), {
    message: 'could not complete dashboard authentication',
  });
});

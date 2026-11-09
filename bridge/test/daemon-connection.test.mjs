// One Paseo connection serves this process's calls until it fails or sits idle.
// The handshake costs about as much as the RPC it carries (bridge.md §2), so
// this is what keeps a list request from paying for two of them — and what must
// never hand a dead socket to the next request.

import assert from 'node:assert/strict';
import test from 'node:test';
import { daemonAdapter } from '../src/sessions/daemon.mjs';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function fixture() {
  const clients = [];
  let connects = 0;
  const connect = async () => {
    connects += 1;
    const client = {
      isConnected: true,
      closed: false,
      async fetchAgent({ agentId }) {
        if (client.broken) {
          client.isConnected = false;
          throw new Error('socket gone');
        }
        if (client.missing) return { agent: null };
        return { agent: { id: agentId } };
      },
      async close() {
        client.closed = true;
        client.isConnected = false;
      },
    };
    clients.push(client);
    return client;
  };
  return { connect, clients, connects: () => connects };
}

test('one connection serves several calls', async () => {
  const f = fixture();
  const daemon = daemonAdapter({ connect: f.connect });
  assert.equal(await daemon.exists('a'), true);
  assert.equal(await daemon.exists('b'), true);
  assert.equal(f.connects(), 1, 'the second call reused the open connection');
});

test('a transport failure drops the connection instead of reusing it', async () => {
  const f = fixture();
  const daemon = daemonAdapter({ connect: f.connect });
  assert.equal(await daemon.exists('a'), true);
  f.clients[0].broken = true;
  await assert.rejects(() => daemon.exists('b'), (err) => err.status === 503 && err.code === 'paseo_unavailable');
  assert.equal(f.clients[0].closed, true, 'the broken connection was closed');
  assert.equal(await daemon.exists('c'), true);
  assert.equal(f.connects(), 2, 'the next request opened its own connection');
});

test("Paseo's own 404 keeps the connection", async () => {
  const f = fixture();
  const daemon = daemonAdapter({ connect: f.connect });
  await daemon.exists('a');
  f.clients[0].missing = true;
  assert.equal(await daemon.exists('gone'), false);
  assert.equal(f.connects(), 1, 'a "not found" answer is not a broken connection');
  assert.equal(f.clients[0].closed, false);
});

test('an idle connection is closed and reopened on the next call', async () => {
  const f = fixture();
  const daemon = daemonAdapter({ connect: f.connect, idleCloseMs: 20 });
  await daemon.exists('a');
  await sleep(60);
  assert.equal(f.clients[0].closed, true, 'the idle connection was closed');
  assert.equal(await daemon.exists('b'), true);
  assert.equal(f.connects(), 2);
});

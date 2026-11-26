import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import { voiceLeaseRoutes } from '../src/routes/voice-lease.mjs';
import { startBridge } from './helpers.mjs';

function fixture() {
  let time = 0;
  const [{ handler }] = voiceLeaseRoutes({ now: () => time, wall: () => 1_000_000 + time });
  const request = (device, room, endpointId, action = 'claim', generation, pulse) => handler({
    device: { id: device }, params: [room], rawBody: Buffer.from(JSON.stringify({ action, endpointId, generation, pulse })),
  }).data;
  return { request, advance: (ms) => { time += ms; } };
}

test('single room endpoint wins simultaneous Talk; another room is independent', async () => {
  const { request, advance } = fixture();
  advance(12_000);
  const a = randomUUID(); const b = randomUUID();
  const results = await Promise.allSettled([
    Promise.resolve().then(() => request('device-a', 'room-one', a)),
    Promise.resolve().then(() => request('device-b', 'room-one', b)),
  ]);
  const [winner, loser] = results;
  assert.equal(winner.value.endpointId, a);
  assert.equal(loser.reason.code, 'meeting_audio_busy');
  assert.equal(request('device-b', 'room-two', b).endpointId, b);
  assert.throws(() => request('device-b', 'room-one', a), { code: 'meeting_audio_busy' });
});

test('claim and pulse replays are idempotent; expired generations never renew', () => {
  const { request, advance } = fixture();
  advance(12_000);
  const a = randomUUID(); const b = randomUUID();
  const first = request('a', 'room', a);
  advance(3_000);
  assert.deepEqual(request('a', 'room', a), { ...first, remainingMs: 9_000 });
  const second = request('a', 'room', a, 'renew', first.generation, 1);
  advance(500);
  assert.deepEqual(request('a', 'room', a, 'renew', first.generation, 1), { ...second, remainingMs: 11_500 });
  advance(11_500);
  const next = request('b', 'room', b);
  assert.notEqual(next.generation, first.generation);
  assert.throws(() => request('a', 'room', a, 'renew', first.generation, 2), { code: 'meeting_audio_stale' });
  assert.deepEqual(request('a', 'room', a, 'release', first.generation), { released: true });
  assert.throws(() => request('a', 'room', a), { code: 'meeting_audio_busy' });
});

test('restarts wait one TTL; release requires room, device, endpoint, generation', () => {
  const { request, advance } = fixture();
  const a = randomUUID(); const b = randomUUID();
  assert.throws(() => request('a', 'room', a), { code: 'meeting_audio_unavailable' });
  advance(12_000);
  const grant = request('a', 'room', a);
  request('b', 'room', a, 'release', grant.generation);
  request('a', 'other', a, 'release', grant.generation);
  request('a', 'room', b, 'release', grant.generation);
  assert.throws(() => request('b', 'room', b), { code: 'meeting_audio_busy' });
  request('a', 'room', a, 'release', grant.generation);
  request('a', 'room', a, 'release', grant.generation);
  assert.equal(request('b', 'room', b).endpointId, b);
});

test('real HTTP routing requires paired voice scope and validates IDs before mutation', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const noScope = await api.token();
  const voice = await api.token(['voice:transcribe']);
  const body = { action: 'claim', endpointId: randomUUID() };
  const post = (token, room, payload = body) => api.request(`/v1/meetings/${room}/audio-lease`, { token, method: 'POST', body: payload });
  assert.equal((await post(null, 'room')).status, 401);
  assert.equal((await post(noScope, 'room')).status, 403);
  assert.equal((await post(voice, '%2Foutside')).status, 400);
  assert.equal((await post(voice, 'room', { ...body, endpointId: 'bad' })).status, 400);
  assert.equal((await post(voice, 'room')).body.error.code, 'meeting_audio_unavailable');
});

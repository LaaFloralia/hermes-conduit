import { randomUUID } from 'node:crypto';
import { performance } from 'node:perf_hooks';
import { BridgeError, badRequest } from '../errors.mjs';

const TTL_MS = 12_000;
const MAX_ROOMS = 256;
const ID = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/;
const UUID = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/;

// The authenticated owner-device scope is the trust boundary (Hermes owns
// membership). This route holds no transcript or audio and does no Hermes I/O.
export function voiceLeaseRoutes({ now = () => performance.now(), wall = Date.now } = {}) {
  const rooms = new Map();
  // After a restart, let every possibly outstanding local grant expire before
  // issuing a grant that could overlap it. No persisted state or timer needed.
  const warmAt = now() + TTL_MS;
  return [{
    method: 'POST', pattern: /^\/v1\/meetings\/([^/]+)\/audio-lease$/,
    auth: true, scope: 'voice:transcribe', bodyLimit: 1024,
    handler({ rawBody, device, params: [roomId] }) {
      let body;
      try { body = JSON.parse(rawBody); } catch { throw badRequest('payload_invalid', 'invalid lease request'); }
      const { action, endpointId, generation, pulse } = body ?? {};
      const valid = ID.test(roomId) && typeof endpointId === 'string' && UUID.test(endpointId) &&
        (action === 'claim' && generation == null && pulse == null ||
         action === 'renew' && typeof generation === 'string' && UUID.test(generation) && Number.isSafeInteger(pulse) && pulse > 0 ||
         action === 'release' && typeof generation === 'string' && UUID.test(generation) && pulse == null);
      if (!valid) throw badRequest('payload_invalid', 'invalid lease request');
      const time = now();
      for (const [id, lease] of rooms) if (lease.until <= time) rooms.delete(id);
      let lease = rooms.get(roomId);
      const same = lease?.deviceId === device.id && lease.endpointId === endpointId;
      const owns = same && lease.generation === generation;
      if (action === 'release') {
        if (owns) rooms.delete(roomId);
        return { status: 200, data: { released: true } };
      }
      if (action === 'claim') {
        if (lease && !same) throw new BridgeError(409, 'meeting_audio_busy', 'another endpoint holds this room');
        if (!lease) {
          if (time < warmAt || rooms.size >= MAX_ROOMS) throw new BridgeError(503, 'meeting_audio_unavailable', 'lease service temporarily unavailable');
          lease = { roomId, endpointId, deviceId: device.id, generation: randomUUID(), pulse: 0 };
          rooms.set(roomId, lease);
          lease.until = time + TTL_MS;
          lease.expiresAt = wall() + TTL_MS;
        }
      } else {
        if (!owns) throw new BridgeError(409, 'meeting_audio_stale', 'lease no longer current');
        if (pulse > lease.pulse) {
          lease.pulse = pulse;
          lease.until = time + TTL_MS;
          lease.expiresAt = wall() + TTL_MS;
        }
      }
      // Returning remaining time (not nominal TTL) keeps duplicate claims or
      // old pulses from extending the client's conservative local deadline.
      return { status: 200, data: {
        roomId, endpointId, generation: lease.generation, expiresAt: lease.expiresAt,
        remainingMs: Math.floor(Math.max(0, lease.until - time)),
      } };
    },
  }];
}

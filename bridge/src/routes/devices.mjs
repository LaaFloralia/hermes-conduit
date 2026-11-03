// Device-scoped operations that are safe for the device itself.
//
// `POST /v1/devices/self/revoke` exists so a voice-only device can retire the
// token it is replacing. Re-pairing to pick up a new voice scope otherwise
// leaves the old bearer token valid forever, which is exactly the kind of stale
// credential a narrow grant must not create. The route takes no target: it
// revokes the caller and nothing else, so a device cannot reach another
// device's token with it. Operator-wide revocation stays in the CLI
// (`laa-bridge revoke`), and `devices:admin` remains ungranted.
//
// Only a device that holds a voice scope may use it. The main LAA app
// credential (sessions, tasks, Brain) has no voice scope, so it cannot retire
// itself by accident and its token stays under the operator's control.
//
// The response carries only the device's own id and revocation time. No scope,
// name or token material is echoed.

import { hasScope } from '../auth.mjs';
import { BridgeError, badRequest } from '../errors.mjs';

const VOICE_SCOPES = ['voice:polish', 'voice:transcribe'];

export function deviceRoutes({ store, now = () => Date.now() } = {}) {
  return [
    {
      method: 'POST',
      path: '/v1/devices/self/revoke',
      auth: true,
      idempotent: false,
      handler({ device, rawBody }) {
        if (!VOICE_SCOPES.some((scope) => hasScope(device, scope))) {
          throw new BridgeError(403, 'insufficient_scope', 'device is missing a voice scope');
        }
        if (rawBody !== undefined && rawBody.length > 0) {
          let payload;
          try {
            payload = JSON.parse(rawBody.toString('utf8'));
          } catch {
            throw badRequest('payload_invalid', 'request body is not valid JSON');
          }
          if (payload !== null && typeof payload === 'object' && Object.keys(payload).length > 0) {
            throw badRequest('payload_invalid', 'a device can only revoke itself; no target is accepted');
          }
        }

        const outcome = store.mutate((state) => {
          const current = state.devices[device.id];
          if (!current) return { missing: true };
          // Same shape as `laa-bridge revoke` (pairing.mjs): an ISO-8601
          // string, not the millisecond number the store's clock returns.
          // The CLI and any reader of state.json rely on that type.
          if (!current.revokedAt) current.revokedAt = new Date(now()).toISOString();
          return { revokedAt: current.revokedAt };
        });
        if (outcome.missing) {
          throw new BridgeError(401, 'invalid_token', 'token is not recognised');
        }
        return {
          status: 200,
          data: {
            deviceId: device.id,
            revokedAt: outcome.revokedAt,
          },
        };
      },
    },
  ];
}

// HTTP surface of the LAA Bridge (BRIDGE.md sections 3 and 9).
//
// Envelope:  {"data":...,"requestId":"..."} / {"error":{"code","message","retryable"},"requestId"}
// Codes:     400 invalid, 401 unauthenticated/revoked, 403 scope, 404 outside
//            range, 409 idempotency conflict, 429 throttled, 503 dependency down.
//
// The listener is loopback-only; reachability is Tailscale Serve's job and is
// deliberately not treated as authentication.

import { createServer } from 'node:http';
import { randomBytes } from 'node:crypto';
import {
  BODY_LIMIT_BYTES,
  IDEMPOTENCY_INFLIGHT_GRACE_MS,
  VERSION,
  testEndpointsEnabled,
} from './config.mjs';
import {
  authenticate,
  hasScope,
  hashPairingCode,
  hashToken,
  newDevice,
  normalizePairingCode,
  randomDeviceId,
  randomToken,
} from './auth.mjs';
import { IDEMPOTENCY_KEY_PATTERN, complete, requestFingerprint, reserve } from './idempotency.mjs';
import { driveAdapterFromEnv } from './drive/google-api.mjs';
import { driveRoutes } from './routes/drive.mjs';
import { BridgeError, badRequest } from './errors.mjs';
import { businessRoutes } from './routes/index.mjs';

export { BridgeError };

const LOOPBACK_ORIGIN = /^https?:\/\/(127\.0\.0\.1|localhost|\[::1\])(:\d+)?$/;
const ENROLL_FAILURE_WINDOW_MS = 60 * 1000;
const ENROLL_FAILURE_LIMIT = 10;

function parseJsonBody(raw) {
  if (raw.length === 0) return undefined;
  try {
    return JSON.parse(raw.toString('utf8'));
  } catch {
    throw badRequest('payload_invalid', 'request body is not valid JSON');
  }
}

function requireObject(payload) {
  if (payload === undefined) return {};
  if (payload === null || typeof payload !== 'object' || Array.isArray(payload)) {
    throw badRequest('payload_invalid', 'request body must be a JSON object');
  }
  return payload;
}

export function createBridge({
  store,
  version = VERSION,
  testEndpoints = testEndpointsEnabled(),
  allowedOrigins = [],
  drive = null,
  now = () => Date.now(),
  log = defaultLog(),
  routeOptions = {},
} = {}) {
  const startedAt = now();
  const enrollFailures = [];

  function sendJson(res, status, body, requestId, headers = {}) {
    const payload = `${JSON.stringify(body)}\n`;
    res.writeHead(status, {
      'content-type': 'application/json; charset=utf-8',
      'content-length': Buffer.byteLength(payload),
      'cache-control': 'no-store',
      'x-content-type-options': 'nosniff',
      'x-request-id': requestId,
      ...headers,
    });
    res.end(payload);
  }

  function ok(res, status, data, requestId, headers = {}) {
    sendJson(res, status, { data, requestId }, requestId, headers);
  }

  function fail(res, requestId, error) {
    sendJson(
      res,
      error.status,
      {
        error: { code: error.code, message: error.message, retryable: error.retryable },
        requestId,
      },
      requestId,
    );
  }

  async function readBody(req) {
    const chunks = [];
    let size = 0;
    for await (const chunk of req) {
      size += chunk.length;
      if (size > BODY_LIMIT_BYTES) {
        req.pause();
        throw badRequest('payload_too_large', `request body exceeds ${BODY_LIMIT_BYTES} bytes`);
      }
      chunks.push(chunk);
    }
    return Buffer.concat(chunks);
  }

  function checkOrigin(req) {
    const origin = req.headers.origin;
    if (!origin) return; // native clients send no Origin
    if (allowedOrigins.includes(origin) || LOOPBACK_ORIGIN.test(origin)) return;
    throw new BridgeError(403, 'origin_rejected', 'request origin is not allowed');
  }

  function noteEnrollFailure() {
    const t = now();
    enrollFailures.push(t);
    while (enrollFailures.length > 0 && enrollFailures[0] < t - ENROLL_FAILURE_WINDOW_MS) {
      enrollFailures.shift();
    }
    if (enrollFailures.length >= ENROLL_FAILURE_LIMIT) {
      throw new BridgeError(429, 'rate_limited', 'too many failed pairing attempts', { retryable: true });
    }
  }

  // --- handlers: return {status, data}; the pipeline owns the envelope -------

  function health() {
    return { status: 200, data: { version, uptimeSeconds: Math.floor((now() - startedAt) / 1000) } };
  }

  function enroll({ rawBody }) {
    const payload = requireObject(parseJsonBody(rawBody));
    const code = normalizePairingCode(payload.code);
    if (!code) throw badRequest('payload_invalid', 'code must be an 8-character pairing code');
    const name = typeof payload.name === 'string' ? payload.name.trim() : '';
    if (name.length === 0 || name.length > 64) {
      throw badRequest('payload_invalid', 'name must be 1-64 characters');
    }
    const platform = payload.platform === undefined ? null : String(payload.platform).slice(0, 32);
    const codeHash = hashPairingCode(code);
    const t = now();

    const result = store.mutate((state) => {
      const pairing = state.pairings[codeHash];
      if (!pairing) return { error: new BridgeError(401, 'pairing_code_invalid', 'pairing code is not valid') };
      if (pairing.usedAt) return { error: new BridgeError(401, 'pairing_code_used', 'pairing code has already been used') };
      if (pairing.expiresAt < t) return { error: new BridgeError(401, 'pairing_code_expired', 'pairing code has expired') };

      const token = randomToken();
      const device = newDevice({ id: randomDeviceId(), name, scopes: pairing.scopes, platform, now: t });
      device.tokenHash = hashToken(token);
      state.devices[device.id] = device;
      pairing.usedAt = t;
      pairing.deviceId = device.id;
      return { device, token };
    });

    if (result.error) {
      noteEnrollFailure();
      throw result.error;
    }
    // The plaintext token exists only in this response; state keeps its hash.
    return {
      status: 201,
      data: {
        deviceId: result.device.id,
        token: result.token,
        scopes: result.device.scopes,
        createdAt: result.device.createdAt,
      },
    };
  }

  function me({ device }) {
    return {
      status: 200,
      data: {
        deviceId: device.id,
        name: device.name,
        scopes: device.scopes,
        platform: device.platform,
        createdAt: device.createdAt,
      },
    };
  }

  // Exists only when LAA_BRIDGE_TEST_ENDPOINTS=1: the state-changing stand-in
  // that exercises the idempotency ledger until real business endpoints exist.
  function testEcho({ device, rawBody }) {
    const payload = parseJsonBody(rawBody);
    return {
      status: 201,
      data: {
        echo: payload ?? null,
        deviceId: device.id,
        mutationId: `mut_${randomBytes(6).toString('hex')}`,
      },
    };
  }

  const ROUTES = [
    { method: 'GET', path: '/v1/health', auth: false, handler: health },
    { method: 'POST', path: '/v1/devices/enroll', auth: false, idempotent: false, handler: enroll },
    { method: 'GET', path: '/v1/me', auth: true, handler: me },
    { method: 'POST', path: '/v1/_test/echo', auth: true, scope: 'sessions:write', idempotent: true, testOnly: true, handler: testEcho },
    ...driveRoutes({ adapter: drive ?? driveAdapterFromEnv(), now, log: log === null ? null : undefined }),
    ...businessRoutes({ store, now, options: routeOptions }),
  ];

  // --- request pipeline -----------------------------------------------------

  async function handle(req, res) {
    const requestId = `req_${randomBytes(8).toString('hex')}`;
    const started = now();
    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    const pathname = url.pathname.length > 1 && url.pathname.endsWith('/')
      ? url.pathname.slice(0, -1)
      : url.pathname;
    let deviceId = null;
    let errorCode = null;

    try {
      checkOrigin(req);

      const candidates = ROUTES.filter((route) => (route.pattern ? route.pattern.test(pathname) : route.path === pathname));
      if (candidates.length === 0) {
        throw new BridgeError(404, 'not_found', 'no such endpoint');
      }
      const route = candidates.find((candidate) => candidate.method === req.method);
      if (!route) {
        throw new BridgeError(405, 'method_not_allowed', `${req.method} is not allowed on ${pathname}`);
      }
      if (route.testOnly && !testEndpoints) {
        // Hide test endpoints entirely in a normal deployment.
        throw new BridgeError(404, 'not_found', 'no such endpoint');
      }

      const rawBody = await readBody(req);

      let device = null;
      if (route.auth) {
        const auth = authenticate(store.read(), req.headers.authorization);
        if (auth.reason === 'missing') throw new BridgeError(401, 'unauthenticated', 'Bearer token is required');
        if (auth.reason === 'invalid_token') throw new BridgeError(401, 'invalid_token', 'token is not recognised');
        if (auth.reason === 'token_revoked') throw new BridgeError(401, 'token_revoked', 'device has been revoked');
        device = auth.device;
        deviceId = device.id;
        if (route.scope && !hasScope(device, route.scope)) {
          throw new BridgeError(403, 'insufficient_scope', `device is missing scope ${route.scope}`);
        }
      }

      let idempotencyKey = null;
      if (route.idempotent) {
        idempotencyKey = req.headers['idempotency-key'];
        if (typeof idempotencyKey !== 'string' || idempotencyKey === '') {
          throw badRequest('idempotency_key_required', 'Idempotency-Key header is required');
        }
        if (!IDEMPOTENCY_KEY_PATTERN.test(idempotencyKey)) {
          throw badRequest('idempotency_key_invalid', 'Idempotency-Key must be 1-200 of A-Z a-z 0-9 . _ : -');
        }
        const fingerprint = requestFingerprint(req.method, pathname, rawBody);
        const outcome = store.mutate((state) => reserve(state, {
          deviceId: device.id,
          key: idempotencyKey,
          method: req.method,
          path: pathname,
          fingerprint,
          now: now(),
          inflightGraceMs: IDEMPOTENCY_INFLIGHT_GRACE_MS,
        }));

        if (outcome.action === 'conflict') {
          throw new BridgeError(409, 'idempotency_key_conflict', 'Idempotency-Key was used for a different request');
        }
        if (outcome.action === 'in_flight') {
          throw new BridgeError(409, 'idempotency_key_in_flight', 'the same Idempotency-Key is still executing', { retryable: true });
        }
        if (outcome.action === 'unresolved') {
          throw new BridgeError(409, 'idempotency_outcome_unknown', 'the earlier request never finished; reconcile before retrying');
        }
        if (outcome.action === 'replay') {
          ok(res, outcome.entry.httpStatus ?? 200, outcome.entry.response, requestId, {
            'idempotency-replayed': 'true',
          });
          return;
        }
      }

      const params = route.pattern ? (route.pattern.exec(pathname) ?? []).slice(1) : [];
      const result = await route.handler({ req, res, requestId, device, rawBody, params });
      // A streaming handler (Drive content) writes its own bytes and returns nothing.
      if (!result) return;
      if (idempotencyKey) {
        store.mutate((state) => complete(state, {
          deviceId: device.id,
          key: idempotencyKey,
          httpStatus: result.status,
          response: result.data,
          now: now(),
        }));
      }
      ok(res, result.status, result.data, requestId, result.headers ?? {});
    } catch (err) {
      const error = err instanceof BridgeError
        ? err
        : new BridgeError(500, 'internal_error', 'unexpected server error');
      errorCode = error.code;
      if (!(err instanceof BridgeError) && log) {
        log({ level: 'error', requestId, error: err?.message ?? String(err) });
      }
      if (!res.headersSent) fail(res, requestId, error);
    } finally {
      if (log) {
        log({
          level: 'info',
          requestId,
          method: req.method,
          path: pathname,
          status: res.statusCode,
          ms: now() - started,
          deviceId,
          code: errorCode,
        });
      }
    }
  }

  return {
    server: createServer((req, res) => {
      handle(req, res).catch(() => {
        if (!res.headersSent) {
          res.writeHead(500, { 'content-type': 'application/json; charset=utf-8' });
          res.end('{"error":{"code":"internal_error","message":"unexpected server error","retryable":false}}');
        }
      });
    }),
    version,
    startedAt,
    listen({ port, host }) {
      return new Promise((resolvePromise, reject) => {
        this.server.once('error', reject);
        this.server.listen(port, host, () => {
          this.server.off('error', reject);
          resolvePromise(this.server.address());
        });
      });
    },
    close() {
      return new Promise((resolvePromise) => {
        this.server.closeAllConnections?.();
        this.server.close(() => resolvePromise());
      });
    },
  };
}

function defaultLog() {
  if (process.env.LAA_BRIDGE_QUIET === '1') return null;
  return (entry) => {
    process.stdout.write(`${JSON.stringify({ ts: new Date().toISOString(), ...entry })}\n`);
  };
}

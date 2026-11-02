// Error type shared by the router and the route modules. The HTTP pipeline
// turns it into {"error":{code,message,retryable,details?},"requestId"} with
// its status.
//
// Route modules throw BridgeError (or the small helpers below) instead of
// writing status codes by hand, so a forgotten throw cannot leak a stack trace.
//
// `details` is for the one case where a refusal has to hand back the state the
// caller lost against: a stale If-Match returns the current project version,
// hash, ETag and body so the app can show both sides. Everything else stays in
// `message`.

export class BridgeError extends Error {
  constructor(status, code, message, { retryable = false, details = undefined, writeStarted = undefined } = {}) {
    super(message);
    this.name = 'BridgeError';
    this.status = status;
    this.code = code;
    this.retryable = retryable;
    this.details = details;
    if (writeStarted !== undefined) this.writeStarted = writeStarted;
  }
}

// The idempotency ledger may release a reservation only when the handler can
// prove that no external write was attempted. HTTP status is not that proof: a
// 400 or 404 can arrive after a mutation (for example from a write response the
// source could not parse), and a 503 can arrive before one (configuration or
// validation). The marker travels with the error instead.
export function markBeforeWrite(error) {
  if (error && typeof error === 'object' && error.writeStarted === undefined) error.writeStarted = false;
  return error;
}

export function markWriteStarted(error) {
  if (error && typeof error === 'object' && error.writeStarted === undefined) error.writeStarted = true;
  return error;
}

export const badRequest = (code, message) => new BridgeError(400, code, message);

export const notFound = (message = 'no such resource') => new BridgeError(404, 'not_found', message);

export const conflict = (code, message) => new BridgeError(409, code, message);

export const dependencyUnavailable = (message) =>
  new BridgeError(503, 'dependency_unavailable', message, { retryable: true });

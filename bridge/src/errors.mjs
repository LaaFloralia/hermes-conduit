// Error type shared by the router and the route modules. The HTTP pipeline
// turns it into {"error":{code,message,retryable},"requestId"} with its status.
//
// Route modules throw BridgeError (or the small helpers below) instead of
// writing status codes by hand, so a forgotten throw cannot leak a stack trace.

export class BridgeError extends Error {
  constructor(status, code, message, { retryable = false } = {}) {
    super(message);
    this.name = 'BridgeError';
    this.status = status;
    this.code = code;
    this.retryable = retryable;
  }
}

export const badRequest = (code, message) => new BridgeError(400, code, message);

export const notFound = (message = 'no such resource') => new BridgeError(404, 'not_found', message);

export const conflict = (code, message) => new BridgeError(409, code, message);

export const dependencyUnavailable = (message) =>
  new BridgeError(503, 'dependency_unavailable', message, { retryable: true });

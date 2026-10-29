// Error type shared by the router and the route modules. The HTTP pipeline
// turns it into {"error":{code,message,retryable},"requestId"} with its status.

export class BridgeError extends Error {
  constructor(status, code, message, { retryable = false } = {}) {
    super(message);
    this.status = status;
    this.code = code;
    this.retryable = retryable;
  }
}

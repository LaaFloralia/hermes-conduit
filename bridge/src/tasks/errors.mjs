// Error type shared by the task sources and the routes that expose them.
//
// The route layer only forwards a message it produced itself; anything else is
// replaced with a generic sentence so an unexpected error cannot leak a token,
// a GraphQL echo or a filesystem path into a response.

export class TaskSourceError extends Error {
  constructor(code, message, { status = 503, retryable = false } = {}) {
    super(message);
    this.name = 'TaskSourceError';
    this.code = code;
    this.status = status;
    this.retryable = retryable;
  }
}

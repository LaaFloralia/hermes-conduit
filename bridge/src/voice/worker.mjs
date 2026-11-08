// Child-process client for the on-device voice worker.
//
// The Bridge never talks to the model itself: the recogniser and the polisher
// hold their weights in a separate process, so a crash or a runaway generation
// cannot take the HTTP surface down, and the process that owns the microphone
// and Accessibility permissions is not the process that serves requests.
//
// Transport is the child's stdin/stdout, one JSON object per line:
//
//   Bridge -> worker   {id, kind: 'polish', text, language}
//                      {id, kind: 'summarize', text, language}
//                      {id, kind: 'transcribe', pcm16, sampleRate, language}
//   worker -> Bridge   {id, ok: true, text, nothing?}
//                      {id, ok: false, error: 'timeout'|'empty'|'unavailable'|'internal'}
//
// A worker that predates `kind` treats a missing field as polish, so an older
// text-only worker still answers the polish route unchanged. There is no port,
// no socket and no token: the only reachable endpoint is the pipe the Bridge
// created, so the transcript and the audio never appear in argv, the
// environment, a URL or a log line.
//
// Single user, single GPU: there is **no queue**. While a request is being
// generated the next one is answered `busy` immediately, so a request that the
// client has already given up on can never start later. A request that misses
// its deadline, or whose client disconnects, is cancelled by terminating the
// child; the next request starts a fresh one. Cancellation is per request: a
// caller that was refused as busy can never stop the generation already
// running.
//
// Process lifecycle is deliberate:
//   * a child is only replaced after its exit is confirmed (SIGTERM, then
//     SIGKILL after `killGraceMs`); until then new requests get `busy`;
//   * if even SIGKILL is not followed by an exit within the grace period the
//     worker is `wedged` and no new child is started — a second model on the
//     same GPU is worse than being unavailable;
//   * the worker exits on stdin EOF, so a Bridge that dies (even SIGKILL) does
//     not leave an orphan holding the model.

import { spawn } from 'node:child_process';
import { VOICE_COLD_TIMEOUT_MS, VOICE_REQUEST_TIMEOUT_MS } from '../config.mjs';

const DEFAULT_REQUEST_TIMEOUT_MS = VOICE_REQUEST_TIMEOUT_MS;
// A freshly spawned worker loads its model before it reads its first request.
// A dictation that follows speech recognition pays that load again, so the cold
// budget is the request budget plus room for the load rather than a tighter cap
// that would kill a healthy worker and start the load again on every retry.
const DEFAULT_COLD_TIMEOUT_MS = VOICE_COLD_TIMEOUT_MS;
const DEFAULT_KILL_GRACE_MS = 2_000;
// A reply line is a few hundred bytes. 256 KiB is far beyond any answer and
// small enough that a malformed child cannot grow the Bridge's heap.
const MAX_LINE_BYTES = 256 * 1024;

// Newline framing with a byte ceiling, per line.
//
// The limit applies to one line, not to whatever happens to arrive in one
// chunk: a chunk that carries a complete line plus the start of the next one
// must not be refused because their sum is large. A line of exactly
// `maxBytes` is allowed; one byte more is not.
export function createLineFramer(maxBytes) {
  let buffer = Buffer.alloc(0);
  return {
    push(chunk) {
      const lines = [];
      let start = 0;
      for (;;) {
        const newline = chunk.indexOf(0x0A, start);
        if (newline === -1) break;
        const segment = chunk.subarray(start, newline);
        if (buffer.length + segment.length > maxBytes) {
          buffer = Buffer.alloc(0);
          return { lines, tooLong: true };
        }
        buffer = buffer.length === 0 ? segment : Buffer.concat([buffer, segment]);
        lines.push(buffer.toString('utf8'));
        buffer = Buffer.alloc(0);
        start = newline + 1;
      }
      const tail = chunk.subarray(start);
      if (buffer.length + tail.length > maxBytes) {
        buffer = Buffer.alloc(0);
        return { lines, tooLong: true };
      }
      if (tail.length > 0) buffer = buffer.length === 0 ? tail : Buffer.concat([buffer, tail]);
      return { lines, tooLong: false };
    },
  };
}

export class VoiceWorkerError extends Error {
  // kind: busy | timeout | cancelled | unavailable | bad_reply | failed | empty
  constructor(kind) {
    super(kind);
    this.name = 'VoiceWorkerError';
    this.kind = kind;
  }
}

// The one line the worker reads. Polish keeps its original shape plus the
// explicit kind; transcribe carries the base64 PCM the client sent, never
// decoded or re-encoded here, so the worker sees exactly the bytes the app
// recorded.
function wireMessage(id, entry) {
  if (entry.kind === 'transcribe') {
    return { id, kind: 'transcribe', pcm16: entry.pcm16, sampleRate: entry.sampleRate, language: entry.language };
  }
  return { id, kind: entry.kind === 'summarize' ? 'summarize' : 'polish', text: entry.text, language: entry.language };
}

export function createVoiceWorker({
  command,
  args = [],
  env,
  requestTimeoutMs = DEFAULT_REQUEST_TIMEOUT_MS,
  coldTimeoutMs = DEFAULT_COLD_TIMEOUT_MS,
  killGraceMs = DEFAULT_KILL_GRACE_MS,
  restartDelayMs = 750,
  spawnImpl = spawn,
  now = () => Date.now(),
} = {}) {
  if (typeof command !== 'string' || command === '') {
    throw new Error('a voice worker command is required');
  }

  // Only what the worker needs to start and find its model under $HOME. The
  // Bridge's own environment is not forwarded: it may hold credentials that
  // have nothing to do with voice.
  const childEnv = env ?? {
    PATH: process.env.PATH ?? '/usr/bin:/bin:/usr/sbin:/sbin',
    HOME: process.env.HOME ?? '',
    TMPDIR: process.env.TMPDIR ?? '/tmp',
  };

  let child = null;
  let inflight = null;
  let stopped = false;
  let warm = false;
  let lastExitAt = 0;
  let sequence = 0;
  let terminating = null;
  let killTimer = null;
  let wedgeTimer = null;
  let wedged = false;

  function settle(entry) {
    clearTimeout(entry.timer);
    if (entry.signal && entry.onAbort) entry.signal.removeEventListener('abort', entry.onAbort);
  }

  function failInflight(kind) {
    if (!inflight) return;
    const entry = inflight;
    inflight = null;
    settle(entry);
    entry.reject(new VoiceWorkerError(kind));
  }

  // Ask the current child to stop and wait for its exit. A new child is never
  // spawned while this is in progress; SIGKILL is the last resort, and if even
  // that produces no exit the worker stays wedged.
  function terminate(kind) {
    failInflight(kind);
    const target = child;
    if (!target) return;
    if (terminating === target) return;
    terminating = target;
    warm = false;
    try {
      target.kill('SIGTERM');
    } catch {
      // The exit handler still runs if the process is already gone.
    }
    clearTimeout(killTimer);
    killTimer = setTimeout(() => {
      try {
        target.kill('SIGKILL');
      } catch {
        // Nothing left to kill.
      }
      clearTimeout(wedgeTimer);
      wedgeTimer = setTimeout(() => {
        if (terminating === target) wedged = true;
      }, killGraceMs);
      wedgeTimer.unref?.();
    }, killGraceMs);
    killTimer.unref?.();
  }

  function onLine(line, source) {
    // Only the current child may answer; a replaced child's late bytes are
    // dropped before they can be mistaken for the new child's reply.
    if (child !== source) return;
    if (Buffer.byteLength(line, 'utf8') > MAX_LINE_BYTES) {
      terminate('bad_reply');
      return;
    }
    if (line.trim() === '') return;

    let message;
    try {
      message = JSON.parse(line);
    } catch {
      terminate('bad_reply');
      return;
    }
    if (message === null || typeof message !== 'object' || !inflight || message.id !== inflight.id) {
      // A reply nobody is waiting for is a protocol violation, not something to
      // hand to the next caller.
      terminate('bad_reply');
      return;
    }

    const entry = inflight;
    inflight = null;
    settle(entry);

    // An explicit no-op from the polisher (nothing worth inserting). It must
    // not carry text: the Bridge returns an empty answer, and a later client
    // can choose not to insert rather than treating it as a normal reply.
    if (message.ok === true && message.nothing === true) {
      if (message.text !== undefined && (typeof message.text !== 'string' || message.text !== '')) {
        entry.reject(new VoiceWorkerError('bad_reply'));
        terminate('bad_reply');
        return;
      }
      warm = true;
      entry.resolve({ nothing: true });
      return;
    }
    // An empty string is a valid answer: speech recognition returns it for
    // silence, and the transcribe route reports that as success.
    if (message.ok === true && typeof message.text === 'string') {
      warm = true;
      entry.resolve({ text: message.text });
      return;
    }
    if (message.ok === false && typeof message.error === 'string') {
      switch (message.error) {
        case 'timeout':
          entry.reject(new VoiceWorkerError('timeout'));
          return;
        case 'empty':
          // The model returned no usable text for real speech. This is a
          // content outcome, not a protocol fault: keep the warm child.
          warm = true;
          entry.reject(new VoiceWorkerError('empty'));
          return;
        case 'unavailable':
          // The worker cannot run the model. Retire it like any other dead
          // child: the next request gets a fresh process only after this one
          // has exited, and may then recover (for example after weights were
          // installed or a transient MLX failure cleared).
          entry.reject(new VoiceWorkerError('unavailable'));
          terminate('unavailable');
          return;
        case 'internal':
          entry.reject(new VoiceWorkerError('failed'));
          return;
        default:
          entry.reject(new VoiceWorkerError('bad_reply'));
          terminate('bad_reply');
          return;
      }
    }
    entry.reject(new VoiceWorkerError('bad_reply'));
    terminate('bad_reply');
  }

  function ensureChild() {
    if (stopped || wedged) throw new VoiceWorkerError('unavailable');
    if (terminating) throw new VoiceWorkerError('busy');
    if (child && child.exitCode === null) return child;
    if (lastExitAt !== 0 && now() - lastExitAt < restartDelayMs) {
      // Cool-down after an unexpected crash, so a broken worker cannot be
      // respawned once per request.
      throw new VoiceWorkerError('unavailable');
    }

    const started = spawnImpl(command, args, { stdio: ['pipe', 'pipe', 'pipe'], env: childEnv });
    child = started;
    warm = false;
    lastExitAt = 0;
    // Each child owns its framing buffer. A killed child can still flush the
    // tail of a reply, and that tail must neither reach the new child's buffer
    // nor be attributed to the request now in flight.
    // Bytes, not UTF-16 code units: a 200 k-character Japanese line is 600 kB
    // on the wire, and the cap must apply to what the worker actually sends.
    const framer = createLineFramer(MAX_LINE_BYTES);

    started.stdout.on('data', (chunk) => {
      if (child !== started) return;
      const { lines, tooLong } = framer.push(chunk);
      if (tooLong) {
        terminate('bad_reply');
        return;
      }
      for (const line of lines) {
        onLine(line, started);
        if (child !== started) return;
      }
    });
    // Diagnostics are dropped on purpose: they can quote the input text or the
    // audio, and the client must never receive or the operator log retain it.
    started.stderr.resume();
    started.on('error', () => {
      if (child !== started) return;
      if (terminating === started) {
        // An exit event usually follows; the wedge timer covers the rest.
        return;
      }
      child = null;
      lastExitAt = now();
      failInflight('unavailable');
    });
    started.on('exit', (code) => {
      if (terminating === started) {
        clearTimeout(killTimer);
        clearTimeout(wedgeTimer);
        terminating = null;
        wedged = false;
        child = null;
        // A kill we asked for is not a crash: the next request may start
        // immediately. An unexpected exit keeps the cool-down.
        lastExitAt = 0;
        return;
      }
      if (child !== started) return;
      child = null;
      if (code === 3) {
        // The worker refused to start because another process owns the model
        // (the previous Bridge's child is still shutting down). Transient:
        // report busy and allow an immediate retry once the lock is free.
        lastExitAt = 0;
        failInflight('busy');
        return;
      }
      lastExitAt = now();
      failInflight('unavailable');
    });
    started.stdin.on('error', () => {
      if (child === started) terminate('unavailable');
    });
    return started;
  }

  function start(entry) {
    const started = ensureChild();
    const id = `p${++sequence}`;
    // The first request of a child pays for the model load; every later one
    // pays only for generation.
    const budget = warm ? (entry.timeoutMs ?? requestTimeoutMs) : coldTimeoutMs;
    const timer = setTimeout(() => {
      if (inflight && inflight.id === id) terminate('timeout');
    }, budget);
    timer.unref?.();

    const record = { id, timer, resolve: entry.resolve, reject: entry.reject, signal: entry.signal, onAbort: null };
    if (entry.signal) {
      // Cancelling is scoped to this request: by the time the signal fires the
      // id may belong to nobody (already answered) or to a later request, and
      // neither may be stopped by this caller.
      record.onAbort = () => {
        if (inflight && inflight.id === id) terminate('cancelled');
      };
      entry.signal.addEventListener('abort', record.onAbort, { once: true });
    }
    inflight = record;
    try {
      started.stdin.write(`${JSON.stringify(wireMessage(id, entry))}\n`);
    } catch {
      terminate('unavailable');
    }
    return id;
  }

  // `payload.kind` is 'polish' (default), 'summarize' or 'transcribe'. `signal` cancels this
  // request only, when the client that asked for it disconnects.
  function request(payload, { timeoutMs, signal } = {}) {
    return new Promise((resolve, reject) => {
      if (inflight || terminating) {
        // Single user: no queue. A retry after this answer is the client's
        // decision, and it cannot start behind an abandoned request.
        reject(new VoiceWorkerError('busy'));
        return;
      }
      if (signal?.aborted) {
        // The client is already gone; starting a generation nobody can receive
        // would hold the model for the next caller.
        reject(new VoiceWorkerError('cancelled'));
        return;
      }
      try {
        start({ ...payload, timeoutMs, resolve, reject, signal });
      } catch (error) {
        reject(error instanceof VoiceWorkerError ? error : new VoiceWorkerError('unavailable'));
      }
    });
  }

  async function stop() {
    stopped = true;
    const target = child;
    terminate('unavailable');
    if (!target) return;
    const exited = new Promise((resolve) => {
      if (target.exitCode !== null) return resolve();
      target.once('exit', resolve);
      return undefined;
    });
    await Promise.race([
      exited,
      new Promise((resolve) => setTimeout(resolve, killGraceMs * 2).unref?.()),
    ]);
  }

  return {
    request,
    stop,
    get busy() {
      return Boolean(inflight) || Boolean(terminating);
    },
    get wedged() {
      return wedged;
    },
    get pid() {
      return child && child.exitCode === null ? child.pid : null;
    },
  };
}

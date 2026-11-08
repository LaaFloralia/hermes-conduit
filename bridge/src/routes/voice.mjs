// The voice endpoints: POST /v1/voice/{polish,summarize,transcribe}.
//
// These are the only Bridge endpoints that accept the owner's speech, so their
// contract is deliberately narrow:
//
//   * Each route is opened by its own opt-in scope (`voice:polish`,
//     `voice:transcribe`), and neither is part of the default grant (BRIDGE §9).
//     A device gets one only when an operator pairs or re-pairs it with
//     `--scopes voice:polish` / `--scopes voice:transcribe`.
//   * The polish and summary body is `{text, language?}`; the transcribe body is
//     `{pcm16, sampleRate, language?}`. A model name, chat messages, a prompt or
//     an unknown field is refused, so neither endpoint can be turned into a
//     general model proxy.
//   * Neither request is idempotent (nothing is stored), so the idempotency
//     ledger never sees the text or the audio. The Bridge access log records
//     method, path, status and device id only — never the body.
//   * Errors are fixed strings. They never quote the input, the worker's
//     diagnostics or a filesystem path.
//
// Responses repeat no part of the request:
//
//   polish      {text, model: 'qwen3-4b'} or {text: '', nothing: true, model}
//   summarize   {text, model: 'qwen3-4b'}; same opt-in text scope, Japanese only
//   transcribe  {text, model: 'haas-ja-v1.0-q8_0'}
//
// `nothing` is additive for polish: existing clients that only read `text`
// still decode the response unchanged. Transcribe returns an empty `text` as a
// successful result when the recording held no speech.

import {
  VOICE_POLISH_MAX_CHARS,
  VOICE_REQUEST_TIMEOUT_MS,
  VOICE_TRANSCRIBE_BODY_LIMIT_BYTES,
  VOICE_TRANSCRIBE_MAX_BYTES,
  VOICE_TRANSCRIBE_SAMPLE_RATE,
} from '../config.mjs';
import { BridgeError, badRequest } from '../errors.mjs';
import { VoiceWorkerError } from '../voice/worker.mjs';

const POLISH_MODEL = 'qwen3-4b';
const SUMMARY_MAX_CHARS = 2000;
const TRANSCRIBE_MODEL = 'haas-ja-v1.0-q8_0';
const LANGUAGES = new Set(['ja', 'zh', 'en', 'auto']);
// The recogniser is Japanese-only; accepting another language would silently
// transcribe with the wrong model.
const TRANSCRIBE_LANGUAGES = new Set(['ja']);
const POLISH_FIELDS = new Set(['text', 'language']);
const TRANSCRIBE_FIELDS = new Set(['pcm16', 'sampleRate', 'language']);
const BASE64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

function parseObject(rawBody, allowed) {
  if (rawBody === undefined || rawBody.length === 0) {
    throw badRequest('payload_invalid', 'request body must be a JSON object');
  }
  let payload;
  try {
    payload = JSON.parse(rawBody.toString('utf8'));
  } catch {
    throw badRequest('payload_invalid', 'request body is not valid JSON');
  }
  if (payload === null || typeof payload !== 'object' || Array.isArray(payload)) {
    throw badRequest('payload_invalid', 'request body must be a JSON object');
  }
  for (const key of Object.keys(payload)) {
    if (!allowed.has(key)) {
      // The key is not echoed either: a malformed client could put the
      // transcript itself in a field name, and errors must stay body-free.
      throw badRequest('payload_invalid', 'request body contains unsupported fields');
    }
  }
  return payload;
}

function validatePolish(payload, maxChars) {
  const { text } = payload;
  if (typeof text !== 'string') {
    throw badRequest('payload_invalid', 'text must be a string');
  }
  if (text.trim().length === 0) {
    throw badRequest('payload_invalid', 'text must not be empty');
  }
  // Counted in UTF-16 code units (`String.length`) to match the iOS client and
  // the worker; spreading into code points would let the app and the Bridge
  // disagree on where 4,000 ends.
  if (text.length > maxChars) {
    throw badRequest('text_too_long', `text must be at most ${maxChars} characters`);
  }
  const language = payload.language ?? 'ja';
  if (typeof language !== 'string' || !LANGUAGES.has(language)) {
    throw badRequest('payload_invalid', 'language must be one of ja, zh, en, auto');
  }
  return { text, language };
}

// The audio is validated here, not in the worker: the Bridge must refuse an
// oversized or malformed recording before a model process sees it, and the
// base64 must be canonical so two encodings of the same bytes cannot look like
// two different recordings.
function validateTranscribe(payload) {
  const { pcm16 } = payload;
  if (typeof pcm16 !== 'string' || pcm16 === '') {
    throw badRequest('audio_invalid', 'pcm16 must be a non-empty base64 string');
  }
  if (pcm16.length % 4 !== 0 || !BASE64.test(pcm16)) {
    throw badRequest('audio_invalid', 'pcm16 must be canonical base64');
  }
  const bytes = Buffer.from(pcm16, 'base64');
  // Node skips characters it does not understand, so the round trip is the
  // check that the string really is the canonical encoding of its bytes.
  if (bytes.length === 0 || bytes.toString('base64') !== pcm16) {
    throw badRequest('audio_invalid', 'pcm16 must be canonical base64');
  }
  if (bytes.length % 2 !== 0) {
    throw badRequest('audio_invalid', 'pcm16 must be a whole number of 16-bit samples');
  }
  if (bytes.length > VOICE_TRANSCRIBE_MAX_BYTES) {
    throw new BridgeError(400, 'audio_too_large', `pcm16 must be at most ${VOICE_TRANSCRIBE_MAX_BYTES} bytes (25 s at 16 kHz mono)`);
  }
  if (payload.sampleRate !== VOICE_TRANSCRIBE_SAMPLE_RATE) {
    throw badRequest('payload_invalid', `sampleRate must be ${VOICE_TRANSCRIBE_SAMPLE_RATE}`);
  }
  const language = payload.language ?? 'ja';
  if (typeof language !== 'string' || !TRANSCRIBE_LANGUAGES.has(language)) {
    throw badRequest('payload_invalid', 'language must be ja');
  }
  return { pcm16, sampleRate: payload.sampleRate, language };
}

function failure(error) {
  if (error instanceof VoiceWorkerError) {
    if (error.kind === 'busy') {
      return new BridgeError(429, 'voice_busy', 'the on-device model is still working on another request', {
        retryable: true,
      });
    }
    if (error.kind === 'timeout') {
      return new BridgeError(504, 'voice_timeout', 'the on-device model did not answer in time', {
        retryable: true,
      });
    }
    if (error.kind === 'empty') {
      // The app's `Pipeline` retries an empty reply once and then reports
      // `emptyReply`; this is a content failure, not a protocol fault. Keep it
      // distinct from `voice_bad_reply` so the client is not told to re-pair.
      return new BridgeError(503, 'voice_empty', 'the on-device model returned no text', {
        retryable: false,
      });
    }
    if (error.kind === 'cancelled') {
      // The client is gone; this status never reaches it.
      return new BridgeError(499, 'client_closed', 'the client closed the connection', { retryable: false });
    }
    if (error.kind === 'bad_reply') {
      return new BridgeError(503, 'voice_bad_reply', 'the on-device model returned an unusable answer', {
        retryable: false,
      });
    }
    if (error.kind === 'failed') {
      return new BridgeError(503, 'voice_failed', 'the on-device model failed to produce an answer', {
        retryable: true,
      });
    }
  }
  return new BridgeError(503, 'voice_unavailable', 'the on-device model is not available', {
    retryable: true,
  });
}

function badReply() {
  return new BridgeError(503, 'voice_bad_reply', 'the on-device model returned an unusable answer', {
    retryable: false,
  });
}

// Runs one request against the worker and cancels it only if this request's own
// client goes away. The controller is per request, so a caller that was refused
// as busy cannot stop the generation that was already running.
async function run(worker, payload, { res, timeoutMs }) {
  if (!worker) {
    throw new BridgeError(503, 'voice_not_configured', 'voice is not configured on this Mac');
  }
  // The socket can already be gone when the handler runs (the client closed
  // while the body was read or auth was checked). Starting a generation for a
  // response nobody can receive must not happen, and `close` would never fire
  // again to cancel it.
  if (res && (res.destroyed || res.writableEnded)) {
    throw new BridgeError(499, 'client_closed', 'the client closed the connection', { retryable: false });
  }

  const controller = new AbortController();
  const onClose = () => {
    if (!res.writableEnded) controller.abort();
  };
  if (res && typeof res.once === 'function') res.once('close', onClose);
  try {
    return await worker.request(payload, { timeoutMs, signal: controller.signal });
  } catch (error) {
    throw failure(error);
  } finally {
    if (res && typeof res.off === 'function') res.off('close', onClose);
  }
}

export function voiceRoutes({
  worker = null,
  maxChars = VOICE_POLISH_MAX_CHARS,
  timeoutMs = VOICE_REQUEST_TIMEOUT_MS,
  maxOutputChars = 16_000,
} = {}) {
  return [
    {
      method: 'POST',
      path: '/v1/voice/polish',
      auth: true,
      scope: 'voice:polish',
      idempotent: false,
      async handler({ rawBody, res }) {
        const payload = validatePolish(parseObject(rawBody, POLISH_FIELDS), maxChars);
        if (!worker) {
          throw new BridgeError(503, 'voice_not_configured', 'voice polish is not configured on this Mac');
        }
        const result = await run(worker, payload, { res, timeoutMs });
        if (result?.nothing === true) {
          // A contradictory payload is a protocol fault, not a no-op.
          if (result.text !== undefined && result.text !== '') throw badReply();
          return { status: 200, data: { text: '', nothing: true, model: POLISH_MODEL } };
        }
        const text = typeof result?.text === 'string' ? result.text.trim() : '';
        if (text === '' || text.length > maxOutputChars) throw badReply();
        return { status: 200, data: { text, model: POLISH_MODEL } };
      },
    },
    {
      method: 'POST',
      path: '/v1/voice/summarize',
      auth: true,
      scope: 'voice:polish',
      idempotent: false,
      async handler({ rawBody, res }) {
        const payload = validatePolish(parseObject(rawBody, POLISH_FIELDS), Math.min(maxChars, SUMMARY_MAX_CHARS));
        if (payload.language !== 'ja') throw badRequest('payload_invalid', 'summary requires ja');
        const result = await run(worker, { kind: 'summarize', ...payload }, { res, timeoutMs });
        const text = typeof result?.text === 'string' ? result.text.trim() : '';
        if (result?.nothing === true || text === '' || text.length > maxOutputChars) throw badReply();
        return { status: 200, data: { text, model: POLISH_MODEL } };
      },
    },
    {
      method: 'POST',
      path: '/v1/voice/transcribe',
      auth: true,
      scope: 'voice:transcribe',
      idempotent: false,
      // 25 s of 16 kHz mono PCM16LE is 800,000 bytes, ~1.07 MB once base64
      // encoded, so this route raises the default 64 KiB body limit.
      bodyLimit: VOICE_TRANSCRIBE_BODY_LIMIT_BYTES,
      async handler({ rawBody, res }) {
        const payload = validateTranscribe(parseObject(rawBody, TRANSCRIBE_FIELDS));
        if (!worker) {
          throw new BridgeError(503, 'voice_not_configured', 'voice transcribe is not configured on this Mac');
        }
        const result = await run(worker, { kind: 'transcribe', ...payload }, { res, timeoutMs });
        // Silence is a successful result with no text, not a failure: the app
        // decides whether an empty transcript means "say that again".
        const text = typeof result?.text === 'string' ? result.text.trim() : null;
        if (text === null || text.length > maxOutputChars) throw badReply();
        return { status: 200, data: { text, model: TRANSCRIBE_MODEL } };
      },
    },
  ];
}

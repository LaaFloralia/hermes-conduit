// Google credentials are read at runtime from the owner's
// existing wrapper; they are never cached to disk, logged, or returned.
import { execFile } from 'node:child_process';
import { BridgeError } from '../errors.mjs';

export const DEFAULT_CREDENTIAL_HELPER = '/Users/laa/.config/laa/google-calendar-credential.sh';
const HELPER_TIMEOUT_MS = 10_000;
const HELPER_MAX_BUFFER = 16 * 1024;
const REQUEST_TIMEOUT_MS = 12_000;
const TOKEN_SKEW_MS = 60_000;

const failure = (code, message, retryable = false) => new BridgeError(503, code, message, { retryable });
const unavailable = () => failure('calendar_not_configured', 'Google Calendar credentials are unavailable');
const nonEmpty = (value) => (typeof value === 'string' && value.trim() !== '' ? value : null);

// Executes the helper directly: no shell, no arguments, bounded output. The
// helper's stdout is a secret and stderr is discarded, so neither can reach a
// log or an API error.
export function readCredentialViaHelper(
  helper = DEFAULT_CREDENTIAL_HELPER,
  { timeoutMs = HELPER_TIMEOUT_MS, execFileImpl = execFile } = {},
) {
  return new Promise((resolve, reject) => {
    execFileImpl(helper, [], { timeout: timeoutMs, maxBuffer: HELPER_MAX_BUFFER }, (error, stdout) => {
      if (error) {
        reject(unavailable());
        return;
      }
      let parsed;
      try {
        parsed = JSON.parse(stdout);
      } catch {
        reject(unavailable());
        return;
      }
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
        reject(unavailable());
        return;
      }
      resolve(parsed);
    });
  });
}

export function createGoogleConnection({
  env = process.env,
  fetchImpl = fetch,
  helper = DEFAULT_CREDENTIAL_HELPER,
  readCredential = () => readCredentialViaHelper(helper),
  now = Date.now,
} = {}) {
  let cachedToken = null;
  let pendingRefresh = null;

  async function credential() {
    const envClientId = nonEmpty(env.LAA_GOOGLE_CALENDAR_CLIENT_ID);
    const envClientSecret = nonEmpty(env.LAA_GOOGLE_CALENDAR_CLIENT_SECRET);
    const envRefreshToken = nonEmpty(env.LAA_GOOGLE_CALENDAR_REFRESH_TOKEN);
    let clientId;
    let clientSecret;
    let refreshToken;
    let helperCalendarId = null;
    if (envClientId && envClientSecret && envRefreshToken) {
      // Explicit test override; all three values must be present.
      clientId = envClientId;
      clientSecret = envClientSecret;
      refreshToken = envRefreshToken;
    } else {
      let value;
      try {
        value = await readCredential();
      } catch {
        throw unavailable();
      }
      if (!value || typeof value !== 'object' || Array.isArray(value)) throw unavailable();
      clientId = nonEmpty(value.client_id);
      clientSecret = nonEmpty(value.client_secret);
      refreshToken = nonEmpty(value.refresh_token);
      if (!clientId || !clientSecret || !refreshToken) throw unavailable();
      if (value.calendar_id != null && typeof value.calendar_id !== 'string') throw unavailable();
      helperCalendarId = nonEmpty(value.calendar_id);
    }
    return {
      clientId,
      clientSecret,
      refreshToken,
      calendarId: nonEmpty(env.LAA_GOOGLE_CALENDAR_ID) ?? helperCalendarId ?? 'primary',
    };
  }

  const request = async (signal, url, options) => {
    try {
      return await fetchImpl(url, { ...options, signal, redirect: 'error' });
    } catch {
      throw failure('calendar_unavailable', 'Google Calendar could not be reached', true);
    }
  };

  const json = async (response) => {
    try {
      return await response.json();
    } catch {
      throw failure('calendar_invalid_response', 'Google Calendar returned an invalid response', true);
    }
  };

  async function refresh() {
    const { clientId, clientSecret, refreshToken, calendarId } = await credential();
    const auth = await request(AbortSignal.timeout(REQUEST_TIMEOUT_MS), 'https://oauth2.googleapis.com/token', {
      method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ client_id: clientId, client_secret: clientSecret,
        refresh_token: refreshToken, grant_type: 'refresh_token' }),
    });
    if (!auth.ok) {
      throw failure(auth.status >= 500 || auth.status === 429 ? 'calendar_unavailable' : 'calendar_auth_required',
        'Google Calendar authorization could not be refreshed', auth.status >= 500 || auth.status === 429);
    }
    const token = await json(auth);
    if (typeof token?.access_token !== 'string' || !token.access_token) {
      throw failure('calendar_invalid_response', 'Google Calendar returned an invalid response');
    }
    const expiresIn = Number(token.expires_in);
    const lifetimeMs = Number.isFinite(expiresIn) && expiresIn > 0 ? expiresIn * 1000 : 300_000;
    cachedToken = {
      value: token.access_token,
      calendarId,
      expiresAt: now() + Math.max(0, lifetimeMs - TOKEN_SKEW_MS),
    };
    return cachedToken;
  }

  function accessToken() {
    if (cachedToken && now() < cachedToken.expiresAt) return Promise.resolve(cachedToken);
    if (!pendingRefresh) {
      pendingRefresh = (async () => {
        try {
          return await refresh();
        } finally {
          pendingRefresh = null;
        }
      })();
    }
    return pendingRefresh;
  }

  return {
    accessToken,
    async request(url, options = {}, area = 'calendar') {
      const target = new URL(url);
      if (target.protocol !== 'https:' || target.port || target.username || target.password ||
        !['www.googleapis.com','lh3.googleusercontent.com','lh4.googleusercontent.com','lh5.googleusercontent.com','lh6.googleusercontent.com'].includes(target.hostname)) {
        throw new BridgeError(400, 'google_url_invalid', 'Unsupported Google request target');
      }
      const token = await accessToken();
      const response = await request(options.signal ?? AbortSignal.timeout(REQUEST_TIMEOUT_MS), url,
        { method: 'GET', ...options, headers: { ...options.headers, authorization: `Bearer ${token.value}` } });
      if (!response.ok && response.status !== 308 && response.status !== 416) {
        if (response.status === 401 && cachedToken === token) cachedToken = null;
        const code = response.status === 401 ? `${area}_auth_required`
          : response.status === 403 ? `${area}_access_denied`
            : response.status === 404 ? `${area}_not_found`
              : response.status === 412 ? `${area}_conflict` : `${area}_unavailable`;
        throw new BridgeError(response.status === 412 ? 409 : 503, code,
          `Google ${area} request failed`, { retryable: response.status === 429 || response.status >= 500 });
      }
      return response;
    },
    json,
  };
}

// Production Calendar and Drive share the same refresh and in-memory token.
export const googleConnection = createGoogleConnection();

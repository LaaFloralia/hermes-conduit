// Google Drive REST adapter (v3) with zero dependencies.
//
// The Bridge does not read the Drive desktop sync folder: macOS gates that
// folder behind a TCC prompt for the node process, and the sync client only
// serves a file after materializing it, which defeats Range playback. Instead
// the Bridge calls the Drive API directly and relays the client's Range header
// to files.get?alt=media, so the bytes and the seek behaviour are Drive's.
//
// Authorization is deliberately not created here. The adapter takes an access
// token provider; if no provider is configured the routes answer 503
// drive_not_configured and nothing is attempted. The credential the owner has
// to approve is an OAuth client plus a refresh token with
// https://www.googleapis.com/auth/drive.readonly (see bridge/README.md).

const DEFAULT_BASE_URL = 'https://www.googleapis.com/drive/v3';
const TOKEN_URL = 'https://oauth2.googleapis.com/token';
const FILE_FIELDS = 'id,name,mimeType,size,modifiedTime,parents,webViewLink,trashed,shortcutDetails';
const LIST_FIELDS = `nextPageToken,files(${FILE_FIELDS})`;

const WORKSPACE_MIME = {
  'application/vnd.google-apps.document': [
    'application/pdf',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'text/plain',
  ],
  'application/vnd.google-apps.spreadsheet': [
    'application/pdf',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'text/csv',
  ],
  'application/vnd.google-apps.presentation': [
    'application/pdf',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  ],
  'application/vnd.google-apps.drawing': ['application/pdf'],
  'application/vnd.google-apps.form': ['application/pdf'],
};

export class DriveNotConfiguredError extends Error {
  constructor(message = 'no Google Drive authorization is configured for the Bridge') {
    super(message);
    this.code = 'drive_not_configured';
  }
}

export class DriveAuthError extends Error {
  constructor(message = 'the Google Drive authorization was refused') {
    super(message);
    this.code = 'drive_auth_failed';
  }
}

export class DriveUpstreamError extends Error {
  constructor(message = 'the Google Drive API request failed', status = null) {
    super(message);
    this.code = 'drive_upstream_failed';
    this.upstreamStatus = status;
  }
}

const ID_PATTERN = /^[A-Za-z0-9_-]{5,200}$/;

export function isDriveId(value) {
  return typeof value === 'string' && ID_PATTERN.test(value);
}

// Drive search syntax: backslash and single quote are the only characters that
// can end the literal early.
function escapeQuery(value) {
  return value.replace(/\\/g, '\\\\').replace(/'/g, "\\'");
}

export function itemFromDrive(file) {
  const mimeType = file.mimeType ?? 'application/octet-stream';
  const isFolder = mimeType === 'application/vnd.google-apps.folder';
  const exportFormats = WORKSPACE_MIME[mimeType];
  const kind = isFolder ? 'folder' : exportFormats ? 'workspace_document' : 'file';
  const size = typeof file.size === 'string' ? Number(file.size) : typeof file.size === 'number' ? file.size : null;
  const item = {
    id: file.id,
    name: file.name ?? '',
    mimeType,
    kind,
    size: kind === 'file' ? size : null,
    modifiedAt: file.modifiedTime ?? null,
    parents: Array.isArray(file.parents) ? file.parents : [],
    downloadable: kind === 'file',
    webViewLink: file.webViewLink ?? null,
  };
  if (kind === 'workspace_document') item.exportFormats = exportFormats;
  return item;
}

/**
 * Exchange a refresh token for access tokens and cache them until shortly
 * before they expire. The refresh token, client id and secret are only ever
 * sent to the token endpoint; they are not logged or returned.
 */
export function createRefreshTokenProvider({
  clientId,
  clientSecret,
  refreshToken,
  fetch: fetchImpl = globalThis.fetch,
  tokenUrl = TOKEN_URL,
  now = () => Date.now(),
  skewMs = 60_000,
} = {}) {
  if (!clientId || !clientSecret || !refreshToken) {
    throw new DriveNotConfiguredError('refresh token credentials are incomplete');
  }
  let cached = null;
  let inflight = null;
  return async function accessToken() {
    if (cached && cached.expiresAt - skewMs > now()) return cached.token;
    if (inflight) return inflight;
    inflight = (async () => {
      try {
        const response = await fetchImpl(tokenUrl, {
          method: 'POST',
          headers: { 'content-type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({
            grant_type: 'refresh_token',
            client_id: clientId,
            client_secret: clientSecret,
            refresh_token: refreshToken,
          }).toString(),
        });
        if (!response.ok) throw new DriveAuthError('the refresh token was refused');
        const body = await response.json();
        if (typeof body.access_token !== 'string' || body.access_token === '') {
          throw new DriveAuthError('the token endpoint returned no access token');
        }
        const lifetime = Number(body.expires_in ?? 0) * 1000;
        cached = { token: body.access_token, expiresAt: now() + (Number.isFinite(lifetime) ? lifetime : 0) };
        return cached.token;
      } finally {
        inflight = null;
      }
    })();
    return inflight;
  };
}

/**
 * @param {object} options
 * @param {() => Promise<string>} [options.getAccessToken] token provider.
 * @param {Function} [options.fetch] fetch implementation (tests).
 * @param {string} [options.baseUrl] Drive API base URL (tests).
 */
export function createGoogleDriveApiAdapter({
  getAccessToken = null,
  fetch: fetchImpl = globalThis.fetch,
  baseUrl = DEFAULT_BASE_URL,
} = {}) {
  const configured = typeof getAccessToken === 'function';

  async function call(path, { query, method = 'GET', headers = {}, signal } = {}) {
    if (!configured) throw new DriveNotConfiguredError();
    const url = new URL(`${baseUrl}${path}`);
    for (const [key, value] of Object.entries(query ?? {})) {
      if (value !== undefined && value !== null && value !== '') url.searchParams.set(key, String(value));
    }
    const token = await getAccessToken();
    let response;
    try {
      response = await fetchImpl(url, {
        method,
        headers: { authorization: `Bearer ${token}`, ...headers },
        signal,
      });
    } catch (error) {
      if (error?.name === 'AbortError') throw error;
      throw new DriveUpstreamError('the Google Drive API is unreachable');
    }
    if (response.status === 401 || response.status === 403) {
      // 403 can be a per-file permission denial too; only a token problem is
      // ours to report as an authorization failure.
      const body = await response.text().catch(() => '');
      if (response.status === 401 || /invalid_grant|invalid_token|insufficient.*scope/i.test(body)) {
        throw new DriveAuthError();
      }
      return { response, denied: true };
    }
    if (response.status === 404) return { response, missing: true };
    if (response.status >= 500) throw new DriveUpstreamError('the Google Drive API failed', response.status);
    if (!response.ok && response.status !== 416) {
      throw new DriveUpstreamError(`the Google Drive API returned ${response.status}`, response.status);
    }
    return { response };
  }

  return {
    kind: 'google-drive-api',
    configured,
    async list({ query = '', folderId = null, pageSize = 50, pageToken = null } = {}) {
      const clauses = ['trashed = false'];
      if (folderId) {
        if (!isDriveId(folderId)) throw new DriveUpstreamError('folder id is not a Drive id');
        clauses.push(`'${folderId}' in parents`);
      }
      if (query) clauses.push(`name contains '${escapeQuery(query)}'`);
      const { response } = await call('/files', {
        query: {
          q: clauses.join(' and '),
          fields: LIST_FIELDS,
          pageSize,
          pageToken,
          orderBy: 'folder,name',
          spaces: 'drive',
          corpora: 'allDrives',
          includeItemsFromAllDrives: 'true',
          supportsAllDrives: 'true',
        },
      });
      const body = await response.json();
      const files = Array.isArray(body.files) ? body.files : [];
      return {
        items: files.map(itemFromDrive),
        nextPageToken: typeof body.nextPageToken === 'string' && body.nextPageToken !== '' ? body.nextPageToken : null,
      };
    },
    async get(id) {
      if (!isDriveId(id)) return null;
      const { response, missing, denied } = await call(`/files/${encodeURIComponent(id)}`, {
        query: { fields: FILE_FIELDS, supportsAllDrives: 'true' },
      });
      if (missing || denied) return null;
      const file = await response.json();
      if (file.trashed) return null;
      return { item: itemFromDrive(file), etag: response.headers.get('etag') ?? null };
    },
    // The client's Range header is forwarded unchanged; Drive answers 206 with
    // Content-Range or 416, and the route relays that status and the bytes.
    async open(id, { range = null, signal } = {}) {
      if (!isDriveId(id)) return null;
      const headers = {};
      if (typeof range === 'string' && range !== '') headers.range = range;
      const { response, missing, denied } = await call(`/files/${encodeURIComponent(id)}`, {
        query: { alt: 'media', supportsAllDrives: 'true' },
        headers,
        signal,
      });
      if (missing || denied) return null;
      return {
        status: response.status,
        headers: response.headers,
        stream: response.body,
      };
    },
  };
}

// Reads the credentials the owner would have to authorize. Nothing is created
// or guessed here: without all three values the routes stay 503.
export function driveAdapterFromEnv(env = process.env, { fetch: fetchImpl } = {}) {
  const clientId = env.LAA_DRIVE_CLIENT_ID;
  const clientSecret = env.LAA_DRIVE_CLIENT_SECRET;
  const refreshToken = env.LAA_DRIVE_REFRESH_TOKEN;
  if (!clientId || !clientSecret || !refreshToken) return null;
  return createGoogleDriveApiAdapter({
    getAccessToken: createRefreshTokenProvider({ clientId, clientSecret, refreshToken, fetch: fetchImpl }),
    fetch: fetchImpl,
  });
}

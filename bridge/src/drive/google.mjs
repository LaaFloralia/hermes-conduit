import { Readable } from 'node:stream';
import { randomUUID } from 'node:crypto';
import { BridgeError } from '../errors.mjs';
import { googleConnection } from '../google/connection.mjs';

const fields = 'id,name,mimeType,size,version,modifiedTime,webViewLink,hasThumbnail,thumbnailLink,thumbnailVersion,capabilities(canDownload,canAddChildren),shortcutDetails,owners(displayName)';
const api = 'https://www.googleapis.com/drive/v3';
const folderType = 'application/vnd.google-apps.folder';
const escapeQuery = value => value.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
const fail = (code, message, status = 503) => new BridgeError(status, code, message);
export function driveItem(f) {
  if (!f || typeof f.id !== 'string' || typeof f.name !== 'string' || typeof f.mimeType !== 'string') throw fail('drive_invalid_response', 'Invalid Google Drive file');
  const workspace = f.mimeType.startsWith('application/vnd.google-apps.') && ![folderType, 'application/vnd.google-apps.shortcut'].includes(f.mimeType);
  return { id: f.id, name: f.name, mimeType: f.mimeType,
    kind: f.mimeType === folderType ? 'folder' : f.mimeType === 'application/vnd.google-apps.shortcut' ? 'shortcut' : workspace ? 'workspace_document' : 'file',
    size: f.size == null ? null : Number(f.size), version: f.version ?? null, modifiedAt: f.modifiedTime ?? null,
    downloadable: f.capabilities?.canDownload ?? null, webViewLink: f.webViewLink ?? null,
    hasThumbnail: f.hasThumbnail ?? false, thumbnailVersion: f.thumbnailVersion ?? null,
    shortcut: f.shortcutDetails ? { targetId: f.shortcutDetails.targetId, targetMimeType: f.shortcutDetails.targetMimeType, requiresResourceKey: !!f.shortcutDetails.targetResourceKey } : null, owners: f.owners ?? [],
    exportFormats: workspace ? ['application/pdf'] : [], thumbnailLink: null };
}
export function createGoogleDrive({ connection = googleConnection, now = Date.now } = {}) {
  const uploads = new Map();
  const request = (url, options) => connection.request(url, options, 'drive');
  async function get(id, { signal } = {}) {
    const url = new URL(`${api}/files/${encodeURIComponent(id)}`);
    url.search = new URLSearchParams({ fields, supportsAllDrives: 'true' });
    return { item: driveItem(await connection.json(await request(url, { signal }))) };
  }
  async function bounded(response, limit) {
    const parts = []; let size = 0;
    for await (const chunk of response.body) {
      size += chunk.length;
      if (size > limit) { await response.body.cancel?.().catch(() => {}); throw fail('drive_export_too_large', 'Google Drive response exceeds the size limit', 409); }
      parts.push(chunk);
    }
    return Buffer.concat(parts);
  }
  return {
    get,
    async list({ query = '', folderId, pageSize = 50, pageToken, view = 'my', signal } = {}) {
      if (view === 'shared' && !folderId) {
        const url = new URL(`${api}/drives`);
        url.search = new URLSearchParams({ pageSize: String(pageSize), fields: 'drives(id,name),nextPageToken', ...(pageToken ? { pageToken } : {}) });
        const data = await connection.json(await request(url, { signal }));
        if (!Array.isArray(data.drives)) throw fail('drive_invalid_response', 'Invalid shared drives');
        return { items: data.drives.filter(d => !query || d.name.toLowerCase().includes(query.toLowerCase()))
          .map(d => driveItem({ ...d, mimeType: folderType })), nextPageToken: data.nextPageToken, incompleteSearch: false };
      }
      const q = ['trashed = false'];
      if (folderId) q.push(`'${escapeQuery(folderId)}' in parents`);
      else if (view === 'sharedWithMe') q.push('sharedWithMe = true');
      else if (view === 'starred') q.push('starred = true');
      else if (view === 'my' && !query) q.push("'root' in parents");
      if (query) q.push(`fullText contains '${escapeQuery(query)}'`);
      const url = new URL(`${api}/files`);
      url.search = new URLSearchParams({ q: q.join(' and '), pageSize: String(pageSize), spaces: 'drive',
        supportsAllDrives: 'true', includeItemsFromAllDrives: 'true',
        orderBy: view === 'recent' ? 'viewedByMeTime desc,modifiedTime desc' : 'folder,name',
        fields: `files(${fields}),nextPageToken,incompleteSearch`, ...(pageToken ? { pageToken } : {}) });
      const data = await connection.json(await request(url, { signal }));
      if (!Array.isArray(data.files)) throw fail('drive_invalid_response', 'Invalid Google Drive listing');
      return { items: data.files.map(driveItem), nextPageToken: data.nextPageToken, incompleteSearch: data.incompleteSearch ?? false };
    },
    async open(id, { range, signal } = {}) {
      const response = await request(`${api}/files/${encodeURIComponent(id)}?alt=media&supportsAllDrives=true`,
        { signal, headers: range ? { range } : {} });
      return { status: response.status, headers: response.headers, stream: response.body ? Readable.fromWeb(response.body) : Readable.from([]) };
    },
    async exportPdf(id, { signal } = {}) {
      const response = await request(`${api}/files/${encodeURIComponent(id)}/export?mimeType=application%2Fpdf`, { signal });
      return { body: await bounded(response, 10_000_000), mimeType: 'application/pdf' };
    },
    async thumbnail(id, { signal } = {}) {
      const meta = await connection.json(await request(`${api}/files/${encodeURIComponent(id)}?fields=thumbnailLink&supportsAllDrives=true`, { signal }));
      if (!meta.thumbnailLink) return null;
      const url = new URL(meta.thumbnailLink);
      // Only Google-issued image hosts, never a file's user-supplied link.
      if (url.protocol !== 'https:' || url.port || url.username || url.password ||
        !['lh3.googleusercontent.com', 'lh4.googleusercontent.com', 'lh5.googleusercontent.com', 'lh6.googleusercontent.com'].includes(url.hostname)) return null;
      const response = await request(url, { signal });
      return { body: await bounded(response, 2 * 1024 * 1024), mimeType: response.headers.get('content-type')?.split(';')[0] };
    },
    async beginUpload({ name, mimeType, size, folderId, deviceId }) {
      for (const [id, value] of uploads) if (value.expires < now()) uploads.delete(id);
      if (uploads.size >= 16) throw fail('upload_busy', 'Too many uploads', 429);
      const url = new URL('https://www.googleapis.com/upload/drive/v3/files');
      url.search = new URLSearchParams({ uploadType: 'resumable', supportsAllDrives: 'true', fields });
      const response = await request(url, { method: 'POST', headers: { 'content-type': 'application/json',
        'x-upload-content-type': mimeType, 'x-upload-content-length': String(size) },
        body: JSON.stringify({ name, ...(folderId ? { parents: [folderId] } : {}) }) });
      const location = response.headers.get('location');
      const target = location && new URL(location);
      if (!target || target.origin !== 'https://www.googleapis.com' || !target.pathname.startsWith('/upload/drive/')) throw fail('drive_invalid_response', 'Invalid upload response');
      const id = randomUUID();
      uploads.set(id, { location, deviceId, size, mimeType, offset: 0, expires: now() + 3600_000 });
      return { id, chunkSize: 4 * 1024 * 1024 };
    },
    async uploadChunk({ id, offset, body, deviceId }) {
      const state = uploads.get(id);
      if (!state || state.deviceId !== deviceId || state.expires < now()) throw fail('upload_expired', 'Upload expired; select the file again', 410);
      if (state.inflight) throw fail('upload_busy', 'Upload chunk is already in flight', 409);
      if (offset !== state.offset || !body.length || offset + body.length > state.size ||
        (offset + body.length < state.size && body.length % (256 * 1024) !== 0)) throw fail('upload_offset_invalid', 'Invalid upload offset', 409);
      state.inflight = true;
      try {
      const response = await request(state.location, { method: 'PUT', headers: { 'content-type': state.mimeType,
        'content-range': `bytes ${offset}-${offset + body.length - 1}/${state.size}` }, body });
      if (response.status === 308) {
        const match = /^bytes=0-(\d+)$/.exec(response.headers.get('range') ?? '');
        if (!match || Number(match[1]) + 1 !== offset + body.length) throw fail('drive_invalid_response', 'Invalid upload acknowledgement');
        state.offset += body.length;
        return { completed: false, offset: state.offset };
      }
      const item = driveItem(await connection.json(response));
      uploads.delete(id);
      return { completed: true, offset: state.size, item };
      } finally { state.inflight = false; }
    },
  };
}

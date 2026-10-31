// Local Studio intake boundary. No TCP, Cloudflare or control.json is used.
import http from 'node:http';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { lstat, readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { BridgeError } from '../errors.mjs';

const execFileAsync = promisify(execFile);
const MAX_JSON = 32 * 1024 * 1024;
const unavailable = () => new BridgeError(503, 'studio_not_connected', 'Studio is not connected on the Mac', { retryable: true });

export function createStudioBackend({
  directory = join(homedir(), 'Library', 'Application Support', 'LAA Creative Studio', 'Remote'),
  launch = () => execFileAsync(join(homedir(), 'dev', 'studio', 'bin', 'studio'), ['{"operation":"intake.snapshot"}'],
    { timeout: 8000, maxBuffer: 1024 * 1024 }),
  now = () => Date.now(), startupIntervalMs = 30000,
} = {}) {
  const socketPath = join(directory, 'intake.sock');
  const metadataPath = join(directory, 'intake.json');
  let lastStart = -Infinity;
  let starting = null;

  async function metadata() {
    try {
      const [folder, file, socket] = await Promise.all([lstat(directory), lstat(metadataPath), lstat(socketPath)]);
      const uid = process.getuid?.();
      if (!folder.isDirectory() || !file.isFile() || !socket.isSocket() ||
          (folder.mode & 0o777) !== 0o700 || (file.mode & 0o777) !== 0o600 || (socket.mode & 0o777) !== 0o600 ||
          (uid !== undefined && [folder, file, socket].some((entry) => entry.uid !== uid))) throw unavailable();
      const doc = JSON.parse(await readFile(metadataPath, 'utf8'));
      if (doc.version !== 1 || doc.socketPath !== socketPath || typeof doc.token !== 'string' ||
          !/^[a-f0-9]{64}$/i.test(doc.token) || typeof doc.bootId !== 'string' ||
          !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(doc.bootId) ||
          !Number.isInteger(doc.pid) || doc.pid <= 0) throw unavailable();
      return doc;
    } catch { throw unavailable(); }
  }

  function rawRequest(info, { path, method = 'GET', body, range, signal }) {
    return new Promise((resolve, reject) => {
      const headers = { authorization: `Bearer ${info.token}`, accept: 'application/json' };
      if (body !== undefined) headers['content-type'] = 'application/json';
      if (range) headers.range = range;
      const request = http.request({ socketPath, path, method, headers, signal, timeout: 12000 }, resolve);
      request.on('timeout', () => request.destroy(Object.assign(new Error('timeout'), { code: 'ETIMEDOUT' })));
      request.on('error', reject);
      if (body !== undefined) request.end(JSON.stringify(body)); else request.end();
    });
  }

  async function startOnce() {
    if (starting) return starting;
    if (now() - lastStart < startupIntervalMs) return;
    lastStart = now();
    starting = Promise.resolve().then(launch).catch(() => {}).finally(() => { starting = null; });
    return starting;
  }

  async function request(args) {
    let response;
    for (let attempt = 0; attempt < 2; attempt += 1) {
      try {
        const info = await metadata();
        response = await rawRequest(info, args);
        if (response.statusCode !== 401) return response;
        response.resume(); // Studio may have restarted and replaced the token.
      } catch (error) {
        if (error?.name === 'AbortError') throw error;
        if (attempt === 0 && (error?.code === 'ENOENT' || error?.code === 'ECONNREFUSED' || error?.code === 'studio_not_connected')) {
          await startOnce();
        } else if (attempt === 0) {
          // A timeout or reset may follow a completed mutation: do not replay it.
          throw unavailable();
        }
      }
    }
    throw unavailable();
  }

  async function json(args) {
    const response = await request(args);
    const chunks = []; let size = 0;
    for await (const chunk of response) {
      size += chunk.length;
      if (size > MAX_JSON) { response.destroy(); throw new BridgeError(502, 'studio_response_invalid', 'Studio response is too large'); }
      chunks.push(chunk);
    }
    let value;
    try { value = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
    catch { throw new BridgeError(502, 'studio_response_invalid', 'Studio returned an invalid response'); }
    if (response.statusCode >= 200 && response.statusCode < 300) return value;
    const code = typeof value?.error === 'string' ? value.error : value?.error?.code;
    const reasons = {
      invalid_request: 'Studio rejected the request as invalid',
      studio_request_missing: 'Studio could not find this request',
      studio_media_not_found: 'Studio could not find this media',
      studio_request_id_conflict: 'The request ID belongs to different content',
      studio_revision_changed: 'The work changed; refresh to use its latest revision',
      studio_principle_changed: 'The principle changed; refresh to use its latest revision',
      studio_work_busy: 'Studio is in use and cannot accept this request',
      studio_resume_unsupported: 'Studio cannot resume; create a new request',
      studio_request_finished: 'The request has already finished',
      studio_stopping: 'Studio is stopping the request',
      studio_answer_pending: 'The previous answer has not yet been received',
      studio_approval_expired: 'The question has expired or the answer is not permitted',
      payload_too_large: 'The request is too large',
    };
    if (Object.hasOwn(reasons, code)) throw new BridgeError(response.statusCode, code, reasons[code]);
    if (response.statusCode === 503) throw new BridgeError(503, 'studio_not_accepting', 'Studio is not accepting requests on the Mac', { retryable: true });
    if (response.statusCode === 404) throw new BridgeError(404, 'not_found', 'Studio could not find the resource');
    throw new BridgeError(502, 'studio_response_invalid', 'Studio could not process the request');
  }
  return {
    snapshot: () => json({ path: '/api/studio/snapshot' }),
    getRequest: (id) => json({ path: `/api/studio/requests/${id}` }),
    createRequest: (body) => json({ path: '/api/studio/requests', method: 'POST', body }),
    action: (body) => json({ path: '/api/studio/action', method: 'POST', body }),
    media: (path, options = {}) => request({ path, ...options }),
  };
}

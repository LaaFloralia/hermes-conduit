// Files a Work reply names on this Mac (`[結果](/Users/laa/work/x/RESULT.md)`,
// `::preview{file="…"}`, a bare path), read for the app so a tap shows them.
//
// The boundary, checked on every read and from one open descriptor:
//   * the path is absolute and lies under the owner's home, both as written
//     and after every symlink is resolved, so a link cannot reach outside it;
//   * a hidden folder or file of the home is read only where Hermes and
//     Muse keep reply pictures (ALLOWED_HIDDEN);
//   * nothing in it is a place secrets live (.ssh, .config, Library with the
//     Keychains, the Bridge's own state, .git) and the name is not one
//     (*.env, keys, credentials, auth.json);
//   * the file is an ordinary single-link file (a hard link could name a
//     secret from a permitted folder) of at most 16 MiB;
//   * the final name is opened without following a symlink, and the
//     descriptor is proven to be the file the resolved path names.
import { closeSync, constants as fsConstants, fstatSync, openSync, readSync, realpathSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, extname, isAbsolute, relative, resolve, sep } from 'node:path';

export const MAX_OWNER_FILE_BYTES = 16 * 1024 * 1024;

// Any folder of these names, at any depth (compared case-insensitively: the
// Mac's disk is).
const DENIED_FOLDERS = new Set([
  '.ssh', '.gnupg', '.aws', '.azure', '.kube', '.docker', '.password-store', '.1password', '.op',
  '.config', '.git', '.gcloud', '.terraform.d', 'keychains',
]);
// The home's hidden folders and files (shell history, tokens, tool state)
// are out unless the path starts with one of these: the pictures Hermes and
// Muse write for a reply. `*` is any one folder name.
const ALLOWED_HIDDEN = [['.hermes', 'profiles', '*', 'images'], ['.local', 'state', 'laa-muse']];
// Folders denied from the home folder down.
const DENIED_FROM_HOME = [['library'], ['.local', 'state', 'laa-bridge']];
const DENIED_NAME = /(?:^|\.)env(?:\.|$)|^\.netrc$|^\.npmrc$|^\.pypirc$|^\.pgpass$|^\.git-credentials$|^\.vault-token$|^id_(?:rsa|dsa|ecdsa|ed25519)|\.(?:pem|key|p12|pfx|keychain|keychain-db|kdbx|ovpn|mobileprovision)$|credential|secret|^auth\.json$/i;

const TYPES = new Map([
  ['.png', 'image/png'], ['.jpg', 'image/jpeg'], ['.jpeg', 'image/jpeg'], ['.gif', 'image/gif'],
  ['.webp', 'image/webp'], ['.heic', 'image/heic'], ['.svg', 'image/svg+xml'],
  ['.html', 'text/html'], ['.htm', 'text/html'], ['.pdf', 'application/pdf'],
  ['.md', 'text/markdown'], ['.txt', 'text/plain'], ['.log', 'text/plain'], ['.csv', 'text/csv'],
  ['.json', 'application/json'], ['.jsonl', 'application/json'], ['.yaml', 'text/yaml'], ['.yml', 'text/yaml'],
  ['.mp4', 'video/mp4'], ['.mov', 'video/quicktime'], ['.m4a', 'audio/mp4'], ['.mp3', 'audio/mpeg'], ['.wav', 'audio/wav'],
]);

export function ownerFileMimeType(path) {
  return TYPES.get(extname(path).toLowerCase()) ?? 'application/octet-stream';
}

function startsWithFolders(segments, folders) {
  return folders.every((folder, index) => segments[index]?.toLowerCase() === folder);
}

/// Whether `path` (absolute, already normalized) is a file under `home` that
/// the app may read. Nothing is opened.
export function ownerPathAllowed(path, home) {
  if (typeof path !== 'string' || typeof home !== 'string' || !path.startsWith(home + sep)) return false;
  const rel = relative(home, path);
  if (!rel || rel.startsWith('..') || isAbsolute(rel)) return false;
  const segments = rel.split(sep);
  if (segments.some((segment) => segment === '' || segment === '.' || segment === '..')) return false;
  if (segments[0].startsWith('.') && !ALLOWED_HIDDEN.some((prefix) => segments.length > prefix.length
      && prefix.every((folder, index) => folder === '*' || segments[index].toLowerCase() === folder))) return false;
  if (DENIED_FROM_HOME.some((folders) => startsWithFolders(segments, folders))) return false;
  if (segments.slice(0, -1).some((segment) => DENIED_FOLDERS.has(segment.toLowerCase()))) return false;
  return !DENIED_NAME.test(basename(path));
}

/// Both the path as written and the file it resolves to must be allowed.
export function ownerFileAllowed(rawPath, real, { home = homedir(), realHome = safeRealpath(home) } = {}) {
  if (typeof rawPath !== 'string' || !isAbsolute(rawPath)) return false;
  return ownerPathAllowed(resolve(rawPath), home) && realHome !== null && ownerPathAllowed(real, realHome);
}

function safeRealpath(path) {
  try { return realpathSync(path); } catch { return null; }
}

function validRawPath(rawPath) {
  return typeof rawPath === 'string' && rawPath !== '' && rawPath.length <= 4096 && !rawPath.includes('\0') && isAbsolute(rawPath);
}

/// Open and check one file; returns `{ fd, real, entry }` or null. The caller
/// owns `fd`.
function openOwnerFile(rawPath, { home = homedir(), maxBytes = MAX_OWNER_FILE_BYTES } = {}) {
  if (!validRawPath(rawPath)) return null;
  const lexical = resolve(rawPath);
  if (!ownerPathAllowed(lexical, home)) return null;
  let fd;
  try {
    // O_NONBLOCK: a FIFO with that name must not hang the Bridge; it fails
    // the isFile check right after.
    fd = openSync(lexical, fsConstants.O_RDONLY | (fsConstants.O_NOFOLLOW ?? 0) | (fsConstants.O_NONBLOCK ?? 0));
  } catch {
    return null;
  }
  try {
    const entry = fstatSync(fd);
    if (!entry.isFile() || entry.nlink !== 1 || entry.size > maxBytes) { closeSync(fd); return null; }
    const real = realpathSync(lexical);
    if (!ownerFileAllowed(lexical, real, { home })) { closeSync(fd); return null; }
    const named = statSync(real);
    if (named.dev !== entry.dev || named.ino !== entry.ino) { closeSync(fd); return null; }
    return { fd, real, entry };
  } catch {
    try { closeSync(fd); } catch {}
    return null;
  }
}

/// Exactly the checked size from the same descriptor; a file that grew or
/// shrank while it was read is not served.
function readBounded(fd, size) {
  const data = Buffer.alloc(size);
  let offset = 0;
  while (offset < size) {
    const read = readSync(fd, data, offset, size - offset, offset);
    if (read <= 0) return null;
    offset += read;
  }
  const extra = Buffer.alloc(1);
  if (readSync(fd, extra, 0, 1, size) > 0) return null;
  return data;
}

/// `{ data, mimeType, path, name, size }` or null. Nothing is thrown: a file
/// that fails any check is simply not served.
export function readOwnerFile(rawPath, options = {}) {
  const opened = openOwnerFile(rawPath, options);
  if (!opened) return null;
  try {
    options.beforeRead?.(opened.fd, opened.entry);
    const data = readBounded(opened.fd, opened.entry.size);
    if (!data || fstatSync(opened.fd).size !== opened.entry.size) return null;
    return { data, mimeType: ownerFileMimeType(opened.real), path: opened.real, name: basename(opened.real), size: data.length };
  } catch {
    return null;
  } finally {
    closeSync(opened.fd);
  }
}

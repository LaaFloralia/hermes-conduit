// Pictures an agent produced on this Mac. Paseo writes them under a
// `paseo-attachments-*` directory in the system temporary folder and names them
// from assistant text as `![Image](file:///…)`. The phone cannot open that path,
// so the Bridge serves only a file that (a) appeared in this session's own
// conversation and (b) passes every check here.
//
// This is deliberately not a file reader: the resolved file must sit directly
// in a Paseo attachment directory under the real temporary directory, must not
// be a symlink, and its extension and magic bytes must agree.
//
// The checks and the bytes come from one open file descriptor. Opening the path
// again after checking it would leave a window where the name is replaced by a
// symlink or another file; `O_NOFOLLOW` plus an `fstat`/`realpath` identity
// match closes that window, and the read itself uses the same descriptor.
import { closeSync, constants as fsConstants, fstatSync, openSync, readSync, realpathSync, statSync } from 'node:fs';
import { basename, dirname, extname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

export const MAX_LOCAL_IMAGE_BYTES = 8 * 1024 * 1024;
const ATTACHMENT_DIRECTORY = /^paseo-attachments-[A-Za-z0-9]{1,32}$/;
const TYPES = new Map([
  ['.png', 'image/png'],
  ['.jpg', 'image/jpeg'],
  ['.jpeg', 'image/jpeg'],
  ['.webp', 'image/webp'],
  ['.gif', 'image/gif'],
]);

function magicMatches(mimeType, head) {
  switch (mimeType) {
    case 'image/png':
      return head.length >= 8 && head.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
    case 'image/jpeg':
      return head.length >= 3 && head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff;
    case 'image/gif':
      return head.length >= 4 && head.subarray(0, 4).toString('latin1') === 'GIF8';
    case 'image/webp':
      return head.length >= 12 && head.subarray(0, 4).toString('latin1') === 'RIFF'
        && head.subarray(8, 12).toString('latin1') === 'WEBP';
    default:
      return false;
  }
}

/// Open `rawPath` without following a final symlink and prove the descriptor is
/// the path that was checked: the fstat identity must match a fresh stat of the
/// resolved path, and that path must be a direct child of a Paseo attachment
/// directory under the real temp root. Returns `{ fd, real, entry, mimeType }`
/// or null; the caller owns `fd`.
function openChecked(rawPath, { tempRoot = realpathSync(tmpdir()), maxBytes = MAX_LOCAL_IMAGE_BYTES } = {}) {
  if (typeof rawPath !== 'string' || rawPath === '' || rawPath.length > 4096 || rawPath.includes('\0')) return null;
  if (!rawPath.startsWith('/')) return null;
  let fd;
  try {
    fd = openSync(rawPath, fsConstants.O_RDONLY | (fsConstants.O_NOFOLLOW ?? 0));
  } catch {
    return null;
  }
  try {
    const entry = fstatSync(fd);
    // A hard link can name a file that lives outside the attachment folder;
    // Paseo's own pictures are single-link files.
    if (!entry.isFile() || entry.nlink !== 1 || entry.size <= 0 || entry.size > maxBytes) {
      closeSync(fd); return null;
    }
    const real = realpathSync(rawPath);
    const directory = dirname(real);
    if (dirname(directory) !== tempRoot || !ATTACHMENT_DIRECTORY.test(basename(directory))) {
      closeSync(fd); return null;
    }
    // The descriptor and the name still have to be the same file: a parent
    // directory swapped between open and realpath would show a different inode.
    const named = statSync(real);
    if (named.dev !== entry.dev || named.ino !== entry.ino) {
      closeSync(fd); return null;
    }
    const mimeType = TYPES.get(extname(real).toLowerCase());
    if (!mimeType) {
      closeSync(fd); return null;
    }
    const head = Buffer.alloc(16);
    const read = readSync(fd, head, 0, 16, 0);
    if (!magicMatches(mimeType, head.subarray(0, read))) {
      closeSync(fd); return null;
    }
    return { fd, real, entry, mimeType };
  } catch {
    try { closeSync(fd); } catch {}
    return null;
  }
}

/// Metadata for a reference, or null. Nothing is thrown: a reference that fails
/// any check is simply not served.
export function inspectLocalImage(rawPath, options = {}) {
  const opened = openChecked(rawPath, options);
  if (!opened) return null;
  try { return { path: opened.real, mimeType: opened.mimeType, size: opened.entry.size }; }
  finally { closeSync(opened.fd); }
}

/// Read exactly the size that was checked, from the same descriptor. A file
/// that grows while it is read would otherwise be copied past the size limit,
/// so one extra byte and a second fstat must both confirm it did not change.
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

/// The bytes and mime type read from the checked descriptor itself. `beforeRead`
/// is a test seam: it runs after the checks and before the bytes are read.
export function readLocalImage(rawPath, options = {}) {
  const opened = openChecked(rawPath, options);
  if (!opened) return null;
  try {
    options.beforeRead?.(opened.fd, opened.entry);
    const data = readBounded(opened.fd, opened.entry.size);
    // Re-check the signature on the bytes actually read, and the size after the
    // read: neither may have changed since the descriptor was checked.
    if (!data || !magicMatches(opened.mimeType, data.subarray(0, 16))
      || fstatSync(opened.fd).size !== opened.entry.size) return null;
    return { data, mimeType: opened.mimeType, path: opened.real };
  } catch {
    return null;
  } finally {
    closeSync(opened.fd);
  }
}

/// Assistant text carries the picture as markdown. Replace each local image
/// reference with an internal marker so the caller can either drop it (served)
/// or leave a visible fallback (not servable) without losing its position.
export function splitLocalImages(text) {
  if (typeof text !== 'string' || !text.includes('file://')) return { text, paths: [] };
  const paths = [];
  const marked = text.replace(
    /!\[([^\]]*)\]\(\s*(file:\/\/[^)\s]+)(?:\s+(?:"[^"]*"|'[^']*'|\([^)]*\)))?\s*\)/g,
    (match, _alt, url) => {
      try {
        const parsed = new URL(url);
        if (parsed.protocol !== 'file:') return match;
        const path = fileURLToPath(parsed);
        const index = paths.push(path) - 1;
        return `\u0000LAAIMG${index}\u0000`;
      } catch {
        return match;
      }
    },
  );
  return { text: marked, paths };
}

/// Put a served image's marker away, and keep a visible line where one cannot
/// be shown. Only the image markers change: code fences, trailing spaces and
/// blank lines in the rest of the message are left exactly as the model wrote
/// them. Never silently deletes a picture the agent meant to send.
export function settleLocalImages(text, paths, resolvedIDs) {
  if (typeof text !== 'string' || !Array.isArray(paths) || paths.length === 0) return text;
  let result = text;
  paths.forEach((_path, index) => {
    const marker = `\u0000LAAIMG${index}\u0000`;
    if (!result.includes(marker)) return;
    result = result.replace(marker, resolvedIDs[index] ? '' : '（画像を表示できません）');
  });
  return result;
}

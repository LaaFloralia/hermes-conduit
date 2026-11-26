import { spawnSync } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { chmodSync, closeSync, constants, fstatSync, lstatSync, mkdirSync, mkdtempSync, openSync, readFileSync,
  readSync, readdirSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { isAbsolute, join } from 'node:path';
import { BridgeError, badRequest } from '../errors.mjs';
import { laneEnabled, lanePath } from '../lane/guard.mjs';

export const DECISION_ID = /^(?:dec_[0-9a-f]{16})$/;
export const IMAGE_ID = /^(?:img_[0-9a-f]{12})$/;
const MAX_GENERAL = 6;
const MAX_INPUT_BYTES = 40 * 1024 * 1024;
const FULL = 3000, THUMB = 720;
const HOUR = 3600_000, RETENTION = 7 * 24 * HOUR;
const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const HEIC_BRANDS = new Set(['heic', 'heix', 'hevc', 'hevx', 'heim', 'heis', 'hevm', 'hevs']);

export const invalidDecisionImage = () => badRequest('decision_image_invalid', 'Use an absolute path to a readable PNG, JPEG, HEIC or WebP (up to 40 MB), at most six general images and one per option.');
export const imageNotFound = () => new BridgeError(404, 'decision_image_not_found', 'decision image not found');
const imageExpired = () => new BridgeError(410, 'decision_image_expired', 'decision image has expired');
const ascii = (bytes, start, end) => bytes.toString('latin1', start, end);

function typeOf(bytes) {
  if (bytes.length > 8 && bytes.subarray(0, 8).equals(PNG)) return 'png';
  if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return 'jpg';
  if (bytes.length >= 16 && ascii(bytes, 0, 4) === 'RIFF' && ascii(bytes, 8, 12) === 'WEBP') return 'webp';
  if (bytes.length >= 16 && ascii(bytes, 4, 8) === 'ftyp') {
    const end = bytes.readUInt32BE(0);
    if (end < 16 || end > bytes.length) return null;
    if (HEIC_BRANDS.has(ascii(bytes, 8, 12))) return 'heic';
    for (let i = 16; i + 4 <= end; i += 4) if (HEIC_BRANDS.has(ascii(bytes, i, i + 4))) return 'heic';
  }
  return null;
}

function readAt(fd, bytes) {
  let used = 0;
  while (used < bytes.length) {
    const n = readSync(fd, bytes, used, bytes.length - used, used);
    if (!n) break;
    used += n;
  }
  return bytes.subarray(0, used);
}

function openInput(path, laneRoot) {
  let fd;
  try {
    if (typeof path !== 'string' || !isAbsolute(path)) throw invalidDecisionImage();
    const source = laneRoot ? lanePath(laneRoot, path, 'decision image input') : path;
    fd = openSync(source, constants.O_RDONLY | constants.O_NONBLOCK | (laneRoot ? constants.O_NOFOLLOW : 0));
    const stat = fstatSync(fd);
    if (!stat.isFile() || stat.size > MAX_INPUT_BYTES || (laneRoot && stat.nlink !== 1)) throw invalidDecisionImage();
    const type = typeOf(readAt(fd, Buffer.alloc(Math.min(stat.size, 4096))));
    if (!type) throw invalidDecisionImage();
    return { fd, size: stat.size, type };
  } catch {
    if (fd !== undefined) closeSync(fd);
    throw invalidDecisionImage();
  }
}

function sips(args) {
  const result = spawnSync('/usr/bin/sips', args, { encoding: 'utf8', timeout: 60_000 });
  if (result.status !== 0) throw invalidDecisionImage();
  return result.stdout;
}

function dimensions(path) {
  const result = sips(['-g', 'pixelWidth', '-g', 'pixelHeight', path]);
  const width = Number(/^  pixelWidth: (\d+)$/m.exec(result)?.[1]);
  const height = Number(/^  pixelHeight: (\d+)$/m.exec(result)?.[1]);
  if (!(width > 0 && height > 0)) throw invalidDecisionImage();
  return { width, height };
}

function convert(source, target, type, max, dims, transform = []) {
  // sips -Z also enlarges small files, so only pass it when scaling down.
  sips(['-s', 'format', type === 'png' ? 'png' : 'jpeg', ...(type === 'jpg' ? ['-s', 'formatOptions', '85'] : []),
    ...(Math.max(dims.width, dims.height) > max ? ['-Z', String(max)] : []), ...transform, source, '--out', target]);
  chmodSync(target, 0o600);
}

function exifOrientation(tiff) {
  if (tiff.length < 8) return 1;
  const order = ascii(tiff, 0, 2);
  if (order !== 'II' && order !== 'MM') return 1;
  const u16 = (offset) => order === 'II' ? tiff.readUInt16LE(offset) : tiff.readUInt16BE(offset);
  const u32 = (offset) => order === 'II' ? tiff.readUInt32LE(offset) : tiff.readUInt32BE(offset);
  const ifd = u32(4);
  if (u16(2) !== 42 || ifd < 8 || ifd + 2 > tiff.length) return 1;
  const limit = Math.min(tiff.length, ifd + 2 + 12 * u16(ifd));
  for (let at = ifd + 2; at + 12 <= limit; at += 12) {
    if (u16(at) === 0x112 && u16(at + 2) === 3 && u32(at + 4) === 1) return u16(at + 8);
  }
  return 1;
}
const ORIENTATION = {
  2: ['-f', 'horizontal'], 3: ['-r', '180'], 4: ['-f', 'vertical'],
  // sips applies rotation before the flip.
  5: ['-r', '90', '-f', 'horizontal'], 6: ['-r', '90'],
  7: ['-r', '270', '-f', 'horizontal'], 8: ['-r', '270'],
};

// sips carries EXIF and other metadata across conversions. Keep only the
// container structures needed to decode the rendered image, not source tags.
const PNG_RENDER_CHUNKS = new Set(['IHDR', 'PLTE', 'IDAT', 'IEND', 'tRNS', 'cHRM', 'gAMA', 'sRGB', 'cICP', 'sBIT']);
function pngPixels(bytes) {
  if (bytes.length < 45 || ascii(bytes, 12, 16) !== 'IHDR') throw invalidDecisionImage();
  const dims = { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) };
  const parts = [PNG];
  let orientation = 1;
  for (let start = 8; start + 12 <= bytes.length;) {
    const size = bytes.readUInt32BE(start), end = start + 12 + size;
    if (end > bytes.length) break;
    const tag = ascii(bytes, start + 4, start + 8);
    if (tag === 'eXIf') orientation = exifOrientation(bytes.subarray(start + 8, end - 4));
    if (PNG_RENDER_CHUNKS.has(tag)) parts.push(bytes.subarray(start, end));
    if (tag === 'IEND') return { ...dims, orientation, parts };
    start = end;
  }
  throw invalidDecisionImage();
}

const JPEG_SOF = new Set([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf]);
function jpegPixels(bytes) {
  const parts = [bytes.subarray(0, 2)];
  let dims, orientation = 1;
  for (let start = 2; start < bytes.length;) {
    let at = start;
    if (bytes[at++] !== 0xff) break;
    while (bytes[at] === 0xff) at++;
    const marker = bytes[at++];
    if (marker === 0xd9 && dims) {
      parts.push(bytes.subarray(start, at));
      return { ...dims, orientation, parts };
    }
    if (at + 2 > bytes.length) break;
    const size = bytes.readUInt16BE(at), end = at + size, payload = at + 2;
    if (size < 2 || end > bytes.length) break;
    if (JPEG_SOF.has(marker) && size >= 7) dims = { width: bytes.readUInt16BE(payload + 3), height: bytes.readUInt16BE(payload + 1) };
    if (marker === 0xe1 && size >= 8 && ascii(bytes, payload, payload + 6) === 'Exif\0\0') orientation = exifOrientation(bytes.subarray(payload + 6, end));
    if (marker === 0xda) {
      // Scan data escapes literal FF as FF00 and may contain restart markers.
      at = end;
      for (;;) {
        at = bytes.indexOf(0xff, at);
        if (at < 0) throw invalidDecisionImage();
        const next = bytes[at + 1];
        if (next !== 0 && !(next >= 0xd0 && next <= 0xd7)) break;
        at += 2;
      }
      parts.push(bytes.subarray(start, at));
      start = at;
      continue;
    }
    // Adobe's fixed APP14 segment signals the color transform, not user data.
    const adobe = marker === 0xee && size === 14 && ascii(bytes, payload, payload + 5) === 'Adobe';
    if (adobe || (marker !== 0xfe && (marker < 0xe0 || marker > 0xef))) parts.push(bytes.subarray(start, end));
    start = end;
  }
  throw invalidDecisionImage();
}

function pixels(bytes, type) {
  if (typeOf(bytes) !== type) throw invalidDecisionImage();
  const decoded = type === 'png' ? pngPixels(bytes) : jpegPixels(bytes);
  if (!(decoded.width > 0 && decoded.height > 0)) throw invalidDecisionImage();
  return decoded;
}

function createCopies(stage, input) {
  const { fd, size, type } = input;
  const bytes = readAt(fd, Buffer.alloc(size + 1));
  if (bytes.length !== size || typeOf(bytes) !== type) throw invalidDecisionImage();
  const source = join(stage, `source.${type}`);
  writeFileSync(source, bytes, { mode: 0o600, flag: 'wx' });
  const dims = dimensions(source);
  const id = `img_${randomBytes(6).toString('hex')}`;
  const ext = type === 'png' ? 'png' : 'jpg';
  const full = join(stage, `${id}.full.${ext}`), thumb = join(stage, `${id}.thumb.${ext}`);
  convert(source, full, ext, FULL, dims);
  let rendered = pixels(readFileSync(full), ext);
  const transform = ORIENTATION[rendered.orientation];
  if (transform) {
    convert(source, full, ext, FULL, dims, transform);
    rendered = pixels(readFileSync(full), ext);
  }
  const { width, height } = rendered;
  if (Math.max(width, height) > Math.min(FULL, Math.max(dims.width, dims.height))) throw invalidDecisionImage();
  writeFileSync(full, Buffer.concat(rendered.parts));
  convert(full, thumb, ext, THUMB, { width, height });
  const small = pixels(readFileSync(thumb), ext);
  if (Math.max(small.width, small.height) > Math.min(THUMB, Math.max(width, height))) throw invalidDecisionImage();
  writeFileSync(thumb, Buffer.concat(small.parts));
  rmSync(source);
  return { id, width, height, ...(input.option === undefined ? {} : { option: input.option }) };
}

export function validDecisionImages(images, optionCount) {
  if (!Array.isArray(images) || !images.length || images.length > MAX_GENERAL + optionCount) return false;
  const ids = new Set(), options = new Set();
  let general = 0;
  for (const image of images) {
    if (!image || typeof image.id !== 'string' || !IMAGE_ID.test(image.id) || ids.has(image.id)
      || ![image.width, image.height].every((n) => Number.isInteger(n) && n > 0 && n <= FULL)) return false;
    ids.add(image.id);
    if (image.option === undefined) { if (++general > MAX_GENERAL) return false; }
    else {
      if (!Number.isInteger(image.option) || image.option < 0 || image.option >= optionCount || options.has(image.option)) return false;
      options.add(image.option);
    }
  }
  return true;
}

function lstat(path) {
  try { return lstatSync(path); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}

function privateDir(path) {
  try { mkdirSync(path, { mode: 0o700 }); }
  catch (error) { if (error.code !== 'EEXIST') throw error; }
  if (!lstatSync(path).isDirectory()) throw new Error('decision image directory is not a real directory');
  chmodSync(path, 0o700);
}

const expired = (record, now) => record.status !== 'open' && now - Date.parse(record.updatedAt) >= RETENTION;

export function createDecisionImages(dir) {
  const root = join(dir, 'decision-images'), staging = join(root, '.staging');
  return {
    stage(inputs, order) {
      if (!inputs.length) return null;
      const options = new Set();
      let general = 0;
      for (const { option } of inputs) {
        if (option === undefined ? ++general > MAX_GENERAL : !order.includes(option) || options.has(option)) throw invalidDecisionImage();
        if (option !== undefined) options.add(option);
      }
      const opened = [];
      let path;
      try {
        // Validate every source before creating any state or staging files.
        const laneRoot = laneEnabled() ? process.env.LAA_LANE_ROOT : null;
        for (const { path: source, option } of inputs) {
          opened.push({ ...openInput(source, laneRoot), option: option === undefined ? undefined : order.indexOf(option) });
        }
        mkdirSync(dir, { recursive: true, mode: 0o700 });
        privateDir(root);
        privateDir(staging);
        path = mkdtempSync(join(staging, '/'));
        chmodSync(path, 0o700);
        const images = opened.map((input) => createCopies(path, input));
        if (!validDecisionImages(images, order.length)) throw new Error('invalid rendered decision images');
        return { images, publish(id) {
          const target = join(root, id);
          if (lstat(target)) throw new Error('decision image directory already exists');
          renameSync(path, target);
        }, cleanup: () => rmSync(path, { recursive: true, force: true }) };
      } catch (error) {
        if (path) rmSync(path, { recursive: true, force: true });
        throw error;
      } finally {
        for (const { fd } of opened) closeSync(fd);
      }
    },
    prune(records, now) {
      if (!lstat(root)?.isDirectory()) return;
      const byId = new Map(records.map((r) => [r.id, r]));
      for (const entry of readdirSync(root, { withFileTypes: true })) {
        if (!entry.isDirectory() || entry.name === '.staging') continue;
        const path = join(root, entry.name), r = byId.get(entry.name);
        if (r ? expired(r, now) : now - (lstat(path)?.mtimeMs ?? now) > HOUR) rmSync(path, { recursive: true, force: true });
      }
      if (!lstat(staging)?.isDirectory()) return;
      for (const entry of readdirSync(staging, { withFileTypes: true })) {
        if (!entry.isDirectory()) continue;
        const path = join(staging, entry.name);
        if (now - (lstat(path)?.mtimeMs ?? now) > HOUR) rmSync(path, { recursive: true, force: true });
      }
    },
    read(record, imgId, size, now) {
      if (!DECISION_ID.test(record?.id ?? '') || !IMAGE_ID.test(imgId) || !record.images?.some(({ id }) => id === imgId)) throw imageNotFound();
      const path = join(root, record.id);
      // Serve no bytes after the deadline, even before the next sync. A closed
      // record can later get a delivery update, but its image dir is never restored.
      if (expired(record, now)) throw imageExpired();
      if (!lstat(root)?.isDirectory()) throw imageNotFound();
      const stat = lstat(path);
      if (!stat && record.status !== 'open') throw imageExpired();
      if (!stat?.isDirectory()) throw imageNotFound();
      for (const [ext, contentType] of [['png', 'image/png'], ['jpg', 'image/jpeg']]) {
        let fd;
        try {
          fd = openSync(join(path, `${imgId}.${size === 'thumb' ? 'thumb' : 'full'}.${ext}`), constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
          const stat = fstatSync(fd);
          if (!stat.isFile() || stat.nlink !== 1) throw imageNotFound();
          const bytes = readFileSync(fd);
          const { width, height } = pixels(bytes, ext);
          return { contentType, width, height, bytes, etag: `"${createHash('sha256').update(bytes).digest('hex')}"` };
        } catch (error) {
          if (error.code === 'ELOOP' || error.code === 'decision_image_invalid') throw imageNotFound();
          if (error.code !== 'ENOENT') throw error;
        } finally { if (fd !== undefined) closeSync(fd); }
      }
      throw imageNotFound();
    },
  };
}

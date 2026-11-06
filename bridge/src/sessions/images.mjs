import { createHash } from 'node:crypto';
import { join } from 'node:path';
import { createJsonFile } from '../routes/state-file.mjs';
import { badRequest, notFound } from '../errors.mjs';
import { inspectLocalImage, readLocalImage } from './local-images.mjs';

/// Pictures attached to one session in two ways:
///   * uploaded by the app (`stage`): the bytes live in this file;
///   * produced on the Mac (`registerLocalBatch`): only a checked path is kept,
///     and the boundary is checked again on every read, from one descriptor.
/// The index is per session, so an id from another session is not readable.
export function sessionImageStore(directory, {
  inspect = inspectLocalImage, readLocal = readLocalImage, now = () => Date.now(), inspectTtlMs = 30_000,
} = {}) {
  // A conversation poll can name the same pictures every couple of seconds.
  // Keep the checked metadata briefly and write the index only for new ids.
  const inspected = new Map();
  function cachedInspect(path) {
    const hit = inspected.get(path);
    if (hit && now() - hit.at < inspectTtlMs) return hit.value;
    const value = inspect(path);
    inspected.set(path, { at: now(), value });
    return value;
  }
  function file(sessionID) {
    if (!/^ses_[0-9a-f]{16}$/.test(sessionID)) throw notFound('session not found');
    return createJsonFile({
      file: join(directory, `${sessionID}.json`),
      initial: () => ({ messages: {}, images: {}, files: {} }),
    });
  }
  return {
    stage(sessionID, messageID, images) {
      if (!images?.length) return;
      file(sessionID).mutate((s) => {
        const ids = images.map((image) => {
          const id = createHash('sha256').update(image.mimeType + ':' + image.data).digest('hex');
          s.images[id] = image;
          return id;
        });
        if (s.messages[messageID] && JSON.stringify(s.messages[messageID]) !== JSON.stringify(ids)) throw badRequest('image_conflict', 'message images changed');
        s.messages[messageID] = ids;
      });
    },
    references(sessionID) { return file(sessionID).read().messages; },
    /// Register every local file this session's own conversation named. Returns
    /// ids in the same order (null where the reference may not be served); the
    /// index is written once, and only for ids it does not already have.
    registerLocalBatch(sessionID, paths) {
      if (!Array.isArray(paths) || paths.length === 0) return [];
      const results = paths.map((path) => {
        const checked = cachedInspect(path);
        if (!checked) return null;
        return { id: createHash('sha256').update(checked.path).digest('hex'), checked };
      });
      const state = file(sessionID).read();
      const missing = results.filter((entry) => entry && !state.files?.[entry.id]);
      if (missing.length > 0) {
        file(sessionID).mutate((s) => {
          s.files ??= {};
          for (const { id, checked } of missing) s.files[id] = { path: checked.path, mimeType: checked.mimeType, size: checked.size };
        });
      }
      return results.map((entry) => entry?.id ?? null);
    },
    read(sessionID, imageID) {
      if (!/^[0-9a-f]{64}$/.test(imageID)) throw notFound('image not found');
      const state = file(sessionID).read();
      const image = state.images?.[imageID];
      if (image) return image;
      const local = state.files?.[imageID];
      if (!local) throw notFound('image not found');
      // One open descriptor for the boundary checks and the bytes: a path
      // swapped after the conversation named it is not served.
      const checked = readLocal(local.path);
      if (!checked || checked.path !== local.path) throw notFound('image not found');
      return { data: checked.data.toString('base64'), mimeType: checked.mimeType };
    },
  };
}

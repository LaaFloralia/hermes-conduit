import { createHash } from 'node:crypto';
import { join } from 'node:path';
import { createJsonFile } from '../routes/state-file.mjs';
import { badRequest, notFound } from '../errors.mjs';

export function sessionImageStore(directory) {
  function file(sessionID) {
    if (!/^ses_[0-9a-f]{16}$/.test(sessionID)) throw notFound('session not found');
    return createJsonFile({ file: join(directory, `${sessionID}.json`), initial: () => ({ messages: {}, images: {} }) });
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
    read(sessionID, imageID) {
      if (!/^[0-9a-f]{64}$/.test(imageID)) throw notFound('image not found');
      const image = file(sessionID).read().images[imageID];
      if (!image) throw notFound('image not found');
      return image;
    },
  };
}

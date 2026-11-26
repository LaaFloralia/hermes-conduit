import { BridgeError } from './errors.mjs';

const LABELS = new Set(['LAA', 'LaaFloralia', 'Hortensia', 'Monet', 'Work', 'Session', 'Chat', 'Today', 'Doc', 'Brain', 'Studio', 'Voice', 'Journal', 'Usage', 'Linear', 'GitHub', 'TestFlight', 'OK']);

export function isOwnerSurface(value) {
  if (typeof value !== 'string') return false;
  const text = value.replace(/^[\s\p{Cf}\p{Cc}]+/u, '').trimEnd();
  return !/^(?:RESULT:|\{)/u.test(text) && (LABELS.has(text) || /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]/u.test(text));
}

export function assertOwnerSurface(value, field) {
  if (!isOwnerSurface(value)) throw new BridgeError(422, 'owner_surface_language', `${field}: 日本語で入力してください。`);
}

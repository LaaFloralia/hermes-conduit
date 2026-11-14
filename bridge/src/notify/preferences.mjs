import { join } from 'node:path';
import { createJsonFile } from '../routes/state-file.mjs';
import { resolveStateDir } from '../config.mjs';
import { badRequest } from '../errors.mjs';
export const DEFAULT_KINDS = Object.freeze({ decision: 'alert', question: 'alert', approval: 'alert', error: 'alert', finished: 'quiet', task: 'alert', calendar: 'alert' });
export function createNotificationPreferences({ file = join(resolveStateDir(), 'notification-preferences.json'), now = () => Date.now() } = {}) {
  const state = createJsonFile({ file, initial: () => ({ kinds: { ...DEFAULT_KINDS }, updatedAt: null }) });
  const view = (s) => ({ kinds: { ...DEFAULT_KINDS, ...s.kinds }, updatedAt: s.updatedAt });
  return {
    get: () => view(state.read()),
    update(body) {
      const kinds = body?.kinds;
      if (!kinds || typeof kinds !== 'object' || Array.isArray(kinds) || Object.keys(body).some((k) => k !== 'kinds')
        || Object.entries(kinds).some(([k, v]) => !Object.hasOwn(DEFAULT_KINDS, k) || !['alert', 'quiet', 'off'].includes(v) || (['decision', 'question', 'approval'].includes(k) && v === 'off')))
        throw badRequest('notification_preferences_invalid', '通知設定を確認してください。');
      return state.mutate((s) => { s.kinds = { ...DEFAULT_KINDS, ...s.kinds, ...kinds }; s.updatedAt = new Date(now()).toISOString(); return view(s); });
    },
  };
}
export function notificationLevel(kind, preferences) {
  const key = { 'decision.new': 'decision', 'decision.failed': 'decision', 'session.question': 'question', 'session.approval': 'approval', 'session.error': 'error', 'session.finished': 'finished', task: 'task', calendar: 'calendar' }[kind];
  return key ? preferences.get().kinds[key] : 'alert';
}

import { join } from 'node:path';
import { createJsonFile } from '../routes/state-file.mjs';
import { resolveStateDir } from '../config.mjs';
import { badRequest } from '../errors.mjs';
// `finished` defaults to off (C-2.1): Monet's `report` is the one completion lane.
// Only kinds the owner explicitly chose are stored; an absent kind follows this table.
// Files written before this change stored every default on the first update, so a stored
// `finished: 'quiet'` cannot be told apart from an owner choice and is kept as stored.
export const DEFAULT_KINDS = Object.freeze({ decision: 'alert', question: 'alert', approval: 'alert', error: 'alert', finished: 'off', report: 'alert', task: 'alert', calendar: 'alert' });
const SCHEMA = 1;
const validKinds = (kinds) => kinds && typeof kinds === 'object' && !Array.isArray(kinds)
  && Object.entries(kinds).every(([k, v]) => Object.hasOwn(DEFAULT_KINDS, k) && ['alert', 'quiet', 'off'].includes(v)
    && (!['decision', 'question', 'approval'].includes(k) || v !== 'off'));

function migratePreferences(doc) {
  // Accept only the known schema-less preferences shape, not unknown versions or damaged data.
  if (!doc || typeof doc !== 'object' || Array.isArray(doc)
    || Object.keys(doc).some((k) => k !== 'kinds' && k !== 'updatedAt') || !validKinds(doc.kinds)
    || !(doc.updatedAt === null || (typeof doc.updatedAt === 'string' && Number.isFinite(Date.parse(doc.updatedAt))))) return doc;
  return { ...doc, schema: SCHEMA };
}

export function createNotificationPreferences({ file = join(resolveStateDir(), 'notification-preferences.json'), now = () => Date.now() } = {}) {
  const state = createJsonFile({ file, schema: SCHEMA, migrate: migratePreferences, initial: () => ({ kinds: {}, updatedAt: null }) });
  const view = (s) => ({ kinds: { ...DEFAULT_KINDS, ...s.kinds }, updatedAt: s.updatedAt });
  return {
    get: () => view(state.read()),
    update(body) {
      const kinds = body?.kinds;
      if (!validKinds(kinds) || Object.keys(body).some((k) => k !== 'kinds'))
        throw badRequest('notification_preferences_invalid', '通知設定を確認してください。');
      return state.mutate((s) => { s.kinds = { ...s.kinds, ...kinds }; s.updatedAt = new Date(now()).toISOString(); return view(s); });
    },
  };
}
export function notificationLevel(kind, preferences) {
  const key = { 'decision.new': 'decision', 'decision.failed': 'decision', 'session.question': 'question', 'session.approval': 'approval', 'session.error': 'error', 'session.finished': 'finished', 'monet.report': 'report', task: 'task', calendar: 'calendar' }[kind];
  return key ? preferences.get().kinds[key] : 'alert';
}

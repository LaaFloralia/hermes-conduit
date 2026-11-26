import { join } from 'node:path';
import { createJsonFile } from '../routes/state-file.mjs';
import { resolveStateDir } from '../config.mjs';
import { badRequest } from '../errors.mjs';
// `finished` defaults to off (C-2.1): Monet's `report` is the one completion lane.
// Only kinds the owner explicitly chose are stored; an absent kind follows this table.
// Old writers materialized quiet even on unrelated updates. Only positive
// provenance (or a value other than the old default) preserves that setting.
export const DEFAULT_KINDS = Object.freeze({ decision: 'alert', question: 'alert', approval: 'alert', error: 'alert', finished: 'off', report: 'alert', task: 'alert', calendar: 'alert' });
const SCHEMA = 1;
const validKinds = (kinds) => kinds && typeof kinds === 'object' && !Array.isArray(kinds)
  && Object.entries(kinds).every(([k, v]) => Object.hasOwn(DEFAULT_KINDS, k) && ['alert', 'quiet', 'off'].includes(v)
    && (!['decision', 'question', 'approval'].includes(k) || v !== 'off'));

function migratePreferences(doc) {
  // Accept only the known schema-less preferences shape, not unknown versions or damaged data.
  if (!doc || typeof doc !== 'object' || Array.isArray(doc)
    || Object.keys(doc).some((k) => !['kinds', 'updatedAt', 'updatedBy', 'finishedUpdatedBy', 'finishedDefaultMigratedAt'].includes(k)) || !validKinds(doc.kinds)
    || !(doc.updatedAt === null || (typeof doc.updatedAt === 'string' && Number.isFinite(Date.parse(doc.updatedAt))))) return doc;
  return { ...doc, schema: SCHEMA };
}

export function createNotificationPreferences({ file = join(resolveStateDir(), 'notification-preferences.json'), now = () => Date.now() } = {}) {
  const state = createJsonFile({ file, schema: SCHEMA, migrate: migratePreferences,
    initial: () => ({ kinds: {}, updatedAt: null, finishedDefaultMigratedAt: new Date(now()).toISOString() }) });
  const view = (s) => ({ kinds: { ...DEFAULT_KINDS, ...s.kinds }, updatedAt: s.updatedAt });
  const migrate = (s) => {
    if (!validKinds(s.kinds)) throw new Error('invalid notification preferences');
    if (!s.finishedDefaultMigratedAt) {
      if (s.kinds.finished === 'quiet' && s.finishedUpdatedBy !== 'owner' && s.updatedBy !== 'owner') delete s.kinds.finished;
      s.finishedDefaultMigratedAt = new Date(now()).toISOString();
    }
    return s;
  };
  return {
    get() {
      const current = state.read();
      if (current.finishedDefaultMigratedAt || current.kinds?.finished !== 'quiet') return view(migrate(current));
      return state.mutate((s) => view(migrate(s)));
    },
    update(body) {
      const kinds = body?.kinds;
      if (!validKinds(kinds) || Object.keys(body).some((k) => k !== 'kinds'))
        throw badRequest('notification_preferences_invalid', '通知設定を確認してください。');
      return state.mutate((s) => {
        migrate(s);
        s.kinds = { ...s.kinds, ...kinds };
        if (Object.hasOwn(kinds, 'finished')) s.finishedUpdatedBy = 'owner';
        s.updatedAt = new Date(now()).toISOString();
        return view(s);
      });
    },
  };
}
export function notificationLevel(kind, preferences) {
  if (['agent-notification', 'monet.proposal'].includes(kind)) return 'off';
  const key = { 'decision.new': 'decision', 'decision.failed': 'decision', 'session.question': 'question', 'session.approval': 'approval', 'session.error': 'error', 'session.finished': 'finished', 'monet.report': 'report', task: 'task', calendar: 'calendar' }[kind];
  return key ? preferences.get().kinds[key] : 'alert';
}

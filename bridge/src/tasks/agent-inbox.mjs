import { createHash } from 'node:crypto';
import { join } from 'node:path';
import { createJsonFile } from '../routes/state-file.mjs';
import { TaskSourceError } from './errors.mjs';

const hash = (value) => createHash('sha256').update(value).digest('hex');
const MAX_EVENTS = 2000;
const LOOKBACK = 14 * 86400_000;
const fail = (code, status = 400) => new TaskSourceError(code, 'the local task inbox could not complete the request', { status });

// This inbox observes only issues visible to the existing agent. It neither
// reads nor marks the owner's native Linear notifications. Its read state and
// watermark survive Bridge restarts and are separate for each authenticated actor.
export function createAgentInboxSource({ source, store, now = () => Date.now() }) {
  const file = createJsonFile({ file: join(store.dir, 'linear-owner-inbox.json'), initial: () => ({ viewers: {} }) });
  let pending;
  let refreshedAt = 0;
  let refreshedViewer;
  const snapshot = (viewer) => file.read().viewers[viewer] ?? { events: {}, versions: {}, watermark: null };
  async function section(name, id, personalSession, commentId) {
    let cursor, count = 0, items = [];
    const seen = new Set();
    do {
      const page = await source.listTaskSection(name, id, { limit: 100, cursor, personalSession, commentId });
      items.push(...page.items); cursor = page.nextCursor;
      if (cursor && seen.has(cursor)) throw fail('linear_pagination_stalled', 503);
      if (cursor) seen.add(cursor);
    } while (cursor && ++count < 20);
    if (cursor) throw fail('linear_activity_incomplete', 503);
    return items;
  }
  async function refresh(session) {
    if (pending) return pending;
    if (refreshedViewer === session.viewer.id && now() - refreshedAt < 55_000) return;
    pending = (async () => {
      const viewer = session.viewer.id;
      const owner = await source.ownerProfile(session);
      const old = snapshot(viewer);
      const since = new Date(Math.max(now() - LOOKBACK, Date.parse(old.watermark ?? '') - 120_000 || 0)).toISOString();
      const started = new Date(now()).toISOString();
      const versions = { ...old.versions };
      const watched = { ...old.watched };
      const events = [];
      const mention = (body) => typeof body === 'string' && [source.ownerUserId, owner.url].some((term) => term && body.includes(term));
      const add = (issue, type, id, date, title, subtitle = '') => {
        if (!date || Date.parse(date) < now() - LOOKBACK) return;
        const eventID = `activity-${hash(`${issue.id}:${type}:${id}`).slice(0, 40)}`;
        events.push({ id: eventID, type, title, subtitle, createdAt: date, updatedAt: date,
          readAt: null, archivedAt: null, snoozedUntilAt: null, user: { id: viewer }, actor: null,
          issue: { id: issue.id, identifier: issue.identifier, title: issue.title }, inboxMode: 'laa' });
      };
      let after, pages = 0;
      const seen = new Set();
      do {
        const page = await source.listActivityCandidates(session, { since, after, owner, watched: Object.keys(watched).slice(0, 2000) });
        for (const issue of page.nodes) {
          if (versions[issue.id] === issue.updatedAt) continue;
          const parent = issue.parent;
          if (parent && (parent.assignee?.id === source.ownerUserId || parent.creator?.id === source.ownerUserId
            || parent.subscribers?.nodes?.some((user) => user.id === source.ownerUserId) || old.watched?.[parent.id] === true)) {
            add(parent, 'issueSubtask', issue.id + ':' + issue.updatedAt, issue.updatedAt, 'サブ課題', issue.title);
          }
          const related = issue.assignee?.id === source.ownerUserId || issue.creator?.id === source.ownerUserId
            || issue.subscribers?.nodes?.some((p) => p.id === source.ownerUserId);
          if (mention(issue.description)) add(issue, 'issueMention', `description:${issue.updatedAt}`, issue.updatedAt, '社長へのメンション', issue.description.slice(0, 250));
          const relevant = related || watched[issue.id] === true;
          if (related) watched[issue.id] = true; else delete watched[issue.id];
          // Root comment activity includes replies; root issue activity includes
          // children. Reading those sections again caused an unbounded N+1 scan.
          const history = relevant ? await section('history', issue.id, session) : [];
          for (const item of history) {
            const fields = [];
            if (item.fromState || item.toState) fields.push('状態');
            if (item.fromAssignee || item.toAssignee) fields.push('担当');
            if (item.fromDueDate !== null && item.fromDueDate !== undefined || item.toDueDate !== null && item.toDueDate !== undefined) fields.push('期限');
            if (item.fromPriority !== null && item.fromPriority !== undefined || item.toPriority !== null && item.toPriority !== undefined) fields.push('優先度');
            if (fields.length) add(issue, 'issueUpdated', item.id, item.createdAt, fields.join('・') + 'を変更');
          }
          versions[issue.id] = issue.updatedAt;
        }
        if (page.pageInfo.hasNextPage && !page.pageInfo.endCursor) throw fail('linear_pagination_stalled', 503);
        after = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : null;
        if (after && seen.has(after)) throw fail('linear_pagination_stalled', 503);
        if (after) seen.add(after);
      } while (after && ++pages < 20);
      if (after) throw fail('linear_activity_incomplete', 503);
      // Comment timestamps are independent of issue.updatedAt, including replies.
      // Query them separately so an unchanged issue version cannot hide activity.
      after = null; pages = 0; seen.clear();
      do {
        const page = await source.listCommentActivityCandidates(session, { since, after, owner,
          watched: Object.keys({ ...old.watched, ...watched }).slice(0, 2000) });
        for (const comment of page.nodes) {
          const issue = comment.issue;
          if (!issue) continue;
          const relevant = issue.assignee?.id === source.ownerUserId || issue.creator?.id === source.ownerUserId
            || issue.subscribers?.nodes?.some((user) => user.id === source.ownerUserId) || old.watched?.[issue.id] === true;
          if (relevant || mention(comment.body)) add(issue, mention(comment.body) ? 'issueMention' : 'issueNewComment',
            comment.id + ':' + comment.updatedAt, comment.updatedAt ?? comment.createdAt,
            mention(comment.body) ? '社長へのメンション' : 'コメント', comment.body?.slice(0, 250));
        }
        if (page.pageInfo.hasNextPage && !page.pageInfo.endCursor) throw fail('linear_pagination_stalled', 503);
        after = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : null;
        if (after && seen.has(after)) throw fail('linear_pagination_stalled', 503);
        if (after) seen.add(after);
      } while (after && ++pages < 20);
      if (after) throw fail('linear_activity_incomplete', 503);
      file.mutate((doc) => {
        const state = doc.viewers[viewer] ??= { events: {}, versions: {}, watermark: null };
        for (const event of events) if (!state.events[event.id]) state.events[event.id] = event;
        state.events = Object.fromEntries(Object.values(state.events).sort((a, b) => b.updatedAt.localeCompare(a.updatedAt)).slice(0, MAX_EVENTS).map((event) => [event.id, event]));
        state.versions = Object.fromEntries(Object.entries(versions).slice(-10000));
        state.watched = Object.fromEntries(Object.entries(watched).slice(-2000));
        state.watermark = started;
      });
      refreshedAt = now(); refreshedViewer = viewer;
    })();
    try { await pending; } finally { pending = null; }
  }
  async function notification(session, id) {
    const item = snapshot(session.viewer.id).events[id];
    if (!item) throw fail('notification_not_found', 404);
    return item;
  }
  return { ...source, ownerInboxAvailable: true,
    async refreshInbox() { await refresh(await source.session()); },
    async listCollection(name, options = {}) {
      if (name !== 'inbox') return source.listCollection(name, options);
      const session = await source.session();
      if (options.waitForRefresh === true) await refresh(session);
      else {
        void refresh(session).catch(() => {});
        // Never report an unsynchronized empty snapshot as an empty inbox.
        if (!snapshot(session.viewer.id).watermark) throw new TaskSourceError('linear_inbox_refreshing',
          '受信箱を同期中です。少し待ってから更新してください。', { status: 503, retryable: true });
      }
      const includeArchived = options.includeArchived === 'true';
      const items = Object.values(snapshot(session.viewer.id).events).filter((v) => includeArchived || !v.archivedAt)
        .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt) || a.id.localeCompare(b.id));
      const limit = options.limit == null ? 50 : Number(options.limit);
      let cursor;
      try { cursor = options.cursor ? JSON.parse(Buffer.from(options.cursor, 'base64url').toString()) : null; }
      catch { throw fail('cursor_invalid'); }
      if (!Number.isInteger(limit) || limit < 1 || limit > 100 || cursor && (cursor.viewer !== session.viewer.id || cursor.archive !== includeArchived || !Number.isInteger(cursor.offset) || cursor.offset < 0 || cursor.offset > MAX_EVENTS)) throw fail('cursor_invalid');
      const offset = cursor?.offset ?? 0;
      return { items: items.slice(offset, offset + limit), nextCursor: offset + limit < items.length
        ? Buffer.from(JSON.stringify({ viewer: session.viewer.id, archive: includeArchived, offset: offset + limit })).toString('base64url') : null,
        viewerId: session.viewer.id, observedAt: snapshot(session.viewer.id).watermark, inboxMode: 'laa',
        notice: 'LAAアプリ独自の受信箱。Linearの既読とは同期しません。' };
    },
    getNotificationInSession: notification,
    async getNotification(id) {
      const session = await source.session();
      return { notification: await notification(session, id), viewerId: session.viewer.id, observedAt: new Date(now()).toISOString() };
    },
    async updateNotification(session, id, action) {
      if (!['read', 'unread', 'archive', 'unarchive'].includes(action)) throw fail('filter_invalid');
      await notification(session, id);
      file.mutate((doc) => {
        const item = doc.viewers[session.viewer.id].events[id];
        if (action === 'read' || action === 'unread') item.readAt = action === 'read' ? new Date(now()).toISOString() : null;
        else item.archivedAt = action === 'archive' ? new Date(now()).toISOString() : null;
      });
      return { id };
    },
  };
}

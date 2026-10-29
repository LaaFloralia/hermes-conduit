// Kanban task source for the LAA Bridge (ROADMAP task 19).
//
// The Conduit app reads Kanban through the Hermes dashboard plugin API
// (/api/plugins/kanban/*, see Conduit/Services/KanbanService.swift). That API
// answers 401 to a bare loopback request and the Bridge has no approved
// Mac-side wrapper for the dashboard credential, so this source stays
// unavailable until the parent authorizes one. It is never faked into looking
// empty: every response carries availability, and the caller decides.
//
// The mapping and the Linear de-duplication are exercised against fixtures
// (bridge/test/tasks.test.mjs) so the wiring is ready when the wrapper exists.
//
// Kanban assigns a profile, and that assignment can start a worker. This source
// is read-only: it never calls /dispatch, /tasks/{id}/reassign or any other
// mutating endpoint, and the Bridge exposes no path that does.

const BOARD_PATH = '/api/plugins/kanban/board';
const DETAIL_PATH = (id) => `/api/plugins/kanban/tasks/${encodeURIComponent(id)}`;
const COMMENTS_PATH = (id) => `/api/plugins/kanban/tasks/${encodeURIComponent(id)}/comments`;

const LINEAR_REF_KEYS = [
  'linear_identifier',
  'linearIdentifier',
  'source_issue',
  'sourceIssue',
  'external_id',
  'externalId',
];
const LINEAR_ID = /^[A-Za-z][A-Za-z0-9]*-\d+$/;

const CLOSED = new Set(['done', 'completed', 'canceled', 'cancelled', 'failed']);

function toIso(value) {
  if (typeof value === 'number' && Number.isFinite(value)) {
    // Kanban timestamps are epoch seconds or milliseconds depending on the
    // backend; anything below 1e12 is seconds.
    const ms = value < 1e12 ? value * 1000 : value;
    return new Date(ms).toISOString();
  }
  if (typeof value === 'string' && value !== '') {
    const parsed = Date.parse(value);
    return Number.isNaN(parsed) ? null : new Date(parsed).toISOString();
  }
  return null;
}

function statusCategory(status) {
  if (typeof status !== 'string') return 'open';
  return CLOSED.has(status.toLowerCase()) ? 'closed' : 'open';
}

function linearRefs(raw) {
  const refs = [];
  for (const key of LINEAR_REF_KEYS) {
    const value = raw?.[key];
    if (typeof value === 'string' && LINEAR_ID.test(value)) refs.push(value);
  }
  return [...new Set(refs)];
}

export function toKanbanTask(raw) {
  const id = raw?.id === undefined || raw?.id === null ? '' : String(raw.id);
  const assignee = typeof raw?.assignee === 'string' && raw.assignee !== '' ? raw.assignee : null;
  const createdBy = typeof raw?.created_by === 'string' && raw.created_by !== '' ? raw.created_by : null;
  const links = raw?.links ?? {};
  const parents = Array.isArray(links.parents) ? links.parents.map(String) : [];
  const children = Array.isArray(links.children) ? links.children.map(String) : [];
  const updatedAt = toIso(raw?.completed_at ?? raw?.updated_at ?? raw?.created_at ?? null);
  return {
    id: `kanban:${id}`,
    source: 'kanban',
    sourceId: id,
    title: typeof raw?.title === 'string' ? raw.title : '',
    // Kanban never holds an owner task: whoever queued it, execution belongs to
    // a profile, and that profile is the executor, not the owner of LAA's work.
    owner: { kind: 'agent', name: assignee ?? createdBy, id: null },
    executor: assignee ? { kind: 'agent', name: assignee, id: null } : null,
    status: { name: typeof raw?.status === 'string' ? raw.status : null, type: raw?.status ?? null, category: statusCategory(raw?.status) },
    dependencies: { blockedBy: parents, blocks: children, complete: true },
    result: {
      state: typeof raw?.result === 'string' && raw.result !== '' ? 'reported' : (raw?.completed_at ? 'completed' : 'none'),
      summary: typeof raw?.result === 'string' ? raw.result : (typeof raw?.latest_summary === 'string' ? raw.latest_summary : null),
      commentId: null,
      reportedAt: toIso(raw?.completed_at ?? null),
    },
    project: typeof raw?.tenant === 'string' && raw.tenant !== '' ? { id: null, name: raw.tenant } : null,
    labels: [],
    url: null,
    updatedAt,
    version: id,
    // Kept internal: routes strip the array and keep the first reference, using
    // it to suppress a Kanban copy of a task Linear already owns.
    linearRefs: linearRefs(raw),
  };
}

function unavailable() {
  return {
    source: 'kanban',
    state: 'unavailable',
    reason: 'kanban_wrapper_not_authorized',
    detail: 'the Hermes dashboard Kanban API needs an authenticated Mac-side wrapper that does not exist yet',
    observedAt: new Date().toISOString(),
  };
}

export function createKanbanTaskSource({
  baseUrl = process.env.LAA_BRIDGE_KANBAN_URL ?? '',
  request = null,
  now = () => Date.now(),
} = {}) {
  const configured = typeof request === 'function' && typeof baseUrl === 'string' && baseUrl !== '';

  function describe() {
    if (!configured) {
      return { ...unavailable(), observedAt: new Date(now()).toISOString() };
    }
    return { source: 'kanban', state: 'available', observedAt: new Date(now()).toISOString() };
  }

  async function listTasks() {
    if (!configured) return { items: [] };
    const payload = await request({ path: BOARD_PATH, method: 'GET' });
    const tasks = payload?.data?.tasks ?? payload?.tasks ?? [];
    if (!Array.isArray(tasks)) {
      throw new Error('kanban board response has no task list');
    }
    return { items: tasks.filter((task) => task && task.id !== undefined).map(toKanbanTask) };
  }

  async function getTask(sourceId) {
    if (!configured) return null;
    const payload = await request({ path: DETAIL_PATH(sourceId), method: 'GET' });
    const raw = payload?.data?.task ?? payload?.task;
    if (!raw) return null;
    let comments = [];
    try {
      const commentPayload = await request({ path: COMMENTS_PATH(sourceId), method: 'GET' });
      const list = commentPayload?.data?.comments ?? commentPayload?.comments ?? [];
      if (Array.isArray(list)) {
        comments = list.map((comment) => ({
          id: comment?.id ?? null,
          author: comment?.author ?? null,
          createdAt: toIso(comment?.created_at ?? null),
          updatedAt: toIso(comment?.updated_at ?? null),
          body: typeof comment?.body === 'string' ? comment.body : '',
          truncated: false,
          agentReport: false,
        }));
      }
    } catch {
      // A missing comment feed must not hide the task itself.
      comments = [];
    }
    return { task: toKanbanTask(raw), comments, links: [] };
  }

  return { describe, listTasks, getTask };
}

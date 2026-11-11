// The owner's own Linear tasks, readable and writable (Work tab).
//
// This is the write half of the Linear task source in `linear.mjs`. That module
// stays read-only on purpose: its GraphQL guard accepts only `query`
// documents, and `/v1/tasks` must not be able to assign or start anything. The
// two modules share the credential path (`readTokenViaHelper`,
// `authorizationHeader`) so the Bridge still holds no key of its own.
//
// What keeps this module from becoming a general Linear client:
//   * every document is a module constant, and the transport refuses anything
//     that is not one of those constants by identity (no arbitrary GraphQL);
//   * the team (key BUS), the owner id and the Todo workflow state are resolved
//     from the account itself and cached briefly, never taken from the client;
//   * every write first re-reads the issue and requires it to be in team BUS,
//     assigned to the owner, with no delegate, including archived issues.
//
// Errors carry no upstream body: a GraphQL echo can contain the query, values
// or a token, so only the fact of a rejection is surfaced.

import { markBeforeWrite, markWriteStarted } from '../errors.mjs';
import { TaskSourceError } from './errors.mjs';
import { authorizationHeader, readTokenViaHelper } from './linear.mjs';
import { createLinearListCache, invalidateLinearLists } from './list-cache.mjs';

export { TaskSourceError };

const DEFAULT_ENDPOINT = 'https://api.linear.app/graphql';
const DEFAULT_TOKEN_HELPER = '/Users/laa/.config/laa/linear-agent-token.sh';
// Same owner id the laa-agent CLI and linear.mjs use.
const DEFAULT_OWNER_USER_ID = 'd1f71177-5355-4f4f-b42c-7894c0870112';
const DEFAULT_TEAM_KEY = 'BUS';
const DEFAULT_TEAM_NAME = 'LAA';
const TODO_STATE_NAME = 'Todo';

const PAGE_SIZE = 100;
const MAX_PAGES = 20;
const CONFIG_TTL_MS = 5 * 60 * 1000;

const ISSUE_FIELDS = `
  id
  identifier
  title
  description
  dueDate
  priority
  url
  updatedAt
  archivedAt
  trashed
  state { name type }
  assignee { id name }
  delegate { id name }
  team { id key name }
  project { id name }
  labels(first: 20) { nodes { id name color } }
`;

const VIEWER_QUERY = `query BridgeOwnerViewer($key: String!) {
  viewer { id name }
  teams(filter: { key: { eq: $key } }) {
    nodes { id key name states { nodes { id name type } } }
  }
}`;

const LIST_QUERY = `query BridgeOwnerTasks($team: String!, $owner: ID!, $after: String) {
  issues(first: ${PAGE_SIZE}, after: $after, filter: {
    team: { key: { eq: $team } }
    assignee: { id: { eq: $owner } }
    state: { type: { nin: ["completed", "canceled"] } }
    delegate: { null: true }
  }) {
    nodes { ${ISSUE_FIELDS} }
    pageInfo { hasNextPage endCursor }
  }
}`;

const ARCHIVED_LIST_QUERY = `query BridgeOwnerArchivedTasks($team: String!, $owner: ID!, $after: String) {
  issues(first: ${PAGE_SIZE}, after: $after, includeArchived: true, filter: {
    team: { key: { eq: $team } }
    assignee: { id: { eq: $owner } }
    archivedAt: { null: false }
    delegate: { null: true }
  }) {
    nodes { ${ISSUE_FIELDS} }
    pageInfo { hasNextPage endCursor }
  }
}`;

const ISSUE_QUERY = `query BridgeOwnerTask($id: String!) {
  issue(id: $id) { ${ISSUE_FIELDS} }
}`;

const CREATE_MUTATION = `mutation BridgeOwnerTaskCreate($input: IssueCreateInput!) {
  issueCreate(input: $input) {
    success
    issue { ${ISSUE_FIELDS} }
  }
}`;

const UPDATE_MUTATION = `mutation BridgeOwnerTaskUpdate($id: String!, $input: IssueUpdateInput!) {
  issueUpdate(id: $id, input: $input) {
    success
    issue { ${ISSUE_FIELDS} }
  }
}`;

const ARCHIVE_MUTATION = `mutation BridgeOwnerTaskArchive($id: String!) {
  issueArchive(id: $id) { success }
}`;
const RESTORE_MUTATION = `mutation BridgeOwnerTaskRestore($id: String!) {
  issueUnarchive(id: $id) { success }
}`;
const COMMENT_QUERY = `query BridgeOwnerTaskComment($id: String!) {
  comment(id: $id) { id issueId body }
}`;
const COMMENT_MUTATION = `mutation BridgeOwnerTaskCommentCreate($input: CommentCreateInput!) {
  commentCreate(input: $input) { success comment { id issueId body } }
}`;

const DOCUMENTS = new Set([
  VIEWER_QUERY,
  LIST_QUERY,
  ARCHIVED_LIST_QUERY,
  ISSUE_QUERY,
  CREATE_MUTATION,
  UPDATE_MUTATION,
  ARCHIVE_MUTATION,
  RESTORE_MUTATION,
  COMMENT_QUERY,
  COMMENT_MUTATION,
]);

// Only an unknown issue id produces this shape; every other rejection stays a
// dependency error so an outage is never reported as "not found".
function isMissingIssue(errors, field = 'issue') {
  return errors.length > 0 && errors.every((error) => (
    error?.path?.[0] === field
    && error?.extensions?.userError === true
    && String(error?.extensions?.code ?? '') === 'INPUT_ERROR'
  ));
}

function statusOf(type) {
  if (type === 'started') return 'doing';
  if (type === 'completed') return 'done';
  if (type === 'canceled') return 'canceled';
  return 'todo';
}

export const LINEAR_OWNER_DOCUMENTS = Object.freeze([...DOCUMENTS]);

function isClosed(issue) {
  const type = issue?.state?.type;
  return type === 'completed' || type === 'canceled';
}

function toTask(issue) {
  const task = {
    id: issue.id,
    identifier: typeof issue.identifier === 'string' ? issue.identifier : '',
    title: typeof issue.title === 'string' ? issue.title : '',
    description: typeof issue.description === 'string' ? issue.description : '',
    priority: Number.isInteger(issue.priority) ? issue.priority : 0,
    status: statusOf(issue.state?.type),
    stateName: typeof issue.state?.name === 'string' ? issue.state.name : '',
    updatedAt: typeof issue.updatedAt === 'string' ? issue.updatedAt : '',
    archivedAt: typeof issue.archivedAt === 'string' ? issue.archivedAt : null,
  };
  if (typeof issue.dueDate === 'string' && issue.dueDate !== '') task.dueDate = issue.dueDate;
  if (typeof issue.url === 'string' && issue.url !== '') task.url = issue.url;
  // The app groups the list by genre: Linear's project and labels name it
  // before the title does. Sent only when set, so an unset task reads as before.
  if (typeof issue.project?.id === 'string' && typeof issue.project?.name === 'string' && issue.project.name !== '') {
    task.project = { id: issue.project.id, name: issue.project.name };
  }
  const labels = (Array.isArray(issue.labels?.nodes) ? issue.labels.nodes : [])
    .filter((label) => typeof label?.name === 'string' && label.name !== '')
    .map((label) => ({
      id: typeof label.id === 'string' ? label.id : null,
      name: label.name,
      color: typeof label.color === 'string' ? label.color : null,
    }));
  if (labels.length > 0) task.labels = labels;
  return task;
}

export function createLinearOwnerTaskSource({
  endpoint = process.env.LAA_BRIDGE_LINEAR_ENDPOINT ?? DEFAULT_ENDPOINT,
  tokenHelper = process.env.LAA_BRIDGE_LINEAR_TOKEN_HELPER ?? DEFAULT_TOKEN_HELPER,
  teamKey = process.env.LAA_BRIDGE_LINEAR_TEAM ?? DEFAULT_TEAM_KEY,
  teamName = process.env.LAA_BRIDGE_LINEAR_TEAM_NAME ?? DEFAULT_TEAM_NAME,
  ownerUserId = process.env.LAA_BRIDGE_LINEAR_OWNER_ID ?? DEFAULT_OWNER_USER_ID,
  fetchImpl = globalThis.fetch,
  readToken = () => readTokenViaHelper(tokenHelper),
  requestTimeoutMs = 15_000,
  configTtlMs = CONFIG_TTL_MS,
  listTtlMs = 45_000,
  now = () => Date.now(),
} = {}) {
  let cachedToken = null;
  let cachedConfig = null;
  const cachedList = createLinearListCache({ now, ttlMs: listTtlMs });

  async function token({ refresh = false } = {}) {
    if (cachedToken && !refresh) return cachedToken;
    cachedToken = await readToken();
    return cachedToken;
  }

  async function post(tokenValue, document, variables) {
    let response;
    try {
      response = await fetchImpl(endpoint, {
        method: 'POST',
        headers: {
          authorization: authorizationHeader(tokenValue),
          'content-type': 'application/json',
          accept: 'application/json',
        },
        body: JSON.stringify({ query: document, variables }),
        signal: AbortSignal.timeout(requestTimeoutMs),
      });
    } catch {
      throw new TaskSourceError('linear_unreachable', 'Linear could not be reached', { retryable: true });
    }
    return response;
  }

  // Every error from a mutation document is marked as "a write may have
  // started", whatever its HTTP status becomes. Read documents stay unmarked.
  async function gql(document, variables = {}, options = {}) {
    if (options.write === true) invalidateLinearLists();
    try {
      return await gqlUnmarked(document, variables, options);
    } catch (error) {
      if (options.write === true) markWriteStarted(error);
      throw error;
    } finally {
      if (options.write === true) invalidateLinearLists();
    }
  }

  async function gqlUnmarked(document, variables = {}, { notFoundIsNull = false } = {}) {
    if (!DOCUMENTS.has(document)) {
      throw new TaskSourceError('linear_document_rejected', 'only the fixed Linear documents may be sent', {
        status: 500,
        retryable: false,
      });
    }
    let response = await post(await token(), document, variables);
    if (response.status === 401) {
      response = await post(await token({ refresh: true }), document, variables);
      if (response.status === 401) {
        throw new TaskSourceError('linear_unauthorized', 'Linear rejected the stored credential');
      }
    }
    if (!response.ok) {
      throw new TaskSourceError(
        'linear_unavailable',
        `Linear responded with HTTP ${response.status}`,
        { retryable: response.status === 429 || response.status >= 500 },
      );
    }
    let payload;
    try {
      payload = await response.json();
    } catch {
      throw new TaskSourceError('linear_response_invalid', 'Linear returned a response that is not JSON', {
        retryable: true,
      });
    }
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
      throw new TaskSourceError('linear_response_invalid', 'Linear returned an unexpected response body');
    }
    if (Array.isArray(payload.errors) && payload.errors.length > 0) {
      const field = typeof notFoundIsNull === 'string' ? notFoundIsNull : 'issue';
      if (notFoundIsNull && isMissingIssue(payload.errors, field)) return { [field]: null };
      throw new TaskSourceError('linear_request_rejected', 'Linear rejected the request');
    }
    if (!payload.data || typeof payload.data !== 'object' || Array.isArray(payload.data)) {
      throw new TaskSourceError('linear_response_invalid', 'Linear returned no data object');
    }
    return payload.data;
  }

  // The team, the Todo state and the signed-in user are configuration, not
  // request input: resolve them from the account and keep them for a few
  // minutes. A missing team or state is a 503, never an empty list. This path
  // only reads, so its failures are safe to release from the idempotency
  // ledger even though many of them are 503.
  async function config(options = {}) {
    try {
      return await resolveConfig(options);
    } catch (error) {
      throw markBeforeWrite(error);
    }
  }

  async function resolveConfig({ refresh = false } = {}) {
    if (!refresh && cachedConfig && now() - cachedConfig.at < configTtlMs) return cachedConfig.value;

    const viewerData = await gql(VIEWER_QUERY, { key: teamKey });
    const viewer = viewerData.viewer;
    if (!viewer || typeof viewer.id !== 'string') {
      throw new TaskSourceError('linear_owner_config_incomplete', 'Linear did not return the signed-in user');
    }
    if (viewer.id !== ownerUserId) {
      throw new TaskSourceError(
        'linear_owner_identity_mismatch',
        'the Linear credential is not the owner',
        { retryable: false },
      );
    }

    const teams = viewerData.teams?.nodes;
    if (!Array.isArray(teams)) {
      throw new TaskSourceError('linear_response_invalid', 'Linear returned an unexpected team list');
    }
    const matches = teams.filter((team) => team?.key === teamKey);
    if (matches.length !== 1) {
      throw new TaskSourceError('linear_owner_config_incomplete', `Linear has no single team with key ${teamKey}`);
    }
    const team = matches[0];
    if (typeof team.id !== 'string' || team.id === '') {
      throw new TaskSourceError('linear_owner_config_incomplete', 'the Linear team has no id');
    }
    if (team.name !== teamName) {
      throw new TaskSourceError(
        'linear_owner_config_incomplete',
        `the Linear team ${teamKey} is not named ${teamName}`,
      );
    }

    const states = team.states?.nodes;
    if (!Array.isArray(states)) {
      throw new TaskSourceError('linear_response_invalid', 'Linear returned an unexpected state list');
    }
    const todo = states.find((state) => state?.name === TODO_STATE_NAME && state?.type !== 'completed' && state?.type !== 'canceled');
    if (!todo || typeof todo.id !== 'string' || todo.id === '') {
      throw new TaskSourceError('linear_owner_config_incomplete', `the Linear team has no ${TODO_STATE_NAME} state`);
    }
    const completed = states.find((s) => s?.type === 'completed' && s.name === 'Done') ?? states.find((s) => s?.type === 'completed');
    const value = { teamId: team.id, todoStateId: todo.id, completedStateId: typeof completed?.id === 'string' && completed.id ? completed.id : null };
    cachedConfig = { at: now(), value };
    return value;
  }

  async function getIssue(id) {
    const data = await gql(ISSUE_QUERY, { id }, { notFoundIsNull: true });
    // Only a present `issue: null` means "no such issue". A missing key or a
    // non-object value is a broken response, not evidence of deletion.
    if (!Object.hasOwn(data, 'issue')) {
      throw new TaskSourceError('linear_response_invalid', 'Linear returned no issue field');
    }
    const issue = data.issue;
    if (issue === null) return null;
    if (typeof issue !== 'object' || Array.isArray(issue)) {
      throw new TaskSourceError('linear_response_invalid', 'Linear returned an invalid issue');
    }
    return issue;
  }

  // Archived tasks retain their owner; unassigned and trashed tasks are excluded.
  function owned(issue) {
    if (!issue) return false;
    if (issue.trashed === true) return false;
    if (issue.team?.key !== teamKey) return false;
    if (issue.delegate) return false;
    if (issue.assignee) return issue.assignee.id === ownerUserId;
    return false;
  }

  async function listOwnerTasks({ archived = false } = {}) {
    return cachedList(archived, () => loadOwnerTasks({ archived }));
  }

  async function loadOwnerTasks({ archived }) {
    await config();
    const items = [];
    // Every cursor that was used: a cycle (A -> B -> A) would otherwise read
    // the same page forever and look like a complete list.
    const seen = new Set();
    let cursor = null;
    for (let page = 0; page < MAX_PAGES; page += 1) {
      const data = await gql(archived ? ARCHIVED_LIST_QUERY : LIST_QUERY, { team: teamKey, owner: ownerUserId, after: cursor });
      const connection = data.issues;
      if (!connection || !Array.isArray(connection.nodes)) {
        throw new TaskSourceError('linear_response_invalid', 'Linear returned an unexpected issue list');
      }
      for (const issue of connection.nodes) {
        if (!issue || typeof issue !== 'object') {
          throw new TaskSourceError('linear_response_invalid', 'Linear returned an unexpected issue');
        }
        // The query already filters by team and assignee; the same rule is
        // applied to the rows themselves so a filter change or an unexpected
        // row can never put an agent's or another team's task in this list.
        if (Boolean(issue.archivedAt) !== archived || issue.trashed === true || (!archived && isClosed(issue)) || !owned(issue)) continue;
        items.push(toTask(issue));
      }
      const pageInfo = connection.pageInfo;
      if (!pageInfo || typeof pageInfo !== 'object' || typeof pageInfo.hasNextPage !== 'boolean') {
        throw new TaskSourceError('linear_response_invalid', 'Linear returned no usable page information');
      }
      if (!pageInfo.hasNextPage) return { items };
      const next = pageInfo.endCursor;
      if (typeof next !== 'string' || next === '') {
        throw new TaskSourceError('linear_pagination_stalled', 'Linear pagination did not advance');
      }
      if (seen.has(next)) {
        throw new TaskSourceError('linear_pagination_stalled', 'Linear pagination repeated a page');
      }
      seen.add(next);
      cursor = next;
    }
    // A partial list must never look like the whole list.
    throw new TaskSourceError('linear_pagination_incomplete', 'the owner task list is larger than the Bridge reads');
  }

  async function readOwnerTask(id) {
    const issue = await getIssue(id);
    return owned(issue) ? toTask(issue) : null;
  }

  // A retry after a lost response sends the same client UUID; Linear then
  // refuses the duplicate. Only an issue this endpoint owns and that already
  // holds exactly this content is the same request; a different title, body,
  // due date or priority is a conflict, not a success.
  function sameContent(issue, input) {
    const description = typeof issue.description === 'string' ? issue.description : '';
    const dueDate = typeof issue.dueDate === 'string' && issue.dueDate !== '' ? issue.dueDate : null;
    return issue.title === input.title
      && description === (typeof input.description === 'string' ? input.description : '')
      && dueDate === (typeof input.dueDate === 'string' ? input.dueDate : null)
      && (Number.isInteger(issue.priority) ? issue.priority : 0) === (Number.isInteger(input.priority) ? input.priority : 0);
  }

  async function createOwnerTask({ id, title, description, dueDate, priority }) {
    const settings = await config();
    const input = {
      id,
      teamId: settings.teamId,
      title,
      stateId: settings.todoStateId,
      assigneeId: ownerUserId,
      priority,
    };
    if (typeof description === 'string') input.description = description;
    if (typeof dueDate === 'string') input.dueDate = dueDate;

    let payload = null;
    let rejection = null;
    try {
      const data = await gql(CREATE_MUTATION, { input }, { write: true });
      payload = data.issueCreate;
    } catch (error) {
      // Only a refused document may be re-read; an outage or a credential
      // failure stays what it is.
      if (!(error instanceof TaskSourceError) || error.code !== 'linear_request_rejected') throw error;
      rejection = error;
    }
    if (payload && payload.success !== false && payload.issue) return toTask(payload.issue);

    // From here on a write was attempted. Every failure keeps the reservation,
    // even when the reconciliation read itself fails or returns 404.
    try {
      const existing = await getIssue(id);
      if (existing && owned(existing)) {
        if (!sameContent(existing, input)) {
          // The duplicate id proves this create did not add a new issue, so a
          // retry may replay the same conflict instead of staying in flight.
          throw new TaskSourceError(
            'linear_owner_task_conflict',
            'a task with this id already exists with different content',
            { status: 409, writeStarted: false },
          );
        }
        return toTask(existing);
      }
      if (rejection) throw rejection;
      throw new TaskSourceError('linear_write_rejected', 'Linear did not create the issue', { status: 502, writeStarted: true });
    } catch (error) {
      throw markWriteStarted(error);
    }
  }

  async function patchOwnerTask(id, patch) {
    const input = {};
    if (Object.hasOwn(patch, 'title')) input.title = patch.title;
    if (Object.hasOwn(patch, 'description')) input.description = patch.description;
    if (Object.hasOwn(patch, 'dueDate')) input.dueDate = patch.dueDate;
    if (Object.hasOwn(patch, 'priority')) input.priority = patch.priority;

    const data = await gql(UPDATE_MUTATION, { id, input }, { write: true });
    const payload = data.issueUpdate;
    if (payload?.success === false || !payload?.issue) {
      throw new TaskSourceError('linear_write_rejected', 'Linear did not update the issue', { status: 502, writeStarted: true });
    }
    return toTask(payload.issue);
  }

  async function setArchived(id, archived) {
    const document = archived ? ARCHIVE_MUTATION : RESTORE_MUTATION;
    const field = archived ? 'issueArchive' : 'issueUnarchive';
    let failure;
    try {
      const data = await gql(document, { id }, { write: true });
      if (data[field]?.success === true) return;
    } catch (error) { failure = error; }
    // Missing or trashed is never evidence of a successful archive/restore.
    try {
      const current = await getIssue(id);
      if (owned(current) && Boolean(current.archivedAt) === archived) return;
    } catch { /* Preserve the uncertainty of the attempted write. */ }
    if (failure) throw failure;
    throw new TaskSourceError('linear_archive_unconfirmed', 'Linear did not confirm the archive state', { writeStarted: true });
  }

  async function requireOwned(id) {
    await config();
    const issue = await getIssue(id);
    if (!owned(issue)) throw new TaskSourceError('linear_owner_task_not_found', 'no such owner task', { status: 404, writeStarted: false });
    return issue;
  }

  async function prepareCompletion() {
    const settings = await config();
    if (!settings.completedStateId) throw new TaskSourceError('linear_owner_config_incomplete', 'the Linear team has no completed state', { writeStarted: false });
    return settings;
  }

  // Client UUIDs make comments idempotent even if Linear accepted a write but
  // the Bridge lost its response or died before recording the completed step.
  async function commentOwnerTask(issueId, { id, body }) {
    if (typeof id !== 'string' || !/^[0-9a-f-]{36}$/.test(id) || typeof body !== 'string' || body.length > 4000) {
      throw new TaskSourceError('linear_comment_invalid', 'invalid task comment', { status: 400, writeStarted: false });
    }
    await requireOwned(issueId);
    const same = (c) => c?.id === id && c.issueId === issueId && c.body === body;
    async function existing() {
      const data = await gql(COMMENT_QUERY, { id }, { notFoundIsNull: 'comment' });
      if (!Object.hasOwn(data, 'comment') || (data.comment !== null && (typeof data.comment !== 'object' || Array.isArray(data.comment)))) {
        throw new TaskSourceError('linear_response_invalid', 'Linear returned an invalid comment');
      }
      if (data.comment && !same(data.comment)) throw new TaskSourceError('linear_comment_conflict', 'the comment id has different content', { status: 409 });
      return data.comment;
    }
    if (await existing()) return;
    // Re-read immediately before the mutation, including on a resumed step.
    await requireOwned(issueId);
    let failure;
    try {
      const data = await gql(COMMENT_MUTATION, { input: { id, issueId, body } }, { write: true });
      if (data.commentCreate?.success === true && same(data.commentCreate.comment)) return;
    } catch (e) { failure = e; }
    try { await requireOwned(issueId); if (await existing()) return; } catch { /* Retain the write's uncertainty. */ }
    if (failure) throw failure;
    throw new TaskSourceError('linear_comment_unconfirmed', 'Linear did not confirm the comment', { writeStarted: true });
  }

  async function completeOwnerTask(id) {
    const settings = await prepareCompletion();
    const current = await requireOwned(id);
    if (current.state?.type === 'completed') return toTask(current);
    let failure;
    try {
      const data = await gql(UPDATE_MUTATION, { id, input: { stateId: settings.completedStateId } }, { write: true });
      if (data.issueUpdate?.success === true && owned(data.issueUpdate.issue) && data.issueUpdate.issue.state?.type === 'completed') return toTask(data.issueUpdate.issue);
    } catch (e) { failure = e; }
    try { const reread = await getIssue(id); if (owned(reread) && reread.state?.type === 'completed') return toTask(reread); } catch { /* Keep the attempted write uncertain. */ }
    if (failure) throw failure;
    throw new TaskSourceError('linear_completion_unconfirmed', 'Linear did not confirm the completed state', { writeStarted: true });
  }

  return {
    config, listOwnerTasks, readOwnerTask, createOwnerTask, patchOwnerTask,
    prepareCompletion, commentOwnerTask, completeOwnerTask,
    archiveOwnerTask: (id) => setArchived(id, true),
    restoreOwnerTask: (id) => setArchived(id, false),
  };
}

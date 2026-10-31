// Linear operations for the owner's personal account. The agent credential is
// intentionally not a fallback: until the owner provisions the helper and the
// expected viewer, this source is unavailable.
import { isAbsolute } from 'node:path';
import { createHash } from 'node:crypto';
import { readTokenViaHelper } from './linear.mjs';
import { TaskSourceError } from './errors.mjs';

const ISSUE_FIELDS = `
  id identifier title url updatedAt priority estimate dueDate
  state { id name type } team { id key name }
  assignee { id name app } delegate { id name app }
  project { id name } projectMilestone { id name }
  cycle { id name number } parent { id identifier title }
  labels(first: 100) { nodes { id name color } pageInfo { hasNextPage endCursor } }
`;
const PAGE = 'pageInfo { hasNextPage endCursor }';

// Documents are fixed here, never supplied by a device. They are exported so
// tests can validate them against the public Linear schema, without credentials.
export const PERSONAL_DOCUMENTS = Object.freeze({
  viewer: 'query LAAPersonalViewer { viewer { id name } }',
  issues: `query LAAPersonalIssues($first: Int!, $after: String, $filter: IssueFilter) {
    issues(first: $first, after: $after, filter: $filter) { nodes { ${ISSUE_FIELDS} } ${PAGE} }
  }`,
  search: `query LAAPersonalSearch($first: Int!, $after: String, $filter: IssueFilter, $term: String!) {
    searchIssues(first: $first, after: $after, filter: $filter, term: $term) { nodes { ${ISSUE_FIELDS} } ${PAGE} }
  }`,
  view: `query LAAPersonalView($id: String!, $first: Int!, $after: String) {
    customView(id: $id) { id name modelName issues(first: $first, after: $after) { nodes { ${ISSUE_FIELDS} } ${PAGE} } }
  }`,
  issue: `query LAAPersonalIssue($id: String!) { issue(id: $id) { ${ISSUE_FIELDS} description } }`,
  createIssue: `mutation LAAPersonalIssueCreate($input: IssueCreateInput!) {
    issueCreate(input: $input) { success issue { id identifier updatedAt } }
  }`,
  updateIssue: `mutation LAAPersonalIssueUpdate($id: String!, $input: IssueUpdateInput!) {
    issueUpdate(id: $id, input: $input) { success issue { id identifier updatedAt } }
  }`,
  metadata: `query LAAPersonalMetadata {
    teams(first: 100) { nodes { id key name } ${PAGE} }
    users(first: 100) { nodes { id name app active } ${PAGE} }
    workflowStates(first: 100) { nodes { id name type color position team { id } } ${PAGE} }
    issueLabels(first: 100) { nodes { id name color team { id } } ${PAGE} }
    projects(first: 100) { nodes { id name } ${PAGE} }
    projectMilestones(first: 100) { nodes { id name project { id } } ${PAGE} }
    cycles(first: 100) { nodes { id name number team { id } } ${PAGE} }
    issuePriorityValues { priority label }
  }`,
  projects: `query LAAPersonalProjects($first: Int!, $after: String) {
    projects(first: $first, after: $after) { nodes { id name description } ${PAGE} }
  }`,
  cycles: `query LAAPersonalCycles($first: Int!, $after: String) {
    cycles(first: $first, after: $after) { nodes { id name number startsAt endsAt team { id key name } } ${PAGE} }
  }`,
  teams: `query LAAPersonalTeams($first: Int!, $after: String) {
    teams(first: $first, after: $after) { nodes { id key name } ${PAGE} }
  }`,
  users: `query LAAPersonalUsers($first: Int!, $after: String) {
    users(first: $first, after: $after) { nodes { id name app active } ${PAGE} }
  }`,
  states: `query LAAPersonalStates($first: Int!, $after: String) {
    workflowStates(first: $first, after: $after) { nodes { id name type color position team { id } } ${PAGE} }
  }`,
  labels: `query LAAPersonalLabels($first: Int!, $after: String) {
    issueLabels(first: $first, after: $after) { nodes { id name color team { id } } ${PAGE} }
  }`,
  milestones: `query LAAPersonalMilestones($first: Int!, $after: String) {
    projectMilestones(first: $first, after: $after) { nodes { id name project { id } } ${PAGE} }
  }`,
  views: `query LAAPersonalViews($first: Int!, $after: String) {
    customViews(first: $first, after: $after) { nodes { id name modelName description } ${PAGE} }
  }`,
  inbox: `query LAAPersonalInbox($first: Int!, $after: String) {
    notifications(first: $first, after: $after) {
      nodes { id type createdAt updatedAt readAt archivedAt snoozedUntilAt
        ... on IssueNotification { actor { id name } issue { id identifier title } comment { id } }
      } ${PAGE}
    }
  }`,
});

function failure(code, message, options) { return new TaskSourceError(code, message, options); }
function text(value, name, { required = false, max = 200 } = {}) {
  if ((value === undefined || value === null || value === '') && !required) return null;
  if (typeof value !== 'string' || value.trim() === '' || value.length > max || /[\u0000-\u001f]/.test(value)) {
    throw failure('filter_invalid', `${name} is invalid`, { status: 400 });
  }
  return value.trim();
}
function pageSize(value) {
  const size = value === null || value === undefined || value === '' ? 50 : Number(value);
  if (!Number.isInteger(size) || size < 1 || size > 100) throw failure('filter_invalid', 'limit must be between 1 and 100', { status: 400 });
  return size;
}
function filterHash(value) { return createHash('sha256').update(JSON.stringify(value)).digest('hex').slice(0, 24); }
function decodeCursor(raw, filter) {
  if (!raw) return null;
  try {
    if (raw.length > 4000 || !/^[A-Za-z0-9_-]+$/.test(raw)) throw new Error();
    const cursor = JSON.parse(Buffer.from(raw, 'base64url').toString('utf8'));
    if (cursor.v !== 1 || cursor.f !== filterHash(filter) || typeof cursor.a !== 'string' || !cursor.a || cursor.a.length > 2000) throw new Error();
    return cursor.a;
  } catch { throw failure('cursor_invalid', 'cursor does not match this list', { status: 400 }); }
}
function makePage(connection, filter, map = (value) => value) {
  if (!connection || !Array.isArray(connection.nodes) || typeof connection.pageInfo?.hasNextPage !== 'boolean') {
    throw failure('linear_response_invalid', 'Linear returned an incomplete page');
  }
  const { hasNextPage, endCursor } = connection.pageInfo;
  if (hasNextPage && (typeof endCursor !== 'string' || !endCursor)) throw failure('linear_response_invalid', 'Linear returned an invalid cursor');
  return {
    items: connection.nodes.map(map),
    nextCursor: hasNextPage ? Buffer.from(JSON.stringify({ v: 1, f: filterHash(filter), a: endCursor })).toString('base64url') : null,
    paginationConsistency: 'live',
  };
}
function person(user, viewerId) {
  if (!user) return { kind: 'unassigned', id: null, name: null };
  return { id: user.id, name: user.name, kind: user.id === viewerId ? 'owner' : user.app === true ? 'agent' : 'person' };
}
function issueToTask(issue, viewerId) {
  if (!issue || typeof issue.id !== 'string' || typeof issue.identifier !== 'string' || typeof issue.title !== 'string') {
    throw failure('linear_response_invalid', 'Linear returned an incomplete issue');
  }
  const state = issue.state ?? {};
  return {
    id: `linear:${issue.identifier}`, source: 'linear', sourceId: issue.identifier, linearId: issue.id,
    title: issue.title,
    ...(Object.hasOwn(issue, 'description') ? { description: issue.description ?? '' } : {}),
    owner: person(issue.assignee, viewerId),
    executor: issue.delegate ? person(issue.delegate, viewerId) : null,
    status: { id: state.id ?? null, name: state.name ?? null, type: state.type ?? null,
      category: state.type === 'completed' ? 'done' : state.type === 'canceled' ? 'closed' : 'open' },
    team: issue.team ?? null, project: issue.project ?? null, milestone: issue.projectMilestone ?? null,
    cycle: issue.cycle ?? null, parent: issue.parent ?? null,
    priority: issue.priority ?? null, estimate: issue.estimate ?? null, dueDate: issue.dueDate ?? null,
    labels: (issue.labels?.nodes ?? []).map(({ id, name, color }) => ({ id, name, color })),
    labelsComplete: issue.labels?.pageInfo?.hasNextPage === false,
    url: issue.url ?? null, updatedAt: issue.updatedAt ?? null, version: issue.updatedAt ?? null,
  };
}

export function createPersonalLinearSource({
  endpoint = 'https://api.linear.app/graphql', fetchImpl = globalThis.fetch,
  expectedViewerId = process.env.LAA_LINEAR_PERSONAL_VIEWER_ID,
  tokenHelper = process.env.LAA_LINEAR_PERSONAL_TOKEN_HELPER,
  readToken = null, now = () => Date.now(),
} = {}) {
  const obtainToken = readToken ?? (() => {
    if (typeof tokenHelper !== 'string' || !isAbsolute(tokenHelper)) {
      throw failure('linear_personal_not_configured', 'the personal Linear credential is not configured');
    }
    return readTokenViaHelper(tokenHelper);
  });
  async function graph(token, document, variables = {}) {
    let response;
    try {
      response = await fetchImpl(endpoint, {
        method: 'POST', headers: { 'content-type': 'application/json', authorization: token },
        body: JSON.stringify({ query: document, variables }), signal: AbortSignal.timeout(20_000),
      });
    } catch { throw failure('linear_unavailable', 'Linear could not be reached', { retryable: true }); }
    if (!response.ok) {
      const status = response.status === 429 ? 429 : response.status === 401 || response.status === 403 ? 403 : 503;
      throw failure('linear_request_failed', 'Linear did not accept the request', { status, retryable: status === 429 || status === 503 });
    }
    let body;
    try { body = await response.json(); } catch { throw failure('linear_response_invalid', 'Linear returned an invalid response'); }
    if (!body || body.errors?.length || !body.data || typeof body.data !== 'object') {
      throw failure('linear_graphql_error', 'Linear could not complete the request');
    }
    return body.data;
  }
  async function session() {
    if (typeof expectedViewerId !== 'string' || expectedViewerId.trim() === '') {
      throw failure('linear_personal_not_configured', 'the expected personal Linear viewer is not configured');
    }
    const token = await obtainToken();
    if (typeof token !== 'string' || !token.startsWith('lin_api_')) {
      throw failure('linear_personal_credential_invalid', 'the personal Linear API key is invalid');
    }
    const data = await graph(token, PERSONAL_DOCUMENTS.viewer);
    if (data.viewer?.id !== expectedViewerId) {
      throw failure('linear_viewer_mismatch', 'the Linear credential does not belong to the expected viewer', { status: 403 });
    }
    return { viewer: data.viewer, run: (document, variables) => graph(token, document, variables) };
  }
  async function listTasks(options = {}) {
    const view = text(options.view, 'view') ?? 'all';
    if (!['all', 'mine', 'active', 'backlog'].includes(view)) throw failure('filter_invalid', 'view is invalid', { status: 400 });
    const term = text(options.search, 'search');
    const project = text(options.project, 'project');
    const cycle = text(options.cycle, 'cycle');
    const customView = text(options.customView, 'customView');
    if (customView && (view !== 'all' || term || project || cycle)) throw failure('filter_invalid', 'a saved view cannot be combined with another filter', { status: 400 });
    const listFilter = { view, term, project, cycle, customView };
    const first = pageSize(options.limit);
    const { viewer, run } = await session();
    const cursorFilter = { ...listFilter, viewerId: viewer.id };
    const after = decodeCursor(options.cursor, cursorFilter);
    const filter = {};
    if (view === 'mine') filter.assignee = { id: { eq: viewer.id } };
    if (view === 'active') filter.state = { type: { eq: 'started' } };
    if (view === 'backlog') filter.state = { type: { eq: 'backlog' } };
    if (project) filter.project = { id: { eq: project } };
    if (cycle) filter.cycle = { id: { eq: cycle } };
    const data = customView
      ? await run(PERSONAL_DOCUMENTS.view, { id: customView, first, after })
      : term ? await run(PERSONAL_DOCUMENTS.search, { first, after, filter, term })
        : await run(PERSONAL_DOCUMENTS.issues, { first, after, filter });
    if (customView && data.customView?.modelName !== 'Issue') throw failure('linear_view_not_issue', 'this saved view does not contain issues', { status: 400 });
    const connection = customView ? data.customView?.issues : term ? data.searchIssues : data.issues;
    return { ...makePage(connection, cursorFilter, (node) => issueToTask(node, viewer.id)), observedAt: new Date(now()).toISOString(), viewerId: viewer.id };
  }
  async function getTaskInSession(personalSession, id) {
    const issueId = text(id, 'id', { required: true });
    const { viewer, run } = personalSession;
    const data = await run(PERSONAL_DOCUMENTS.issue, { id: issueId.replace(/^linear:/, '') });
    if (!data.issue) return null;
    return { task: issueToTask(data.issue, viewer.id), viewerId: viewer.id };
  }
  async function getTask(id) { return getTaskInSession(await session(), id); }
  async function createIssue(personalSession, input) {
    const data = await personalSession.run(PERSONAL_DOCUMENTS.createIssue, { input });
    const result = data.issueCreate;
    if (result?.success !== true || typeof result.issue?.id !== 'string' || typeof result.issue?.identifier !== 'string') {
      throw failure('linear_mutation_unconfirmed', 'Linear did not confirm the issue creation');
    }
    return result.issue;
  }
  async function updateIssue(personalSession, id, input) {
    const data = await personalSession.run(PERSONAL_DOCUMENTS.updateIssue, { id: id.replace(/^linear:/, ''), input });
    const result = data.issueUpdate;
    if (result?.success !== true || typeof result.issue?.id !== 'string' || typeof result.issue?.identifier !== 'string') {
      throw failure('linear_mutation_unconfirmed', 'Linear did not confirm the issue update');
    }
    return result.issue;
  }
  async function listCollection(name, options = {}) {
    if (!['projects', 'cycles', 'views', 'inbox', 'teams', 'users', 'states', 'labels', 'milestones'].includes(name)) {
      throw failure('filter_invalid', 'collection is invalid', { status: 400 });
    }
    const filter = { collection: name };
    const first = pageSize(options.limit);
    const { viewer, run } = await session();
    const cursorFilter = { ...filter, viewerId: viewer.id };
    const after = decodeCursor(options.cursor, cursorFilter);
    const data = await run(PERSONAL_DOCUMENTS[name], { first, after });
    const field = { views: 'customViews', inbox: 'notifications', states: 'workflowStates', labels: 'issueLabels', milestones: 'projectMilestones' }[name] ?? name;
    const connection = data[field];
    return { ...makePage(connection, cursorFilter), observedAt: new Date(now()).toISOString(), viewerId: viewer.id };
  }
  async function metadata() {
    const { viewer, run } = await session();
    const data = await run(PERSONAL_DOCUMENTS.metadata);
    const result = { viewer: { id: viewer.id, name: viewer.name }, observedAt: new Date(now()).toISOString() };
    for (const name of ['teams', 'users', 'workflowStates', 'issueLabels', 'projects', 'projectMilestones', 'cycles']) {
      const connection = data[name];
      if (!connection || !Array.isArray(connection.nodes) || typeof connection.pageInfo?.hasNextPage !== 'boolean') {
        throw failure('linear_response_invalid', 'Linear returned incomplete choices');
      }
      result[name] = { items: connection.nodes, complete: !connection.pageInfo.hasNextPage };
    }
    if (!Array.isArray(data.issuePriorityValues)) throw failure('linear_response_invalid', 'Linear returned incomplete priorities');
    result.priorities = data.issuePriorityValues;
    return result;
  }
  return { listTasks, getTask, getTaskInSession, createIssue, updateIssue, listCollection, metadata, session };
}

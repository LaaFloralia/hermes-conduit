// Fixed Linear operations, bound to the authenticated actor. Agent mode uses
// the existing credential and a separate owner-scoped local activity inbox.
import { invalidateLinearLists } from './list-cache.mjs';
import { isAbsolute } from 'node:path';
import { createHash } from 'node:crypto';
import { authorizationHeader, readTokenViaHelper } from './linear.mjs';
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
const ACTIVITY_ISSUE_FIELDS = `id identifier title updatedAt description assignee { id } creator { id }
  subscribers(first: 1, filter: $subscriberFilter) { nodes { id } ${PAGE} }`;
const NOTIFICATION_FIELDS = `id type title subtitle createdAt updatedAt readAt archivedAt snoozedUntilAt
  user { id } actor { id name }
  ... on IssueNotification { issue { id identifier title } comment { id } }`;
const NOTIFICATION_STATUS = 'id readAt archivedAt user { id }';
const PRIVATE_FILE_LIMIT = 20 * 1024 * 1024;
const COMMENT_FIELDS = `id body issueId parentId createdAt updatedAt url user { id name app }`;
const RELATION_FIELDS = `id type issue { id identifier title } relatedIssue { id identifier title }`;
const SECTION_FIELDS = Object.freeze({
  comments: COMMENT_FIELDS,
  children: ISSUE_FIELDS,
  history: `id createdAt actor { id name app } fromState { id name } toState { id name }
    fromAssignee { id name app } toAssignee { id name app } fromPriority toPriority
    fromTitle toTitle updatedDescription
    fromDelegate { id name } toDelegate { id name }
    fromCycle { id name } toCycle { id name }
    fromProject { id name } toProject { id name }
    fromProjectMilestone { id name } toProjectMilestone { id name }
    fromTeam { id name } toTeam { id name }
    fromParent { id identifier title } toParent { id identifier title }
    fromEstimate toEstimate fromDueDate toDueDate
    addedLabels { id name } removedLabels { id name }
    addedToReleases { id name } removedFromReleases { id name }
    relationChanges { identifier type }
    archived autoArchived autoClosed trashed
    fromSlaType toSlaType fromSlaBreached toSlaBreached fromSlaBreachesAt toSlaBreachesAt
    attachment { id title } toConvertedProject { id name } issueImport { id displayName }
    customerNeedId triageResponsibilityAutoAssigned`,
  relations: RELATION_FIELDS,
  inverseRelations: RELATION_FIELDS,
  attachments: `id title subtitle url sourceType createdAt`,
});

// Documents are fixed here, never supplied by a device. They are exported so
// tests can validate them against the public Linear schema, without credentials.
export const PERSONAL_DOCUMENTS = Object.freeze({
  viewer: 'query LAAPersonalViewer { viewer { id name app } }',
  ownerProfile: 'query LAAOwnerProfile($id: String!) { user(id: $id) { id name displayName avatarUrl url } }',
  activity: `query LAAOwnerActivity($first: Int!, $after: String, $filter: IssueFilter, $subscriberFilter: UserFilter) {
    issues(first: $first, after: $after, filter: $filter) { nodes { ${ACTIVITY_ISSUE_FIELDS}
      parent { id identifier title assignee { id } creator { id } subscribers(first: 1, filter: $subscriberFilter) { nodes { id } } }
    } ${PAGE} }
  }`,
  activityComments: `query LAAOwnerCommentActivity($first: Int!, $after: String, $filter: CommentFilter, $subscriberFilter: UserFilter) {
    comments(first: $first, after: $after, filter: $filter) { nodes { ${COMMENT_FIELDS}
      issue { ${ACTIVITY_ISSUE_FIELDS} }
    } ${PAGE} }
  }`,
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
  ...Object.fromEntries(Object.entries(SECTION_FIELDS).map(([name, fields]) => [name,
    `query LAAPersonalSection_${name}($id: String!, $first: Int!, $after: String) {
      issue(id: $id) { id ${name}(first: $first, after: $after) { nodes { ${fields} } ${PAGE} } }
    }`])),
  commentReplies: `query LAAPersonalCommentReplies($id: String!, $first: Int!, $after: String) {
    comment(id: $id) { id issueId children(first: $first, after: $after) { nodes { ${COMMENT_FIELDS} } ${PAGE} } }
  }`,
  commentParent: `query LAAPersonalCommentParent($id: String!) { comment(id: $id) { id issueId } }`,
  commentFileSource: `query LAAPersonalCommentFileSource($id: String!) { comment(id: $id) { id issueId body } }`,
  attachmentFileSource: `query LAAPersonalAttachmentFileSource($id: String!) { attachment(id: $id) { id title url issue { id } } }`,
  fileUpload: `mutation LAAPersonalFileUpload($contentType: String!, $filename: String!, $size: Int!) {
    fileUpload(contentType: $contentType, filename: $filename, size: $size, makePublic: false) {
      success uploadFile { assetUrl uploadUrl headers { key value } }
    }
  }`,
  deleteUpload: `mutation LAAPersonalDeleteUpload($assetUrl: String!) {
    fileUploadDangerouslyDelete(assetUrl: $assetUrl) { success }
  }`,
  createComment: `mutation LAAPersonalCommentCreate($input: CommentCreateInput!) {
    commentCreate(input: $input) { success comment { id } }
  }`,
  createRelation: `mutation LAAPersonalRelationCreate($input: IssueRelationCreateInput!) {
    issueRelationCreate(input: $input) { success issueRelation { id } }
  }`,
  createAttachment: `mutation LAAPersonalAttachmentCreate($input: AttachmentCreateInput!) {
    attachmentCreate(input: $input) { success attachment { id } }
  }`,
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
  inbox: `query LAAPersonalInbox($first: Int!, $after: String, $includeArchived: Boolean!) {
    notifications(first: $first, after: $after, includeArchived: $includeArchived) {
      nodes { ${NOTIFICATION_FIELDS} } ${PAGE}
    }
  }`,
  notification: `query LAAPersonalNotification($id: String!) { notification(id: $id) { ${NOTIFICATION_FIELDS} } }`,
  updateNotification: `mutation LAAPersonalNotificationUpdate($id: String!, $input: NotificationUpdateInput!) {
    notificationUpdate(id: $id, input: $input) { success notification { ${NOTIFICATION_STATUS} } }
  }`,
  archiveNotification: `mutation LAAPersonalNotificationArchive($id: String!) {
    notificationArchive(id: $id) { success entity { ${NOTIFICATION_STATUS} } }
  }`,
  unarchiveNotification: `mutation LAAPersonalNotificationUnarchive($id: String!) {
    notificationUnarchive(id: $id) { success entity { ${NOTIFICATION_STATUS} } }
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
function notificationStatusValid(value) {
  return value && typeof value.id === 'string' && typeof value.user?.id === 'string'
    && Object.hasOwn(value, 'readAt') && (value.readAt === null || typeof value.readAt === 'string')
    && Object.hasOwn(value, 'archivedAt') && (value.archivedAt === null || typeof value.archivedAt === 'string');
}
function checkedNotification(value, viewerId) {
  if (value === null) throw failure('notification_not_found', 'the notification was not found', { status: 404 });
  if (!notificationStatusValid(value) || typeof value.type !== 'string'
      || typeof value.createdAt !== 'string' || typeof value.updatedAt !== 'string') {
    throw failure('linear_response_invalid', 'Linear returned an incomplete notification');
  }
  if (value.user.id !== viewerId) throw failure('notification_not_found', 'the notification was not found', { status: 404 });
  return value;
}

// A phone supplies only a digest, never a URL. Each fetch re-reads the
// associated issue/comment/attachment and matches the digest against it.
function privateFileURL(value) {
  try {
    if (typeof value !== 'string' || value.length > 4096) return null;
    const url = new URL(value);
    if (url.protocol !== 'https:' || url.hostname !== 'uploads.linear.app' ||
        url.port || url.username || url.password || url.hash) return null;
    return url;
  } catch { return null; }
}
function uploadURL(value) {
  try {
    const url = new URL(value);
    if (url.protocol !== 'https:' || url.port || url.username || url.password || url.hash ||
        !(url.hostname === 'storage.googleapis.com' || url.hostname.endsWith('.storage.googleapis.com'))) return null;
    return url;
  } catch { return null; }
}
function fileId(url) { return createHash('sha256').update(url.href).digest('hex'); }
function fileName(url) {
  let name;
  try { name = decodeURIComponent(url.pathname.split('/').pop() || 'file'); } catch { name = 'file'; }
  name = name.replace(/[\/\\\x00-\x1f\x7f:]/g, '_').slice(0, 160);
  return name && name !== '.' && name !== '..' ? name : 'file';
}
function markdownFiles(markdown) {
  const found = new Map();
  for (const match of (markdown ?? '').matchAll(/https:\/\/uploads\.linear\.app\/[^\s<>"'\)\]\}]+/gi)) {
    const url = privateFileURL(match[0]);
    if (url) found.set(fileId(url), { id: fileId(url), name: fileName(url), url });
  }
  return [...found.values()];
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
  agentAccount = false, ownerUserId = process.env.LAA_BRIDGE_LINEAR_OWNER_ID ?? 'd1f71177-5355-4f4f-b42c-7894c0870112',
} = {}) {
  const obtainToken = readToken ?? (() => {
    if (typeof tokenHelper !== 'string' || !isAbsolute(tokenHelper)) {
      throw failure('linear_personal_not_configured', 'the personal Linear credential is not configured');
    }
    return readTokenViaHelper(tokenHelper);
  });
  const mutationRoots = new Map([
    [PERSONAL_DOCUMENTS.createIssue, 'issueCreate'], [PERSONAL_DOCUMENTS.updateIssue, 'issueUpdate'],
    [PERSONAL_DOCUMENTS.createComment, 'commentCreate'], [PERSONAL_DOCUMENTS.createRelation, 'issueRelationCreate'],
    [PERSONAL_DOCUMENTS.createAttachment, 'attachmentCreate'],
    [PERSONAL_DOCUMENTS.updateNotification, 'notificationUpdate'],
    [PERSONAL_DOCUMENTS.archiveNotification, 'notificationArchive'],
    [PERSONAL_DOCUMENTS.unarchiveNotification, 'notificationUnarchive'],
  ]);
  const nullableRoots = new Map([[PERSONAL_DOCUMENTS.issue, 'issue'], [PERSONAL_DOCUMENTS.notification, 'notification']]);
  function inputRejected(document, body) {
    const root = mutationRoots.get(document);
    if (!root || !Array.isArray(body?.errors) || !body.errors.length) return false;
    const inputError = body.errors.every((error) => error?.extensions?.userError === true
      && error?.extensions?.code === 'INPUT_ERROR'
      && (!error.path || (Array.isArray(error.path) && error.path.length === 1 && error.path[0] === root)));
    return inputError && (body.data == null || (typeof body.data === 'object'
      && Object.keys(body.data).every((key) => key === root) && body.data[root] == null));
  }
  async function graph(token, document, variables = {}) {
    const write = document.trimStart().startsWith('mutation');
    if (write) invalidateLinearLists();
    try { return await graphUncached(token, document, variables); }
    finally { if (write) invalidateLinearLists(); }
  }
  async function graphUncached(token, document, variables = {}) {
    let response;
    try {
      response = await fetchImpl(endpoint, {
        method: 'POST', headers: { 'content-type': 'application/json', authorization: authorizationHeader(token) },
        body: JSON.stringify({ query: document, variables }), signal: AbortSignal.timeout(20_000),
      });
    } catch { throw failure('linear_unavailable', 'Linear could not be reached', { retryable: true }); }
    if (!response.ok) {
      if (response.status === 400) {
        let rejection;
        try { rejection = await response.json(); } catch { /* an opaque 400 is not proof of a no-write */ }
        if (inputRejected(document, rejection)) throw failure('linear_rejected', 'Linear refused the submitted input', { status: 400 });
      }
      const status = response.status === 429 ? 429 : response.status === 401 || response.status === 403 ? 403 : 503;
      throw failure('linear_request_failed', 'Linear did not accept the request', { status, retryable: status === 429 || status === 503 });
    }
    let body;
    try { body = await response.json(); } catch { throw failure('linear_response_invalid', 'Linear returned an invalid response'); }
    if (body?.errors?.length) {
      // Only a root-level input rejection with no returned mutation payload is
      // definite. Nested/partial errors could follow a successful write.
      if (inputRejected(document, body)) {
        throw failure('linear_rejected', 'Linear refused the submitted input', { status: 400 });
      }
      const nullableRoot = nullableRoots.get(document);
      if (nullableRoot && body.data && Object.hasOwn(body.data, nullableRoot) && body.data[nullableRoot] === null
          && body.errors.every((error) => Array.isArray(error?.path) && error.path.length === 1 && error.path[0] === nullableRoot
            && error?.extensions?.userError === true && error?.extensions?.code === 'INPUT_ERROR')) {
        return { [nullableRoot]: null };
      }
    }
    if (!body || body.errors?.length || !body.data || typeof body.data !== 'object') {
      throw failure('linear_graphql_error', 'Linear could not complete the request');
    }
    return body.data;
  }
  async function session() {
    if (!agentAccount && (typeof expectedViewerId !== 'string' || expectedViewerId.trim() === '')) {
      throw failure('linear_personal_not_configured', 'the expected personal Linear viewer is not configured');
    }
    const token = await obtainToken();
    if (typeof token !== 'string' || (!agentAccount && !token.startsWith('lin_api_'))) {
      throw failure('linear_personal_credential_invalid', 'the personal Linear API key is invalid');
    }
    const data = await graph(token, PERSONAL_DOCUMENTS.viewer);
    if (typeof data.viewer?.id !== 'string' || (!agentAccount && data.viewer.id !== expectedViewerId)) {
      throw failure('linear_viewer_mismatch', 'the Linear credential does not belong to the expected viewer', { status: 403 });
    }
    return {
      viewer: data.viewer, run: (document, variables) => graph(token, document, variables),
      async readPrivateFile(value) {
        const url = privateFileURL(value);
        if (!url) throw failure('file_not_found', 'the private file was not found', { status: 404 });
        let response;
        try {
          response = await fetchImpl(url.href, { headers: { authorization: authorizationHeader(token) },
            redirect: 'manual', signal: AbortSignal.timeout(60_000) });
        } catch { throw failure('linear_unavailable', 'the private file could not be reached', { retryable: true }); }
        if (response.status !== 200 || !response.body) {
          if (response.body) await response.body.cancel().catch(() => {});
          throw failure('linear_file_unavailable', 'Linear did not return the private file', { status: 503 });
        }
        const declared = response.headers.get('content-length');
        if (declared && (!/^\d+$/.test(declared) || Number(declared) > PRIVATE_FILE_LIMIT)) {
          await response.body.cancel().catch(() => {});
          throw failure('file_too_large', 'the file exceeds the 20 MiB limit', { status: 413 });
        }
        const chunks = []; let size = 0;
        try {
          for await (const chunk of response.body) {
            size += chunk.length;
            if (size > PRIVATE_FILE_LIMIT) throw failure('file_too_large', 'the file exceeds the 20 MiB limit', { status: 413 });
            chunks.push(Buffer.from(chunk));
          }
        } catch (error) {
          if (error instanceof TaskSourceError) throw error;
          throw failure('linear_file_unavailable', 'the private file could not be read', { status: 503 });
        }
        return { name: fileName(url), content: Buffer.concat(chunks).toString('base64'), size };
      },
    };
  }
  async function ownerProfile(personalSession) {
    const value = (await personalSession.run(PERSONAL_DOCUMENTS.ownerProfile, { id: ownerUserId })).user;
    if (value?.id !== ownerUserId || typeof value.url !== 'string') throw failure('linear_response_invalid', 'owner profile is incomplete');
    return value;
  }
  async function listActivityCandidates(personalSession, { since, after = null, owner, watched = [] } = {}) {
    const mentions = [ownerUserId, owner.url].filter(Boolean);
    const related = [...(watched.length ? [{ id: { in: watched } }] : []), { assignee: { id: { eq: ownerUserId } } }, { creator: { id: { eq: ownerUserId } } },
      { subscribers: { some: { id: { eq: ownerUserId } } } },
      ...mentions.flatMap((term) => [{ description: { contains: term } }, { comments: { some: { body: { contains: term } } } }])];
    const data = await personalSession.run(PERSONAL_DOCUMENTS.activity,
      { first: 100, after, filter: { updatedAt: { gte: since }, or: [...related, { parent: { or: [{ assignee: { id: { eq: ownerUserId } } }, { creator: { id: { eq: ownerUserId } } }, { subscribers: { some: { id: { eq: ownerUserId } } } }, ...(watched.length ? [{ id: { in: watched } }] : [])] } }] }, subscriberFilter: { id: { eq: ownerUserId } } });
    if (!Array.isArray(data.issues?.nodes) || typeof data.issues.pageInfo?.hasNextPage !== 'boolean') throw failure('linear_response_invalid', 'activity is incomplete');
    return data.issues;
  }
  async function listCommentActivityCandidates(personalSession, { since, after = null, owner, watched = [] } = {}) {
    const mentions = [ownerUserId, owner.url].filter(Boolean);
    const related = [{ assignee: { id: { eq: ownerUserId } } }, { creator: { id: { eq: ownerUserId } } },
      { subscribers: { some: { id: { eq: ownerUserId } } } }, ...(watched.length ? [{ id: { in: watched } }] : [])];
    const data = await personalSession.run(PERSONAL_DOCUMENTS.activityComments, { first: 100, after,
      filter: { updatedAt: { gte: since }, or: [{ issue: { or: related } }, ...mentions.map((term) => ({ body: { contains: term } }))] },
      subscriberFilter: { id: { eq: ownerUserId } } });
    if (!Array.isArray(data.comments?.nodes) || typeof data.comments.pageInfo?.hasNextPage !== 'boolean') throw failure('linear_response_invalid', 'comment activity is incomplete');
    return data.comments;
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
    if (view === 'mine') filter.assignee = { id: { eq: agentAccount ? ownerUserId : viewer.id } };
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
  async function prepareActor(personalSession) {
    if (!agentAccount || personalSession.viewer.app !== true || personalSession.attributionOwner) return;
    const owner = (await personalSession.run(PERSONAL_DOCUMENTS.ownerProfile, { id: ownerUserId })).user;
    if (owner?.id !== ownerUserId || !owner.name) throw failure('linear_response_invalid', 'the owner profile could not be verified');
    personalSession.attributionOwner = owner;
  }
  async function attributedInput(personalSession, input, kind) {
    if (!agentAccount) return input;
    if (personalSession.viewer.app === true) {
      await prepareActor(personalSession);
      const owner = personalSession.attributionOwner;
      return { ...input, createAsUser: owner.name, ...(owner.avatarUrl ? { displayIconUrl: owner.avatarUrl } : {}) };
    }
    if (kind === 'comment') return { ...input, body: input.body + '\n\n— LAAアプリから' };
    return { ...input, description: (input.description || '') + '\n\n— LAAアプリから' };
  }
  async function createIssue(personalSession, input) {
    input = await attributedInput(personalSession, input, 'issue');
    const data = await personalSession.run(PERSONAL_DOCUMENTS.createIssue, { input });
    const result = data.issueCreate;
    if (result?.success === false && result.issue == null) throw failure('linear_rejected', 'Linear refused the submitted input', { status: 400 });
    if (result?.success !== true || typeof result.issue?.id !== 'string' || typeof result.issue?.identifier !== 'string') {
      throw failure('linear_mutation_unconfirmed', 'Linear did not confirm the issue creation');
    }
    return result.issue;
  }
  async function updateIssue(personalSession, id, input) {
    const data = await personalSession.run(PERSONAL_DOCUMENTS.updateIssue, { id: id.replace(/^linear:/, ''), input });
    const result = data.issueUpdate;
    if (result?.success === false && result.issue == null) throw failure('linear_rejected', 'Linear refused the submitted input', { status: 400 });
    if (result?.success !== true || typeof result.issue?.id !== 'string' || typeof result.issue?.identifier !== 'string') {
      throw failure('linear_mutation_unconfirmed', 'Linear did not confirm the issue update');
    }
    return result.issue;
  }
  async function listTaskSection(name, id, options = {}) {
    if (!Object.hasOwn(SECTION_FIELDS, name) && name !== 'commentReplies') {
      throw failure('filter_invalid', 'task section is invalid', { status: 400 });
    }
    const issueId = text(id, 'id', { required: true }).replace(/^linear:/, '');
    const commentId = name === 'commentReplies' ? text(options.commentId, 'commentId', { required: true }) : null;
    const first = pageSize(options.limit);
    const personalSession = options.personalSession ?? await session();
    const { viewer, run } = personalSession;
    const cursorFilter = { section: name, issueId, commentId, viewerId: viewer.id };
    const after = decodeCursor(options.cursor, cursorFilter);
    let connection;
    if (name === 'commentReplies') {
      const issue = await getTaskInSession(personalSession, issueId);
      if (!issue) throw failure('task_not_found', 'the task was not found', { status: 404 });
      const data = await run(PERSONAL_DOCUMENTS.commentReplies, { id: commentId, first, after });
      if (!data.comment || data.comment.issueId !== issue.task.linearId) {
        throw failure('comment_not_found', 'the comment was not found for this task', { status: 404 });
      }
      connection = data.comment.children;
    } else {
      const data = await run(PERSONAL_DOCUMENTS[name], { id: issueId, first, after });
      if (!data.issue) throw failure('task_not_found', 'the task was not found', { status: 404 });
      connection = data.issue[name];
    }
    const map = name === 'children' ? (node) => issueToTask(node, viewer.id) : (node) => node;
    return { ...makePage(connection, cursorFilter, map), observedAt: new Date(now()).toISOString(), viewerId: viewer.id };
  }
  async function assertCommentInIssue(personalSession, commentId, issueId) {
    const data = await personalSession.run(PERSONAL_DOCUMENTS.commentParent, { id: commentId });
    if (!data.comment || data.comment.issueId !== issueId) {
      throw failure('comment_not_found', 'the comment was not found for this task', { status: 404 });
    }
  }
  async function fileSource(personalSession, id, commentId) {
    const issue = await getTaskInSession(personalSession, id);
    if (!issue) throw failure('task_not_found', 'the task was not found', { status: 404 });
    if (!commentId) return markdownFiles(issue.task.description);
    const data = await personalSession.run(PERSONAL_DOCUMENTS.commentFileSource, { id: commentId });
    if (!data.comment || data.comment.issueId !== issue.task.linearId) {
      throw failure('comment_not_found', 'the comment was not found for this task', { status: 404 });
    }
    return markdownFiles(data.comment.body);
  }
  async function listFiles(id, commentId) {
    const personalSession = await session();
    const files = await fileSource(personalSession, id, commentId);
    return { viewerId: personalSession.viewer.id, items: files.map(({ id: fileIdValue, name }) => ({ id: fileIdValue, name })) };
  }
  async function readFile(id, { commentId, assetId, attachmentId }) {
    const personalSession = await session();
    let url, title;
    if (attachmentId) {
      const issue = await getTaskInSession(personalSession, id);
      if (!issue) throw failure('task_not_found', 'the task was not found', { status: 404 });
      const data = await personalSession.run(PERSONAL_DOCUMENTS.attachmentFileSource, { id: attachmentId });
      if (data.attachment?.issue?.id === issue.task.linearId) {
        url = privateFileURL(data.attachment.url);
        title = data.attachment.title;
      }
    } else {
      const files = await fileSource(personalSession, id, commentId);
      url = files.find((file) => file.id === assetId)?.url;
    }
    if (!url) throw failure('file_not_found', 'the private file was not found for this task', { status: 404 });
    const result = await personalSession.readPrivateFile(url.href);
    if (typeof title === 'string' && title.length > 0) {
      const safeTitle = title.replace(/[\/\\\x00-\x1f\x7f:]/g, '_').slice(0, 160);
      if (safeTitle && safeTitle !== '.' && safeTitle !== '..') result.name = safeTitle;
    }
    return { ...result, viewerId: personalSession.viewer.id };
  }
  async function deleteUpload(personalSession, assetUrl) {
    if (!privateFileURL(assetUrl)) throw failure('linear_response_invalid', 'the uploaded asset URL is invalid');
    const data = await personalSession.run(PERSONAL_DOCUMENTS.deleteUpload, { assetUrl });
    if (data.fileUploadDangerouslyDelete?.success !== true) throw failure('linear_mutation_unconfirmed', 'Linear did not confirm asset cleanup');
  }
  async function uploadFile(personalSession, { filename, contentType, bytes }) {
    const data = await personalSession.run(PERSONAL_DOCUMENTS.fileUpload, { filename, contentType, size: bytes.length });
    const payload = data.fileUpload;
    const file = payload?.uploadFile;
    const target = uploadURL(file?.uploadUrl);
    const asset = privateFileURL(file?.assetUrl);
    if (payload?.success !== true || !target || !asset || !Array.isArray(file?.headers) || file.headers.length > 30) {
      throw failure('linear_upload_invalid', 'Linear did not return a supported upload target');
    }
    const headers = { 'content-type': contentType };
    for (const header of file.headers) {
      const key = typeof header?.key === 'string' ? header.key.toLowerCase() : '';
      if (!/^(?:x-goog-[a-z0-9-]+|content-type|cache-control)$/.test(key) ||
          typeof header.value !== 'string' || header.value.length > 8192 || /[\r\n]/.test(header.value)) {
        throw failure('linear_upload_invalid', 'Linear returned unsupported upload headers');
      }
      headers[key] = header.value;
    }
    let response;
    try {
      response = await fetchImpl(target.href, { method: 'PUT', headers, body: bytes,
        redirect: 'manual', signal: AbortSignal.timeout(120_000) });
    } catch { throw failure('linear_upload_failed', 'the file upload could not be completed', { retryable: true }); }
    if (!response.ok) throw failure('linear_upload_failed', 'Linear storage did not accept the file');
    return asset.href;
  }
  async function createTaskItem(personalSession, kind, input) {
    if (kind === 'comment') input = await attributedInput(personalSession, input, kind);
    const mapping = {
      comment: ['createComment', 'commentCreate', 'comment'],
      relation: ['createRelation', 'issueRelationCreate', 'issueRelation'],
      attachment: ['createAttachment', 'attachmentCreate', 'attachment'],
    };
    const [document, field, resultName] = mapping[kind] ?? [];
    if (!document) throw failure('filter_invalid', 'task item is invalid', { status: 400 });
    const data = await personalSession.run(PERSONAL_DOCUMENTS[document], { input });
    const result = data[field];
    if (result?.success === false && result[resultName] == null) throw failure('linear_rejected', 'Linear refused the submitted input', { status: 400 });
    if (result?.success !== true || typeof result[resultName]?.id !== 'string') {
      throw failure('linear_mutation_unconfirmed', 'Linear did not confirm the task operation');
    }
    return result[resultName];
  }
  async function listCollection(name, options = {}) {
    if (agentAccount && name === 'inbox') throw failure('linear_owner_inbox_unavailable', 'owner inbox requires owner authorization', { status: 403 });
    if (!['projects', 'cycles', 'views', 'inbox', 'teams', 'users', 'states', 'labels', 'milestones'].includes(name)) {
      throw failure('filter_invalid', 'collection is invalid', { status: 400 });
    }
    if (name === 'inbox' && options.includeArchived != null && !['true', 'false'].includes(options.includeArchived)) {
      throw failure('filter_invalid', 'includeArchived must be true or false', { status: 400 });
    }
    const includeArchived = name === 'inbox' && options.includeArchived === 'true';
    const filter = { collection: name, ...(name === 'inbox' ? { includeArchived } : {}) };
    const first = pageSize(options.limit);
    const { viewer, run } = await session();
    const cursorFilter = { ...filter, viewerId: viewer.id };
    const after = decodeCursor(options.cursor, cursorFilter);
    const data = await run(PERSONAL_DOCUMENTS[name], { first, after, ...(name === 'inbox' ? { includeArchived } : {}) });
    const field = { views: 'customViews', inbox: 'notifications', states: 'workflowStates', labels: 'issueLabels', milestones: 'projectMilestones' }[name] ?? name;
    const connection = data[field];
    return { ...makePage(connection, cursorFilter, name === 'inbox' ? (value) => checkedNotification(value, viewer.id) : undefined),
      observedAt: new Date(now()).toISOString(), viewerId: viewer.id };
  }
  async function getNotificationInSession(personalSession, id) {
    if (agentAccount) throw failure('linear_owner_inbox_unavailable', 'owner inbox requires owner authorization', { status: 403 });
    const data = await personalSession.run(PERSONAL_DOCUMENTS.notification, { id });
    const item = checkedNotification(data.notification, personalSession.viewer.id);
    if (item.id !== id) throw failure('notification_not_found', 'the notification was not found', { status: 404 });
    return item;
  }
  async function getNotification(id) {
    if (agentAccount) throw failure('linear_owner_inbox_unavailable', 'owner inbox requires owner authorization', { status: 403 });
    const personalSession = await session();
    return { notification: await getNotificationInSession(personalSession, id), viewerId: personalSession.viewer.id,
      observedAt: new Date(now()).toISOString() };
  }
  async function updateNotification(personalSession, id, action) {
    if (!['read', 'unread', 'archive', 'unarchive'].includes(action)) {
      throw failure('filter_invalid', 'the notification action is invalid', { status: 400 });
    }
    let document, root, resultName, variables;
    if (action === 'read' || action === 'unread') {
      document = PERSONAL_DOCUMENTS.updateNotification; root = 'notificationUpdate'; resultName = 'notification';
      variables = { id, input: { readAt: action === 'read' ? new Date(now()).toISOString() : null } };
    } else {
      document = action === 'archive' ? PERSONAL_DOCUMENTS.archiveNotification : PERSONAL_DOCUMENTS.unarchiveNotification;
      root = action === 'archive' ? 'notificationArchive' : 'notificationUnarchive'; resultName = 'entity'; variables = { id };
    }
    const result = (await personalSession.run(document, variables))[root];
    if (result?.success === false && result[resultName] == null) {
      throw failure('linear_rejected', 'Linear refused the submitted input', { status: 400 });
    }
    const value = result?.[resultName];
    if (result?.success !== true || !notificationStatusValid(value) || value.id !== id
        || value.user.id !== personalSession.viewer.id
        || (action === 'read' && value.readAt === null) || (action === 'unread' && value.readAt !== null)
        || (action === 'archive' && value.archivedAt === null) || (action === 'unarchive' && value.archivedAt !== null)) {
      throw failure('linear_mutation_unconfirmed', 'Linear did not confirm the notification state');
    }
    return { id: value.id };
  }
  async function metadata() {
    const { viewer, run } = await session();
    const data = await run(PERSONAL_DOCUMENTS.metadata);
    const result = { ownerUserId: agentAccount ? ownerUserId : viewer.id, agentAccount, viewer: { id: viewer.id, name: viewer.name }, observedAt: new Date(now()).toISOString() };
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
  return { agentAccount, ownerUserId, ownerProfile, listActivityCandidates, listCommentActivityCandidates, prepareActor, ownerInboxAvailable: !agentAccount, listTasks, getTask, getTaskInSession, createIssue, updateIssue, listTaskSection, listFiles, readFile, uploadFile, deleteUpload,
    assertCommentInIssue, createTaskItem, listCollection, getNotification, getNotificationInSession, updateNotification, metadata, session };
}

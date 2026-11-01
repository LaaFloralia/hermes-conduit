// One-off import of the owner's Linear tasks into the owner-task store.
//
// Read-only by construction: the module has no mutation document, every request
// goes through `assertReadOnlyDocument`, and a test asserts that no request body
// contains "mutation". The existing agent credential wrapper is read at run time
// and never cached to disk, logged or returned.
//
// A dry-run writes a manifest and nothing else. The approved manifest is
// re-checked against Linear immediately before it is applied, and the whole
// import commits in a single store transaction.

import { BridgeError } from '../errors.mjs';
import { TaskSourceError } from './errors.mjs';
import { assertReadOnlyDocument, authorizationHeader, readTokenViaHelper } from './linear.mjs';
import { canonicalJson, sha256Hex, uuidv5 } from './stable.mjs';
import { MAX_MEMO, MAX_TITLE, STATUSES, validateDueDate } from './owner-service.mjs';

export const IMPORT_FORMAT = 'laa-owner-tasks-import';
export const IMPORT_VERSION = 1;
export const IMPORT_PAGE_SIZE = 50;
export const IMPORT_MAX_PAGES = 100;
export const TASK_ID_NAMESPACE = 'laa-owner-task.v1|';

const DEFAULT_ENDPOINT = 'https://api.linear.app/graphql';
const DEFAULT_TOKEN_HELPER = '/Users/laa/.config/laa/linear-agent-token.sh';

const IMPORT_FIELDS = `
  id
  identifier
  title
  description
  url
  updatedAt
  dueDate
  state { name type }
  assignee { id name }
  team { id key name }
  project { id name }
  labels(first: 1) { nodes { id } }
  comments(first: 1) { nodes { id } }
  attachments(first: 1) { nodes { id } }
`;

function importQuery({ includeClosed }) {
  const state = includeClosed ? '' : ', state: { type: { nin: ["completed", "canceled"] } }';
  return `query LAAOwnerTaskImport($assigneeId: ID!, $after: String) {
  issues(first: ${IMPORT_PAGE_SIZE}, after: $after, includeArchived: false, filter: { assignee: { id: { eq: $assigneeId } }${state} }) {
    nodes { ${IMPORT_FIELDS} }
    pageInfo { hasNextPage endCursor }
  }
}`;
}

// Exported so a test can prove every document is a query.
export const IMPORT_DOCUMENTS = Object.freeze({
  open: importQuery({ includeClosed: false }),
  all: importQuery({ includeClosed: true }),
});

const STATE_TO_STATUS = Object.freeze({
  backlog: 'todo',
  unstarted: 'todo',
  started: 'doing',
  completed: 'done',
  canceled: 'canceled',
});

function failure(code, message, { status = 503, retryable = false } = {}) {
  return new TaskSourceError(code, message, { status, retryable });
}

function checkAssigneeId(value) {
  if (typeof value !== 'string' || value.trim() === '' || value.length > 100
    // eslint-disable-next-line no-control-regex
    || /[\u0000-\u001f\u007f]/.test(value)) {
    throw new BridgeError(400, 'field_invalid', 'assignee must be a Linear user id', { details: { field: 'assignee' } });
  }
  return value.trim();
}

export function createLinearImporter({
  endpoint = process.env.LAA_BRIDGE_LINEAR_ENDPOINT ?? DEFAULT_ENDPOINT,
  tokenHelper = process.env.LAA_BRIDGE_LINEAR_TOKEN_HELPER ?? DEFAULT_TOKEN_HELPER,
  fetchImpl = globalThis.fetch,
  readToken = () => readTokenViaHelper(tokenHelper),
  timeoutMs = 20_000,
  maxPages = IMPORT_MAX_PAGES,
} = {}) {
  let cached = null;

  async function token() {
    if (cached === null) cached = await readToken();
    return cached;
  }

  async function post(document, variables) {
    assertReadOnlyDocument(document);
    // The credential is read before the network try/catch: a missing helper is a
    // credential problem, not an unreachable Linear.
    const authorization = authorizationHeader(await token());
    let response;
    try {
      response = await fetchImpl(endpoint, {
        method: 'POST',
        headers: {
          authorization,
          'content-type': 'application/json',
          accept: 'application/json',
        },
        body: JSON.stringify({ query: document, variables }),
        signal: AbortSignal.timeout(timeoutMs),
      });
    } catch {
      throw failure('linear_unreachable', 'Linear could not be reached', { retryable: true });
    }
    if (response.status === 401 || response.status === 403) {
      throw failure('linear_unauthorized', 'Linear rejected the stored credential', { status: 403 });
    }
    if (!response.ok) {
      throw failure('linear_unavailable', `Linear responded with HTTP ${response.status}`, {
        retryable: response.status === 429 || response.status >= 500,
      });
    }
    let payload;
    try {
      payload = await response.json();
    } catch {
      throw failure('linear_response_invalid', 'Linear returned a response that is not JSON', { retryable: true });
    }
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
      throw failure('linear_response_invalid', 'Linear returned an unexpected response body');
    }
    // GraphQL error text can echo the query or its values; only the fact of a
    // rejection is surfaced.
    if (Array.isArray(payload.errors) && payload.errors.length > 0) {
      throw failure('linear_request_rejected', 'Linear rejected the read query');
    }
    if (!payload.data || typeof payload.data !== 'object' || Array.isArray(payload.data)) {
      throw failure('linear_response_invalid', 'Linear returned no data object');
    }
    return payload.data;
  }

  async function fetchAll({ assignee, includeClosed = false } = {}) {
    const assigneeId = checkAssigneeId(assignee);
    const document = includeClosed ? IMPORT_DOCUMENTS.all : IMPORT_DOCUMENTS.open;
    const issues = [];
    const seenCursors = new Set();
    let after = null;
    for (let page = 0; ; page += 1) {
      if (page >= maxPages) {
        throw failure('linear_page_limit', `Linear returned more than ${maxPages} pages; refusing a partial import`);
      }
      const data = await post(document, { assigneeId, after });
      const connection = data.issues;
      if (!connection || !Array.isArray(connection.nodes)
        || typeof connection.pageInfo?.hasNextPage !== 'boolean') {
        throw failure('linear_response_invalid', 'Linear returned an incomplete page');
      }
      for (const node of connection.nodes) issues.push(node);
      if (!connection.pageInfo.hasNextPage) break;
      const cursor = connection.pageInfo.endCursor;
      if (typeof cursor !== 'string' || cursor === '') {
        throw failure('linear_response_invalid', 'Linear returned an invalid page cursor');
      }
      if (seenCursors.has(cursor)) {
        throw failure('linear_pagination_loop', 'Linear repeated a page cursor; refusing a partial import');
      }
      seenCursors.add(cursor);
      after = cursor;
    }
    return issues;
  }

  return { fetchAll, documents: IMPORT_DOCUMENTS };
}

function noteList(issue) {
  const notes = [];
  if ((issue.comments?.nodes ?? []).length > 0) notes.push('comments_not_migrated');
  if ((issue.attachments?.nodes ?? []).length > 0) notes.push('attachments_not_migrated');
  if (issue.project) notes.push('project_not_migrated');
  if ((issue.labels?.nodes ?? []).length > 0) notes.push('labels_not_migrated');
  return notes;
}

function checkedIssue(issue) {
  if (!issue || typeof issue.id !== 'string' || issue.id === ''
    || typeof issue.identifier !== 'string' || typeof issue.title !== 'string'
    || typeof issue.updatedAt !== 'string') {
    throw failure('linear_response_invalid', 'Linear returned an incomplete issue');
  }
  return issue;
}

// A due date Linear reports must be one the store accepts; the same validator
// keeps the dry-run honest about what the import will write.
function dueDateOf(issue) {
  if (issue.dueDate === null || issue.dueDate === undefined) return { value: null };
  try {
    return { value: validateDueDate(issue.dueDate) };
  } catch {
    return { problem: 'due_date_invalid' };
  }
}

export function candidateOf(issue, { assigneeId, isImported = () => null, taskIdExists = () => false } = {}) {
  const source = checkedIssue(issue);
  const taskId = uuidv5(`${TASK_ID_NAMESPACE}${source.id}`);
  const title = source.title.trim();
  const memo = typeof source.description === 'string' ? source.description : '';
  const status = STATE_TO_STATUS[source.state?.type] ?? null;
  const due = dueDateOf(source);
  let url = null;
  if (typeof source.url === 'string' && source.url !== '') {
    try {
      const parsed = new URL(source.url);
      url = parsed.protocol === 'https:' ? source.url : null;
    } catch {
      url = null;
    }
  }
  let excluded = null;
  if (source.assignee?.id !== assigneeId) excluded = 'assignee_mismatch';
  else if (title === '') excluded = 'missing_title';
  else if (status === null) excluded = 'state_undecided';
  else if (memo.length > MAX_MEMO) excluded = 'memo_too_large';
  else if (title.length > MAX_TITLE) excluded = 'title_too_large';
  else if (due.problem) excluded = due.problem;
  else if (typeof source.url === 'string' && source.url !== '' && url === null) excluded = 'url_invalid';
  else if (isImported(source.id)) excluded = 'already_imported';
  else if (taskIdExists(taskId)) excluded = 'task_id_conflict';

  return {
    linearId: source.id,
    identifier: source.identifier,
    title,
    memo,
    status: status ?? 'todo',
    dueDate: due.value ?? null,
    url,
    linearUpdatedAt: source.updatedAt,
    linearState: { name: source.state?.name ?? null, type: source.state?.type ?? null },
    taskId,
    excluded,
    notes: noteList(source),
  };
}

function compareCandidates(a, b) {
  if (a.linearUpdatedAt !== b.linearUpdatedAt) return a.linearUpdatedAt < b.linearUpdatedAt ? -1 : 1;
  return a.identifier < b.identifier ? -1 : a.identifier > b.identifier ? 1 : 0;
}

export function manifestContent(manifest) {
  const { generatedAt, contentHash, ...content } = manifest;
  return content;
}

export function computeManifestHash(manifest) {
  return `sha256:${sha256Hex(canonicalJson(manifestContent(manifest)))}`;
}

export function buildManifest({
  issues, assigneeId, includeClosed = false, isImported = () => null, taskIdExists = () => false, now = () => Date.now(),
}) {
  const candidates = issues
    .map((issue) => candidateOf(issue, { assigneeId, isImported, taskIdExists }))
    .sort(compareCandidates);
  const counts = {
    fetched: candidates.length,
    selected: candidates.filter((candidate) => candidate.excluded === null).length,
    excluded: candidates.filter((candidate) => candidate.excluded !== null).length,
    undecided: candidates.filter((candidate) => candidate.excluded === 'state_undecided').length,
  };
  const manifest = {
    format: IMPORT_FORMAT,
    version: IMPORT_VERSION,
    generatedAt: new Date(now()).toISOString(),
    assigneeId,
    includeClosed: Boolean(includeClosed),
    candidates,
    counts,
  };
  manifest.contentHash = computeManifestHash(manifest);
  return manifest;
}

export function verifyManifest(manifest) {
  if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest)
    || manifest.format !== IMPORT_FORMAT || manifest.version !== IMPORT_VERSION
    || !Array.isArray(manifest.candidates) || typeof manifest.contentHash !== 'string') {
    throw new BridgeError(400, 'owner_tasks_import_manifest_invalid', 'the file is not an owner-task import manifest');
  }
  if (computeManifestHash(manifest) !== manifest.contentHash) {
    throw new BridgeError(400, 'owner_tasks_import_manifest_invalid', 'the manifest checksum does not match its contents');
  }
  for (const candidate of manifest.candidates) {
    if (!candidate || typeof candidate.linearId !== 'string' || typeof candidate.identifier !== 'string'
      || typeof candidate.title !== 'string' || typeof candidate.memo !== 'string'
      || !STATUSES.includes(candidate.status) || typeof candidate.taskId !== 'string'
      || (candidate.excluded !== null && typeof candidate.excluded !== 'string')) {
      throw new BridgeError(400, 'owner_tasks_import_manifest_invalid', 'the manifest has an invalid candidate');
    }
  }
  return manifest;
}

function projectionOf(candidate) {
  return {
    linearId: candidate.linearId,
    identifier: candidate.identifier,
    title: candidate.title,
    memoHash: sha256Hex(candidate.memo),
    status: candidate.status,
    dueDate: candidate.dueDate,
    url: candidate.url,
    linearUpdatedAt: candidate.linearUpdatedAt,
    linearState: candidate.linearState,
    notes: candidate.notes,
  };
}

// Compares the approved manifest with what Linear returns now. Store-dependent
// exclusions (already imported, reserved id) are not compared: they describe the
// store, not the source.
export function assertManifestCurrent(manifest, issues, { assigneeId } = {}) {
  const fresh = issues.map((issue) => candidateOf(issue, { assigneeId: assigneeId ?? manifest.assigneeId }));
  const freshById = new Map(fresh.map((candidate) => [candidate.linearId, projectionOf(candidate)]));
  const approvedById = new Map(manifest.candidates.map((candidate) => [candidate.linearId, projectionOf(candidate)]));
  const missing = [...approvedById.keys()].filter((id) => !freshById.has(id));
  const added = [...freshById.keys()].filter((id) => !approvedById.has(id));
  const drifted = [];
  for (const [id, approved] of approvedById) {
    const current = freshById.get(id);
    if (current && canonicalJson(current) !== canonicalJson(approved)) {
      drifted.push(approved.identifier);
    }
  }
  if (missing.length > 0 || added.length > 0 || drifted.length > 0) {
    throw new BridgeError(409, 'owner_tasks_import_stale',
      'Linear changed after the dry-run; take a new dry-run and approve it',
      {
        details: {
          missing: missing.length,
          added: added.length,
          drifted,
        },
      });
  }
  return true;
}

export function selectedCandidates(manifest) {
  return manifest.candidates.filter((candidate) => candidate.excluded === null);
}

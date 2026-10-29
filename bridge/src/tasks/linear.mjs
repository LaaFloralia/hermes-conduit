// Read-only Linear task source for the LAA Bridge (ROADMAP task 19).
//
// The Mac already reaches Linear through one wrapper: the 1Password service
// account read by ~/.config/laa/linear-agent-token.sh, which the laa-agent CLI
// and the Linear MCP headers use. This module reuses that wrapper instead of
// adding a key. The helper writes the token to stdout for one child process;
// nothing here caches it to disk, logs it, or returns it.
//
// Read-only by construction: the GraphQL guard accepts only `query` documents,
// and this module defines no mutation. Reading a task therefore cannot assign
// it, comment on it, or start a worker.

import { execFile } from 'node:child_process';
import { TaskSourceError } from './errors.mjs';

export { TaskSourceError };

const DEFAULT_ENDPOINT = 'https://api.linear.app/graphql';
const DEFAULT_TOKEN_HELPER = '/Users/laa/.config/laa/linear-agent-token.sh';
// The owner's Linear user id (same value the laa-agent CLI uses to tell a
// person's assignment from an agent's). Assignment to anyone else is an agent.
const DEFAULT_OWNER_USER_ID = 'd1f71177-5355-4f4f-b42c-7894c0870112';
const DEFAULT_TEAM_KEY = 'BUS';

const PAGE_SIZE = 50;
const MAX_PAGES = 10;
const COMMENT_BODY_LIMIT = 4000;
const REPORT_PREFIX = /^\[laa-agent\]/i;

const LIST_FIELDS = `
  id
  identifier
  title
  url
  priority
  createdAt
  updatedAt
  archivedAt
  completedAt
  canceledAt
  state { name type }
  assignee { id name }
  delegate { id name }
  project { id name }
  labels(first: 50) { nodes { name } }
  relations(first: 50) { nodes { type relatedIssue { identifier } } pageInfo { hasNextPage } }
  inverseRelations(first: 50) { nodes { type issue { identifier } } pageInfo { hasNextPage } }
`;

const LIST_QUERY = `query BridgeTasks($team: String!, $after: String) {
  issues(first: ${PAGE_SIZE}, after: $after, filter: { team: { key: { eq: $team } } }) {
    nodes { ${LIST_FIELDS} }
    pageInfo { hasNextPage endCursor }
  }
}`;

const DETAIL_QUERY = `query BridgeTask($id: String!) {
  issue(id: $id) {
    ${LIST_FIELDS}
    description
    comments(first: ${PAGE_SIZE}) {
      nodes { id body createdAt updatedAt user { id name } }
      pageInfo { hasNextPage endCursor }
    }
    attachments(first: ${PAGE_SIZE}) {
      nodes { id title url createdAt }
      pageInfo { hasNextPage endCursor }
    }
  }
}`;

const COMMENTS_QUERY = `query BridgeTaskComments($id: String!, $after: String) {
  issue(id: $id) {
    comments(first: ${PAGE_SIZE}, after: $after) {
      nodes { id body createdAt updatedAt user { id name } }
      pageInfo { hasNextPage endCursor }
    }
  }
}`;

const ATTACHMENTS_QUERY = `query BridgeTaskAttachments($id: String!, $after: String) {
  issue(id: $id) {
    attachments(first: ${PAGE_SIZE}, after: $after) {
      nodes { id title url createdAt }
      pageInfo { hasNextPage endCursor }
    }
  }
}`;

const RELATIONS_QUERY = `query BridgeTaskRelations($id: String!, $after: String) {
  issue(id: $id) {
    relations(first: ${PAGE_SIZE}, after: $after) {
      nodes { type relatedIssue { identifier } }
      pageInfo { hasNextPage endCursor }
    }
  }
}`;

const INVERSE_RELATIONS_QUERY = `query BridgeTaskInverseRelations($id: String!, $after: String) {
  issue(id: $id) {
    inverseRelations(first: ${PAGE_SIZE}, after: $after) {
      nodes { type issue { identifier } }
      pageInfo { hasNextPage endCursor }
    }
  }
}`;

// Reads the existing credential wrapper without a shell and without echoing
// stderr: the child's output is a secret and must never reach a log.
export function readTokenViaHelper(helper = DEFAULT_TOKEN_HELPER, { timeoutMs = 20_000 } = {}) {
  return new Promise((resolve, reject) => {
    execFile(helper, [], { timeout: timeoutMs, maxBuffer: 16 * 1024 }, (error, stdout) => {
      if (error) {
        reject(new TaskSourceError(
          'linear_credential_unavailable',
          'the Linear credential helper did not return a token',
        ));
        return;
      }
      const token = stdout.trim();
      if (token === '') {
        reject(new TaskSourceError(
          'linear_credential_unavailable',
          'the Linear credential helper returned an empty token',
        ));
        return;
      }
      resolve(token);
    });
  });
}

// Linear answers an unknown identifier with data:null and a user error on the
// `issue` field. Only that shape becomes "not found"; every other rejection
// stays a dependency error so an outage is never reported as 404.
function isMissingIssue(errors) {
  return errors.length > 0 && errors.every((error) => (
    error?.path?.[0] === 'issue'
    && error?.extensions?.userError === true
    && String(error?.extensions?.code ?? '') === 'INPUT_ERROR'
  ));
}

export function assertReadOnlyDocument(document) {
  if (
    typeof document !== 'string'
    || !/^\s*query\s+[A-Za-z_]/.test(document)
    || /\bmutation\b|\bsubscription\b/i.test(document)
  ) {
    throw new TaskSourceError('linear_read_only_guard', 'only named read-only queries are allowed', {
      status: 500,
      retryable: false,
    });
  }
}

function authorizationHeader(token) {
  // The helper returns either a personal API key (lin_api_...) or a bearer
  // token, matching the laa-agent CLI's handling of the same credential.
  return token.startsWith('lin_api_') ? token : `Bearer ${token}`;
}

function clip(text, limit) {
  if (typeof text !== 'string') return '';
  return text.length > limit ? text.slice(0, limit) : text;
}

function unique(values) {
  return [...new Set(values.filter((value) => typeof value === 'string' && value !== ''))];
}

function categoryOf(type) {
  if (type === 'completed') return 'done';
  if (type === 'canceled') return 'closed';
  return 'open';
}

function dependenciesOf(issue, { complete = true } = {}) {
  const relations = issue?.relations?.nodes ?? [];
  const inverse = issue?.inverseRelations?.nodes ?? [];
  return {
    blockedBy: unique(inverse.filter((node) => node.type === 'blocks').map((node) => node.issue?.identifier)),
    blocks: unique(relations.filter((node) => node.type === 'blocks').map((node) => node.relatedIssue?.identifier)),
    complete: complete
      && !issue?.relations?.pageInfo?.hasNextPage
      && !issue?.inverseRelations?.pageInfo?.hasNextPage,
  };
}

function resultOf(issue) {
  const type = issue?.state?.type;
  const closedAt = issue?.completedAt ?? issue?.canceledAt ?? null;
  if (issue?.completedAt) return { state: 'completed', summary: null, commentId: null, reportedAt: closedAt };
  if (type === 'canceled' || issue?.canceledAt) {
    return { state: 'canceled', summary: null, commentId: null, reportedAt: closedAt };
  }
  return { state: 'none', summary: null, commentId: null, reportedAt: null };
}

function toComment(node) {
  const body = typeof node?.body === 'string' ? node.body : '';
  return {
    id: node?.id ?? null,
    author: node?.user ? { id: node.user.id ?? null, name: node.user.name ?? null } : null,
    createdAt: node?.createdAt ?? null,
    updatedAt: node?.updatedAt ?? null,
    body: clip(body, COMMENT_BODY_LIMIT),
    truncated: body.length > COMMENT_BODY_LIMIT,
    agentReport: REPORT_PREFIX.test(body.trimStart()),
  };
}

function toLink(node) {
  return {
    id: node?.id ?? null,
    title: node?.title ?? null,
    url: node?.url ?? null,
    createdAt: node?.createdAt ?? null,
  };
}

export function createLinearTaskSource({
  endpoint = process.env.LAA_BRIDGE_LINEAR_ENDPOINT ?? DEFAULT_ENDPOINT,
  tokenHelper = process.env.LAA_BRIDGE_LINEAR_TOKEN_HELPER ?? DEFAULT_TOKEN_HELPER,
  teamKey = process.env.LAA_BRIDGE_LINEAR_TEAM ?? DEFAULT_TEAM_KEY,
  ownerUserId = process.env.LAA_BRIDGE_LINEAR_OWNER_ID ?? DEFAULT_OWNER_USER_ID,
  fetchImpl = globalThis.fetch,
  readToken = () => readTokenViaHelper(tokenHelper),
  requestTimeoutMs = 15_000,
} = {}) {
  let cachedToken = null;

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

  async function gql(document, variables = {}, { notFoundIsNull = false } = {}) {
    assertReadOnlyDocument(document);
    let response = await post(await token(), document, variables);
    if (response.status === 401) {
      // A rotated key should recover once; a second 401 is a real refusal.
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
    if (payload.data && typeof payload.data === 'object' && !Array.isArray(payload.data)
      && Object.hasOwn(payload.data, 'issue') && payload.data.issue === null) {
      return payload.data;
    }
    // GraphQL error text can echo the query or its values; only the fact of a
    // rejection is surfaced.
    if (Array.isArray(payload.errors) && payload.errors.length > 0) {
      if (notFoundIsNull && isMissingIssue(payload.errors)) return { issue: null };
      throw new TaskSourceError('linear_request_rejected', 'Linear rejected the read query');
    }
    if (!payload.data || typeof payload.data !== 'object' || Array.isArray(payload.data)) {
      throw new TaskSourceError('linear_response_invalid', 'Linear returned no data object');
    }
    return payload.data;
  }

  function toTask(issue, { detail = false } = {}) {
    const assignee = issue?.assignee ?? null;
    const delegate = issue?.delegate ?? null;
    const ownerKind = !assignee ? 'unassigned' : (assignee.id === ownerUserId ? 'owner' : 'agent');
    const executor = delegate
      ? { kind: 'agent', name: delegate.name ?? null, id: delegate.id ?? null }
      : (assignee && assignee.id !== ownerUserId
        ? { kind: 'agent', name: assignee.name ?? null, id: assignee.id ?? null }
        : null);
    const task = {
      id: `linear:${issue.identifier}`,
      source: 'linear',
      sourceId: issue.identifier,
      title: issue.title ?? '',
      owner: { kind: ownerKind, name: assignee?.name ?? null, id: assignee?.id ?? null },
      executor,
      status: {
        name: issue.state?.name ?? null,
        type: issue.state?.type ?? null,
        category: categoryOf(issue.state?.type),
      },
      dependencies: dependenciesOf(issue),
      result: resultOf(issue),
      project: issue.project ? { id: issue.project.id ?? null, name: issue.project.name ?? null } : null,
      labels: unique((issue.labels?.nodes ?? []).map((label) => label?.name)),
      url: issue.url ?? null,
      updatedAt: issue.updatedAt ?? null,
      // Linear has no revision field. updatedAt is the version a future write
      // adapter must echo as If-Match.
      version: issue.updatedAt ?? null,
    };
    if (detail) {
      task.description = typeof issue.description === 'string' ? issue.description : '';
    }
    return task;
  }

  async function listTasks() {
    const items = [];
    let cursor = null;
    for (let page = 0; page < MAX_PAGES; page += 1) {
      const data = await gql(LIST_QUERY, { team: teamKey, after: cursor });
      const connection = data.issues;
      if (!connection || !Array.isArray(connection.nodes)) {
        throw new TaskSourceError('linear_response_invalid', 'Linear returned an unexpected issue list');
      }
      for (const issue of connection.nodes) {
        if (!issue || issue.archivedAt) continue;
        items.push(toTask(issue));
      }
      const pageInfo = connection.pageInfo ?? {};
      if (!pageInfo.hasNextPage) return { items, truncated: false };
      const next = pageInfo.endCursor;
      if (!next || next === cursor) {
        throw new TaskSourceError('linear_pagination_stalled', 'Linear pagination did not advance');
      }
      cursor = next;
    }
    return { items, truncated: true };
  }

  async function collect(document, field, identifier, nodes, pageInfo) {
    const collected = [...nodes];
    let cursor = pageInfo?.endCursor ?? null;
    let hasNext = Boolean(pageInfo?.hasNextPage);
    for (let page = 0; hasNext && page < MAX_PAGES; page += 1) {
      const data = await gql(document, { id: identifier, after: cursor });
      const connection = data.issue?.[field];
      if (!connection || !Array.isArray(connection.nodes)) {
        throw new TaskSourceError('linear_response_invalid', `Linear returned an unexpected ${field} list`);
      }
      collected.push(...connection.nodes);
      hasNext = Boolean(connection.pageInfo?.hasNextPage);
      const next = connection.pageInfo?.endCursor;
      if (hasNext && (!next || next === cursor)) {
        throw new TaskSourceError('linear_pagination_stalled', `Linear ${field} pagination did not advance`);
      }
      cursor = next;
    }
    return collected;
  }

  async function getTask(sourceId) {
    const data = await gql(DETAIL_QUERY, { id: sourceId }, { notFoundIsNull: true });
    const issue = data.issue;
    if (!issue) return null;

    const commentNodes = await collect(
      COMMENTS_QUERY,
      'comments',
      sourceId,
      issue.comments?.nodes ?? [],
      issue.comments?.pageInfo,
    );
    const attachmentNodes = await collect(
      ATTACHMENTS_QUERY,
      'attachments',
      sourceId,
      issue.attachments?.nodes ?? [],
      issue.attachments?.pageInfo,
    );
    const relationNodes = await collect(
      RELATIONS_QUERY,
      'relations',
      sourceId,
      issue.relations?.nodes ?? [],
      issue.relations?.pageInfo,
    );
    const inverseRelationNodes = await collect(
      INVERSE_RELATIONS_QUERY,
      'inverseRelations',
      sourceId,
      issue.inverseRelations?.nodes ?? [],
      issue.inverseRelations?.pageInfo,
    );
    const comments = commentNodes.map(toComment);
    const task = toTask({
      ...issue,
      relations: { nodes: relationNodes, pageInfo: { hasNextPage: false } },
      inverseRelations: { nodes: inverseRelationNodes, pageInfo: { hasNextPage: false } },
    }, { detail: true });

    // The task's reported outcome is the newest [laa-agent] comment, the
    // convention hq/tools/LINEAR.md defines for finished work.
    const report = comments
      .filter((comment) => comment.agentReport)
      .sort((a, b) => String(b.updatedAt ?? '').localeCompare(String(a.updatedAt ?? '')))[0];
    if (report) {
      const firstLine = report.body.split('\n').find((line) => line.trim() !== '') ?? '';
      task.result = {
        state: 'reported',
        summary: clip(firstLine.replace(REPORT_PREFIX, '').trim(), 400),
        commentId: report.id,
        reportedAt: report.updatedAt ?? report.createdAt ?? null,
        completedAt: issue.completedAt ?? null,
      };
    }

    return { task, comments, links: attachmentNodes.map(toLink) };
  }

  return { listTasks, getTask };
}

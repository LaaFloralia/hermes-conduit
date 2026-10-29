import assert from 'node:assert/strict';
import test from 'node:test';
import {
  TaskSourceError,
  assertReadOnlyDocument,
  createLinearTaskSource,
  readTokenViaHelper,
} from '../src/tasks/linear.mjs';

const OWNER_ID = 'owner-user-id';

function response(body, status = 200) {
  return { ok: status >= 200 && status < 300, status, json: async () => body };
}

function recordingFetch(handler) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    const body = JSON.parse(init.body);
    calls.push({ url, headers: init.headers, body });
    return handler(body, calls.length);
  };
  fetchImpl.calls = calls;
  return fetchImpl;
}

function issue(overrides = {}) {
  return {
    id: 'issue-1',
    identifier: 'BUS-101',
    title: 'Bridge tasks API',
    description: 'read-only task views',
    url: 'https://linear.app/laa/issue/BUS-101',
    priority: 2,
    createdAt: '2026-10-20T00:00:00.000Z',
    updatedAt: '2026-10-25T00:00:00.000Z',
    archivedAt: null,
    completedAt: null,
    canceledAt: null,
    state: { name: 'Todo', type: 'unstarted' },
    assignee: { id: OWNER_ID, name: '社長' },
    delegate: null,
    project: { id: 'proj_1', name: 'Hermes Conduit' },
    labels: { nodes: [{ name: 'agent' }] },
    relations: { nodes: [{ type: 'blocks', relatedIssue: { identifier: 'BUS-110' } }], pageInfo: { hasNextPage: false } },
    inverseRelations: { nodes: [{ type: 'blocks', issue: { identifier: 'BUS-90' } }], pageInfo: { hasNextPage: false } },
    ...overrides,
  };
}

function source(fetchImpl, overrides = {}) {
  return createLinearTaskSource({
    teamKey: 'BUS',
    ownerUserId: OWNER_ID,
    fetchImpl,
    readToken: async () => 'test-token',
    ...overrides,
  });
}

test('listTasks pages through Linear and maps owner and executor separately', async () => {
  const fetchImpl = recordingFetch((body, call) => {
    if (call === 1) {
      return response({
        data: {
          issues: {
            nodes: [
              issue(),
              issue({ id: 'issue-2', identifier: 'BUS-102', assignee: { id: 'agent-user', name: 'LAA' } }),
              issue({ id: 'issue-3', identifier: 'BUS-103', delegate: { id: 'agent-user', name: 'LAA' } }),
              issue({ id: 'issue-4', identifier: 'BUS-104', archivedAt: '2026-10-24T00:00:00.000Z' }),
            ],
            pageInfo: { hasNextPage: true, endCursor: 'cursor-1' },
          },
        },
      });
    }
    return response({
      data: {
        issues: {
          nodes: [issue({ id: 'issue-5', identifier: 'BUS-105', assignee: null })],
          pageInfo: { hasNextPage: false, endCursor: null },
        },
      },
    });
  });

  const { items, truncated } = await source(fetchImpl).listTasks();
  assert.equal(truncated, false);
  assert.deepEqual(items.map((item) => item.sourceId), ['BUS-101', 'BUS-102', 'BUS-103', 'BUS-105']);

  const [ownerTask, agentTask, delegated, unassigned] = items;
  assert.equal(ownerTask.owner.kind, 'owner');
  assert.equal(ownerTask.executor, null);
  assert.equal(ownerTask.id, 'linear:BUS-101');
  assert.deepEqual(ownerTask.status, { name: 'Todo', type: 'unstarted', category: 'open' });
  assert.deepEqual(ownerTask.dependencies, { blockedBy: ['BUS-90'], blocks: ['BUS-110'], complete: true });
  assert.deepEqual(ownerTask.result, { state: 'none', summary: null, commentId: null, reportedAt: null });
  assert.deepEqual(ownerTask.project, { id: 'proj_1', name: 'Hermes Conduit' });
  assert.deepEqual(ownerTask.labels, ['agent']);

  assert.equal(agentTask.owner.kind, 'agent');
  assert.equal(agentTask.executor.name, 'LAA');
  assert.equal(delegated.owner.kind, 'owner');
  assert.equal(delegated.executor.name, 'LAA');
  assert.equal(unassigned.owner.kind, 'unassigned');

  assert.equal(fetchImpl.calls.length, 2);
  assert.equal(fetchImpl.calls[0].url, 'https://api.linear.app/graphql');
  assert.equal(fetchImpl.calls[0].headers.authorization, 'Bearer test-token');
  assert.deepEqual(fetchImpl.calls[0].body.variables, { team: 'BUS', after: null });
  assert.deepEqual(fetchImpl.calls[1].body.variables, { team: 'BUS', after: 'cursor-1' });
  for (const call of fetchImpl.calls) {
    assert.match(call.body.query, /^\s*query\s+BridgeTasks/);
    assert.doesNotMatch(call.body.query, /\bmutation\b/i);
  }
});

test('a personal API key is sent as-is and a rotated key is retried once', async () => {
  let reads = 0;
  const tokens = ['lin_api_first', 'lin_api_second'];
  const fetchImpl = recordingFetch((body, call) => {
    if (call === 1) return response({ errors: [{ message: 'expired' }] }, 401);
    return response({ data: { issues: { nodes: [], pageInfo: { hasNextPage: false } } } });
  });
  const linear = createLinearTaskSource({
    teamKey: 'BUS',
    ownerUserId: OWNER_ID,
    fetchImpl,
    readToken: async () => {
      reads += 1;
      return tokens[Math.min(reads - 1, tokens.length - 1)];
    },
  });

  await linear.listTasks();
  assert.equal(reads, 2);
  assert.equal(fetchImpl.calls[0].headers.authorization, 'lin_api_first');
  assert.equal(fetchImpl.calls[1].headers.authorization, 'lin_api_second');
});

test('a persistent 401 is a credential refusal, not a retry loop', async () => {
  const fetchImpl = recordingFetch(() => response({ errors: [{ message: 'nope' }] }, 401));
  const linear = source(fetchImpl);
  await assert.rejects(linear.listTasks(), (error) => {
    assert.ok(error instanceof TaskSourceError);
    assert.equal(error.code, 'linear_unauthorized');
    assert.equal(error.retryable, false);
    return true;
  });
});

test('GraphQL errors and transport failures are sanitised', async () => {
  const rejected = recordingFetch(() => response({ errors: [{ message: 'prompt text' }] }));
  await assert.rejects(source(rejected).listTasks(), (error) => {
    assert.equal(error.code, 'linear_request_rejected');
    assert.ok(!error.message.includes('prompt text'));
    return true;
  });

  const throttled = recordingFetch(() => response({ errors: [] }, 429));
  await assert.rejects(source(throttled).listTasks(), (error) => {
    assert.equal(error.code, 'linear_unavailable');
    assert.equal(error.retryable, true);
    return true;
  });

  const unreachable = createLinearTaskSource({
    teamKey: 'BUS',
    fetchImpl: async () => {
      throw new Error('offline');
    },
    readToken: async () => 'test-token',
  });
  await assert.rejects(unreachable.listTasks(), (error) => {
    assert.equal(error.code, 'linear_unreachable');
    return true;
  });
});

test('a missing credential helper fails closed without printing its output', async () => {
  await assert.rejects(readTokenViaHelper('/nonexistent/linear-token.sh'), (error) => {
    assert.ok(error instanceof TaskSourceError);
    assert.equal(error.code, 'linear_credential_unavailable');
    assert.equal(error.status, 503);
    assert.ok(!error.message.includes('/nonexistent'));
    return true;
  });

  const linear = createLinearTaskSource({
    teamKey: 'BUS',
    fetchImpl: async () => {
      throw new Error('must not be called without a token');
    },
    readToken: async () => {
      throw new TaskSourceError('linear_credential_unavailable', 'the Linear credential helper did not return a token');
    },
  });
  await assert.rejects(linear.listTasks(), { code: 'linear_credential_unavailable' });
});

test('a stalled cursor is refused instead of repeating pages forever', async () => {
  const fetchImpl = recordingFetch(() => response({
    data: {
      issues: {
        nodes: [issue()],
        pageInfo: { hasNextPage: true, endCursor: 'same-cursor' },
      },
    },
  }));
  await assert.rejects(source(fetchImpl).listTasks(), { code: 'linear_pagination_stalled' });
});

test('only named read-only queries pass the mutation guard', () => {
  assert.doesNotThrow(() => assertReadOnlyDocument('query BridgeTasks($team: String!) { issues { nodes { id } } }'));
  for (const document of [
    'mutation { issueCreate { issue { id } } }',
    'subscription { issues { id } }',
    'query Q { issues { id } } mutation { x }',
    '{ issues { id } }',
    null,
  ]) {
    assert.throws(() => assertReadOnlyDocument(document), { code: 'linear_read_only_guard' });
  }
});

test('detail returns comments, links, description and the [laa-agent] result', async () => {
  const fetchImpl = recordingFetch((body) => {
    if (body.query.includes('BridgeTaskComments')) {
      return response({
        data: {
          issue: {
            comments: {
              nodes: [{ id: 'c2', body: 'second', createdAt: '2026-10-25T02:00:00.000Z', updatedAt: '2026-10-25T02:00:00.000Z', user: { id: 'u', name: 'LAA' } }],
              pageInfo: { hasNextPage: false, endCursor: null },
            },
          },
        },
      });
    }
    if (body.query.includes('BridgeTaskAttachments')) {
      return response({ data: { issue: { attachments: { nodes: [], pageInfo: { hasNextPage: false } } } } });
    }
    if (body.query.includes('BridgeTaskRelations(') || body.query.includes('BridgeTaskInverseRelations')) {
      return response({ data: { issue: { [body.query.includes('Inverse') ? 'inverseRelations' : 'relations']: { nodes: [], pageInfo: { hasNextPage: false } } } } });
    }
    return response({
      data: {
        issue: issue({
          completedAt: '2026-10-25T03:00:00.000Z',
          comments: {
            nodes: [{
              id: 'c1',
              body: '[laa-agent] 完了: /v1/tasks を実装し 25 件を照合した\n詳細...',
              createdAt: '2026-10-25T01:00:00.000Z',
              updatedAt: '2026-10-25T01:00:00.000Z',
              user: { id: 'u', name: 'LAA' },
            }],
            pageInfo: { hasNextPage: true, endCursor: 'comments-1' },
          },
          attachments: {
            nodes: [{ id: 'a1', title: 'report.md', url: 'https://example.invalid/report.md', createdAt: '2026-10-25T01:00:00.000Z' }],
            pageInfo: { hasNextPage: false, endCursor: null },
          },
        }),
      },
    });
  });

  const found = await source(fetchImpl).getTask('BUS-101');
  assert.equal(found.task.description, 'read-only task views');
  assert.equal(found.task.result.state, 'reported');
  assert.equal(found.task.result.summary, '完了: /v1/tasks を実装し 25 件を照合した');
  assert.equal(found.task.result.commentId, 'c1');
  assert.equal(found.task.result.completedAt, '2026-10-25T03:00:00.000Z');
  assert.equal(found.comments.length, 2);
  assert.equal(found.comments[0].agentReport, true);
  assert.equal(found.comments[1].agentReport, false);
  assert.deepEqual(found.links, [{ id: 'a1', title: 'report.md', url: 'https://example.invalid/report.md', createdAt: '2026-10-25T01:00:00.000Z' }]);
  assert.equal(fetchImpl.calls.length, 2);
});

test('a completed issue without an agent comment reports completed', async () => {
  const fetchImpl = recordingFetch((body) => {
    if (body.query.includes('BridgeTaskComments')) {
      return response({ data: { issue: { comments: { nodes: [], pageInfo: { hasNextPage: false } } } } });
    }
    if (body.query.includes('BridgeTaskAttachments')) {
      return response({ data: { issue: { attachments: { nodes: [], pageInfo: { hasNextPage: false } } } } });
    }
    if (body.query.includes('BridgeTaskRelations')) {
      const field = body.query.includes('Inverse') ? 'inverseRelations' : 'relations';
      return response({ data: { issue: { [field]: { nodes: [], pageInfo: { hasNextPage: false } } } } });
    }
    return response({
      data: {
        issue: issue({
          state: { name: 'Done', type: 'completed' },
          completedAt: '2026-10-25T03:00:00.000Z',
          comments: { nodes: [], pageInfo: { hasNextPage: false } },
          attachments: { nodes: [], pageInfo: { hasNextPage: false } },
        }),
      },
    });
  });
  const found = await source(fetchImpl).getTask('BUS-101');
  assert.deepEqual(found.task.result, {
    state: 'completed',
    summary: null,
    commentId: null,
    reportedAt: '2026-10-25T03:00:00.000Z',
  });
  assert.equal(found.comments.length, 0);
  assert.equal(found.links.length, 0);
});

test('an unknown issue is null, not an error', async () => {
  const bare = recordingFetch(() => response({ data: { issue: null } }));
  assert.equal(await source(bare).getTask('BUS-404'), null);

  // Linear answers an unknown id with data:null and a user error on `issue`.
  const entityNotFound = [{
    message: 'Entity not found: Issue',
    path: ['issue'],
    extensions: { code: 'INPUT_ERROR', userError: true, statusCode: 400 },
  }];
  const withError = recordingFetch(() => response({ data: null, errors: entityNotFound }));
  assert.equal(await source(withError).getTask('BUS-404'), null);

  // Any other rejection stays a dependency error, not a 404.
  const outage = recordingFetch(() => response({
    data: null,
    errors: [{ message: 'boom', path: ['issue'], extensions: { code: 'INTERNAL', userError: false } }],
  }));
  await assert.rejects(source(outage).getTask('BUS-404'), { code: 'linear_request_rejected' });
});

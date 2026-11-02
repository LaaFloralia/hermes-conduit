import test from 'node:test';
import assert from 'node:assert/strict';
import { performance } from 'node:perf_hooks';
import { setTimeout as delay } from 'node:timers/promises';
import { createLinearOwnerTaskSource, LINEAR_OWNER_DOCUMENTS } from '../src/tasks/linear-owner.mjs';

test('same 2,000-issue fixture: server filtering and caching remove the 20-page owner scan', async t => {
  const owner = 'd1f71177-5355-4f4f-b42c-7894c0870112';
  const team = { id: 'team', key: 'BUS', name: 'LAA', states: { nodes: [{ id: 'todo', name: 'Todo', type: 'unstarted' }] } };
  const issues = Array.from({ length: 2000 }, (_, n) => ({ id: String(n), identifier: `BUS-${n}`, title: `Task ${n}`,
    assignee: { id: owner }, team, archivedAt: n >= 1820 ? '2026-01-01T00:00:00Z' : null,
    state: { name: n < 20 ? 'Todo' : 'Done', type: n < 20 ? 'unstarted' : 'completed' } }));
  let calls = 0;
  const fetchImpl = async (_url, init) => {
    calls++; await delay(500); // Fixed upstream latency, identical before/after.
    const { query, variables = {} } = JSON.parse(init.body);
    let data;
    if (/BaselineViewer/.test(query)) data = { viewer: { id: owner } };
    else if (/BaselineTeam/.test(query)) data = { teams: { nodes: [team] } };
    else if (/BaselineStates/.test(query)) data = { team: { states: team.states } };
    else if (/BridgeOwnerViewer/.test(query)) data = { viewer: { id: owner }, teams: { nodes: [team] } };
    else {
      const rows = /state:.*nin:/s.test(query) ? issues.filter(i => !i.archivedAt && i.state.type !== 'completed') : issues;
      const offset = Number(variables.after ?? 0), next = offset + 100;
      data = { issues: { nodes: rows.slice(offset, next), pageInfo: { hasNextPage: next < rows.length, endCursor: next < rows.length ? String(next) : null } } };
    }
    return { ok: true, status: 200, json: async () => ({ data }) };
  };
  const run = async (query, variables) => (await (await fetchImpl('', { body: JSON.stringify({ query, variables }) })).json()).data;
  const baselineQuery = LINEAR_OWNER_DOCUMENTS.find(q => q.startsWith('query BridgeOwnerTasks'))
    .replace('after: $after, filter:', 'after: $after, includeArchived: true, filter:')
    .replace('    state: { type: { nin: ["completed", "canceled"] } }\n', '').replace('    delegate: { null: true }\n', '');
  let start = performance.now();
  await run('query BaselineViewer { viewer { id } }');
  await run('query BaselineTeam { teams { nodes { id } } }');
  await run('query BaselineStates($id: String!) { team(id: $id) { id } }', { id: 'team' });
  const before = []; let after = null;
  do {
    const data = await run(baselineQuery, { team: 'BUS', owner, after });
    before.push(...data.issues.nodes.filter(i => !i.archivedAt && !['completed', 'canceled'].includes(i.state.type)));
    after = data.issues.pageInfo.endCursor;
  } while (after);
  const beforeMs = performance.now() - start, beforeCalls = calls;
  const source = createLinearOwnerTaskSource({ fetchImpl, readToken: async () => 'fixture' });
  calls = 0; start = performance.now();
  const cold = await source.listOwnerTasks();
  const coldMs = performance.now() - start, coldCalls = calls;
  calls = 0; start = performance.now();
  const warm = await source.listOwnerTasks();
  const warmMs = performance.now() - start;
  assert.deepEqual(cold.items.map(i => i.id), before.map(i => i.id));
  assert.deepEqual(warm, cold);
  assert.equal(beforeCalls, 23); assert.equal(coldCalls, 2); assert.equal(calls, 0);
  assert(coldMs < 3000); assert(warmMs < 1000);
  t.diagnostic(JSON.stringify({ fixtureIssues: 2000, visible: cold.items.length, upstreamLatencyMs: 500,
    before: { calls: beforeCalls, ms: Math.round(beforeMs) }, cold: { calls: coldCalls, ms: Math.round(coldMs) }, warm: { calls, ms: +warmMs.toFixed(2) } }));
});

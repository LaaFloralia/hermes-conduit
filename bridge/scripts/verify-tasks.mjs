#!/usr/bin/env node
// Operator check that /v1/tasks maps Linear faithfully (ROADMAP task 19).
//
// Reads Linear twice: once through the Bridge adapter, once through a separate
// minimal query below. Compares identifiers and the mapped fields, prints a
// short JSON summary and exits non-zero on any mismatch. Read-only; reuses the
// existing credential wrapper and never prints the token.
//
//   node bridge/scripts/verify-tasks.mjs [--min-items 20]
//
// Not part of `npm test`: CI has no Linear credential and must not need one.

import { createLinearTaskSource, readTokenViaHelper } from '../src/tasks/linear.mjs';

const OWNER_USER_ID = process.env.LAA_BRIDGE_LINEAR_OWNER_ID ?? 'd1f71177-5355-4f4f-b42c-7894c0870112';
const ENDPOINT = 'https://api.linear.app/graphql';

const args = process.argv.slice(2);
const minIndex = args.indexOf('--min-items');
const minItems = minIndex >= 0 ? Number(args[minIndex + 1]) : 20;

async function directIssues() {
  const token = await readTokenViaHelper();
  const authorization = token.startsWith('lin_api_') ? token : `Bearer ${token}`;
  const query = `query VerifyTasks($after: String) {
    issues(first: 50, after: $after, filter: { team: { key: { eq: "BUS" } } }) {
      nodes {
        identifier title updatedAt archivedAt
        state { name type }
        assignee { id name }
        delegate { id name }
        project { id name }
        relations(first: 50) { nodes { type relatedIssue { identifier } } pageInfo { hasNextPage } }
        inverseRelations(first: 50) { nodes { type issue { identifier } } pageInfo { hasNextPage } }
      }
      pageInfo { hasNextPage endCursor }
    }
  }`;
  const issues = [];
  let cursor = null;
  for (let page = 0; page < 50; page += 1) {
    const response = await fetch(ENDPOINT, {
      method: 'POST',
      headers: { authorization, 'content-type': 'application/json' },
      body: JSON.stringify({ query, variables: { after: cursor } }),
    });
    if (!response.ok) throw new Error(`Linear responded with HTTP ${response.status}`);
    const payload = await response.json();
    if (payload.errors) throw new Error('Linear rejected the verification query');
    const connection = payload.data.issues;
    issues.push(...connection.nodes.filter((issue) => !issue.archivedAt));
    if (!connection.pageInfo.hasNextPage) return issues;
    cursor = connection.pageInfo.endCursor;
  }
  throw new Error('Linear pagination did not finish');
}

const bridgeItems = (await createLinearTaskSource().listTasks()).items;
const directItems = await directIssues();
const bridge = new Map(bridgeItems.map((item) => [item.sourceId, item]));
const direct = new Map(directItems.map((item) => [item.identifier, item]));

const mismatches = [];
for (const [identifier, item] of direct) {
  const mapped = bridge.get(identifier);
  if (!mapped) {
    mismatches.push({ identifier, fields: ['missing'] });
    continue;
  }
  const expectedOwner = !item.assignee
    ? 'unassigned'
    : (item.assignee.id === OWNER_USER_ID ? 'owner' : 'agent');
  const executor = item.delegate ?? (item.assignee && item.assignee.id !== OWNER_USER_ID ? item.assignee : null);
  const blockedBy = [...new Set(item.inverseRelations.nodes.filter((r) => r.type === 'blocks').map((r) => r.issue.identifier))];
  const blocks = [...new Set(item.relations.nodes.filter((r) => r.type === 'blocks').map((r) => r.relatedIssue.identifier))];
  const fields = [];
  if (mapped.title !== item.title) fields.push('title');
  if (mapped.status.name !== item.state?.name || mapped.status.type !== item.state?.type) fields.push('status');
  if (mapped.owner.kind !== expectedOwner) fields.push('owner.kind');
  if ((mapped.owner.name ?? null) !== (item.assignee?.name ?? null)) fields.push('owner.name');
  if ((mapped.executor?.id ?? null) !== (executor?.id ?? null)) fields.push('executor');
  if ((mapped.project?.name ?? null) !== (item.project?.name ?? null)) fields.push('project');
  if (mapped.updatedAt !== item.updatedAt) fields.push('updatedAt');
  if (JSON.stringify([...mapped.dependencies.blockedBy].sort()) !== JSON.stringify(blockedBy.sort())) fields.push('blockedBy');
  if (JSON.stringify([...mapped.dependencies.blocks].sort()) !== JSON.stringify(blocks.sort())) fields.push('blocks');
  if (mapped.dependencies.complete !== true) fields.push('dependencies.complete');
  if (fields.length > 0) mismatches.push({ identifier, fields });
}

const onlyInBridge = [...bridge.keys()].filter((identifier) => !direct.has(identifier));
const summary = {
  bridgeCount: bridge.size,
  directCount: direct.size,
  compared: bridgeItems.filter((item) => direct.has(item.sourceId)).length,
  onlyInBridge,
  minItems,
  meetsMinimum: bridge.size >= minItems,
  mismatches,
};
process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
process.exit(mismatches.length === 0 && onlyInBridge.length === 0 && summary.meetsMinimum ? 0 : 1);

// Proposal intake is local bookkeeping. Linear BUS holds the task itself.
import { createHash, randomUUID } from 'node:crypto';
import { join } from 'node:path';
import { BridgeError, badRequest, conflict, notFound } from '../errors.mjs';
import { createJsonFile } from '../routes/state-file.mjs';
import { assertReadOnlyDocument, authorizationHeader, readTokenViaHelper } from './linear.mjs';
import { createLinearOwnerTaskSource, TaskSourceError } from './linear-owner.mjs';

const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/;
const IDENTIFIER = /^BUS-[1-9][0-9]*$/;
const STATES = ['pending', 'proposed', 'dismissed'];
const OVERLAP_MS = 15 * 60_000;
const MAX_PAGES = 8;
const object = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const timestamp = (v) => typeof v === 'string' && Number.isFinite(Date.parse(v));
const comment = (v) => typeof v === 'string' && /^[a-z0-9_-]{1,128}$/i.test(v);
const unavailable = () => new BridgeError(503, 'task_proposals_store_unavailable', 'cannot read or write task proposals');

function taskId(value) {
  const id = typeof value === 'string' ? value.toLowerCase() : '';
  if (!UUID.test(id)) throw badRequest('task_proposal_id_invalid', 'use a Linear issue UUID');
  return id;
}

export function createTaskProposalStore({ dir, now = Date.now } = {}) {
  const file = createJsonFile({ file: join(dir, 'task-proposals.json'), initial: () => ({ scan: null, issues: {}, staffIntents: {} }) });
  function checked(doc) {
    if (!object(doc.issues) || !object(doc.staffIntents)
      || Object.entries(doc.staffIntents).some(([id, tokens]) => !UUID.test(id) || !Array.isArray(tokens)
        || tokens.length === 0 || tokens.some((token) => !UUID.test(token)))
      || (doc.scan !== null && (!timestamp(doc.scan?.baseline) || !timestamp(doc.scan?.through)
      || Date.parse(doc.scan.through) < Date.parse(doc.scan.baseline)))
      || Object.entries(doc.issues).some(([id, record]) => !UUID.test(id) || !object(record)
        || !STATES.includes(record.state) || (record.createdAt === null
          ? record.state !== 'dismissed' || record.identifier !== null
          : !timestamp(record.createdAt) || !IDENTIFIER.test(record.identifier))
        || (record.commentId !== null && (record.state !== 'proposed' || !comment(record.commentId))))) {
      throw unavailable();
    }
    return doc;
  }
  const access = (fn) => {
    try { return fn(); }
    catch (error) { if (error instanceof BridgeError) throw error; throw unavailable(); }
  };
  const read = () => access(() => checked(file.read()));
  const mutate = (fn) => access(() => file.mutate((doc) => {
    const result = fn(checked(doc));
    checked(doc);
    return result;
  }));
  function register(doc, { id: givenId, identifier, createdAt = new Date(now()).toISOString() }) {
    const id = taskId(givenId);
    if (!IDENTIFIER.test(identifier) || !timestamp(createdAt)) {
      throw badRequest('task_proposal_metadata_invalid', 'expected a BUS issue and creation timestamp');
    }
    return doc.issues[id] ??= { identifier, createdAt, state: 'pending', commentId: null };
  }
  function dismissForStaff(doc, id) {
    const record = doc.issues[id] ??= { identifier: null, createdAt: null, state: 'dismissed', commentId: null };
    if (record.state === 'pending') record.state = 'dismissed';
    delete doc.staffIntents[id];
  }
  function pending() {
    const { issues, staffIntents } = read();
    const candidates = Object.entries(issues)
      .filter(([, record]) => record.createdAt !== null)
      .map(([id, record]) => ({ id, ...record }))
      .sort((a, b) => Date.parse(a.createdAt) - Date.parse(b.createdAt) || a.id.localeCompare(b.id));
    const totalSeen = candidates.length;
    const newestCreatedAt = candidates.at(-1)?.createdAt ?? null;
    const digest = createHash('sha256').update(JSON.stringify([totalSeen, newestCreatedAt])).digest('hex');
    return { pending: candidates.filter((record) => record.state === 'pending' && !staffIntents[record.id]), totalSeen, newestCreatedAt, digest };
  }
  return {
    file: file.file,
    pending,
    scan: () => read().scan,
    recordOwnerTask: (task) => mutate((doc) => register(doc, task)),
    stageStaffTask(givenId) {
      const id = taskId(givenId);
      const token = randomUUID();
      return mutate((doc) => {
        (doc.staffIntents[id] ??= []).push(token);
        return token;
      });
    },
    releaseStaffTask(givenId, token) {
      const id = taskId(givenId);
      mutate((doc) => {
        const remaining = doc.staffIntents[id]?.filter((value) => value !== token);
        if (remaining?.length) doc.staffIntents[id] = remaining;
        else delete doc.staffIntents[id];
      });
    },
    suppressStaffTask(givenId) {
      const id = taskId(givenId);
      return mutate((doc) => dismissForStaff(doc, id));
    },
    mark(givenId, state, commentId = null, isStaff = () => false) {
      const id = taskId(givenId);
      if (!['proposed', 'dismissed'].includes(state) || (commentId !== null && (state !== 'proposed' || !comment(commentId)))) {
        throw badRequest('task_proposal_state_invalid', 'use proposed or dismissed; a comment ID belongs to proposed');
      }
      const outcome = mutate((doc) => {
        const record = doc.issues[id];
        if (!record) throw notFound('task proposal not found');
        if (isStaff(id)) dismissForStaff(doc, id);
        if (doc.staffIntents[id]) throw conflict('task_proposal_staff_dispatch', 'staff dispatch is pending');
        if (record.state === 'pending') Object.assign(record, { state, commentId });
        return { id, ...record };
      });
      if (outcome.state !== state || outcome.commentId !== commentId) {
        throw conflict('task_proposal_already_resolved', 'the task proposal has already been resolved');
      }
      return outcome;
    },
    reconcile({ expected, through, items, staffIds }) {
      return mutate((doc) => {
        for (const id of staffIds()) dismissForStaff(doc, taskId(id));
        // A concurrent scan may already have committed a later checkpoint.
        if (doc.scan?.through !== expected?.through) return;
        const baseline = doc.scan?.baseline ?? through;
        for (const item of items) {
          if (Date.parse(item.createdAt) > Date.parse(baseline) && !doc.staffIntents[taskId(item.id)]) register(doc, item);
        }
        doc.scan = { baseline, through };
      });
    },
  };
}

// The owner-list source omits creation metadata. Reuse its credential and
// account/team verification, then request only the fields needed for intake.
const CANDIDATES = `query BridgeOwnerProposalCandidates($filter: IssueFilter!, $after: String) {
  viewer {
    id
    createdIssues(first: 50, after: $after, orderBy: createdAt, filter: $filter) {
      nodes { id identifier createdAt archivedAt trashed
        creator { id } assignee { id } delegate { id } team { id }
        state { type }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
}`;

export function createLinearProposalSource({
  endpoint = process.env.LAA_BRIDGE_LINEAR_ENDPOINT ?? 'https://api.linear.app/graphql',
  tokenHelper = process.env.LAA_BRIDGE_LINEAR_TOKEN_HELPER,
  fetchImpl = globalThis.fetch,
  readToken = () => readTokenViaHelper(tokenHelper),
  ...ownerOptions
} = {}) {
  return async ({ since, through }) => {
    let credential;
    // The factory verifies the account with the same credential used to query
    // viewer.createdIssues. A subsequent call obtains a fresh credential.
    const sharedToken = async () => (credential = await readToken());
    const source = createLinearOwnerTaskSource({ ...ownerOptions, endpoint, fetchImpl, readToken: sharedToken });
    const { teamId } = await source.config();
    if (since === null) return [];
    assertReadOnlyDocument(CANDIDATES);
    const filter = {
      team: { id: { eq: teamId } },
      delegate: { null: true },
      state: { type: { nin: ['completed', 'canceled'] } },
      createdAt: { gte: since, lte: through },
    };
    const items = [];
    const cursors = new Set();
    let after = null;
    for (let page = 0; page < MAX_PAGES; page += 1) {
      let payload;
      try {
        const response = await fetchImpl(endpoint, {
          method: 'POST',
          headers: { authorization: authorizationHeader(credential), 'content-type': 'application/json' },
          body: JSON.stringify({ query: CANDIDATES, variables: { filter, after } }),
          signal: AbortSignal.timeout(10_000),
        });
        if (!response.ok) throw new Error();
        payload = await response.json();
      } catch {
        throw new TaskSourceError('linear_proposal_sync_unavailable', 'could not read Linear proposal candidates');
      }
      const viewer = payload?.data?.viewer;
      const connection = viewer?.createdIssues;
      const info = connection?.pageInfo;
      if (payload?.errors?.length || !viewer?.id || !Array.isArray(connection?.nodes) || typeof info?.hasNextPage !== 'boolean') {
        throw new TaskSourceError('linear_response_invalid', 'invalid Linear proposal candidate list');
      }
      for (const row of connection.nodes) {
        if (row?.creator?.id !== viewer.id || row?.assignee?.id !== viewer.id || row.team?.id !== teamId
          || row.archivedAt || row.trashed || row.delegate || !row.state?.type || ['completed', 'canceled'].includes(row.state.type)) continue;
        if (!UUID.test(String(row.id).toLowerCase()) || !IDENTIFIER.test(row.identifier) || !timestamp(row.createdAt)) {
          throw new TaskSourceError('linear_response_invalid', 'invalid Linear proposal candidate metadata');
        }
        if (Date.parse(row.createdAt) < Date.parse(since) || Date.parse(row.createdAt) > Date.parse(through)) continue;
        items.push({ id: row.id, identifier: row.identifier, createdAt: row.createdAt });
      }
      if (!info.hasNextPage) return items;
      if (typeof info.endCursor !== 'string' || !info.endCursor || cursors.has(info.endCursor)) break;
      after = info.endCursor;
      cursors.add(after);
    }
    throw new TaskSourceError('linear_pagination_incomplete', 'could not complete the Linear proposal scan');
  };
}

export async function syncLinearTaskProposals({ proposals, candidates, staffIds, now = Date.now }) {
  const expected = proposals.scan();
  const through = new Date(now()).toISOString();
  if (expected && Date.parse(through) <= Date.parse(expected.through)) return;
  const since = expected ? new Date(Math.max(Date.parse(expected.baseline), Date.parse(expected.through) - OVERLAP_MS)).toISOString() : null;
  const items = await candidates({ since, through });
  proposals.reconcile({ expected, through, items, staffIds });
}

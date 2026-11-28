// Requirement flows: one record per owner requirement that is moving from
// intake to the report (schema laa.flow.v1). The pipeline is the only writer;
// every step is a compare-and-set on `state`, so a retried or overlapping step
// cannot move a flow twice.

import { randomBytes } from 'node:crypto';
import { join } from 'node:path';
import { createJsonFile } from '../routes/state-file.mjs';
import { BridgeError, conflict, notFound } from '../errors.mjs';

export const FLOW_ID = /^flw_[0-9a-f]{12}$/;
export const FLOW_STATES = ['intake', 'expanding', 'advising', 'designed', 'dispatching', 'verifying', 'awaiting_decision', 'reported', 'failed', 'withdrawn'];
export const CLOSED_STATES = ['reported', 'failed', 'withdrawn'];
const KEEP_CLOSED_MS = 30 * 86400_000;
const MAX_STEPS = 60;

export function createFlowStore({ dir, now = () => Date.now() }) {
  const stamp = () => new Date(now()).toISOString();
  const file = createJsonFile({ file: join(dir, 'requirement-flows.json'), initial: () => ({ flows: {} }) });

  function access(fn) {
    try { return fn(); } catch (error) {
      if (error instanceof BridgeError) throw error;
      throw new BridgeError(503, 'flow_store_unavailable', '要件フローの保存先を読み書きできません。', { retryable: true });
    }
  }
  const read = () => access(() => file.read().flows ?? {});
  function mutate(fn) {
    return access(() => file.mutate((doc) => {
      doc.flows ??= {};
      const time = now();
      for (const [id, flow] of Object.entries(doc.flows)) {
        if (CLOSED_STATES.includes(flow.state) && time - Date.parse(flow.updatedAt) > KEEP_CLOSED_MS) delete doc.flows[id];
      }
      return structuredClone(fn(doc.flows));
    }));
  }
  function step(flow, state, by, note) {
    flow.steps = [...(flow.steps ?? []), { at: stamp(), state, by, note: note ? [...String(note)].slice(0, 200).join('') : null }].slice(-MAX_STEPS);
    flow.updatedAt = stamp();
  }
  function must(flows, id) {
    const flow = flows[id];
    if (!flow) throw notFound('flow not found');
    return flow;
  }

  return {
    file: file.file,
    get: (id) => { const flow = read()[id]; return flow ? structuredClone(flow) : null; },
    list({ state = null, projectId = null, open = false } = {}) {
      return structuredClone(Object.values(read()).filter((flow) => (!state || flow.state === state) && (!projectId || flow.projectId === projectId)
        && (!open || !CLOSED_STATES.includes(flow.state))).sort((a, b) => a.createdAt.localeCompare(b.createdAt)));
    },
    // Idempotent per (projectId, requestId): the same owner request starts one flow.
    create(input) {
      return mutate((flows) => {
        const existing = Object.values(flows).find((flow) => flow.projectId === input.projectId && flow.requestId === input.requestId && flow.state !== 'withdrawn');
        if (existing) {
          if (existing.request.title !== input.request.title) throw conflict('flow_request_conflict', 'requestId was used for a different requirement');
          return { flow: existing, created: false };
        }
        const at = stamp();
        const flow = {
          schema: 'laa.flow.v1', id: `flw_${randomBytes(6).toString('hex')}`, requestId: input.requestId, projectId: input.projectId,
          state: 'intake', size: input.size, risk: input.risk, request: input.request, dryStaff: input.dryStaff === true,
          requirementIds: [], staff: [], advisor: null, design: null, packages: [], decisions: [], failure: null, retryAt: null,
          steps: [{ at, state: 'intake', by: input.by ?? 'monet', note: null }], createdAt: at, updatedAt: at, reportedAt: null, report: null,
        };
        flows[flow.id] = flow;
        return { flow, created: true };
      });
    },
    // Compare-and-set: applies `patch` and moves `from` → `to` only when the flow
    // is still in `from`. Returns { flow, moved }. `to === from` records progress
    // inside a state without a step entry.
    advance(id, from, to, patch = {}, { by = 'bridge', note = null } = {}) {
      return mutate((flows) => {
        const flow = must(flows, id);
        const allowed = Array.isArray(from) ? from : [from];
        if (!allowed.includes(flow.state)) return { flow, moved: false };
        const next = typeof patch === 'function' ? patch(flow) ?? {} : patch;
        Object.assign(flow, next);
        if (to !== flow.state) { flow.state = to; step(flow, to, by, note); } else flow.updatedAt = stamp();
        return { flow, moved: true };
      });
    },
    // Edit one package (or one staff row) under the lock; `fn` mutates the row.
    setPackage(id, packageId, fn) {
      return mutate((flows) => {
        const flow = must(flows, id);
        const pkg = flow.packages.find((item) => item.id === packageId);
        if (!pkg) throw notFound('flow package not found');
        fn(pkg, flow);
        flow.updatedAt = stamp();
        return flow;
      });
    },
    setStaff(id, role, patch) {
      return mutate((flows) => {
        const flow = must(flows, id);
        const row = flow.staff.find((item) => item.role === role);
        if (row) Object.assign(row, patch);
        flow.updatedAt = stamp();
        return flow;
      });
    },
    update(id, fn) {
      return mutate((flows) => { const flow = must(flows, id); fn(flow); flow.updatedAt = stamp(); return flow; });
    },
  };
}

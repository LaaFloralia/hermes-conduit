// In-memory implementation of the StudioBackend boundary for contract tests.
// Time and Studio's receipt of a request are controlled explicitly by the test.
import { isDeepStrictEqual } from 'node:util';
import { BridgeError } from '../src/errors.mjs';

const terminal = new Set(['completed', 'failed', 'stopped', 'interrupted']);
const error = (status, code) => new BridgeError(status, code, code);
const copy = (value) => structuredClone(value);

export function mockStudioBackend({ projects = [], principles = [], now = () => Date.now() } = {}) {
  const state = { connected: true, accepting: true, projects: copy(projects), principles: copy(principles), records: new Map() };
  const stamp = () => new Date(now()).toISOString();
  const ensureConnected = () => { if (!state.connected) throw error(503, 'studio_not_connected'); };
  const visible = (entry) => {
    const record = copy(entry.record);
    if (record.status === 'queued' && now() - entry.createdAt >= 45_000) record.status = 'unreceived';
    return record;
  };
  const get = (id) => {
    const entry = state.records.get(id);
    if (!entry) throw error(404, 'studio_request_missing');
    return entry;
  };
  return {
    state,
    async snapshot() {
      ensureConnected();
      return { online: true, accepting: state.accepting && ![...state.records.values()].some(({ record }) => !terminal.has(record.status)),
        lastSeen: stamp(), projects: state.projects.map(({ preview, ...project }) => copy(project)), principles: copy(state.principles),
        requests: [...state.records.values()].reverse().slice(0, 60).map(visible) };
    },
    async getRequest(id) { ensureConnected(); return visible(get(id)); },
    async createRequest(request) {
      ensureConnected();
      const existing = state.records.get(request.id);
      if (existing) {
        if (!isDeepStrictEqual(existing.record.request, request)) throw error(409, 'studio_request_id_conflict');
        return visible(existing);
      }
      if (!state.accepting || [...state.records.values()].some(({ record }) => !terminal.has(record.status))) throw error(409, 'studio_work_busy');
      const project = state.projects.find((item) => item.id === request.projectId);
      if (request.create ? !!project : !project || project.revision !== request.expectedRevision) throw error(409, 'studio_revision_changed');
      if (request.principle) {
        const principle = state.principles.find((item) => item.id === request.principle.id);
        if (!principle || principle.version !== request.principle.version || principle.revision !== request.principle.revision) {
          throw error(409, 'studio_principle_changed');
        }
      }
      const record = { request: copy(request), status: 'queued', bootId: null, updatedAt: stamp(), report: null };
      state.records.set(request.id, { record, createdAt: now() });
      return copy(record);
    },
    async action(action) {
      ensureConnected();
      if (action.action === 'resume') throw error(409, 'studio_resume_unsupported');
      const entry = get(action.id);
      if (terminal.has(entry.record.status)) throw error(409, 'studio_request_finished');
      if (action.action === 'stop') {
        entry.record.status = 'stopped';
      } else {
        const approval = entry.record.report?.approvals.find((item) => item.id === action.approvalId);
        if (entry.record.status !== 'approval' || !approval || !approval.supported || (action.persist && !approval.allowSession)) {
          throw error(409, 'studio_approval_expired');
        }
        entry.record.status = 'running';
        entry.record.report = { ...entry.record.report, status: 'running', approvals: [], sequence: entry.record.report.sequence + 1 };
      }
      entry.record.updatedAt = stamp();
      return visible(entry);
    },
    // Test-controlled reception/reporting; creating a request never runs Studio.
    report(id, { status, bootId, text = '', approvals = [] }) {
      const entry = get(id);
      entry.record.status = status;
      entry.record.bootId = bootId;
      entry.record.updatedAt = stamp();
      entry.record.report = { id, bootId, sequence: (entry.record.report?.sequence ?? 0) + 1, status, text, approvals: copy(approvals) };
    },
  };
}

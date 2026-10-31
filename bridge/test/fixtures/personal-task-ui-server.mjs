// Loopback-only, in-memory data for a dedicated UI-test simulator. It uses the
// real Bridge routes and task ledger, never a Linear credential or network API.
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { startBridge } from '../helpers.mjs';

const viewer = { id: 'fixture-viewer', name: 'Fixture Owner' };
const team = { id: 'fixture-team', name: 'Fixture Team', key: 'FIX' };
const state = { id: 'fixture-state', name: 'Todo', type: 'unstarted', team: { id: team.id } };
const initial = () => ({ id: 'linear:FIX-1', linearId: 'fixture-issue-1', sourceId: 'FIX-1', title: 'Fixture task',
  description: 'Fixture original', owner: { id: viewer.id, name: viewer.name, kind: 'owner' }, executor: null,
  status: state, team, project: null, milestone: null, cycle: null, parent: null, priority: 0, estimate: null,
  dueDate: null, labels: [], labelsComplete: true, updatedAt: '2026-11-01T00:00:00.000Z', url: null });

export async function startPersonalTaskUIFixture() {
  const tasks = [initial()];
  let conflictPending = true;
  const copy = (value) => structuredClone(value);
  const find = (id) => tasks.find((task) => [task.id, task.sourceId, task.linearId].includes(id));
  const personal = {
    async session() { return { viewer }; },
    async listTasks() { return { items: copy(tasks), nextCursor: null, observedAt: '2026-11-01T00:00:00.000Z', viewerId: viewer.id }; },
    async getTask(id) { const task = find(id); return task ? { task: copy(task), viewerId: viewer.id } : null; },
    async getTaskInSession(_session, id) {
      const task = find(id);
      if (task && conflictPending) {
        conflictPending = false; task.description = 'Fixture remote revision'; task.updatedAt = '2026-11-01T00:01:00.000Z';
      }
      return task ? { task: copy(task), viewerId: viewer.id } : null;
    },
    async listCollection() { return { items: [], nextCursor: null, observedAt: '2026-11-01T00:00:00.000Z', viewerId: viewer.id }; },
    async metadata() {
      const group = (items) => ({ items, complete: true });
      return { viewer, teams: group([team]), users: group([{ ...viewer, active: true }]), workflowStates: group([state]),
        issueLabels: group([]), projects: group([]), projectMilestones: group([]), cycles: group([]),
        priorities: [{ priority: 0, label: 'None' }, { priority: 1, label: 'Urgent' },
          { priority: 2, label: 'High' }, { priority: 3, label: 'Medium' }, { priority: 4, label: 'Low' }] };
    },
    async createIssue(_session, input) {
      const identifier = `FIX-${tasks.length + 1}`;
      const task = { ...initial(), id: `linear:${identifier}`, sourceId: identifier, linearId: input.id,
        title: input.title, description: input.description ?? '' };
      tasks.push(task);
      return { id: input.id, identifier, updatedAt: task.updatedAt };
    },
    async updateIssue(_session, id, input) {
      const task = find(id);
      if (!task) throw new Error('fixture target missing');
      Object.assign(task, input, { updatedAt: '2026-11-01T00:02:00.000Z' });
      return { id: task.linearId, identifier: task.sourceId, updatedAt: task.updatedAt };
    },
  };
  return startBridge({ tasks: { personal } });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const fixture = await startPersonalTaskUIFixture();
  const pairing = await fixture.pair();
  const credentialsFile = join(fixture.dir, 'simulator-pairing.json');
  writeFileSync(credentialsFile, JSON.stringify({ address: fixture.base, code: pairing.code }), { mode: 0o600 });
  // The short-lived fixture pairing code is stored locally, not printed.
  process.stdout.write(`Synthetic loopback Bridge is ready; pairing file: ${credentialsFile}\n`);
  const stop = async () => { await fixture.close(); process.exit(0); };
  process.on('SIGINT', stop); process.on('SIGTERM', stop);
}

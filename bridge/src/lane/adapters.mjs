import { appendFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { badRequest } from '../errors.mjs';
import { createPhoneUse } from '../phone-use/service.mjs';
import { daemonAdapter } from '../sessions/daemon.mjs';
import { readConversation } from '../sessions/history.mjs';
import { laneMissing, lanePath } from './guard.mjs';

// Refusals stand in for whole subsystems whose factories may themselves start
// I/O. Do not instantiate production factories and then discard their routes.
const blocked = new Map(Object.entries({
  drive: 'Google Drive', photos: 'Google Drive Picker', media: 'Google Drive',
  calendar: 'Google Calendar', tasks: 'Linear / Kanban', 'linear-owner-tasks': 'Linear',
  'personal-tasks': 'Linear', 'task-attachments': 'Linear / Drive',
  usage: 'usage feed', mac: 'storage / capacity', voice: 'audio worker',
  campaigns: 'campaign ledger', routines: 'Console jobs', studio: 'Studio', instructions: 'instruction files',
}));

export function refusedLaneEdge(path) {
  if (path === '/v1/brain/search') return 'Brain search';
  if (path === '/v1/brain/gates' || path === '/v1/brain/files') return 'Brain vault / policy / Syncthing';
  if (path.startsWith('/v1/brain/')) return 'Brain vault / policy / Syncthing';
  const area = path.split('/')[2];
  return blocked.get(area) ?? (area?.startsWith('task-') ? 'Linear' : undefined);
}

export const LANE_PROFILE = Object.freeze({ id: 'lab-echo', provider: 'lab', model: 'echo', effort: 'low', label: 'Lab Echo', fast: false });

export function laneRecorder(lane, edge) {
  const path = lanePath(lane.root, join(lane.sink, `${edge}.jsonl`), edge);
  return (event) => {
    mkdirSync(lane.sink, { mode: 0o700, recursive: true });
    // Do not persist input text, credentials, push tokens or audio in a sink.
    appendFileSync(path, `${JSON.stringify({ at: new Date().toISOString(), ...event })}\n`, { mode: 0o600 });
  };
}

export function laneAdapters(lane, store, now) {
  const notifyRecord = laneRecorder(lane, 'notify');
  const apnsRecord = laneRecorder(lane, 'apns');
  const workRecord = laneRecorder(lane, 'work');
  const notify = async ({ kind }) => { notifyRecord({ kind }); return { status: 'sent' }; };
  const connect = async () => {
    if (!lane.client) throw laneMissing('Work engine');
    const { connectEngine } = await import(pathToFileURL(lane.client).href);
    return connectEngine({ socket: lane.work });
  };
  const daemon = lane.work ? daemonAdapter({ connect, now }) : null;
  async function callWork(operation, fn) {
    const client = await connect();
    try {
      const result = await fn(client);
      workRecord({ operation });
      return result;
    } finally { await client.close(); }
  }
  const refuse = (edge) => () => { throw laneMissing(edge); };
  const adapter = {
    origin: 'lab-work',
    create: async ({ requestId, profile, cwd, task, title }) => {
      if (profile !== LANE_PROFILE.id) throw badRequest('model_choice_invalid', 'only the in-lane Lab Echo profile is available');
      const checkedCwd = lanePath(lane.root, cwd, 'Work cwd');
      const agent = await callWork('create', (client) => client.createAgent({
        idempotencyKey: requestId, provider: LANE_PROFILE.provider, model: LANE_PROFILE.model,
        thinkingOptionId: LANE_PROFILE.effort, cwd: checkedCwd, title, initialPrompt: task.prompt, naming: false,
      }));
      return { sessionId: agent.id, requested: { profile, ...LANE_PROFILE } };
    },
    status: refuse('Work engine'), send: refuse('Work engine'), stop: refuse('Work engine'),
  };
  return {
    sessions: {
      adapter, daemon, notify, homeCwd: lane.home,
      options: () => ({ profiles: [LANE_PROFILE], switchProfiles: [], defaultProfile: LANE_PROFILE.id, defaultMode: 'bypass' }),
      history: async (id) => {
        const result = await readConversation(id, connect);
        // Work messages may name real host files. Never open them to resolve
        // a preview; inline pictures remain in the Bridge's lane-owned store.
        return { ...result, items: result.items.map(({ localImages: _ignored, ...item }) => item) };
      },
      firstPrompt: async () => null,
      readOwner: refuse('host file attachments'),
    },
    decisions: { notify },
    workspaces: { roots: [], gitRun: refuse('workspace git'), createWorktree: refuse('Work CLI worktree') },
    skills: { roots: [], brainRoots: [lane.brain] },
    phoneUse: { service: createPhoneUse({ dir: store.dir, now, devices: (id) => store.read().devices?.[id] ?? null,
      push: async ({ kind }) => { apnsRecord({ kind: kind ?? 'phone-use' }); return { sent: true }; } }) },
  };
}

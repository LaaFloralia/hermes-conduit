// Registration point for the Bridge's business route modules.
//
// `http.mjs` imports this file once and knows nothing about projects,
// workspaces, sessions or later areas: each area owns its handlers, validation,
// storage and tests, and appends a single line to `businessRoutes`. That keeps
// parallel work on the same router to one import plus one spread.
//
// A route descriptor is:
//   { method, path | pattern, auth, scope?, idempotent?, handler(ctx) }
// `path` is an exact match, `pattern` is an anchored RegExp whose capture
// groups arrive as the handler's `params` array (same shape as drive.mjs).
// Handlers return `{status, data, headers?}` or throw a BridgeError.

import { personalAgentAdapter } from '../sessions/adapter.mjs';
import { createSessionService } from '../sessions/service.mjs';
import { createSessionStore } from '../sessions/store.mjs';
import { createProjectRoutes, createProjectStore } from './projects.mjs';
import { createSessionRoutes } from './sessions.mjs';
import { createWorkspaceRoutes, createWorkspaceStore, workspaceServiceFromOptions } from './workspaces.mjs';
import { taskRoutes } from './tasks.mjs';
import { brainRoutes } from './brain.mjs';

export function businessRoutes({ store, now = () => Date.now(), options = {} } = {}) {
  const projectStore = createProjectStore({ file: `${store.dir}/projects.json`, now });
  const workspaceStore = createWorkspaceStore({ file: `${store.dir}/workspaces.json`, now });
  const workspaceOptions = options.workspaces ?? {};
  // Sessions resolve their cwd through the same inventory the workspace
  // endpoints use, so a session can never point outside the allowlisted roots.
  const workspaceService = workspaceOptions.service ?? workspaceServiceFromOptions({ now, ...workspaceOptions });
  const sessionOptions = options.sessions ?? {};

  const sessionStore = createSessionStore({
    file: `${store.dir}/sessions.json`,
    now,
    retentionMs: sessionOptions.eventRetentionMs,
  });
  const sessionService = sessionOptions.service ?? createSessionService({
    ...sessionOptions,
    sessionStore,
    retentionMs: sessionOptions.eventRetentionMs,
    adapter: sessionOptions.adapter ?? personalAgentAdapter(),
    findWorkspace: sessionOptions.findWorkspace ?? ((id) => workspaceService.find(id)),
    findProject: sessionOptions.findProject ?? ((id) => projectStore.get(id)),
    now,
  });

  return [
    ...taskRoutes({ ...(options.tasks ?? {}), now }),
    ...brainRoutes({ store, now, options: options.brain ?? {} }),
    ...createProjectRoutes({ projects: projectStore, now }),
    ...createWorkspaceRoutes({
      workspaceStore,
      service: workspaceService,
      findProject: (id) => projectStore.get(id),
      now,
      ...workspaceOptions,
    }),
    ...createSessionRoutes({ sessions: sessionService }),
  ];
}

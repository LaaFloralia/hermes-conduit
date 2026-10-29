// Registration point for the Bridge's business route modules.
//
// `http.mjs` imports this file once and knows nothing about projects,
// workspaces or later areas: each area owns its handlers, validation, storage
// and tests, and appends a single line to `businessRoutes`. That keeps parallel
// work on the same router to one import plus one spread.
//
// A route descriptor is:
//   { method, path | pattern, auth, scope?, idempotent?, handler(ctx) }
// `path` is an exact match, `pattern` is an anchored RegExp whose capture
// groups arrive as the handler's `params` array (same shape as drive.mjs).
// Handlers return `{status, data, headers?}` or throw a BridgeError.

import { createProjectRoutes, createProjectStore } from './projects.mjs';
import { createWorkspaceRoutes, createWorkspaceStore } from './workspaces.mjs';
import { taskRoutes } from './tasks.mjs';

export function businessRoutes({ store, now = () => Date.now(), options = {} } = {}) {
  const projectStore = createProjectStore({ file: `${store.dir}/projects.json`, now });
  const workspaceStore = createWorkspaceStore({ file: `${store.dir}/workspaces.json`, now });

  return [
    ...taskRoutes({ ...(options.tasks ?? {}), now }),
    ...createProjectRoutes({ projects: projectStore, now }),
    ...createWorkspaceRoutes({
      workspaceStore,
      findProject: (id) => projectStore.get(id),
      now,
      ...(options.workspaces ?? {}),
    }),
  ];
}

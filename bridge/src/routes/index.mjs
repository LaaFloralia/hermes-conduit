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

import { flushOwnerNotifications } from '../notify/index.mjs';
import { daemonAdapter } from '../sessions/daemon.mjs';
import { personalAgentAdapter } from '../sessions/adapter.mjs';
import { createSessionService } from '../sessions/service.mjs';
import { createSessionStore } from '../sessions/store.mjs';
import { resolveModelsFile, sessionOptionsReader } from '../sessions/options.mjs';
import { createProjectRoutes, createProjectStore } from './projects.mjs';
import { createSessionRoutes } from './sessions.mjs';
import { createWorkspaceRoutes, createWorkspaceStore, workspaceServiceFromOptions } from './workspaces.mjs';
import { taskRoutes } from './tasks.mjs';
import { personalTaskRoutes } from './personal-tasks.mjs';
import { linearOwnerTaskRoutes } from './linear-owner-tasks.mjs';
import { skillRoutes } from './skills.mjs';
import { ownerTaskRoutes } from './owner-tasks.mjs';
import { createOwnerTaskStore } from '../tasks/owner-store.mjs';
import { createOwnerTaskService } from '../tasks/owner-service.mjs';
import { brainRoutes } from './brain.mjs';
import { usageRoutes } from './usage.mjs';
import { studioRoutes } from './studio.mjs';
import { createGoogleCalendar } from '../calendar/google.mjs';
import { createCalendarReminders } from '../calendar/reminders.mjs';
import { calendarRoutes } from './calendar.mjs';
import { routineRoutes } from './routines.mjs';
import { instructionRoutes } from './instructions.mjs';
import { voiceRoutes } from './voice.mjs';
import { deviceRoutes } from './devices.mjs';

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
    daemon: sessionOptions.daemon ?? (sessionOptions.live ? daemonAdapter({ now }) : null),
    retentionMs: sessionOptions.eventRetentionMs,
    adapter: sessionOptions.adapter ?? personalAgentAdapter(),
    findWorkspace: sessionOptions.findWorkspace ?? ((id) => workspaceService.find(id)),
    findProject: sessionOptions.findProject ?? ((id) => projectStore.get(id)),
    resolveProjectInstructions: sessionOptions.resolveProjectInstructions
      ?? ((project) => projectStore.instructionsFor(project)),
    resolveProjectFiles: sessionOptions.resolveProjectFiles ?? ((project) => projectStore.filesFor(project)),
    now,
  });

  if (!sessionOptions.service && sessionOptions.live) {
    const timer = setInterval(() => { sessionService.syncDaemon().catch(() => {}); }, 5000);
    timer.unref();
    sessionOptions.registerCleanup?.(() => clearInterval(timer));
    sessionService.syncDaemon().catch(() => {});
    const delivery = setInterval(() => { flushOwnerNotifications().catch(() => {}); }, 30_000);
    delivery.unref();
    sessionOptions.registerCleanup?.(() => clearInterval(delivery));
  }

  const ownerTasks = options.ownerTasks ?? {};
  const ownerTaskStore = ownerTasks.store
    ?? createOwnerTaskStore({ dir: ownerTasks.dir ?? store.dir, now, lockTimeoutMs: ownerTasks.lockTimeoutMs });
  const ownerTaskService = ownerTasks.service ?? createOwnerTaskService({ store: ownerTaskStore, now });

  const calendarOptions = options.calendar ?? {};
  const calendarService = calendarOptions.service ?? createGoogleCalendar();
  // Opt-in until the parent has completed Google consent and notification setup.
  if (calendarOptions.remindersEnabled ?? process.env.LAA_GOOGLE_REMINDERS_ENABLED === '1') {
    const reminders = createCalendarReminders({ service: calendarService, now,
      file: `${store.dir}/calendar-reminders.json`, ...calendarOptions.reminders });
    const tick = () => { reminders.tick().catch(() => {}); };
    tick(); // Catch up once at startup, rather than waiting for the first interval.
    const timer = setInterval(tick, 30_000);
    timer.unref();
    calendarOptions.registerCleanup?.(() => clearInterval(timer));
  }

  return [
    ...taskRoutes({ ...(options.tasks ?? {}), now }),
    ...linearOwnerTaskRoutes(options.linearOwnerTasks ?? {}),
    ...personalTaskRoutes({ ...(options.tasks ?? {}), store, now }),
    ...skillRoutes(options.skills ?? {}),
    ...ownerTaskRoutes({ service: ownerTaskService }),
    ...brainRoutes({ store, now, options: options.brain ?? {} }),
    ...createProjectRoutes({ projects: projectStore, now }),
    ...createWorkspaceRoutes({
      workspaceStore,
      service: workspaceService,
      findProject: (id) => projectStore.get(id),
      now,
      ...workspaceOptions,
    }),
    ...createSessionRoutes({
      sessions: sessionService,
      sessionOptions: sessionOptions.options ?? sessionOptionsReader({ file: sessionOptions.modelsFile ?? resolveModelsFile() }),
    }),
    ...usageRoutes({ ...(options.usage ?? {}), now }),
    ...studioRoutes(options.studio ?? {}),
    ...routineRoutes(options.routines ?? {}),
    ...calendarRoutes({ ...calendarOptions, service: calendarService }),
    // Disabled in production pending independent review; explicit injection is for tests.
    ...(options.instructions?.enabled === true
      ? instructionRoutes({ backupDir: `${store.dir}/instruction-backups`, ...options.instructions })
      : []),
    ...voiceRoutes(options.voice ?? {}),
    ...deviceRoutes({ store, now }),
  ];
}

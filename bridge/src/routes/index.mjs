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

import { notificationRoutes } from './notifications.mjs';
import { notifyOwner, flushOwnerNotifications } from '../notify/index.mjs';
import { daemonAdapter } from '../sessions/daemon.mjs';
import { personalAgentAdapter } from '../sessions/adapter.mjs';
import { createSessionService } from '../sessions/service.mjs';
import { createSessionStore } from '../sessions/store.mjs';
import { resolveModelsFile, sessionOptionsReader, sharedProviderAvailability } from '../sessions/options.mjs';
import { createProjectRoutes, createProjectStore, DEFAULT_PROJECT_ID } from './projects.mjs';
import { assignSessionProject, projectSessionViews } from '../sessions/projects.mjs';
import { createSessionRoutes } from './sessions.mjs';
import { createWorkspaceRoutes, createWorkspaceStore, workspaceServiceFromOptions } from './workspaces.mjs';
import { taskRoutes } from './tasks.mjs';
import { personalTaskRoutes } from './personal-tasks.mjs';
import { linearOwnerTaskRoutes } from './linear-owner-tasks.mjs';
import { createLinearOwnerTaskSource } from '../tasks/linear-owner.mjs';
import { createTaskRunStore, createTaskDispatchService, taskCleanup } from '../tasks/dispatch.mjs';
import { skillRoutes } from './skills.mjs';
import { ownerTaskRoutes } from './owner-tasks.mjs';
import { habitRoutes } from './habits.mjs';
import { createOwnerTaskStore } from '../tasks/owner-store.mjs';
import { createOwnerTaskService } from '../tasks/owner-service.mjs';
import { brainRoutes } from './brain.mjs';
import { usageRoutes } from './usage.mjs';
import { laneUsageRoutes } from '../lane/usage.mjs';
import { studioRoutes } from './studio.mjs';
import { createGoogleCalendar } from '../calendar/google.mjs';
import { createCalendarReminders } from '../calendar/reminders.mjs';
import { calendarRoutes } from './calendar.mjs';
import { routineRoutes } from './routines.mjs';
import { staffRoutes } from './staff.mjs';
import { instructionRoutes } from './instructions.mjs';
import { voiceRoutes } from './voice.mjs';
import { voiceLeaseRoutes } from './voice-lease.mjs';
import { deviceRoutes } from './devices.mjs';
import { createDecisionStore } from '../decisions/store.mjs';
import { createDecisionService, isWaiting, mayDeliverDecisionNotice, onDecisionBoard } from '../decisions/service.mjs';
import { createDecisionRoutes } from './decisions.mjs';
import { monetRoutes, resolveMonetTrigger } from './monet.mjs';
import { createCompletionReporter } from '../notify/completion-report.mjs';
import { createRefService } from '../refs/service.mjs';
import { projectRefItem, sessionRefItem } from '../refs/items.mjs';
import { refRoutes } from '../refs/routes.mjs';
import { ownerProfileRoutes } from './owner-profile.mjs';
import { createPhoneUse } from '../phone-use/service.mjs';
import { phoneUseRoutes } from '../phone-use/routes.mjs';
import { deviceReportRoutes } from './device-reports.mjs';
import { campaignRoutes } from './campaigns.mjs';

export function businessRoutes({ store, now = () => Date.now(), options = {}, lane = null } = {}) {
  const projectStore = createProjectStore({ file: `${store.dir}/projects.json`, now });
  const workspaceStore = createWorkspaceStore({ file: `${store.dir}/workspaces.json`, now });
  const workspaceOptions = options.workspaces ?? {};
  // Sessions resolve their cwd through the same inventory the workspace
  // endpoints use, so a session can never point outside the allowlisted roots.
  const workspaceService = workspaceOptions.service ?? workspaceServiceFromOptions({ now, ...workspaceOptions });
  const sessionOptions = options.sessions ?? {};
  // One registry per state directory. An injected instance lets a test drive
  // observation directly; the server-owned one reconciles itself in live mode.
  const refs = options.refs ?? createRefService({
    file: `${store.dir}/refs.json`,
    now,
    live: sessionOptions.live === true,
    log: options.log ?? null,
  });

  const sessionStore = createSessionStore({
    file: `${store.dir}/sessions.json`,
    now,
    retentionMs: sessionOptions.eventRetentionMs,
  });
  if (sessionStore.all().some((row) => !row.projectId)) {
    projectStore.ensureDefault();
    sessionStore.backfillProjects(DEFAULT_PROJECT_ID);
  }
  const daemon = sessionOptions.daemon ?? (sessionOptions.live ? daemonAdapter({ now }) : null);
  const sessionChoices = sessionOptions.options ?? sessionOptionsReader({ file: sessionOptions.modelsFile ?? resolveModelsFile(),
    availability: sessionOptions.availability ?? (sessionOptions.live ? sharedProviderAvailability() : null) });
  let sessionService;
  const decisionsOptions = options.decisions ?? {};
  const decisionStore = decisionsOptions.store ?? createDecisionStore({ dir: store.dir, now });
  const decisions = decisionsOptions.service ?? createDecisionService({
    refs: (kind, key) => refs.refFor(kind, key), observeRefs: () => refs.observeSource('decision'), log: options.log,
    ...decisionsOptions, store: decisionStore, sessionStore,
    sessions: { syncDaemon: () => sessionService.syncDaemon(), decision: (id) => sessionService.decision(id) }, daemon, now,
  });
  sessionService = sessionOptions.service ?? createSessionService({
    ...sessionOptions,
    sessionStore,
    choices: sessionChoices,
    daemon,
    decisions,
    retentionMs: sessionOptions.eventRetentionMs,
    adapter: sessionOptions.adapter ?? personalAgentAdapter(),
    findWorkspace: sessionOptions.findWorkspace ?? ((id) => workspaceService.find(id)),
    findProject: sessionOptions.findProject ?? ((id) => projectStore.get(id)),
    defaultProject: () => projectStore.ensureDefault(),
    activeProjectIds: () => new Set(projectStore.list().filter((row) => !row.archivedAt).map((row) => row.id)),
    moveProject: (input) => assignSessionProject({ projects: projectStore, sessionStore, ...input }),
    resolveProjectInstructions: sessionOptions.resolveProjectInstructions
      ?? ((project) => projectStore.instructionsFor(project)),
    resolveProjectFiles: sessionOptions.resolveProjectFiles ?? ((project) => projectStore.filesFor(project)),
    now,
  });

  refs.registerSource('session', () => sessionService.visibleRecords()
    .map((record) => sessionRefItem(record, refs.refFor)));
  refs.registerSource('project', () => projectStore.list()
    .filter((project) => !project.archivedAt)
    .map(projectRefItem));
  // Keep J stable while an item is open, needs delivery, or has a Monet
  // answer the owner can still change.
  refs.registerSource('decision', () => decisionStore.all()
    .filter(onDecisionBoard)
    .map((d) => ({ key: d.id, title: d.title, createdAt: d.createdAt, external: { sessionId: d.source?.sessionId ?? null } })));

  if (!sessionOptions.service && sessionOptions.live) {
    const timer = setInterval(() => { sessionService.syncDaemon().catch(() => {}); }, 5000);
    timer.unref();
    sessionOptions.registerCleanup?.(() => clearInterval(timer));
    sessionService.syncDaemon().catch(() => {});
    const delivery = setInterval(() => {
      flushOwnerNotifications((kind, link) => mayDeliverDecisionNotice(kind, link, decisionStore)).catch(() => {});
    }, 30_000);
    delivery.unref();
    sessionOptions.registerCleanup?.(() => clearInterval(delivery));
    // Answers held for a busy conversation go out when its turn ends, and
    // survive a restart: the first pass runs now.
    const held = () => { decisions.deliverWaiting?.().catch(() => {}); };
    const waiting = setInterval(held, 5000);
    waiting.unref();
    sessionOptions.registerCleanup?.(() => clearInterval(waiting));
    held();
  }

  const ownerTasks = options.ownerTasks ?? {};
  const ownerTaskStore = ownerTasks.store
    ?? createOwnerTaskStore({ dir: ownerTasks.dir ?? store.dir, now, lockTimeoutMs: ownerTasks.lockTimeoutMs });
  const ownerTaskService = ownerTasks.service ?? createOwnerTaskService({ store: ownerTaskStore, now });

  const calendarOptions = options.calendar ?? {};
  const calendarService = lane ? null : calendarOptions.service ?? createGoogleCalendar();
  // Opt-in until the parent has completed Google consent and notification setup.
  if (!lane && (calendarOptions.remindersEnabled ?? process.env.LAA_GOOGLE_REMINDERS_ENABLED === '1')) {
    const reminders = createCalendarReminders({ service: calendarService, now,
      file: `${store.dir}/calendar-reminders.json`, ...calendarOptions.reminders });
    const tick = () => { reminders.tick().catch(() => {}); };
    tick(); // Catch up once at startup, rather than waiting for the first interval.
    const timer = setInterval(tick, 30_000);
    timer.unref();
    calendarOptions.registerCleanup?.(() => clearInterval(timer));
  }

  sessionOptions.registerCleanup?.(() => refs.stop());
  // The follow-up queue's timer belongs to the session service; a closed server
  // must not leave it ticking.
  if (!sessionOptions.service) sessionOptions.registerCleanup?.(() => sessionService.close?.());

  const linearOptions = options.linearOwnerTasks ?? {};
  const linearTasks = lane ? null : linearOptions.source ?? createLinearOwnerTaskSource();
  const taskDispatch = lane ? null : linearOptions.dispatch ?? createTaskDispatchService({
    ...linearOptions, store: linearOptions.runStore ?? createTaskRunStore({ dir: store.dir, now }), tasks: linearTasks,
    sessions: sessionService, sessionStore, decisionStore, sessionOptions: sessionChoices, refs, daemon, now,
    cleanup: linearOptions.cleanup ?? (() => taskCleanup({ log: options.log })), log: options.log,
  });
  if (sessionOptions.live) {
    const tick = () => { taskDispatch.tick().catch(() => {}); };
    const timer = setInterval(tick, 30_000); timer.unref(); tick();
    sessionOptions.registerCleanup?.(() => clearInterval(timer));
  }

  const reportOptions = options.monet ?? {};
  const liveReports = !lane && sessionOptions.live === true;
  const report = createCompletionReporter({
    notify: reportOptions.notify ?? (liveReports ? notifyOwner : sessionOptions.notify ?? (() => ({ delivered: false, reason: 'not_configured' }))),
    readProject: async (id) => { await sessionService.syncDaemon(); return projectStore.get(id); },
    readOpenDecisions: () => decisionStore.all(), readSessions: () => sessionStore.all(), resolveCaller: resolveMonetTrigger,
  });
  const routes = [
    ...monetRoutes({ reporter: report, tokenHash: reportOptions.tokenHash ?? (liveReports ? process.env.LAA_BRIDGE_MONET_TOKEN_SHA256 : null) }),
    ...notificationRoutes({ file: `${store.dir}/notification-preferences.json`, now }),
    ...createDecisionRoutes({ service: decisions }),
    ...(!lane ? [
      ...taskRoutes({ ...(options.tasks ?? {}), now }),
      ...linearOwnerTaskRoutes({ ...linearOptions, source: linearTasks, dispatch: taskDispatch, refs }),
      ...personalTaskRoutes({ ...(options.tasks ?? {}), store, now }),
    ] : []),
    ...skillRoutes({ ...(options.skills ?? {}), refs }),
    ...staffRoutes({ ...options.staff, log: options.log, lane }),
    ...ownerTaskRoutes({ service: ownerTaskService }),
    ...habitRoutes({ dir: store.dir, now, ...options.habits }),
    ...(!lane ? brainRoutes({ store, now, options: options.brain ?? {} }) : []),
    ...createProjectRoutes({ projects: projectStore, now, refs, choices: sessionChoices,
      projectSessions: (id) => projectSessionViews(sessionStore, id,
        decisionStore.all().filter((row) => row.status === 'open' || isWaiting(row)
          || (row.status === 'answered' && row.delivery?.state === 'failed'))),
      sessionMembership: () => new Map(sessionStore.all().map((row) => [row.id, row.projectId])),
    }),
    ...createWorkspaceRoutes({
      workspaceStore,
      service: workspaceService,
      findProject: (id) => projectStore.get(id),
      now,
      ...workspaceOptions,
    }),
    ...createSessionRoutes({
      sessions: sessionService,
      refs,
      sessionOptions: sessionChoices,
      daemon,
    }),
    ...(lane ? laneUsageRoutes(lane, store.dir, now) : []),
    ...(!lane ? [
      ...usageRoutes({ collectMacBook: sessionOptions.live === true,
        routineFile: `${store.dir}/usage-routine.json`, ...(options.usage ?? {}), now }),
      ...studioRoutes({ store, now, registerCleanup: sessionOptions.registerCleanup, ...options.studio }),
      ...routineRoutes({ ...(options.routines ?? {}), refs }),
      ...calendarRoutes({ ...calendarOptions, service: calendarService }),
      // Disabled in production pending independent review; explicit injection is for tests.
      ...(options.instructions?.enabled === true
        ? instructionRoutes({ backupDir: `${store.dir}/instruction-backups`, ...options.instructions })
        : []),
      ...voiceRoutes(options.voice ?? {}), ...voiceLeaseRoutes(options.voiceLease),
      ...campaignRoutes(options.campaigns ?? {}),
    ] : []),
    ...deviceRoutes({ store, now }),
    ...refRoutes({ refs }),
    ...ownerProfileRoutes({ dir: store.dir }),
    ...deviceReportRoutes({ dir: store.dir, now }),
    ...phoneUseRoutes({ service: options.phoneUse?.service ?? createPhoneUse({ dir: store.dir, now, devices: (id) => store.read().devices?.[id] ?? null }) }),
  ];
  // Start after every factory has registered its source: the first live pass
  // must cover all five kinds, not only sessions and projects.
  refs.start();
  return routes;
}

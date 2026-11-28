// Builds the requirement flow and Monet's inbox for one Bridge process and
// returns what routes/index.mjs needs: the routes, the session-transition hook
// and a starter for the timer. Kept here so the route table stays a few lines.

import { join } from 'node:path';
import { createMonetInbox } from '../monet/inbox.mjs';
import { assignSessionProject } from '../sessions/projects.mjs';
import { flowRoutes } from '../routes/flow.mjs';
import { flowConfigReader } from './config.mjs';
import { createFlowPipeline } from './pipeline.mjs';
import { createFlowRequirements } from './requirements.mjs';
import { createRunners } from './runners.mjs';
import { createFlowStore } from './store.mjs';

export function createMonetFlow({ dir, now, options = {}, projects, sessionStore, sessions, decisionStore, decisions, findingStore, reporter, tokenHash, log = null }) {
  const config = options.config ? () => options.config : flowConfigReader(options.configFile ? { file: options.configFile } : { file: options.live ? undefined : join(dir, 'requirement-flow.json') });
  const inbox = options.inbox ?? createMonetInbox({ dir, now, leaseMs: config().inbox.leaseMs, maxAttempts: config().inbox.maxAttempts });
  const flows = options.store ?? createFlowStore({ dir, now });
  const requirements = createFlowRequirements({ projects, now });
  const runners = options.runners ?? createRunners({ config, sessions: { createSession: (input) => sessions().createSession(input),
    conversation: (id, page) => sessions().conversation(id, page), sendMessage: (input) => sessions().sendMessage(input), stopSession: (id) => sessions().stopSession(id) },
  attach: (input) => assignSessionProject({ projects, sessionStore, ...input }), ...(options.oneshot ? { oneshot: options.oneshot } : {}) });
  const pipeline = createFlowPipeline({ flows, inbox, requirements, projects, sessionStore, decisionStore, decisions, findingStore, runners, config, reporter, now, log });
  return {
    pipeline, inbox, flows, config,
    routes: flowRoutes({ pipeline, flows, inbox, tokenHash }),
    onTransition: (transition) => pipeline.onTransition(transition),
    // The timer: scans the board and the findings, consumes what Bridge code handles and moves each open flow one step.
    start(registerCleanup) {
      const tick = () => { pipeline.tick().catch(() => {}); };
      const timer = setInterval(tick, config().tickMs);
      timer.unref();
      registerCleanup?.(() => clearInterval(timer));
      tick();
    },
  };
}

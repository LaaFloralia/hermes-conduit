// The flow's two ways of asking a model: a staff one-shot (`hermes -p <profile>
// -z <prompt>`, the staff member's own Chat profile answering once, no session
// kept) and Work sessions for the adviser and the implementation packages.
//
// Sessions go through the Bridge's own session service, so they are ordinary
// rows of the Project: idempotent per requestId, visible in the app and
// reported back through the same phase changes as any other session.

import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { parseMeetingReply } from './parse.mjs';

// The Bridge runs under launchd with PATH=/usr/bin:/bin:/usr/sbin:/sbin, so the
// binary is always an absolute path from the configuration.
export function runHermesOneshot({ bin, profile, prompt, timeoutMs, outputLimitBytes = 65_536, toolsets = null, spawnImpl = spawn, env = process.env }) {
  return new Promise((resolve) => {
    const started = Date.now();
    const done = (state, text = '', reason = null) => resolve({ state, text, reason, ms: Date.now() - started });
    if (!bin || !existsSync(bin)) { done('absent', '', 'hermes_missing'); return; }
    let child;
    try {
      child = spawnImpl(bin, ['-p', profile, ...(toolsets ? ['-t', toolsets] : []), '-z', prompt], { stdio: ['ignore', 'pipe', 'pipe'], env: { ...env, HOME: env.HOME } });
    } catch { done('absent', '', 'spawn_failed'); return; }
    let out = '', size = 0, settled = false;
    const finish = (state, reason) => { if (settled) return; settled = true; clearTimeout(timer); done(state, out, reason); };
    const timer = setTimeout(() => { child.kill('SIGKILL'); finish('timeout', 'timeout'); }, timeoutMs);
    child.stdout.on('data', (chunk) => {
      size += chunk.length;
      if (size <= outputLimitBytes) out += chunk;
      else if (!settled) { child.kill('SIGKILL'); finish('done', 'output_truncated'); }
    });
    // Drained and dropped: a provider error on stderr is not staff input.
    child.stderr.on('data', () => {});
    child.on('error', () => finish('absent', 'spawn_failed'));
    child.on('close', (code) => finish(code === 0 && out.trim() ? 'done' : 'absent', code === 0 ? 'empty_reply' : `exit_${code}`));
  });
}

export function createRunners({ config, sessions, attach = null, oneshot = runHermesOneshot }) {
  return {
    // One staff member's contribution. Never throws: an unusable reply is an
    // absent member, and the flow goes on with the others.
    async runStaff({ member, prompt }) {
      const cfg = config().staff;
      const result = await oneshot({ bin: cfg.hermesBin, profile: member.profile, prompt, timeoutMs: cfg.timeoutMs, outputLimitBytes: cfg.outputLimitBytes, toolsets: cfg.toolsets });
      if (result.state !== 'done') return { state: result.state, reason: result.reason, ms: result.ms };
      const parsed = parseMeetingReply(result.text);
      if (!parsed.ok) return { state: 'absent', reason: 'reply_unparsed', ms: result.ms };
      return { state: 'done', reason: result.reason === 'output_truncated' ? result.reason : null, ms: result.ms, ...parsed.reply };
    },
    // Start (or find again) a Work session of the flow. `requestId` makes a
    // retried step reconcile with the session it already started.
    async startSession({ requestId, projectId, requirementId = null, profile, name, task }) {
      const { session, created } = await sessions.createSession({ deviceId: 'requirement-flow', body: {
        requestId, projectId, profile, name, mode: config().session.mode,
        prompt: task.prompt, purpose: task.purpose, completion: task.completion, scope: task.scope, returnTo: task.returnTo,
      } });
      if (requirementId && attach) attach({ projectId, sessionId: session.id, requirementId });
      return { sessionId: session.id, created };
    },
    async lastReply(sessionId) {
      const page = await sessions.conversation(sessionId, { limit: 8 });
      for (let i = page.items.length - 1; i >= 0; i -= 1) {
        if (page.items[i].role === 'assistant' && page.items[i].text?.trim()) return page.items[i].text;
      }
      return '';
    },
    async send({ sessionId, messageId, text }) {
      return sessions.sendMessage({ id: sessionId, body: { message: text, messageId, delivery: 'queue' } });
    },
    async stop(sessionId) {
      return sessions.stopSession(sessionId);
    },
  };
}

// One notification egress for every Bridge area. The installed Hermes plugin
// owns the pairing, redaction, encryption and relay authentication.
import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createJsonFile } from '../routes/state-file.mjs';
import { resolveStateDir } from '../config.mjs';

function pythonPath() {
  try {
    const launcher = readFileSync(join(homedir(), '.local/share/hermes-agent/.hermes/bin/hermes'), 'utf8');
    return launcher.match(/^exec (\/\S+) -I /m)?.[1];
  } catch { return null; }
}
export function deliverWithPlugin(event) {
  const python = pythonPath();
  if (!python || !existsSync(python)) return Promise.resolve({ delivered: false, reason: 'not_configured' });
  return new Promise((resolve) => {
    const child = spawn(python, ['-I', fileURLToPath(new URL('./deliver.py', import.meta.url))], { stdio: ['pipe', 'pipe', 'ignore'] });
    let output = '', done = false;
    const finish = (result) => { if (!done) { done = true; clearTimeout(timer); resolve(result); } };
    const timer = setTimeout(() => { child.kill(); finish({ delivered: false, reason: 'delivery_timeout' }); }, 20_000);
    child.stdout.on('data', (chunk) => { if (output.length < 4096) output += chunk; });
    child.on('error', () => finish({ delivered: false, reason: 'delivery_unavailable' }));
    child.on('close', () => { try { finish(JSON.parse(output)); } catch { finish({ delivered: false, reason: 'delivery_unavailable' }); } });
    child.stdin.on('error', () => {});
    child.stdin.end(JSON.stringify(event));
  });
}
export function createOwnerNotifier({ deliver = deliverWithPlugin, file = join(resolveStateDir(), 'owner-notifications.json'), now = () => Date.now() } = {}) {
  const state = createJsonFile({ file, initial: () => ({ delivered: {}, pending: {} }) });
  const inflight = new Map();
  async function deliverPending(key, event) {
    if (inflight.has(key)) return inflight.get(key);
    if (inflight.size >= 2) return { delivered: false, reason: "queued" };
    const pending = (async () => {
      let result;
      try { result = await deliver(event); } catch { result = { delivered: false, reason: "delivery_unavailable" }; }
      if (result.delivered) state.mutate((s) => {
        s.delivered[key] = now();
        delete s.pending?.[key];
        s.delivered = Object.fromEntries(Object.entries(s.delivered).filter(([, at]) => now() - at < 7 * 86400_000).slice(-2000));
      });
      return result;
    })().finally(() => inflight.delete(key));
    inflight.set(key, pending);
    return pending;
  }
  const notify = async ({ kind, title, body, deepLink, dedupeKey } = {}) => {
    if (typeof kind !== 'string' || typeof title !== 'string' || typeof body !== 'string'
      || typeof deepLink !== 'string' || !/^laa:\/\/(work|today|brain|assets)(\/|$)/.test(deepLink) || deepLink.length > 400
      || typeof dedupeKey !== 'string' || !dedupeKey) return { delivered: false, reason: 'invalid_notification' };
    const key = createHash('sha256').update(dedupeKey).digest('hex');
    if (state.read().delivered[key]) return { delivered: false, reason: 'duplicate' };
    const event = { type: 'response.ready', event_id: `laa-bridge:${key}`, profile: 'laa-monet',
      session_id: `laa-bridge:${deepLink}`, title: title.slice(0, 120), body: body.slice(0, 500) };
    state.mutate((s) => { (s.pending ??= {})[key] ??= { event, queuedAt: now() }; });
    return deliverPending(key, event);
  };
  notify.flush = async () => {
    const rows = Object.entries(state.read().pending ?? {});
    for (const [key, item] of rows) {
      if (now() - item.queuedAt > 7 * 86400_000) { state.mutate((s) => { delete s.pending[key]; }); continue; }
      await deliverPending(key, item.event);
    }
  };
  return notify;
}
let notifier;
export async function notifyOwner(payload) { notifier ??= createOwnerNotifier(); return notifier(payload); }

export async function flushOwnerNotifications() { notifier ??= createOwnerNotifier(); await notifier.flush(); }

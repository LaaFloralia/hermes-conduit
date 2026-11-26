// One notification egress for every Bridge area. The installed Hermes plugin
// owns the pairing, redaction, encryption and relay authentication.
import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { createNotificationPreferences, notificationLevel } from './preferences.mjs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createJsonFile } from '../routes/state-file.mjs';
import { resolveStateDir } from '../config.mjs';
import { assertOwnerSurface } from '../owner-surface.mjs';

// Keep complete non-option metadata; only labels may be shortened.
export function encodeNotificationSessionId(deepLink, kind, meta) {
  const legacy = `laa-bridge:${deepLink}`;
  if (Buffer.byteLength(legacy, 'utf8') > 512) return null;
  const m = { ...(meta && Object.getPrototypeOf(meta) === Object.prototype ? meta : {}), v: 1, k: kind };
  const encode = () => `${legacy}#${Buffer.from(JSON.stringify(m)).toString('base64url')}`;
  const fits = () => Buffer.byteLength(encode(), 'utf8') <= 512;
  if (fits()) return encode();
  if (Array.isArray(m.o)) {
    const labels = m.o.map((label) => Array.from(String(label)));
    for (let length = Math.max(0, ...labels.map((l) => l.length)) - 1; length >= 1; length--) {
      m.o = labels.map((l) => l.length > length ? l.slice(0, length - 1).join('') + '…' : l.join(''));
      if (fits()) return encode();
    }
    delete m.o;
    if (fits()) return encode();
  }
  return legacy;
}

export function pythonPath() {
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
export function createOwnerNotifier({ deliver = deliverWithPlugin, file = join(resolveStateDir(), 'owner-notifications.json'), now = () => Date.now(), preferences = createNotificationPreferences({ file: join(dirname(file), 'notification-preferences.json'), now }) } = {}) {
  const state = createJsonFile({ file, initial: () => ({ delivered: {}, pending: {} }) });
  // Monet reports are at most once per key for good (C-2.2), so they get their own ledger
  // outside the 7-day / 2000-row window that bounds every other kind's dedupe.
  const REPORT = 'monet.report', REPORT_LEDGER_MAX = 10_000;
  const inflight = new Map();
  async function deliverPending(key, event) {
    if (inflight.has(key)) return inflight.get(key);
    if (inflight.size >= 2) return { delivered: false, reason: "queued" };
    const pending = (async () => {
      let result;
      try { result = await deliver(event); } catch { result = { delivered: false, reason: "delivery_unavailable" }; }
      if (result.delivered) state.mutate((s) => {
        s.delivered[key] = now();
        if (s.pending?.[key]?.kind === REPORT) (s.reports ??= {})[key] = now();
        delete s.pending?.[key];
        s.delivered = Object.fromEntries(Object.entries(s.delivered).filter(([, at]) => now() - at < 7 * 86400_000).slice(-2000));
      });
      return result;
    })().finally(() => inflight.delete(key));
    inflight.set(key, pending);
    return pending;
  }
  const notify = async ({ kind, title, body, deepLink, dedupeKey, meta, author } = {}) => {
    if (typeof kind !== 'string' || typeof title !== 'string' || typeof body !== 'string'
      || typeof deepLink !== 'string' || !/^laa:\/\/(work|today|brain|assets)(\/|$)/.test(deepLink) || deepLink.length > 400
      || typeof dedupeKey !== 'string' || !dedupeKey) return { delivered: false, reason: 'invalid_notification' };
    // A report's key is derived from its request, so a replay can never mint a second key.
    if (kind === REPORT && !(typeof meta?.projectId === 'string' && meta.projectId && typeof meta?.requestId === 'string' && meta.requestId
      && dedupeKey === `${REPORT}:${meta.projectId}:${meta.requestId}`)) return { delivered: false, reason: 'invalid_notification' };
    const level = notificationLevel(kind, preferences);
    if (level === 'off') return { delivered: false, reason: 'muted' };
    if (author === 'agent' || kind === REPORT) {
      assertOwnerSurface(title, 'title');
      assertOwnerSurface(body, 'body');
    }
    const key = createHash('sha256').update(dedupeKey).digest('hex');
    const seen = state.read();
    if (Object.hasOwn(seen.delivered, key) || (kind === REPORT && (Object.hasOwn(seen.reports ?? {}, key) || seen.pending?.[key]))) {
      return { delivered: false, reason: 'duplicate' };
    }
    const sessionId = encodeNotificationSessionId(deepLink, kind, { ...meta, ...(level === 'quiet' ? { lv: 'p' } : {}) });
    if (sessionId === null) return { delivered: false, reason: 'invalid_notification' };
    const event = { type: 'response.ready', event_id: `laa-bridge:${key}`, profile: 'laa-monet',
      session_id: sessionId, title: title.slice(0, 120), body: body.slice(0, 500) };
    const claim = state.mutate((s) => {
      if (kind === REPORT) {
        if (Object.hasOwn(s.reports ?? {}, key) || s.pending?.[key] || Object.hasOwn(s.delivered, key)) return { reason: 'duplicate' };
        // Never evict an old report key to make space for replay. Fail closed if full.
        if (Object.keys(s.reports ?? {}).length + Object.values(s.pending ?? {}).filter((r) => r.kind === REPORT).length >= REPORT_LEDGER_MAX) {
          return { reason: 'report_ledger_full' };
        }
      }
      return { row: (s.pending ??= {})[key] ??= { event, kind, queuedAt: now() } };
    });
    if (!claim.row) return { delivered: false, reason: claim.reason };
    const result = await deliverPending(key, claim.row.event);
    return result.delivered ? result : { ...result, queued: true };
  };
  notify.flush = async () => {
    const rows = Object.entries(state.read().pending ?? {});
    for (const [key, item] of rows) {
      let kind = item.kind;
      try { kind ??= JSON.parse(Buffer.from(item.event.session_id.slice(item.event.session_id.lastIndexOf('#') + 1), 'base64url').toString()).k; } catch { /* Legacy queued links have no metadata. */ }
      if (notificationLevel(kind, preferences) === 'off' || now() - item.queuedAt > 7 * 86400_000) {
        state.mutate((s) => {
          // Delivery may have happened without an acknowledgement. Retire
          // old report keys even if their pending row is muted or expires.
          if (kind === REPORT && s.pending?.[key]) (s.reports ??= {})[key] = now();
          delete s.pending?.[key];
        });
        continue;
      }
      await deliverPending(key, item.event);
    }
  };
  return notify;
}
let notifier;
export async function notifyOwner(payload) { notifier ??= createOwnerNotifier(); return notifier(payload); }

export async function flushOwnerNotifications() { notifier ??= createOwnerNotifier(); await notifier.flush(); }

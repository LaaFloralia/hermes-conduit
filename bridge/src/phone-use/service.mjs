// Asking the owner before an agent operates an iPhone that is in use.
//
// `laa-phone unlock` (Mac side, this user's CLI) finds the iPhone open, so the
// owner or another agent is using it. It asks here: the Bridge starts a Live
// Activity on the phone with a push-to-start push, and the owner answers
// Allow or Don't Allow in the Dynamic Island. While the agent works the
// activity stays as "operating" with a Stop button; `laa-phone lock`, its
// guard or Stop ends it.
//
// The phone registers its push-to-start token and each activity's update
// token through the device routes; the CLI process holds the APNs key, given
// by 1Password for that run only. Nothing here sees the passcode or a screen.
import { randomBytes } from 'node:crypto';
import { join } from 'node:path';
import { createJsonFile } from '../routes/state-file.mjs';
import { BridgeError, badRequest } from '../errors.mjs';

const RETENTION_MS = 7 * 86400_000;
const OPEN = new Set(['pending', 'allowed']);
export const ATTRIBUTES_TYPE = 'LAAPhoneUseAttributes';

function clean(value, field, max) {
  if (typeof value !== 'string') throw badRequest('phone_use_invalid', `${field} must be text`);
  const text = value.replace(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/gu, ' ').replace(/\s+/g, ' ').trim();
  if (!text) throw badRequest('phone_use_invalid', `${field} is empty`);
  return [...text].slice(0, max).join('');
}
const hexToken = (value, field) => {
  if (typeof value !== 'string' || !/^[0-9a-f]{16,400}$/i.test(value)) throw badRequest('phone_use_invalid', `${field} must be a hex push token`);
  return value.toLowerCase();
};
const seconds = (ms) => Math.floor(ms / 1000);

// `devices(id)` reads the paired device record (null when unknown): answers
// come only from the one iPhone that registered, and never once it is revoked.
export function createPhoneUse({ dir, now = () => Date.now(), push = null, devices = () => null } = {}) {
  const active = (id) => { const d = devices(id); return Boolean(d && !d.revokedAt); };
  const file = createJsonFile({ file: join(dir, 'phone-use.json'), initial: () => ({ startToken: null, requests: {} }) });

  function prune(state) {
    for (const [id, r] of Object.entries(state.requests)) {
      if (now() - r.createdAt > RETENTION_MS) delete state.requests[id];
    }
  }
  // A pending request whose answer time passed, or an allowed one past its
  // limit, reads as expired: a CLI that died never leaves one open.
  function settle(r) {
    if (r.status === 'pending' && now() >= r.answerBy) return { ...r, status: 'expired', endedAt: r.answerBy };
    if (r.status === 'allowed' && now() >= r.until) return { ...r, status: 'ended', endedAt: r.until, reason: 'limit' };
    return r;
  }
  const view = (r) => {
    const s = settle(r);
    return { id: s.id, who: s.who, purpose: s.purpose, status: s.status, createdAt: s.createdAt, answerBy: s.answerBy,
      answeredAt: s.answeredAt ?? null, endedAt: s.endedAt ?? null, reason: s.reason ?? null, hasActivityToken: Boolean(s.activityToken) };
  };
  function find(state, id) {
    const r = typeof id === 'string' ? state.requests[id] : null;
    if (!r) throw new BridgeError(404, 'phone_use_not_found', 'no such request');
    return r;
  }

  async function send(kind, token, environment, payload) {
    if (!push) return { sent: false, reason: 'no_sender' };
    try { return { sent: true, ...(await push({ kind, token, environment, payload })) }; }
    catch (e) { return { sent: false, reason: e?.code ?? e?.message ?? 'push_failed' }; }
  }
  function endPayload(r, phase) {
    const at = seconds(now());
    return { aps: { timestamp: at, event: 'end', 'content-state': { phase, endedAt: at }, 'dismissal-date': at + (phase === 'ended' ? 4 : 8) } };
  }

  return {
    file: file.file,
    // The first iPhone to register keeps the place while it stays paired;
    // another device takes it only after `laa-bridge phone-use reset` on the Mac.
    // `wakeToken`, the app's own push token, lets the Mac wake the app to
    // take an activity down when it holds no update token for it.
    setStartToken({ deviceId, platform, token, environment, wakeToken }) {
      const value = hexToken(token, 'token');
      const wake = wakeToken == null ? null : hexToken(wakeToken, 'wakeToken');
      if (!['sandbox', 'production'].includes(environment)) throw badRequest('phone_use_invalid', 'environment is sandbox or production');
      if (platform !== 'ios') throw new BridgeError(403, 'phone_use_not_iphone', 'only an iPhone registers for phone use');
      return file.mutate((s) => {
        const held = s.startToken;
        if (held && held.deviceId !== deviceId && active(held.deviceId)) {
          throw new BridgeError(409, 'phone_use_device_pinned', 'another iPhone is registered; reset it on the Mac first');
        }
        s.startToken = { deviceId, token: value, environment, updatedAt: now(),
          wakeToken: wake ?? (held?.deviceId === deviceId ? held.wakeToken ?? null : null) };
        return { registered: true };
      });
    },
    reset() {
      return file.mutate((s) => { const had = Boolean(s.startToken); s.startToken = null; return { reset: had }; });
    },
    setActivityToken({ id, deviceId, token }) {
      const value = hexToken(token, 'token');
      return file.mutate((s) => {
        const r = find(s, id);
        if (r.deviceId !== deviceId) throw new BridgeError(403, 'phone_use_other_device', 'the request belongs to another device');
        r.activityToken = value;
        return view(r);
      }, { tag: id });
    },
    // The update token often comes late or never (iOS need not wake the app
    // for an activity a push started), so the phone also reads its request
    // whenever it runs and takes down an activity whose request closed.
    statusFor({ id, deviceId }) {
      const r = find(file.read(), id);
      if (r.deviceId !== deviceId) throw new BridgeError(403, 'phone_use_other_device', 'the request belongs to another device');
      return view(r);
    },
    // The owner's answer from the Live Activity. Allow and Don't Allow only
    // while the request waits; Stop only while the agent works.
    answer({ id, deviceId, answer }) {
      if (!['allow', 'deny', 'stop'].includes(answer)) throw badRequest('phone_use_invalid', 'answer is allow, deny or stop');
      return file.mutate((s) => {
        const r = find(s, id);
        if (r.deviceId !== deviceId || !active(deviceId)) throw new BridgeError(403, 'phone_use_other_device', 'the request belongs to another device');
        const current = settle(r);
        const allowed = answer === 'stop' ? current.status === 'allowed' : current.status === 'pending';
        if (!allowed) throw new BridgeError(409, 'phone_use_closed', `the request is ${current.status}`, { details: { status: current.status } });
        r.answeredAt ??= now();
        if (answer === 'allow') { r.status = 'allowed'; r.until = now() + r.limitMs; }
        else { r.status = answer === 'deny' ? 'denied' : 'stopped'; r.endedAt = now(); }
        return view(r);
      }, { tag: id });
    },
    status(id) { return view(find(file.read(), id)); },
    // Start the Live Activity. `busy` while another request is still open.
    async ask({ who, purpose, timeoutMs = 90_000, limitMs = 1800_000 }) {
      const w = clean(who, 'who', 40), p = clean(purpose, 'purpose', 80);
      if (!Number.isInteger(timeoutMs) || timeoutMs < 10_000 || timeoutMs > 300_000) throw badRequest('phone_use_invalid', 'timeout is 10..300 seconds');
      const created = file.mutate((s) => {
        prune(s);
        const token = s.startToken;
        if (!token || !active(token.deviceId)) return { error: 'not_registered' };
        const open = Object.values(s.requests).map(settle).find((r) => OPEN.has(r.status));
        if (open) return { error: 'busy', open: view(open) };
        const id = `pu_${randomBytes(8).toString('hex')}`;
        const r = { id, who: w, purpose: p, status: 'pending', createdAt: now(), answerBy: now() + timeoutMs, limitMs,
          deviceId: token.deviceId, environment: token.environment, wakeToken: token.wakeToken ?? null };
        s.requests[id] = r;
        return { request: r, token };
      });
      if (created.error) return { ok: false, error: created.error, open: created.open ?? null };
      const r = created.request, at = seconds(now());
      const payload = { aps: {
        timestamp: at, event: 'start', 'attributes-type': ATTRIBUTES_TYPE,
        attributes: { requestID: r.id, who: r.who, purpose: r.purpose, answerBy: r.answerBy / 1000 },
        'content-state': { phase: 'ask' }, 'stale-date': seconds(r.answerBy), 'input-push-token': 1,
        alert: { title: 'iPhoneの操作', body: `${r.who}：${r.purpose}` },
      } };
      const sent = await send('start', created.token.token, created.token.environment, payload);
      if (!sent.sent) {
        file.mutate((s) => { const x = s.requests[r.id]; if (x) { x.status = 'failed'; x.endedAt = now(); x.reason = String(sent.reason).slice(0, 80); } });
        return { ok: false, error: 'push_failed', reason: sent.reason, request: this.status(r.id) };
      }
      return { ok: true, request: view(r) };
    },
    // Wait for the answer: polls the file (the answer arrives in the server's
    // process). Ends the activity itself when the time runs out.
    async waitForAnswer(id, { pollMs = 400, sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)) } = {}) {
      for (;;) {
        const v = this.status(id);
        if (v.status !== 'pending') {
          if (v.status === 'expired') await this.end(id, { reason: 'no_answer' });
          return this.status(id);
        }
        await sleep(pollMs);
      }
    },
    // The agent finished (lock, guard, error) or nobody answered: close the
    // request and end the activity on the phone.
    async end(id, { reason = 'done' } = {}) {
      const closed = file.mutate((s) => {
        const r = find(s, id);
        const current = settle(r);
        if (OPEN.has(r.status) || current.status !== r.status) {
          Object.assign(r, current);
          if (OPEN.has(r.status)) { r.status = r.status === 'pending' ? 'expired' : 'ended'; r.endedAt = now(); }
          r.reason ??= reason;
        }
        return { ...r };
      }, { tag: id });
      const phase = closed.status === 'expired' ? 'expired' : closed.status === 'denied' ? 'denied' : closed.status === 'stopped' ? 'stopped' : 'ended';
      const sent = closed.activityToken && !closed.pushedEnd
        ? await send('end', closed.activityToken, closed.environment, endPayload(closed, phase))
        : { sent: false, reason: closed.activityToken ? 'already_ended' : 'no_activity_token' };
      if (sent.sent) file.mutate((s) => { if (s.requests[id]) s.requests[id].pushedEnd = now(); });
      // No end push reached it: wake the app, which reads the request and ends it.
      const woke = !sent.sent && closed.wakeToken && !closed.pushedEnd && !closed.wokenAt
        ? await send('wake', closed.wakeToken, closed.environment, { aps: { 'content-available': 1 }, laa_phone_use: { id } })
        : { sent: false, reason: closed.wakeToken ? 'not_needed' : 'no_wake_token' };
      if (woke.sent) file.mutate((s) => { if (s.requests[id]) s.requests[id].wokenAt = now(); });
      return { ...view(closed), endPush: sent.sent ? 'sent' : sent.reason, wake: woke.sent ? 'sent' : woke.reason };
    },
  };
}

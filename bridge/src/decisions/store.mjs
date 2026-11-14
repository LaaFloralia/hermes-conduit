import { createHash, randomBytes } from 'node:crypto';
import { join } from 'node:path';
import { createJsonFile } from '../routes/state-file.mjs';
import { BridgeError, badRequest, conflict, notFound } from '../errors.mjs';

const RETENTION = 30 * 86400_000;
const WAIT_FIELDS = ['waiting', 'waitingSince', 'holds'];
export function text(value, field, max, { optional = false } = {}) {
  if (value == null && optional) return null;
  if (typeof value !== 'string') throw badRequest('decision_invalid', `${field} must be text`);
  const clean = value.replace(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/gu, '').trim();
  if ((!clean && !optional) || [...clean].length > max) throw badRequest('decision_invalid', `${field} exceeds its limit or is empty`);
  return clean || null;
}
export const requestKey = (value) => text(value, 'requestId', 200);

function input(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw badRequest('decision_invalid', 'decision must be an object');
  if (!Array.isArray(body.options) || body.options.length < 2 || body.options.length > 6) throw badRequest('decision_invalid', 'choose 2..6 options');
  const options = body.options.map((o) => {
    if (!o || typeof o !== 'object' || Array.isArray(o) || (o.recommended !== undefined && typeof o.recommended !== 'boolean')) throw badRequest('decision_invalid', 'invalid option');
    return { label: text(o.label, 'label', 80), detail: text(o.detail, 'detail', 200, { optional: true }), recommended: o.recommended === true };
  });
  if (options.filter((o) => o.recommended).length > 1) throw badRequest('decision_invalid', 'only one recommended option');
  if (body.allowOther !== undefined && typeof body.allowOther !== 'boolean') throw badRequest('decision_invalid', 'allowOther must be boolean');
  const deadline = text(body.deadline, 'deadline', 80, { optional: true });
  if (deadline && (!/^\d{4}-\d\d-\d\dT\d\d:\d\d(?::\d\d(?:\.\d{1,3})?)?(?:Z|[+-]\d\d:\d\d)$/.test(deadline) || !Number.isFinite(Date.parse(deadline)))) throw badRequest('decision_invalid', 'deadline must be ISO 8601');
  if (deadline) {
    const date = deadline.slice(0, 10);
    if (new Date(`${date}T00:00:00Z`).toISOString().slice(0, 10) !== date) throw badRequest('decision_invalid', 'deadline has an invalid date');
  }
  return {
    title: text(body.title, 'title', 60), summary: text(body.summary, 'summary', 600),
    options: options.sort((a, b) => Number(b.recommended) - Number(a.recommended)), allowOther: body.allowOther !== false,
    impact: text(body.impact, 'impact', 200, { optional: true }), deadline: deadline ? new Date(deadline).toISOString() : null,
    source: { paseoAgentId: text(body.source?.paseoAgentId, 'agent', 200, { optional: true }),
      sessionId: text(body.source?.sessionId, 'sessionId', 200, { optional: true }), name: text(body.source?.name, 'name', 200, { optional: true }) },
    requestId: requestKey(body.requestId),
  };
}

// The CLI and HTTP server open this same file. Every read-modify-write holds
// the shared state-file lock, including delivery reservations and deduplication.
export function createDecisionStore({ dir, now = () => Date.now() }) {
  const file = createJsonFile({ file: join(dir, 'decisions.json'), initial: () => ({ records: [], operations: {}, notifications: {} }) });
  const stamp = () => new Date(now()).toISOString();
  const validTime = (v) => typeof v === 'string' && Number.isFinite(Date.parse(v));
  function validRecord(r) {
    try {
      if (!r || !/^dec_[0-9a-f]{16}$/.test(r.id) || !['open', 'answered', 'withdrawn'].includes(r.status)
        || !validTime(r.createdAt) || !validTime(r.updatedAt) || (r.ref !== null && text(r.ref, 'ref', 80) !== r.ref)) return false;
      const normalized = input(r);
      if (Object.entries(normalized).some(([k, v]) => JSON.stringify(r[k]) !== JSON.stringify(v))) return false;
      if (r.status !== 'answered') return r.answer === null && r.delivery === null;
      const a = r.answer, d = r.delivery;
      if (!a || !d || !validTime(a.answeredAt) || !['pending', 'delivered', 'failed', 'stored', 'gone'].includes(d.state)
        || !Number.isSafeInteger(d.attempts) || d.attempts < 1 || d.messageId !== `${r.id}:answer:${d.attempts}`
        || (d.state === 'delivered' ? !validTime(d.deliveredAt) : d.deliveredAt !== null)
        || (['failed', 'gone'].includes(d.state) ? text(d.error, 'error', 80) !== d.error : d.error !== null)
        // `waiting` holds an accepted answer for a busy conversation; only a pending delivery may carry it.
        || (d.waiting !== undefined && (d.state !== 'pending' || d.waiting !== true))
        || (d.waitingSince !== undefined && (d.state !== 'pending' || !validTime(d.waitingSince)))
        || (d.holds !== undefined && (d.state !== 'pending' || !Number.isSafeInteger(d.holds) || d.holds < 1))
        || text(a.deviceId, 'deviceId', 200) !== a.deviceId || text(a.label, 'answer', 600) !== a.label
        || text(a.note, 'note', 600, { optional: true }) !== a.note) return false;
      return a.optionIndex === null ? r.allowOther && Boolean(a.label) : Number.isInteger(a.optionIndex) && r.options[a.optionIndex]?.label === a.label;
    } catch { return false; }
  }
  function checked(s) {
    if (!Array.isArray(s.records) || !s.operations || typeof s.operations !== 'object' || Array.isArray(s.operations)
      || !s.notifications || typeof s.notifications !== 'object' || Array.isArray(s.notifications)
      || s.records.some((r) => !validRecord(r)) || new Set(s.records.map((r) => r.id)).size !== s.records.length
      || Object.values(s.operations).some((op) => !op || typeof op.id !== 'string' || typeof op.digest !== 'string')
      || Object.values(s.notifications).some((keys) => !Array.isArray(keys) || keys.some((k) => typeof k !== 'string'))) {
      throw new Error('invalid decision state');
    }
    return s;
  }
  function access(fn) {
    try { return fn(); } catch (e) {
      if (e instanceof BridgeError) throw e;
      throw new BridgeError(503, 'decisions_store_unavailable', '判断の保存先を読み書きできません。', { retryable: true });
    }
  }
  function prune(s) {
    s.records = s.records.filter((r) => r.status === 'open' || now() - Date.parse(r.updatedAt) < RETENTION);
    const ids = new Set(s.records.map((r) => r.id));
    for (const [key, op] of Object.entries(s.operations)) if (!ids.has(op.id)) delete s.operations[key];
    for (const id of Object.keys(s.notifications)) if (!ids.has(id)) delete s.notifications[id];
  }
  const mutate = (fn) => access(() => file.mutate((s) => { checked(s); prune(s); return structuredClone(fn(s)); }));
  function find(s, id) {
    const r = s.records.find((r) => r.id === id || (r.ref && r.ref === id));
    if (!r) throw notFound('decision not found');
    return r;
  }
  function reserve(s, id, deviceId, body, retry) {
    if (body.quick !== undefined && typeof body.quick !== 'boolean') throw badRequest('decision_invalid', 'quick must be boolean');
    const r = find(s, id);
    const key = JSON.stringify([deviceId, requestKey(body.requestId)]);
    const note = retry ? null : text(body.note, 'note', 600, { optional: true });
    const optionIndex = body.optionIndex ?? null;
    const digest = createHash('sha256').update(JSON.stringify([r.id, retry, optionIndex, note])).digest('hex');
    if (s.operations[key]) {
      if (s.operations[key].digest !== digest) throw conflict('decision_request_conflict', 'requestId was used for a different answer');
      return { decision: r, replayed: true };
    }
    if (retry) {
      if (r.status !== 'answered' || r.delivery?.state !== 'failed') throw conflict('decision_closed', 'only failed delivery can be retried');
    } else {
      if (r.status !== 'open') throw conflict('decision_closed', 'decision is already closed');
      if (body.quick && r.deadline !== null && Date.parse(r.deadline) < now()) throw conflict('decision_expired', '回答期限を過ぎています。判断ボードで確認してください。');
      if (optionIndex === null ? (!r.allowOther || !note) : (!Number.isInteger(optionIndex) || optionIndex < 0 || optionIndex >= r.options.length)) throw badRequest('decision_invalid', 'choose an option or provide a free answer');
      r.answer = { optionIndex, label: optionIndex === null ? note : r.options[optionIndex].label, note: optionIndex === null ? null : note, answeredAt: stamp(), deviceId };
      r.status = 'answered';
    }
    const attempts = (r.delivery?.attempts ?? 0) + 1;
    r.delivery = { state: r.source.paseoAgentId ? 'pending' : 'stored', attempts, messageId: `${r.id}:answer:${attempts}`, deliveredAt: null, error: null };
    r.updatedAt = stamp();
    s.operations[key] = { id: r.id, digest };
    return { decision: r, replayed: false };
  }
  return {
    file: file.file,
    all: () => access(() => { const s = checked(file.read()); prune(s); return structuredClone(s.records); }),
    get: (id) => access(() => { const s = checked(file.read()); prune(s); return structuredClone(find(s, id)); }),
    add(body) {
      const value = input(body);
      return mutate((s) => {
        const existing = s.records.find((r) => r.requestId === value.requestId && r.source.paseoAgentId === value.source.paseoAgentId);
        if (existing) return { decision: existing, replayed: true };
        const r = { id: `dec_${randomBytes(8).toString('hex')}`, ref: null, status: 'open', ...value, createdAt: stamp(), updatedAt: stamp(), answer: null, delivery: null };
        s.records.push(r);
        return { decision: r, replayed: false };
      });
    },
    withdraw(id, reason) {
      text(reason, 'reason', 200); // A reason is required; no extra conversation text is retained.
      return mutate((s) => { const r = find(s, id); if (r.status === 'withdrawn') return r; if (r.status !== 'open') throw conflict('decision_closed', 'decision is already closed'); r.status = 'withdrawn'; r.updatedAt = stamp(); return r; });
    },
    // The conversation that asked is gone: its saved answer can never be
    // delivered, so it leaves the board and a retry is refused (owner, 2026-11-14).
    retire(id, reason) {
      text(reason, 'reason', 80);
      return mutate((s) => { const r = find(s, id); const d = r.delivery;
        if (r.status !== 'answered' || d?.state !== 'failed') return r;
        Object.assign(d, { state: 'gone', error: reason, deliveredAt: null }); r.updatedAt = stamp(); return r; });
    },
    reserve: (id, deviceId, body, retry = false) => mutate((s) => reserve(s, id, text(deviceId, 'deviceId', 200), body, retry)),
    settle(id, messageId, state, error = null) {
      return mutate((s) => { const r = find(s, id); if (r.delivery?.messageId !== messageId || r.delivery.state !== 'pending') return r;
        for (const key of WAIT_FIELDS) delete r.delivery[key];
        Object.assign(r.delivery, { state, error, deliveredAt: state === 'delivered' ? stamp() : null }); r.updatedAt = stamp(); return r; });
    },
    // The conversation is busy: keep the accepted answer and let the Bridge
    // deliver it, with the same message id, once that turn ends.
    hold(id, messageId) {
      return mutate((s) => { const r = find(s, id); const d = r.delivery;
        if (d?.messageId !== messageId || d.state !== 'pending' || d.waiting) return r;
        Object.assign(d, { waiting: true, waitingSince: d.waitingSince ?? stamp(), holds: (d.holds ?? 0) + 1 }); r.updatedAt = stamp(); return r; });
    },
    // Claim a waiting answer for one send. Only the claimant sends; a Bridge
    // that stops mid-send leaves a plain pending record, which is never resent.
    release(id, messageId) {
      return mutate((s) => { const r = find(s, id); const d = r.delivery;
        if (d?.messageId !== messageId || d.state !== 'pending' || !d.waiting) return null;
        delete d.waiting; r.updatedAt = stamp(); return r; });
    },
    // Answers an earlier Bridge filed as failed because the conversation was busy.
    requeueBusy() {
      return mutate((s) => s.records.filter((r) => r.status === 'answered' && r.delivery?.state === 'failed' && r.delivery.error === 'session_busy' && r.source.paseoAgentId)
        .map((r) => { Object.assign(r.delivery, { state: 'pending', error: null, deliveredAt: null, waiting: true, waitingSince: stamp(), holds: 1 }); r.updatedAt = stamp(); return r; }));
    },
    notificationDone(id, key) { return access(() => Boolean(checked(file.read()).notifications[id]?.includes(key))); },
    markNotification(id, key) { mutate((s) => { const keys = s.notifications[id] ??= []; if (!keys.includes(key)) keys.push(key); }); },
    prune: () => mutate(() => null),
  };
}

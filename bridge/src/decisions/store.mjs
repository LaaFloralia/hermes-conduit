import { createHash, randomBytes } from 'node:crypto';
import { join } from 'node:path';
import { createJsonFile } from '../routes/state-file.mjs';
import { BridgeError, badRequest, conflict, notFound } from '../errors.mjs';
import { createDecisionImages, DECISION_ID, IMAGE_ID, imageNotFound, validDecisionImages } from './images.mjs';

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

// Owner-only kinds (2026-11-28 owner: 「ブランドの好み以外ばいいです」): the brand
// preference (final choice of a name or look) and the owner's own physical
// operation or authentication. Real-account trading (実口座・売買・発注・取引) is
// owner-only too: its start conditions stay with the owner (GA-10; mirror of
// hq/harness/orchestrate.py OWNER_KIND). Every other kind, even when filed as
// 【必ず社長：お金】 etc., is answered by Monet with its recommended option.
const OWNER_ONLY_KIND = /ブランド|好み|見た目|物理|本人の?操作|本人の?認証|^本人$|実口座|売買|発注|取引|trad(e|es|ing)|real.?account|brand|preference|aesthetic|look|logo|physical|authenticat|passkey|biometric|identity|owner'?s?(operation|action)/iu;
export const ownerOnlyKind = (kind) => OWNER_ONLY_KIND.test(String(kind).normalize('NFKC').replace(/[\s・、,／/]/gu, ''));
export function decisionCategory(impact) {
  const kind = typeof impact === 'string' && /^【必ず社長：([^【】\p{Cc}\p{Cf}\p{Zl}\p{Zp}]+)】/u.exec(impact)?.[1].trim();
  if (kind) return { category: ownerOnlyKind(kind) ? 'owner' : 'delegable', ownerKind: kind };
  return { category: typeof impact === 'string' && impact.startsWith('【任せられる】') ? 'delegable' : 'unmarked', ownerKind: null };
}
// Records written before 2026-11-28 stored every 【必ず社長：…】 kind as owner.
const legacyCategory = (impact) => { const c = decisionCategory(impact); return c.ownerKind ? { ...c, category: 'owner' } : c; };

const withCategory = (r) => Object.assign(r, decisionCategory(r.impact));
function proxyReason(value) {
  if (typeof value !== 'string' || /[\p{Cc}\p{Zl}\p{Zp}]/u.test(value)) throw badRequest('decision_invalid', 'reason must be one line');
  return text(value, 'reason', 200);
}

const ANSWER_NOTE_LIMIT = 8000;
function answerNote(value) {
  if (value == null) return null;
  if (typeof value !== 'string') throw badRequest('decision_invalid', 'note must be text');
  if ([...value].length > ANSWER_NOTE_LIMIT) throw badRequest('decision_note_too_long', `回答は${ANSWER_NOTE_LIMIT}文字以内で入力してください。`);
  // Unlike titles, an answer is conversation text. Preserve whitespace,
  // paragraph breaks and emoji joiners; reject non-text control characters.
  if (/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]/u.test(value)) throw badRequest('decision_invalid', '回答に使用できない制御文字があります。');
  return value.trim() ? value : null;
}

const optionOrder = (options) => options.map((_, i) => i).sort((a, b) => Number(options[b].recommended === true) - Number(options[a].recommended === true));

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
    options: optionOrder(options).map((i) => options[i]), allowOther: body.allowOther !== false,
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
  const images = createDecisionImages(dir);
  const stamp = () => new Date(now()).toISOString();
  const validTime = (v) => typeof v === 'string' && Number.isFinite(Date.parse(v));
  function validRecord(r) {
    try {
      if (!r || !DECISION_ID.test(r.id) || !['open', 'answered', 'withdrawn'].includes(r.status)
        || !validTime(r.createdAt) || !validTime(r.updatedAt) || (r.ref !== null && text(r.ref, 'ref', 80) !== r.ref)) return false;
      const normalized = input(r);
      if (Object.entries(normalized).some(([k, v]) => JSON.stringify(r[k]) !== JSON.stringify(v))) return false;
      if (r.images !== undefined && !validDecisionImages(r.images, r.options.length)) return false;
      const { category, ownerKind } = decisionCategory(r.impact);
      if ((r.category !== undefined || r.ownerKind !== undefined) && r.ownerKind !== ownerKind) return false;
      if (r.category !== undefined && r.category !== category && r.category !== legacyCategory(r.impact).category) return false;
      if (r.status !== 'answered') return r.answer === null && r.delivery === null && r.monetAnswer === undefined && r.overturned === undefined;
      const a = r.answer, d = r.delivery;
      if (r.overturned !== undefined && (r.overturned !== true || !validAnswer(r, r.monetAnswer) || r.monetAnswer.answeredBy !== 'monet' || a?.answeredBy !== 'owner')) return false;
      if (r.monetAnswer !== undefined && !r.overturned) return false;
      if (category === 'owner' && (a?.answeredBy === 'monet' || r.overturned)) return false;
      if (r.previousAttempt !== undefined && (!r.overturned || !d?.waiting || !validTime(r.previousAttempt.at)
        || r.previousAttempt.messageId !== `${r.id}:answer:${d.attempts - 1}`)) return false;
      if (!a || !d || !validTime(a.answeredAt) || !['pending', 'delivered', 'failed', 'stored', 'gone'].includes(d.state)
        || !Number.isSafeInteger(d.attempts) || d.attempts < 1 || d.messageId !== `${r.id}:answer:${d.attempts}`
        || (d.state === 'delivered' ? !validTime(d.deliveredAt) : d.deliveredAt !== null)
        || (['failed', 'gone'].includes(d.state) ? text(d.error, 'error', 80) !== d.error : d.error !== null)
        // `waiting` holds an accepted answer for a busy conversation; only a pending delivery may carry it.
        || (d.waiting !== undefined && (d.state !== 'pending' || d.waiting !== true))
        || (d.waitingSince !== undefined && (d.state !== 'pending' || !validTime(d.waitingSince)))
        || (d.holds !== undefined && (d.state !== 'pending' || !Number.isSafeInteger(d.holds) || d.holds < 1))) return false;
      return validAnswer(r, a);
    } catch { return false; }
  }
  function validAnswer(r, a) {
    if (!a || !validTime(a.answeredAt) || text(a.deviceId, 'deviceId', 200) !== a.deviceId || answerNote(a.note) !== a.note) return false;
    if (a.answeredBy === 'monet' ? proxyReason(a.reason) !== a.reason
      : (a.answeredBy !== undefined && a.answeredBy !== 'owner') || a.reason !== undefined) return false;
    return a.optionIndex === null ? r.allowOther && a.note === null && Boolean(a.label) && answerNote(a.label) === a.label
      : Number.isInteger(a.optionIndex) && r.options[a.optionIndex]?.label === a.label;
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
  function prune(s, time = now()) {
    s.records = s.records.filter((r) => r.status === 'open' || time - Date.parse(r.updatedAt) < RETENTION);
    const ids = new Set(s.records.map((r) => r.id));
    for (const [key, op] of Object.entries(s.operations)) if (!ids.has(op.id)) delete s.operations[key];
    for (const id of Object.keys(s.notifications)) if (!ids.has(id)) delete s.notifications[id];
  }
  // Older records have no category field. Re-read their original prefix instead of guessing.
  const read = () => { const s = checked(file.read()); prune(s); s.records.forEach(withCategory); return s; };
  const mutate = (fn) => access(() => file.mutate((s) => { checked(s); prune(s); s.records.forEach(withCategory); return structuredClone(fn(s)); }));
  function find(s, id) {
    const r = s.records.find((r) => r.id === id || (r.ref && r.ref === id));
    if (!r) throw notFound('decision not found');
    return r;
  }
  function reserve(s, id, deviceId, body, retry, monetReason = null) {
    if (body.quick !== undefined && typeof body.quick !== 'boolean') throw badRequest('decision_invalid', 'quick must be boolean');
    const r = find(s, id);
    if (monetReason && r.category === 'owner') throw conflict('decision_owner_only', 'この判断は社長だけが回答できます。');
    const key = monetReason ? JSON.stringify(['monet', r.id, 'proxy']) : JSON.stringify([deviceId, requestKey(body.requestId)]);
    const note = retry ? null : answerNote(body.note);
    const optionIndex = body.optionIndex ?? null;
    const digest = createHash('sha256').update(JSON.stringify([r.id, retry, optionIndex, note, ...(monetReason ? [monetReason] : [])])).digest('hex');
    if (s.operations[key]) {
      if (s.operations[key].digest !== digest) throw conflict('decision_request_conflict', 'requestId was used for a different answer');
      return { decision: r, replayed: true };
    }
    if (retry) {
      if (r.status !== 'answered' || r.delivery?.state !== 'failed') throw conflict('decision_closed', 'only failed delivery can be retried');
    } else {
      const overturning = !monetReason && r.answer?.answeredBy === 'monet';
      if (r.status !== 'open' && !overturning) throw conflict('decision_closed', 'decision is already closed');
      if ((body.quick || monetReason) && r.deadline !== null && Date.parse(r.deadline) < now()) throw conflict('decision_expired', '回答期限を過ぎています。判断ボードで確認してください。');
      if (optionIndex === null ? (!r.allowOther || !note) : (!Number.isInteger(optionIndex) || optionIndex < 0 || optionIndex >= r.options.length)) throw badRequest('decision_invalid', 'choose an option or provide a free answer');
      if (overturning) {
        r.monetAnswer = r.answer;
        r.overturned = true;
        // Cancel a held proxy answer. If its send is already in flight, queue
        // the owner's answer behind it so an older answer cannot arrive last.
        if (r.delivery.state === 'pending' && !r.delivery.waiting) r.previousAttempt = { messageId: r.delivery.messageId, at: r.updatedAt };
      }
      r.answer = { optionIndex, label: optionIndex === null ? note : r.options[optionIndex].label, note: optionIndex === null ? null : note,
        answeredAt: stamp(), deviceId, answeredBy: monetReason ? 'monet' : 'owner', ...(monetReason ? { reason: monetReason } : {}) };
      r.status = 'answered';
    }
    const attempts = (r.delivery?.attempts ?? 0) + 1;
    r.delivery = { state: r.source.paseoAgentId ? 'pending' : 'stored', attempts, messageId: `${r.id}:answer:${attempts}`, deliveredAt: null, error: null,
      ...(r.previousAttempt ? { waiting: true, waitingSince: stamp() } : {}) };
    r.updatedAt = stamp();
    s.operations[key] = { id: r.id, digest };
    return { decision: r, replayed: false };
  }
  return {
    file: file.file,
    all: () => access(() => structuredClone(read().records)),
    expireAndReadOpen() {
      const due = (r) => r.status === 'open' && r.deadline !== null && Date.parse(r.deadline) <= now();
      const records = access(() => read().records);
      if (!records.some(due)) return records;
      return mutate((s) => {
        for (const r of s.records.filter(due)) { r.status = 'withdrawn'; r.updatedAt = stamp(); }
        return s.records;
      });
    },
    get: (id) => access(() => structuredClone(find(read(), id))),
    image(id, imgId, size) {
      if (!DECISION_ID.test(id) || !IMAGE_ID.test(imgId)) throw imageNotFound();
      return access(() => images.read(read().records.find((r) => r.id === id), imgId, size, now()));
    },
    add(body, imageInputs = []) {
      if (decisionCategory(body?.impact).category === 'unmarked') throw new BridgeError(428, 'decision_category_required',
        '影響の先頭に【必ず社長：種類】または【任せられる】を付けてください。社長だけが答えるのはブランドの好み・本人の操作／本人認証で、ほかはMonetが回答します。');
      const value = withCategory(input(body));
      const staged = access(() => images.stage(imageInputs, optionOrder(body.options)));
      try {
        return mutate((s) => {
          const existing = s.records.find((r) => r.requestId === value.requestId && r.source.paseoAgentId === value.source.paseoAgentId);
          if (existing) return { decision: existing, replayed: true };
          // The same conversation asking again about the same subject replaces
          // its open ask instead of adding a second board item (2026-11-28).
          const superseded = value.source.paseoAgentId ? s.records.filter((r) => r.status === 'open'
            && r.source.paseoAgentId === value.source.paseoAgentId && r.title === value.title) : [];
          for (const r of superseded) { r.status = 'withdrawn'; r.updatedAt = stamp(); }
          const r = { id: `dec_${randomBytes(8).toString('hex')}`, ref: null, status: 'open', ...value, createdAt: stamp(), updatedAt: stamp(), answer: null, delivery: null };
          if (staged) {
            // Publish before the JSON write under the same lock. If that write
            // fails or is interrupted, sync can reclaim the unreferenced dir.
            staged.publish(r.id);
            r.images = staged.images;
          }
          s.records.push(r);
          return { decision: r, replayed: false, ...(superseded.length ? { superseded: superseded.map((x) => x.id) } : {}) };
        });
      } finally { if (staged) access(staged.cleanup); }
    },
    withdraw(id, reason, { ifOpen = false } = {}) {
      text(reason, 'reason', 200); // A reason is required; no extra conversation text is retained.
      return mutate((s) => { const r = find(s, id); if (r.status === 'withdrawn' || (ifOpen && r.status !== 'open')) return r; if (r.status !== 'open') throw conflict('decision_closed', 'decision is already closed'); r.status = 'withdrawn'; r.updatedAt = stamp(); return r; });
    },
    // The conversation that asked is gone: its saved answer can never be
    // delivered, so it leaves the board and a retry is refused (owner, 2026-11-14).
    retire(id, reason, messageId) {
      text(reason, 'reason', 80);
      return mutate((s) => { const r = find(s, id); const d = r.delivery;
        if (r.status !== 'answered' || d?.state !== 'failed' || (messageId && d.messageId !== messageId)) return r;
        Object.assign(d, { state: 'gone', error: reason, deliveredAt: null }); r.updatedAt = stamp(); return r; });
    },
    reserve: (id, deviceId, body, retry = false) => mutate((s) => reserve(s, id, text(deviceId, 'deviceId', 200), body, retry)),
    reserveMonet: (id, body, reason) => mutate((s) => reserve(s, id, 'monet', body, false, proxyReason(reason))),
    // `queued`: the conversation accepted the answer into its queue behind a running turn.
    settle(id, messageId, state, error = null, { queued = false } = {}) {
      return mutate((s) => { const r = find(s, id);
        if (r.previousAttempt?.messageId === messageId) delete r.previousAttempt;
        if (r.delivery?.messageId !== messageId || r.delivery.state !== 'pending') return r;
        delete r.previousAttempt;
        for (const key of WAIT_FIELDS) delete r.delivery[key];
        Object.assign(r.delivery, { state, error, deliveredAt: state === 'delivered' ? stamp() : null, ...(state === 'delivered' && queued ? { queued: true } : {}) }); r.updatedAt = stamp(); return r; });
    },
    // The conversation is busy: keep the accepted answer and let the Bridge
    // deliver it, with the same message id, once that turn ends.
    hold(id, messageId) {
      return mutate((s) => { const r = find(s, id); const d = r.delivery;
        if (r.previousAttempt?.messageId === messageId) delete r.previousAttempt;
        if (d?.messageId !== messageId || d.state !== 'pending' || d.waiting) return r;
        Object.assign(d, { waiting: true, waitingSince: d.waitingSince ?? stamp(), holds: (d.holds ?? 0) + 1 }); r.updatedAt = stamp(); return r; });
    },
    // Claim a waiting answer for one send. Only the claimant sends; a Bridge
    // that stops mid-send leaves a plain pending record, which is never resent.
    release(id, messageId) {
      return mutate((s) => { const r = find(s, id); const d = r.delivery;
        if (d?.messageId !== messageId || d.state !== 'pending' || !d.waiting) return null;
        if (r.previousAttempt && now() - Date.parse(r.previousAttempt.at) <= 60_000) return null;
        delete r.previousAttempt; delete d.waiting; r.updatedAt = stamp(); return r; });
    },
    // Answers an earlier Bridge filed as failed because the conversation was busy.
    requeueBusy() {
      return mutate((s) => s.records.filter((r) => r.status === 'answered' && r.delivery?.state === 'failed' && r.delivery.error === 'session_busy' && r.source.paseoAgentId)
        .map((r) => { Object.assign(r.delivery, { state: 'pending', error: null, deliveredAt: null, waiting: true, waitingSince: stamp(), holds: 1 }); r.updatedAt = stamp(); return r; }));
    },
    notificationDone(id, key) { return access(() => Boolean(checked(file.read()).notifications[id]?.includes(key))); },
    markNotification(id, key) { mutate((s) => { const keys = s.notifications[id] ??= []; if (!keys.includes(key)) keys.push(key); }); },
    prune: () => access(() => file.mutate((s) => {
      checked(s);
      const time = now();
      images.prune(s.records, time);
      prune(s, time);
      s.records.forEach(withCategory);
    })),
  };
}

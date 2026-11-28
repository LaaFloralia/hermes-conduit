import { randomBytes } from 'node:crypto';
import { BridgeError, badRequest, conflict, notFound } from '../errors.mjs';
import { assertOwnerSurface } from '../owner-surface.mjs';
import { SESSION_ID_PATTERN } from '../sessions/store.mjs';

export const REQUIREMENT_ID = /^req_[0-9a-f]{12}$/;
const MAX_REQUIREMENTS = 200;
const MAX_SESSIONS = 30;
const STATES = new Set(['not_started', 'in_progress', 'awaiting_decision', 'completed']);
const SOURCES = new Set(['owner', 'ai']);
const VERIFY_FIELDS = ['verifiedBy', 'note', 'evidence', 'requestId'];
// Written by the requirement flow (Monet's verdicts and the Bridge pipeline) only: an
// implementation session must not be able to rewrite what it will be checked against.
const DESIGN_FIELDS = ['acceptance', 'design', 'flowId'];
const DESIGN_AUTHORS = new Set(['monet', 'bridge']);
export const FLOW_ID = /^flw_[0-9a-f]{12}$/;
const MAX_ACCEPTANCE = 12;
const ACCEPTANCE_STATES = new Set(['open', 'passed', 'failed']);
export const REQUEST_ID_PATTERN = /^[A-Za-z0-9._:-]{1,200}$/;
export const isVerifier = (value) => value === 'monet' || (typeof value === 'string' && SESSION_ID_PATTERN.test(value));
export const validVerificationNote = (value) => typeof value === 'string' && Boolean(value.trim()) && [...value].length <= 200 && !/[\r\n\u2028\u2029\0]/u.test(value);

function verification(next, body, iso, author) {
  const agent = author === 'agent';
  if (body.requestId !== undefined) {
    if (!(body.requestId === null || (typeof body.requestId === 'string' && REQUEST_ID_PATTERN.test(body.requestId)))) {
      throw badRequest('payload_invalid', 'invalid requirement requestId');
    }
    next.requestId = body.requestId;
  }
  if (body.note !== undefined) {
    if (body.note !== null && !validVerificationNote(body.note)) throw new BridgeError(422, 'requirement_note_invalid', 'note must be a single line of at most 200 characters');
    if (agent && body.note !== null) assertOwnerSurface(body.note, 'note');
    next.note = body.note;
  }
  if (body.evidence !== undefined) next.evidence = text(body.evidence, 'evidence', 8192, true);
  if (body.verifiedBy !== undefined && body.verifiedBy !== null && !isVerifier(body.verifiedBy)) {
    throw new BridgeError(422, 'requirement_verifier_invalid', 'verifiedBy must be monet or a Bridge session ID');
  }
  if (agent && body.status === 'completed' && (!isVerifier(body.verifiedBy) || !validVerificationNote(body.note))) {
    throw new BridgeError(422, 'requirement_verification_required', 'completed requires verifiedBy and note');
  }
  if (body.status !== undefined || body.verifiedBy !== undefined || body.note !== undefined || body.requestId !== undefined) {
    const verified = body.status === 'completed' && isVerifier(body.verifiedBy) && validVerificationNote(body.note);
    next.verifiedBy = verified ? body.verifiedBy : null;
    next.verifiedAt = verified ? iso : null;
  }
}

const oneLine = (value, chars) => typeof value === 'string' && Boolean(value.trim()) && [...value].length <= chars && !/[\r\n\u2028\u2029\0]/u.test(value);
const isoTime = (value) => typeof value === 'string' && Number.isFinite(Date.parse(value));

export function parseAcceptance(raw) {
  if (raw === null) return [];
  if (!Array.isArray(raw) || raw.length > MAX_ACCEPTANCE) throw badRequest('payload_invalid', `acceptance holds at most ${MAX_ACCEPTANCE} items`);
  const items = raw.map((item) => {
    if (!item || typeof item !== 'object' || Array.isArray(item) || typeof item.id !== 'string' || !/^[A-Za-z0-9_-]{1,24}$/.test(item.id)) {
      throw badRequest('payload_invalid', 'each acceptance item needs an id of 1-24 letters, digits, _ or -');
    }
    const status = item.status ?? 'open';
    if (!ACCEPTANCE_STATES.has(status)) throw badRequest('payload_invalid', 'acceptance status is open, passed or failed');
    if (item.note != null && !oneLine(item.note, 200)) throw badRequest('payload_invalid', 'acceptance note must be a single line of at most 200 characters');
    if (item.checkedAt != null && !isoTime(item.checkedAt)) throw badRequest('payload_invalid', 'acceptance checkedAt must be an ISO time');
    return { id: item.id, text: text(item.text, 'acceptance text', 300, false), check: item.check == null ? null : text(item.check, 'acceptance check', 600, true),
      status, note: item.note ?? null, checkedAt: item.checkedAt ?? null };
  });
  if (new Set(items.map((item) => item.id)).size !== items.length) throw badRequest('payload_invalid', 'acceptance ids must be distinct');
  return items;
}

function parseDesign(raw) {
  if (raw === null) return null;
  if (!raw || typeof raw !== 'object' || Array.isArray(raw) || Object.keys(raw).some((key) => !['flowId', 'summary', 'advisedBy', 'staff'].includes(key))) {
    throw badRequest('payload_invalid', 'design holds flowId, summary, advisedBy and staff');
  }
  if (raw.flowId != null && !FLOW_ID.test(raw.flowId)) throw badRequest('payload_invalid', 'invalid design flowId');
  if (raw.summary != null && (typeof raw.summary !== 'string' || [...raw.summary].length > 600 || raw.summary.includes('\0'))) {
    throw badRequest('payload_invalid', 'design summary must be text up to 600 characters');
  }
  if (raw.advisedBy != null && (typeof raw.advisedBy !== 'string' || !/^[a-z0-9._-]{1,60}$/.test(raw.advisedBy))) throw badRequest('payload_invalid', 'invalid design advisedBy');
  const staff = raw.staff ?? [];
  if (!Array.isArray(staff) || staff.length > 8 || !staff.every((id) => typeof id === 'string' && /^[a-z0-9_-]{1,24}$/.test(id))) {
    throw badRequest('payload_invalid', 'design staff lists up to 8 role ids');
  }
  return { flowId: raw.flowId ?? null, summary: raw.summary ?? null, advisedBy: raw.advisedBy ?? null, staff };
}

// The flow's own fields. `author` is decided by the calling code, never read from a request body.
function designFields(next, body, author) {
  if (!DESIGN_FIELDS.some((key) => body[key] !== undefined)) return;
  if (!DESIGN_AUTHORS.has(author)) throw new BridgeError(403, 'requirement_design_forbidden', 'acceptance, design and flowId are written by the requirement flow only');
  if (body.acceptance !== undefined) next.acceptance = parseAcceptance(body.acceptance);
  if (body.design !== undefined) next.design = parseDesign(body.design);
  if (body.flowId !== undefined) {
    if (body.flowId !== null && !FLOW_ID.test(body.flowId)) throw badRequest('payload_invalid', 'invalid requirement flowId');
    next.flowId = body.flowId;
  }
}

// Completion by anyone but the owner needs every acceptance item passed (the owner may close a
// requirement by hand in the app). Read against the list this same change leaves behind.
function assertAcceptancePassed(acceptance, statusValue, author, flowId = null) {
  if (author === 'owner' || statusValue !== 'completed') return;
  // A requirement that came through the requirement flow cannot be completed without its acceptance list.
  if (flowId && (!Array.isArray(acceptance) || !acceptance.length)) {
    throw new BridgeError(422, 'acceptance_missing', 'a requirement of the requirement flow needs its acceptance items before completion');
  }
  if (!Array.isArray(acceptance)) return;
  const open = acceptance.filter((item) => item.status !== 'passed').map((item) => item.id);
  if (open.length) throw new BridgeError(422, 'acceptance_open', `acceptance items are not passed: ${open.join(', ')}`, { details: { open } });
}

// Withdrawing must not be a way around acceptance: only the owner or the flow itself removes a
// requirement that carries a flowId or acceptance items.
function assertWithdrawAllowed(item, author) {
  if (author === 'owner' || DESIGN_AUTHORS.has(author)) return;
  if (item.flowId || (Array.isArray(item.acceptance) && item.acceptance.length)) {
    throw new BridgeError(403, 'requirement_withdraw_forbidden', 'a requirement of the requirement flow is withdrawn by the owner or the flow only');
  }
}

function logDenominator(project, at, delta, reason) {
  const fallback = delta === 1 ? '要件を追加' : '要件を取下げ';
  const line = reason === undefined ? fallback : text(reason, 'reason', 800, false);
  project.requirementDenominatorLog = [...(project.requirementDenominatorLog ?? []), { at, delta, reason: line }].slice(-20);
}

export function projectRequirements(project) {
  return (project.requirements ?? []).filter((item) => !item.withdrawnAt).sort((a, b) => a.order - b.order);
}

function text(raw, field, bytes, optional) {
  if (optional && raw === null) return null;
  if (typeof raw !== 'string' || raw.includes('\0') || Buffer.byteLength(raw) > bytes || (!optional && !raw.trim())) {
    throw badRequest('payload_invalid', `${field} must be ${optional ? 'null or ' : ''}text up to ${bytes} bytes`);
  }
  return optional && !raw.trim() ? null : raw;
}

export const parseProgressNote = (raw) => text(raw, 'progressNote', 2048, true);

function fields(body, allowed) {
  if (!Object.keys(body).length || Object.keys(body).some((key) => !allowed.includes(key))) {
    throw badRequest('payload_invalid', `expected fields: ${allowed.join(', ')}`);
  }
}

function status(raw) {
  if (!STATES.has(raw)) throw badRequest('payload_invalid', 'invalid requirement status');
  return raw;
}

function sessionIds(raw, belongs) {
  if (!Array.isArray(raw) || raw.length > MAX_SESSIONS || !raw.every((id) => typeof id === 'string' && SESSION_ID_PATTERN.test(id))
    || new Set(raw).size !== raw.length) {
    throw badRequest('payload_invalid', `sessionIds must contain at most ${MAX_SESSIONS} distinct Bridge session IDs`);
  }
  if (!raw.every(belongs)) throw conflict('session_project_mismatch', 'assign each linked session to this project first');
  return raw;
}

export function changeRequirement(project, { action, id, body, iso, belongs, author = 'owner' }) {
  const active = projectRequirements(project);
  if (action === 'order') {
    fields(body, ['ids']);
    const byId = new Map(active.map((item) => [item.id, item]));
    if (!Array.isArray(body.ids) || body.ids.length !== active.length
      || new Set(body.ids).size !== active.length || !body.ids.every((key) => byId.has(key))) {
      throw badRequest('payload_invalid', 'ids must be a permutation of all current requirements');
    }
    let changed = false;
    body.ids.forEach((key, index) => {
      const item = byId.get(key);
      if (item.order !== index) { changed = true; item.order = index; item.updatedAt = iso; }
    });
    return changed;
  }
  if (action === 'add') {
    fields(body, ['title', 'details', 'source', 'status', 'sessionIds', 'reason', ...VERIFY_FIELDS, ...DESIGN_FIELDS]);
    if (!SOURCES.has(body.source)) throw badRequest('payload_invalid', 'source must be owner or ai');
    if ((project.requirements ?? []).length >= MAX_REQUIREMENTS) {
      throw conflict('requirement_limit', `a project holds up to ${MAX_REQUIREMENTS} requirements including withdrawals`);
    }
    const next = {};
    verification(next, body, iso, author);
    designFields(next, body, author);
    assertAcceptancePassed(next.acceptance, body.status, author, next.flowId ?? null);
    if (author === 'agent' && body.reason !== undefined) assertOwnerSurface(body.reason, 'reason');
    logDenominator(project, iso, 1, body.reason);
    (project.requirements ??= []).push({
      id: `req_${randomBytes(6).toString('hex')}`,
      title: text(body.title, 'title', 600, false),
      details: body.details === undefined ? null : text(body.details, 'details', 8192, true),
      source: body.source,
      status: body.status === undefined ? 'not_started' : status(body.status),
      sessionIds: body.sessionIds === undefined ? [] : sessionIds(body.sessionIds, belongs),
      order: (active.at(-1)?.order ?? -1) + 1,
      updatedAt: iso,
      ...next,
    });
    return true;
  }
  const item = active.find((entry) => entry.id === id);
  if (!item) throw notFound('requirement not found');
  if (action === 'withdraw') {
    if (Object.keys(body).length) fields(body, ['reason']);
    assertWithdrawAllowed(item, author);
    if (author === 'agent' && body.reason !== undefined) assertOwnerSurface(body.reason, 'reason');
    logDenominator(project, iso, -1, body.reason);
    item.withdrawnAt = item.updatedAt = iso;
    return true;
  }
  const next = {};
  if (action === 'attach') {
    next.sessionIds = sessionIds([...new Set([...item.sessionIds, body.sessionId])], belongs);
    if (item.status === 'not_started') next.status = 'in_progress';
  } else {
    fields(body, ['title', 'details', 'status', 'sessionIds', ...VERIFY_FIELDS, ...DESIGN_FIELDS]);
    verification(next, body, iso, author);
    designFields(next, body, author);
    assertAcceptancePassed(next.acceptance ?? item.acceptance, body.status, author, next.flowId ?? item.flowId ?? null);
    // Replaying the same verified transition must not re-date the evidence.
    if (next.verifiedAt && next.verifiedBy === item.verifiedBy && next.note === item.note
      && (next.requestId === undefined || next.requestId === item.requestId) && item.verifiedAt) next.verifiedAt = item.verifiedAt;
    if (body.title !== undefined) {
      next.title = text(body.title, 'title', 600, false);
      if (item.source === 'owner' && next.title !== item.title) {
        throw conflict('requirement_title_locked', 'keep the owner’s original words and update details instead');
      }
    }
    if (body.details !== undefined) next.details = text(body.details, 'details', 8192, true);
    if (body.status !== undefined) next.status = status(body.status);
    if (body.sessionIds !== undefined) next.sessionIds = sessionIds(body.sessionIds, belongs);
  }
  if (!Object.keys(next).some((key) => JSON.stringify(next[key]) !== JSON.stringify(item[key]))) return false;
  Object.assign(item, next, { updatedAt: iso });
  return true;
}

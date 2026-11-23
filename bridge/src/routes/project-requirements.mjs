import { randomBytes } from 'node:crypto';
import { badRequest, conflict, notFound } from '../errors.mjs';
import { SESSION_ID_PATTERN } from '../sessions/store.mjs';

export const REQUIREMENT_ID = /^req_[0-9a-f]{12}$/;
const MAX_REQUIREMENTS = 200;
const MAX_SESSIONS = 30;
const STATES = new Set(['not_started', 'in_progress', 'awaiting_decision', 'completed']);
const SOURCES = new Set(['owner', 'ai']);

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

export function changeRequirement(project, { action, id, body, iso, belongs }) {
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
    fields(body, ['title', 'details', 'source', 'status', 'sessionIds']);
    if (!SOURCES.has(body.source)) throw badRequest('payload_invalid', 'source must be owner or ai');
    if ((project.requirements ?? []).length >= MAX_REQUIREMENTS) {
      throw conflict('requirement_limit', `a project holds up to ${MAX_REQUIREMENTS} requirements including withdrawals`);
    }
    (project.requirements ??= []).push({
      id: `req_${randomBytes(6).toString('hex')}`,
      title: text(body.title, 'title', 600, false),
      details: body.details === undefined ? null : text(body.details, 'details', 8192, true),
      source: body.source,
      status: body.status === undefined ? 'not_started' : status(body.status),
      sessionIds: body.sessionIds === undefined ? [] : sessionIds(body.sessionIds, belongs),
      order: (active.at(-1)?.order ?? -1) + 1,
      updatedAt: iso,
    });
    return true;
  }
  const item = active.find((entry) => entry.id === id);
  if (!item) throw notFound('requirement not found');
  if (action === 'withdraw') {
    item.withdrawnAt = item.updatedAt = iso;
    return true;
  }
  const next = {};
  if (action === 'attach') {
    next.sessionIds = sessionIds([...new Set([...item.sessionIds, body.sessionId])], belongs);
    if (item.status === 'not_started') next.status = 'in_progress';
  } else {
    fields(body, ['title', 'details', 'status', 'sessionIds']);
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

// The mobile intake's accepted subset. Keep in step with Studio's
// src/shared/mobile.ts; reject unknown keys rather than silently changing intent.
import { BridgeError } from '../errors.mjs';

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const entity = /^[a-zA-Z0-9-]{1,100}$/;
const object = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const exact = (v, required, optional = []) => object(v) && required.every((k) => Object.hasOwn(v, k)) &&
  Object.keys(v).every((k) => required.includes(k) || optional.includes(k));
const nonnegative = (v) => Number.isSafeInteger(v) && v >= 0;
const string = (v, max) => typeof v === 'string' && v.length <= max;
const invalid = () => { throw new BridgeError(400, 'studio_payload_invalid', 'Studio request does not match the intake contract'); };

export function validateRequest(value) {
  if (!exact(value, ['id', 'projectId', 'expectedRevision', 'prompt'], ['create', 'principle']) ||
      typeof value.id !== 'string' || !uuid.test(value.id) || typeof value.projectId !== 'string' || !entity.test(value.projectId) || !nonnegative(value.expectedRevision) ||
      !string(value.prompt, 10000) || !value.prompt.trim()) invalid();
  if (value.create !== undefined && (!exact(value.create, ['title']) ||
      !string(value.create.title, 300) || !value.create.title.trim() || value.projectId !== value.id || value.expectedRevision !== 0)) invalid();
  if (value.principle !== undefined && (!exact(value.principle, ['id', 'version', 'revision']) ||
      typeof value.principle.id !== 'string' || !entity.test(value.principle.id) || !string(value.principle.version, 100) || !nonnegative(value.principle.revision))) invalid();
  return { ...value, prompt: value.prompt.trim(), ...(value.create ? { create: { title: value.create.title.trim() } } : {}) };
}

export function validateAction(value) {
  if (!object(value) || typeof value.id !== 'string' || !uuid.test(value.id)) invalid();
  if (value.action === 'resume' && exact(value, ['action', 'id'])) {
    throw new BridgeError(409, 'studio_resume_unsupported', 'Studio cannot resume; create a new request from the latest revision');
  }
  if (value.action === 'stop' && exact(value, ['action', 'id'])) return value;
  if (value.action !== 'answer' || !exact(value, ['action', 'id', 'approvalId', 'accept', 'content'], ['persist']) ||
      typeof value.approvalId !== 'string' || !uuid.test(value.approvalId) || typeof value.accept !== 'boolean' || !object(value.content) ||
      (value.persist !== undefined && typeof value.persist !== 'boolean')) invalid();
  if (!Object.entries(value.content).every(([key, item]) => key.length <= 100 &&
      ((typeof item === 'string' && item.length <= 4000) || typeof item === 'boolean' ||
       (typeof item === 'number' && Number.isFinite(item))))) invalid();
  return { ...value, persist: value.persist ?? false };
}

export function parseBody(raw) {
  try { return JSON.parse(raw.toString('utf8')); } catch { return invalid(); }
}

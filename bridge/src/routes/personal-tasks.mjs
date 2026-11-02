// Owner-scoped Linear endpoints. The existing /v1/tasks agent view remains
// untouched for clients which depend on it.
import { BridgeError, badRequest } from '../errors.mjs';
import { createHash, randomUUID } from 'node:crypto';
import { IDEMPOTENCY_KEY_PATTERN } from '../idempotency.mjs';
import { parseObjectBody } from './state-file.mjs';
import { createTaskOperationLedger, operationFingerprint } from '../tasks/operation-ledger.mjs';
import { createPersonalLinearSource } from '../tasks/personal.mjs';
import { createAgentInboxSource } from '../tasks/agent-inbox.mjs';
import { createOwnerTaskNotificationPoller } from '../tasks/owner-notifications.mjs';
import { TaskSourceError } from '../tasks/errors.mjs';

const DETAIL = /^\/v1\/personal-tasks\/([^/]+)$/;
const SECTION = /^\/v1\/personal-tasks\/([^/]+)\/(comments|children|history|relations|inverse-relations|attachments)$/;
const REPLIES = /^\/v1\/personal-tasks\/([^/]+)\/comments\/([^/]+)\/replies$/;
const FILES = /^\/v1\/personal-tasks\/([^/]+)\/files$/;
const FILE_CONTENT = /^\/v1\/personal-tasks\/([^/]+)\/files\/([0-9a-f]{64})\/content$/;
const ATTACHMENT_CONTENT = /^\/v1\/personal-tasks\/([^/]+)\/attachments\/([^/]+)\/content$/;
const FILE_UPLOAD = /^\/v1\/personal-tasks\/([^/]+)\/files$/;
const INBOX_ITEM = /^\/v1\/task-inbox\/([^/]+)$/;
const UPLOAD_LIMIT = 20 * 1024 * 1024;
const OPERATION = /^\/v1\/task-operations\/([0-9a-f-]+)$/i;
const RESOLUTION = /^\/v1\/task-operations\/([0-9a-f-]+)\/resolve$/i;
const ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,200}$/;

function asBridgeError(error) {
  if (error instanceof BridgeError) return error;
  if (error instanceof TaskSourceError) {
    return new BridgeError(error.status, error.code, error.message, { retryable: error.retryable });
  }
  // Dependency and helper exceptions may contain credentials or issue text.
  return new BridgeError(503, 'linear_unavailable', 'the personal Linear source is not available', { retryable: true });
}

function parameters(req) { return new URL(req.url ?? '/', 'http://127.0.0.1').searchParams; }
function requestedId(value) {
  try {
    const id = decodeURIComponent(value);
    if (ID.test(id)) return id;
  } catch { /* same refusal for all malformed ids */ }
  throw badRequest('task_id_invalid', 'the task id is invalid');
}
function guarded(handler) {
  return async (context) => {
    try { return await handler(context); } catch (error) { throw asBridgeError(error); }
  };
}

function requireKey(req) {
  const key = req.headers['idempotency-key'];
  if (typeof key !== 'string' || !IDEMPOTENCY_KEY_PATTERN.test(key)) {
    throw badRequest('idempotency_key_required', 'a valid Idempotency-Key is required');
  }
  return key;
}

const ISSUE_IDS = new Set(['teamId', 'assigneeId', 'stateId', 'projectId', 'projectMilestoneId', 'cycleId', 'parentId']);
const NULLABLE_IDS = new Set(['assigneeId', 'projectId', 'projectMilestoneId', 'cycleId', 'parentId']);
function issueInput(rawBody, creating) {
  const { expectedViewerId, ...input } = parseObjectBody(rawBody);
  if (typeof expectedViewerId !== 'string' || !ID.test(expectedViewerId)) {
    throw badRequest('expected_viewer_required', 'the original Linear viewer is required');
  }
  const allowed = new Set(['title', 'description', 'priority', 'estimate', 'dueDate', 'labelIds', ...ISSUE_IDS]);
  if (Object.keys(input).length === 0 || Object.keys(input).some((name) => !allowed.has(name))) {
    throw badRequest('payload_invalid', 'the task contains an unsupported field');
  }
  if (creating && (typeof input.teamId !== 'string' || typeof input.title !== 'string')) {
    throw badRequest('payload_invalid', 'teamId and title are required');
  }
  if ('title' in input && (typeof input.title !== 'string' || input.title.trim() === '' || input.title.length > 512)) {
    throw badRequest('payload_invalid', 'title must contain 1–512 characters');
  }
  if ('description' in input && (typeof input.description !== 'string' || Buffer.byteLength(input.description, 'utf8') > 48 * 1024)) {
    throw badRequest('payload_invalid', 'description must be text of at most 48 KiB');
  }
  for (const field of ISSUE_IDS) {
    if (!(field in input)) continue;
    const value = input[field];
    if (value === null && NULLABLE_IDS.has(field)) continue;
    if (typeof value !== 'string' || !ID.test(value)) throw badRequest('payload_invalid', `${field} is invalid`);
  }
  if ('priority' in input && (!Number.isInteger(input.priority) || input.priority < 0 || input.priority > 4)) {
    throw badRequest('payload_invalid', 'priority must be between 0 and 4');
  }
  if ('estimate' in input && input.estimate !== null && (!Number.isInteger(input.estimate) || input.estimate < 0 || input.estimate > 10000)) {
    throw badRequest('payload_invalid', 'estimate must be a non-negative integer or null');
  }
  if ('dueDate' in input && input.dueDate !== null) {
    if (typeof input.dueDate !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(input.dueDate)
        || !Number.isFinite(Date.parse(`${input.dueDate}T00:00:00Z`))
        || new Date(`${input.dueDate}T00:00:00Z`).toISOString().slice(0, 10) !== input.dueDate) {
      throw badRequest('payload_invalid', 'dueDate must be a valid ISO date or null');
    }
  }
  if ('labelIds' in input && (!Array.isArray(input.labelIds) || input.labelIds.length > 100
      || input.labelIds.some((id) => typeof id !== 'string' || !ID.test(id)))) {
    throw badRequest('payload_invalid', 'labelIds must be an array of at most 100 ids');
  }
  return { input, expectedViewerId };
}

function taskItemInput(rawBody, kind) {
  const { expectedViewerId, ...input } = parseObjectBody(rawBody);
  if (typeof expectedViewerId !== 'string' || !ID.test(expectedViewerId)) {
    throw badRequest('expected_viewer_required', 'the original Linear viewer is required');
  }
  const allowed = { comment: ['body', 'parentId'], relation: ['relatedIssueId', 'type'], attachment: ['title', 'url', 'subtitle'] }[kind];
  if (!allowed || Object.keys(input).some((name) => !allowed.includes(name))) {
    throw badRequest('payload_invalid', 'the task item contains an unsupported field');
  }
  const validId = (value) => typeof value === 'string' && ID.test(value);
  if (kind === 'comment' && (typeof input.body !== 'string' || input.body.trim() === ''
      || Buffer.byteLength(input.body, 'utf8') > 48 * 1024 || ('parentId' in input && !validId(input.parentId)))) {
    throw badRequest('payload_invalid', 'a comment needs text of at most 48 KiB and an optional parent');
  }
  if (kind === 'relation' && (!validId(input.relatedIssueId)
      || !['blocks', 'duplicate', 'related', 'similar'].includes(input.type))) {
    throw badRequest('payload_invalid', 'the related task or relation type is invalid');
  }
  if (kind === 'attachment') {
    let url;
    try { url = new URL(input.url); } catch { /* handled below */ }
    if (typeof input.title !== 'string' || input.title.trim() === '' || input.title.length > 512
        || typeof input.url !== 'string' || input.url.length > 2048 || !url || url.protocol !== 'https:'
        || url.username || url.password || ('subtitle' in input && (typeof input.subtitle !== 'string' || input.subtitle.length > 512))) {
      throw badRequest('payload_invalid', 'the attachment needs a title and an HTTPS link');
    }
  }
  return { input, expectedViewerId };
}

export function personalTaskRoutes({ personal, personalConfig, store, registerCleanup, now = () => Date.now() } = {}) {
  const personalMode = Boolean(process.env.LAA_LINEAR_PERSONAL_TOKEN_HELPER && process.env.LAA_LINEAR_PERSONAL_VIEWER_ID);
  const baseSource = personal ?? createPersonalLinearSource({ agentAccount: !personalMode,
    tokenHelper: personalMode ? process.env.LAA_LINEAR_PERSONAL_TOKEN_HELPER
      : process.env.LAA_BRIDGE_LINEAR_TOKEN_HELPER ?? '/Users/laa/.config/laa/linear-agent-token.sh', ...personalConfig, now });
  const source = baseSource.agentAccount === true ? createAgentInboxSource({ source: baseSource, store, now }) : baseSource;
  if (registerCleanup && source.ownerInboxAvailable === true) {
    const poller = createOwnerTaskNotificationPoller({ source });
    registerCleanup(() => poller.stop()); poller.start();
  }
  const operations = createTaskOperationLedger({ store, now });
  const inFlight = new Set();
  let activeUploads = 0;
  const read = (path, handler, pattern) => ({
    method: 'GET', path, ...(pattern ? { pattern } : {}), auth: true, scope: 'tasks:read', handler: guarded(handler),
  });
  const collection = (name) => async ({ req }) => {
    const query = parameters(req);
    return { status: 200, data: await source.listCollection(name, { cursor: query.get('cursor'), limit: query.get('limit'),
      ...(name === 'inbox' ? { includeArchived: query.get('includeArchived') } : {}) }) };
  };
  const write = (method, path, handler, pattern) => ({
    method, path, ...(pattern ? { pattern } : {}), auth: true, scope: 'tasks:write', handler: guarded(handler),
  });
  async function requestSession() { return source.session(); }
  const statusFor = (entry) => ({ status: 200, data: { operation: entry } });
  const expiredOperation = (entry) => entry
    ? new BridgeError(409, 'idempotency_outcome_unknown', 'the earlier result must be reconciled', { details: { operation: entry } })
    : new BridgeError(410, 'task_operation_compacted', 'the completed operation was compacted; its result is no longer available', { details: { tombstone: true } });
  const preflightStatus = (error) => asBridgeError(error).retryable ? 'preflight_retryable' : 'rejected';
  const isDefiniteRejection = (error) => error instanceof TaskSourceError && error.code === 'linear_rejected';
  function resolved(previous) {
    if (previous.status === 'resolved') throw new BridgeError(409, 'operation_resolved',
      'the earlier operation was reconciled; use a new key for a new request', { details: { operation: previous } });
  }

  async function mutateIssue({ req, device, rawBody, params }, creating) {
    const key = requireKey(req);
    const { input, expectedViewerId } = issueInput(rawBody, creating);
    const target = creating ? randomUUID() : requestedId(params[0]);
    const hasDescription = !creating && Object.hasOwn(input, 'description');
    const ifMatch = req.headers['if-match'];
    if (hasDescription && (typeof ifMatch !== 'string' || ifMatch.trim() === '')) {
      throw new BridgeError(428, 'if_match_required', 'editing a description requires its previously read version');
    }
    const personalSession = await requestSession();
    const viewerId = personalSession.viewer.id;
    if (viewerId !== expectedViewerId) {
      throw new BridgeError(409, 'linear_viewer_changed', 'the task was prepared for a different Linear viewer');
    }
    const path = creating ? '/v1/personal-tasks' : `/v1/personal-tasks/${encodeURIComponent(target)}`;
    const reserved = operations.reserve({ deviceId: device.id, viewerId, key, method: req.method, path,
      ifMatch: typeof ifMatch === 'string' ? ifMatch : null, rawBody, kind: creating ? 'create' : 'update', targetId: target });
    if (reserved.action === 'conflict') throw new BridgeError(409, 'idempotency_key_conflict', 'the key belongs to a different request');
    if (reserved.action === 'expired') {
      throw expiredOperation(reserved.entry);
    }
    if (reserved.action === 'existing') {
      const previous = reserved.entry;
      resolved(previous);
      if (previous.status === 'succeeded') return statusFor(previous);
      if (previous.status === 'rejected') {
        if (reserved.rejection === 'version_mismatch') {
          const current = await source.getTaskInSession(personalSession, target);
          throw new BridgeError(412, 'version_mismatch', 'the description changed; compare it before saving', { details: { current: current?.task ?? null } });
        }
        throw new BridgeError(409, 'task_operation_rejected', 'the previous request was refused before the Linear write');
      }
      if (previous.status === 'in_progress') {
        throw new BridgeError(409, 'idempotency_key_in_flight', 'the same operation is still in progress', { details: { operation: previous } });
      }
      throw new BridgeError(409, 'idempotency_outcome_unknown', 'the earlier operation must be reconciled', { details: { operation: previous } });
    }
    const operationId = reserved.entry.operationId;
    inFlight.add(operationId);
    let sent = false;
    try {
      let updateTarget = target;
      if (!creating) {
        const current = await source.getTaskInSession(personalSession, target);
        if (!current?.task?.linearId) throw new BridgeError(404, 'task_not_found', 'the task was not found');
        updateTarget = current.task.linearId;
        const version = typeof ifMatch === 'string' && /^"[^"\r\n]+"$/.test(ifMatch) ? ifMatch.slice(1, -1) : ifMatch;
        if (hasDescription && current.task.updatedAt !== version) {
          throw new BridgeError(412, 'version_mismatch', 'the description changed; compare it before saving', { details: { current: current.task } });
        }
      }
      if (creating) await source.prepareActor?.(personalSession);
      sent = true;
      const result = creating
        ? await source.createIssue(personalSession, { ...input, id: reserved.entry.targetId })
        : await source.updateIssue(personalSession, updateTarget, input);
      if (result.id !== (creating ? reserved.entry.targetId : updateTarget)) {
        throw new Error('Linear returned a different target');
      }
      const finished = operations.finish({ deviceId: device.id, viewerId, key, status: 'succeeded', result });
      return { status: creating ? 201 : 200, data: { operation: finished } };
    } catch (error) {
      if (!sent) {
        const rejection = error instanceof BridgeError && ['version_mismatch', 'task_not_found'].includes(error.code)
          ? error.code : 'preflight_failed';
        operations.finish({ deviceId: device.id, viewerId, key, status: preflightStatus(error), rejection });
        throw error;
      }
      if (isDefiniteRejection(error)) {
        operations.finish({ deviceId: device.id, viewerId, key, status: 'rejected', rejection: 'linear_rejected' });
        throw error;
      }
      try { operations.finish({ deviceId: device.id, viewerId, key, status: 'outcome_unknown' }); } catch { /* fail closed */ }
      throw new BridgeError(409, 'idempotency_outcome_unknown', 'Linear may have received the operation; reconcile before retrying', {
        details: { operationId },
      });
    } finally {
      inFlight.delete(operationId);
    }
  }
  async function createTaskItem({ req, device, rawBody, params }) {
    const section = params[1];
    const kind = { comments: 'comment', relations: 'relation', attachments: 'attachment' }[section];
    if (!kind) throw badRequest('payload_invalid', 'this task section cannot be created');
    const key = requireKey(req);
    const { input, expectedViewerId } = taskItemInput(rawBody, kind);
    const issueId = requestedId(params[0]);
    const personalSession = await requestSession();
    const viewerId = personalSession.viewer.id;
    if (viewerId !== expectedViewerId) {
      throw new BridgeError(409, 'linear_viewer_changed', 'the task item was prepared for a different Linear viewer');
    }
    const path = `/v1/personal-tasks/${encodeURIComponent(issueId)}/${section}`;
    const reserved = operations.reserve({ deviceId: device.id, viewerId, key, method: req.method, path,
      ifMatch: null, rawBody, kind, targetId: randomUUID(), contextId: issueId });
    if (reserved.action === 'conflict') throw new BridgeError(409, 'idempotency_key_conflict', 'the key belongs to a different request');
    if (reserved.action === 'expired') {
      throw expiredOperation(reserved.entry);
    }
    if (reserved.action === 'existing') {
      const previous = reserved.entry;
      resolved(previous);
      if (previous.status === 'succeeded') return statusFor(previous);
      if (previous.status === 'rejected') throw new BridgeError(409, 'task_operation_rejected', 'the previous request was refused before the Linear write');
      if (previous.status === 'in_progress') {
        throw new BridgeError(409, 'idempotency_key_in_flight', 'the same operation is still in progress', { details: { operation: previous } });
      }
      throw new BridgeError(409, 'idempotency_outcome_unknown', 'the earlier operation must be reconciled', { details: { operation: previous } });
    }
    const operationId = reserved.entry.operationId;
    inFlight.add(operationId);
    let sent = false;
    try {
      const issue = await source.getTaskInSession(personalSession, issueId);
      if (!issue?.task?.linearId) throw new BridgeError(404, 'task_not_found', 'the task was not found');
      const fields = { ...input, id: reserved.entry.targetId, issueId: issue.task.linearId };
      if (kind === 'comment' && input.parentId) await source.assertCommentInIssue(personalSession, input.parentId, issue.task.linearId);
      if (kind === 'relation') {
        const related = await source.getTaskInSession(personalSession, input.relatedIssueId);
        if (!related?.task?.linearId) throw new BridgeError(404, 'task_not_found', 'the related task was not found');
        if (related.task.linearId === issue.task.linearId) throw badRequest('payload_invalid', 'a task cannot relate to itself');
        fields.relatedIssueId = related.task.linearId;
      }
      if (kind === 'comment') await source.prepareActor?.(personalSession);
      sent = true;
      const result = await source.createTaskItem(personalSession, kind, fields);
      // Attachment creation can upsert an existing link by URL, while new
      // comments and relations are created with the reserved UUID.
      if (kind !== 'attachment' && result.id !== reserved.entry.targetId) throw new Error('Linear returned a different task item');
      const finished = operations.finish({ deviceId: device.id, viewerId, key, status: 'succeeded', result });
      return { status: 201, data: { operation: finished } };
    } catch (error) {
      if (!sent) {
        operations.finish({ deviceId: device.id, viewerId, key, status: preflightStatus(error), rejection: 'preflight_failed' });
        throw error;
      }
      if (isDefiniteRejection(error)) {
        operations.finish({ deviceId: device.id, viewerId, key, status: 'rejected', rejection: 'linear_rejected' });
        throw error;
      }
      try { operations.finish({ deviceId: device.id, viewerId, key, status: 'outcome_unknown' }); } catch { /* fail closed */ }
      throw new BridgeError(409, 'idempotency_outcome_unknown', 'Linear may have received the operation; reconcile before retrying', {
        details: { operationId },
      });
    } finally { inFlight.delete(operationId); }
  }
  async function updateInbox({ req, device, rawBody, params }) {
    const key = requireKey(req);
    const id = requestedId(params[0]);
    const body = parseObjectBody(rawBody);
    if (Object.keys(body).sort().join(',') !== 'action,expectedViewerId'
        || typeof body.expectedViewerId !== 'string' || !ID.test(body.expectedViewerId)
        || !['read', 'unread', 'archive', 'unarchive'].includes(body.action)) {
      throw badRequest('payload_invalid', 'the viewer and supported notification action are required');
    }
    const personalSession = await requestSession();
    const viewerId = personalSession.viewer.id;
    if (viewerId !== body.expectedViewerId) {
      throw new BridgeError(409, 'linear_viewer_changed', 'the notification belongs to a different Linear viewer');
    }
    const path = `/v1/task-inbox/${encodeURIComponent(id)}`;
    const reserved = operations.reserve({ deviceId: device.id, viewerId, key, method: 'PATCH', path,
      ifMatch: null, rawBody, kind: `inbox_${body.action}`, targetId: id });
    if (reserved.action === 'conflict') throw new BridgeError(409, 'idempotency_key_conflict', 'the key belongs to a different request');
    if (reserved.action === 'expired') throw expiredOperation(reserved.entry);
    if (reserved.action === 'existing') {
      const previous = reserved.entry;
      resolved(previous);
      if (previous.status === 'succeeded') return statusFor(previous);
      if (previous.status === 'rejected') throw new BridgeError(409, 'task_operation_rejected', 'the previous request was refused');
      if (previous.status === 'in_progress') throw new BridgeError(409, 'idempotency_key_in_flight', 'the same operation is still in progress', { details: { operation: previous } });
      throw new BridgeError(409, 'idempotency_outcome_unknown', 'the earlier operation must be reconciled', { details: { operation: previous } });
    }
    const operationId = reserved.entry.operationId;
    inFlight.add(operationId);
    let sent = false;
    try {
      // The notification ID alone is not authority to change another user's Inbox.
      const current = await source.getNotificationInSession(personalSession, id);
      if (!current || current.id !== id || current.user?.id !== viewerId) {
        throw new BridgeError(404, 'notification_not_found', 'the notification was not found');
      }
      if (!Object.hasOwn(current, 'readAt') || !(current.readAt === null || typeof current.readAt === 'string')
          || !Object.hasOwn(current, 'archivedAt') || !(current.archivedAt === null || typeof current.archivedAt === 'string')) {
        throw new BridgeError(503, 'linear_response_invalid', 'Linear returned an incomplete notification');
      }
      const already = body.action === 'read' ? current.readAt !== null : body.action === 'unread' ? current.readAt === null
        : body.action === 'archive' ? current.archivedAt !== null : current.archivedAt === null;
      let result = { id };
      if (!already) {
        sent = true;
        result = await source.updateNotification(personalSession, id, body.action);
        if (result?.id !== id) throw new Error('Linear returned a different notification');
      }
      return statusFor(operations.finish({ deviceId: device.id, viewerId, key, status: 'succeeded', result }));
    } catch (error) {
      if (!sent) {
        operations.finish({ deviceId: device.id, viewerId, key, status: preflightStatus(error),
          rejection: error.code === 'notification_not_found' ? 'notification_not_found' : 'preflight_failed' });
        throw error;
      }
      if (isDefiniteRejection(error)) {
        operations.finish({ deviceId: device.id, viewerId, key, status: 'rejected', rejection: 'linear_rejected' });
        throw error;
      }
      try { operations.finish({ deviceId: device.id, viewerId, key, status: 'outcome_unknown' }); } catch { /* fail closed */ }
      throw new BridgeError(409, 'idempotency_outcome_unknown', 'Linear may have received the operation; reconcile before retrying', { details: { operationId } });
    } finally { inFlight.delete(operationId); }
  }
  async function uploadTaskFile({ req, device, params }) {
    const key = requireKey(req);
    const issueId = requestedId(params[0]);
    const viewerId = req.headers['x-linear-viewer-id'];
    const encodedName = req.headers['x-linear-file-name'];
    const contentType = req.headers['content-type'];
    const expectedHash = req.headers['x-linear-content-sha256'];
    const rawLength = req.headers['content-length'];
    if (typeof viewerId !== 'string' || !ID.test(viewerId)) throw badRequest('expected_viewer_required', 'the original Linear viewer is required');
    if (typeof encodedName !== 'string' || !/^[A-Za-z0-9+/]+={0,2}$/.test(encodedName) || encodedName.length > 700) {
      throw badRequest('payload_invalid', 'the filename is invalid');
    }
    const nameBytes = Buffer.from(encodedName, 'base64');
    const filename = nameBytes.toString('utf8');
    if (nameBytes.toString('base64') !== encodedName || !filename || filename.length > 200 ||
        Buffer.from(filename).compare(nameBytes) !== 0 || /[\/\\\x00-\x1f\x7f]/.test(filename)) {
      throw badRequest('payload_invalid', 'the filename is invalid');
    }
    if (typeof contentType !== 'string' || !/^[a-zA-Z0-9!#$&^_.+-]+\/[a-zA-Z0-9!#$&^_.+-]+$/.test(contentType) || contentType.length > 128 ||
        typeof expectedHash !== 'string' || !/^[0-9a-f]{64}$/.test(expectedHash)) {
      throw badRequest('payload_invalid', 'the file type or digest is invalid');
    }
    if (typeof rawLength !== 'string' || !/^\d+$/.test(rawLength) || Number(rawLength) < 1 || Number(rawLength) > UPLOAD_LIMIT) {
      throw new BridgeError(413, 'file_too_large', 'the file must contain 1 byte to 20 MiB');
    }
    if (activeUploads >= 2) throw new BridgeError(429, 'upload_busy', 'two uploads are already in progress', { retryable: true });
    activeUploads += 1;
    try {
      const personalSession = await requestSession();
      if (personalSession.viewer.id !== viewerId) throw new BridgeError(409, 'linear_viewer_changed', 'the upload was prepared for a different Linear viewer');
      const chunks = []; let size = 0;
      try {
        for await (const chunk of req) {
          size += chunk.length;
          if (size > Number(rawLength) || size > UPLOAD_LIMIT) throw new BridgeError(413, 'file_too_large', 'the upload exceeds its declared size');
          chunks.push(chunk);
        }
      } catch (error) {
        if (error instanceof BridgeError) throw error;
        throw badRequest('upload_interrupted', 'the upload was interrupted');
      }
      if (size !== Number(rawLength)) throw badRequest('upload_interrupted', 'the upload was incomplete');
      const bytes = Buffer.concat(chunks);
      const hash = createHash('sha256').update(bytes).digest('hex');
      if (hash !== expectedHash) throw badRequest('payload_invalid', 'the file digest did not match');
      const path = `/v1/personal-tasks/${encodeURIComponent(issueId)}/files`;
      const rawBody = Buffer.from(JSON.stringify({ viewerId, filename, contentType, size, hash }));
      const reserved = operations.reserve({ deviceId: device.id, viewerId, key, method: 'POST', path,
        ifMatch: null, rawBody, kind: 'file', targetId: randomUUID(), contextId: issueId });
      if (reserved.action === 'conflict') throw new BridgeError(409, 'idempotency_key_conflict', 'the key belongs to a different request');
      if (reserved.action === 'expired') throw expiredOperation(reserved.entry);
      if (reserved.action === 'existing') {
        const previous = reserved.entry;
        resolved(previous);
        if (previous.status === 'succeeded') return statusFor(previous);
        if (previous.status === 'rejected') throw new BridgeError(409, 'task_operation_rejected', 'the previous upload was refused before association');
        if (previous.status === 'in_progress') throw new BridgeError(409, 'idempotency_key_in_flight', 'the same upload is still in progress', { details: { operation: previous } });
        throw new BridgeError(409, 'idempotency_outcome_unknown', 'the earlier upload must be reconciled', { details: { operation: previous } });
      }
      const operationId = reserved.entry.operationId;
      inFlight.add(operationId);
      let sent = false;
      let storageStarted = false;
      let assetUrl = null;
      try {
        const issue = await source.getTaskInSession(personalSession, issueId);
        if (!issue?.task?.linearId) throw new BridgeError(404, 'task_not_found', 'the task was not found');
        storageStarted = true;
        assetUrl = await source.uploadFile(personalSession, { filename, contentType, bytes });
        sent = true;
        const result = await source.createTaskItem(personalSession, 'attachment', {
          id: reserved.entry.targetId, issueId: issue.task.linearId, title: filename, url: assetUrl,
        });
        const finished = operations.finish({ deviceId: device.id, viewerId, key, status: 'succeeded', result });
        return { status: 201, data: { operation: finished } };
      } catch (error) {
        if (!sent) {
          operations.finish({ deviceId: device.id, viewerId, key, status: storageStarted ? 'rejected' : preflightStatus(error), rejection: 'preflight_failed' });
          if (storageStarted && asBridgeError(error).retryable) {
            const refusal = asBridgeError(error);
            throw new BridgeError(refusal.status, refusal.code, refusal.message);
          }
          throw error;
        }
        if (isDefiniteRejection(error)) {
          // Record the definite refusal before cleanup. A crash or cleanup
          // failure must never turn the association into an automatic retry.
          operations.finish({ deviceId: device.id, viewerId, key, status: 'rejected', rejection: 'linear_rejected',
            cleanupAssetHash: createHash('sha256').update(assetUrl).digest('hex') });
          try { await source.deleteUpload(personalSession, assetUrl); } catch { /* best effort; never leak URL */ }
          throw error;
        }
        try { operations.finish({ deviceId: device.id, viewerId, key, status: 'outcome_unknown' }); } catch { /* fail closed */ }
        throw new BridgeError(409, 'idempotency_outcome_unknown', 'Linear may have received the file association; reconcile before retrying', { details: { operationId } });
      } finally { inFlight.delete(operationId); }
    } finally { activeUploads -= 1; }
  }
  async function operationContext(device) {
    const session = await requestSession();
    return { deviceId: device.id, viewerId: session.viewer.id };
  }
  async function originalContext(device, body) {
    if (typeof body.originalDeviceId !== 'string' || !/^dev_[a-f0-9]{16}$/.test(body.originalDeviceId)
        || typeof body.expectedViewerId !== 'string' || !ID.test(body.expectedViewerId)) {
      throw badRequest('payload_invalid', 'the original device and viewer are required');
    }
    // Re-pairing creates a new device ID; only previously registered devices
    // and the very same configured viewer can recover a former operation.
    if (!Object.hasOwn(store.read().devices, body.originalDeviceId)) {
      throw new BridgeError(404, 'operation_not_found', 'the task operation was not found');
    }
    const current = await operationContext(device);
    if (current.viewerId !== body.expectedViewerId) {
      throw new BridgeError(409, 'linear_viewer_changed', 'the original viewer is required');
    }
    return { deviceId: body.originalDeviceId, viewerId: current.viewerId };
  }
  return [
    read('/v1/personal-tasks', async ({ req }) => {
      const query = parameters(req);
      return { status: 200, data: await source.listTasks({
        view: query.get('view'), search: query.get('search'), project: query.get('project'),
        cycle: query.get('cycle'), customView: query.get('customView'),
        cursor: query.get('cursor'), limit: query.get('limit'),
      }) };
    }),
    read('/v1/personal-tasks/{id}', async ({ params }) => {
      const result = await source.getTask(requestedId(params[0]));
      if (!result) throw new BridgeError(404, 'task_not_found', 'the task was not found');
      return { status: 200, data: result };
    }, DETAIL),
    read('/v1/personal-tasks/{id}/files', async ({ req, params }) => {
      const comment = parameters(req).get('comment');
      return { status: 200, data: await source.listFiles(requestedId(params[0]), comment ? requestedId(comment) : null) };
    }, FILES),
    { ...write('POST', '/v1/personal-tasks/{id}/files', uploadTaskFile, FILE_UPLOAD), streamBody: true },
    read('/v1/personal-tasks/{id}/files/{fileId}/content', async ({ req, params }) => {
      const comment = parameters(req).get('comment');
      return { status: 200, data: await source.readFile(requestedId(params[0]), {
        assetId: params[1], commentId: comment ? requestedId(comment) : null,
      }) };
    }, FILE_CONTENT),
    read('/v1/personal-tasks/{id}/attachments/{attachmentId}/content', async ({ params }) => ({
      status: 200, data: await source.readFile(requestedId(params[0]), { attachmentId: requestedId(params[1]) }),
    }), ATTACHMENT_CONTENT),
    read('/v1/personal-tasks/{id}/{section}', async ({ req, params }) => {
      const query = parameters(req);
      const section = params[1] === 'inverse-relations' ? 'inverseRelations' : params[1];
      return { status: 200, data: await source.listTaskSection(section, requestedId(params[0]), {
        cursor: query.get('cursor'), limit: query.get('limit'),
      }) };
    }, SECTION),
    read('/v1/personal-tasks/{id}/comments/{commentId}/replies', async ({ req, params }) => {
      const query = parameters(req);
      return { status: 200, data: await source.listTaskSection('commentReplies', requestedId(params[0]), {
        commentId: requestedId(params[1]), cursor: query.get('cursor'), limit: query.get('limit'),
      }) };
    }, REPLIES),
    read('/v1/task-metadata', async () => ({ status: 200, data: await source.metadata() })),
    read('/v1/task-projects', collection('projects')),
    read('/v1/task-cycles', collection('cycles')),
    read('/v1/task-views', collection('views')),
    read('/v1/task-inbox', collection('inbox')),
    read('/v1/task-inbox/{id}', async ({ params }) => ({
      status: 200, data: await source.getNotification(requestedId(params[0])),
    }), INBOX_ITEM),
    read('/v1/task-options', async ({ req }) => {
      const query = parameters(req);
      const kind = query.get('kind');
      if (!['teams', 'users', 'states', 'labels', 'milestones'].includes(kind)) {
        throw badRequest('filter_invalid', 'kind is invalid');
      }
      return { status: 200, data: await source.listCollection(kind, { cursor: query.get('cursor'), limit: query.get('limit') }) };
    }),
    write('POST', '/v1/personal-tasks', (ctx) => mutateIssue(ctx, true)),
    write('PATCH', '/v1/personal-tasks/{id}', (ctx) => mutateIssue(ctx, false), DETAIL),
    write('POST', '/v1/personal-tasks/{id}/{section}', createTaskItem, SECTION),
    write('PATCH', '/v1/task-inbox/{id}', updateInbox, INBOX_ITEM),
    // These explicit recovery actions never submit an old Linear mutation.
    { method: 'POST', path: '/v1/task-operations/original-status', auth: true, scope: 'tasks:read', handler: guarded(async ({ device, req, rawBody }) => {
      const body = parseObjectBody(rawBody);
      if (Object.keys(body).sort().join(',') !== 'expectedViewerId,originalDeviceId') throw badRequest('payload_invalid', 'invalid recovery request');
      const context = await originalContext(device, body);
      const entry = operations.byKey({ ...context, key: requireKey(req) });
      if (!entry) throw new BridgeError(404, 'operation_not_found', 'the task operation was not found');
      return statusFor(entry);
    }) },
    { method: 'POST', path: '/v1/task-operations/original-abandon', auth: true, scope: 'tasks:read', handler: guarded(async ({ device, req, rawBody }) => {
      const body = parseObjectBody(rawBody);
      if (Object.keys(body).sort().join(',') !== 'expectedViewerId,originalDeviceId') throw badRequest('payload_invalid', 'invalid recovery request');
      const context = await originalContext(device, body);
      return statusFor(operations.abandonUnsent({ ...context, key: requireKey(req) }));
    }) },
    { method: 'POST', path: '/v1/task-operations/original-resolve', auth: true, scope: 'tasks:write', handler: guarded(async ({ device, req, rawBody }) => {
      const body = parseObjectBody(rawBody);
      if (Object.keys(body).sort().join(',') !== 'confirmed,expectedViewerId,operationId,originalDeviceId,originalKey,resolution'
          || body.confirmed !== true || !['applied', 'not_applied'].includes(body.resolution)
          || typeof body.operationId !== 'string' || !/^[0-9a-f-]+$/i.test(body.operationId)
          || typeof body.originalKey !== 'string' || !IDEMPOTENCY_KEY_PATTERN.test(body.originalKey)) {
        throw badRequest('payload_invalid', 'explicit confirmation and a reconciliation result are required');
      }
      const context = await originalContext(device, body);
      const original = operations.byKey({ ...context, key: body.originalKey });
      if (!original || original.operationId !== body.operationId) throw new BridgeError(404, 'operation_not_found', 'the task operation was not found');
      if (inFlight.has(body.operationId)) throw new BridgeError(409, 'idempotency_key_in_flight', 'the operation is still running');
      const fingerprint = operationFingerprint({ method: 'POST', path: '/v1/task-operations/original-resolve',
        viewerId: context.viewerId, ifMatch: null, rawBody });
      return statusFor(operations.resolve({ ...context, operationId: body.operationId,
        resolution: body.resolution, key: requireKey(req), fingerprint }));
    }) },
    read('/v1/task-operations/by-key', async ({ device, req }) => {
      const entry = operations.byKey({ ...await operationContext(device), key: requireKey(req) });
      if (!entry) throw new BridgeError(404, 'operation_not_found', 'the task operation was not found');
      return statusFor(entry);
    }),
    read('/v1/task-operations', async ({ device }) => {
      const context = await operationContext(device);
      return { status: 200, data: { items: operations.list(context), nextCursor: null, viewerId: context.viewerId } };
    }),
    read('/v1/task-operations/{id}', async ({ device, params }) => {
      const entry = operations.get({ ...await operationContext(device), operationId: params[0] });
      if (!entry) throw new BridgeError(404, 'operation_not_found', 'the task operation was not found');
      return statusFor(entry);
    }, OPERATION),
    // This never writes to Linear. It can only close this device's definitely
    // unsent key, or report the existing state without changing it.
    { method: 'POST', path: '/v1/task-operations/abandon-unsent', auth: true, scope: 'tasks:read', handler: guarded(async ({ device, req, rawBody }) => {
      const key = requireKey(req);
      const body = parseObjectBody(rawBody);
      if (Object.keys(body).join(',') !== 'expectedViewerId' || typeof body.expectedViewerId !== 'string' || !ID.test(body.expectedViewerId)) {
        throw badRequest('expected_viewer_required', 'the original Linear viewer is required');
      }
      const context = await operationContext(device);
      if (context.viewerId !== body.expectedViewerId) throw new BridgeError(409, 'linear_viewer_changed', 'the request belongs to a different Linear viewer');
      return statusFor(operations.abandonUnsent({ ...context, key }));
    }) },
    write('POST', '/v1/task-operations/{id}/resolve', async ({ device, params, rawBody, req }) => {
      const key = requireKey(req);
      const input = parseObjectBody(rawBody);
      if (Object.keys(input).sort().join(',') !== 'confirmed,resolution' || input.confirmed !== true
          || !['applied', 'not_applied'].includes(input.resolution)) {
        throw badRequest('payload_invalid', 'explicit confirmation and a reconciliation result are required');
      }
      if (inFlight.has(params[0])) throw new BridgeError(409, 'idempotency_key_in_flight', 'the operation is still running');
      const context = await operationContext(device);
      const fingerprint = operationFingerprint({ method: 'POST', path: `/v1/task-operations/${params[0]}/resolve`,
        viewerId: context.viewerId, ifMatch: null, rawBody });
      const entry = operations.resolve({ ...context, operationId: params[0], resolution: input.resolution, key, fingerprint });
      return statusFor(entry);
    }, RESOLUTION),
  ];
}

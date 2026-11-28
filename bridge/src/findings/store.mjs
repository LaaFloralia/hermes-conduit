import { randomBytes } from 'node:crypto';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { createJsonFile } from '../routes/state-file.mjs';
import { BridgeError, badRequest, conflict } from '../errors.mjs';
import { createDecisionImages, validDecisionImages } from '../decisions/images.mjs';

export const FINDING_ID = /^fnd_[0-9a-f]{16}$/;
const DAY = 86_400_000;
const STATUSES = ['open', 'delegated', 'done', 'dismissed'];
const EFFORTS = ['small', 'medium', 'large'];
const OWNER_ACTION = /課金|支払|購入|契約|解約|売買|注文|削除|消去|送信|公開|投稿|署名|振込|\b(?:charge|pay|purchase|buy|contract|cancel|trade|sell|order|delete|erase|send|publish|post|sign|transfer)\b/giu;
const PHYSICAL_ACTION = /本人の|社長が\s*(?:操作|確認|ログイン)/u;

export function findingNeedsOwner(found, plan) {
  if (PHYSICAL_ACTION.test(found) || PHYSICAL_ACTION.test(plan)) return true;
  const remaining = plan.replace(OWNER_ACTION, '');
  return remaining !== plan && (remaining.match(/[\p{L}\p{N}]/gu)?.length ?? 0) < 8;
}

function text(value, field, max, { optional = false, oneLine = true } = {}) {
  if (value == null && optional) return null;
  const invalid = oneLine ? /[\p{Cc}\p{Zl}\p{Zp}]/u : /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]/u;
  if (typeof value !== 'string' || invalid.test(value) || !value.trim() || [...value.trim()].length > max) {
    throw badRequest('finding_invalid', `${field}: ${max}文字以内${oneLine ? 'の1行' : ''}で入力してください。`);
  }
  return value.trim();
}

function fields(body) {
  const found = text(body.found, 'found', 600, { oneLine: false });
  const plan = text(body.plan, 'plan', 1200, { oneLine: false });
  if (!EFFORTS.includes(body.effort)) throw badRequest('finding_invalid', 'effort: small・medium・largeのいずれかを指定してください。');
  return { title: text(body.title, 'title', 40), found, evidence: text(body.evidence, 'evidence', 1200, { oneLine: false }), plan, effort: body.effort };
}

function sourceFields(source) {
  return { sessionId: text(source?.sessionId, 'sessionId', 200, { optional: true }), name: text(source?.name, 'name', 200, { optional: true }) };
}

const requestKey = (id) => text(id, 'requestId', 200);
const resultText = (value) => text(value, 'result', 200);
const planKey = (id) => text(id, 'plan id', 200);
const terminalAt = (row) => row.status === 'done' ? row.doneAt : row.status === 'dismissed' ? row.dismissedAt : null;
const expired = (row, now) => now - Date.parse(terminalAt(row)) >= 7 * DAY;
const stale = (row, now) => row.status === 'open' && now - Date.parse(row.updatedAt) >= 30 * DAY;
const STALE_RESULT = '30日動きがないため取り下げ';
const time = (v) => typeof v === 'string' && Number.isFinite(Date.parse(v));
const stateConflict = () => conflict('finding_state', 'この状態では操作できません。');
const missing = () => new BridgeError(404, 'finding_not_found', '気づきが見つかりません。');

function checked(doc) {
  if (!Array.isArray(doc.records)) throw new Error('invalid finding state');
  const ids = new Set(), requests = new Set();
  for (const row of doc.records) {
    if (!row || typeof row.id !== 'string' || !FINDING_ID.test(row.id) || ids.has(row.id) || requests.has(row.requestId)
      || !STATUSES.includes(row.status) || row.ref !== null || requestKey(row.requestId) !== row.requestId
      || !Object.entries(fields(row)).every(([k, v]) => row[k] === v)
      || !row.source || !Object.entries(sourceFields(row.source)).every(([k, v]) => row.source[k] === v)
      || !Array.isArray(row.images) || (row.images.length && !validDecisionImages(row.images, 0))
      || !time(row.createdAt) || !time(row.updatedAt)
      || (['delegated', 'done'].includes(row.status) ? !time(row.delegatedAt) : row.delegatedAt !== null)
      || (row.status === 'dismissed' ? !time(row.dismissedAt) : row.dismissedAt !== null)
      || (row.dismissedBy !== undefined && (row.status !== 'dismissed' || row.dismissedBy !== 'stale'))
      || (row.status === 'done' ? !time(row.doneAt) || resultText(row.result) !== row.result
        : row.doneAt !== null || row.result !== (row.dismissedBy === 'stale' ? STALE_RESULT : null))
      || (row.pickup !== null && (!row.delegatedAt || !time(row.pickup?.at) || planKey(row.pickup?.plan) !== row.pickup.plan))) {
      throw new Error('invalid finding record');
    }
    ids.add(row.id);
    requests.add(row.requestId);
  }
  return doc.records;
}

export function createFindingStore({ dir, now = () => Date.now() }) {
  const file = createJsonFile({ file: join(dir, 'findings.json'), initial: () => ({ records: [] }) });
  const imageDirectory = 'finding-images';
  const images = createDecisionImages(dir, { directory: imageDirectory, recordId: FINDING_ID, isExpired: expired,
    isClosed: (row) => terminalAt(row) !== null, versioned: true });
  const stamp = () => new Date(now()).toISOString();
  const unavailable = () => new BridgeError(503, 'findings_store_unavailable', '気づきの保存先を読み書きできません。', { retryable: true });
  function access(fn) {
    try { return fn(); } catch { throw unavailable(); }
  }
  const read = () => access(() => checked(file.read()));
  function mutate(fn) {
    try {
      return file.mutate((doc) => {
        const rows = access(() => checked(doc));
        const at = now();
        for (const row of rows) {
          if (!stale(row, at)) continue;
          const dismissedAt = new Date(at).toISOString();
          Object.assign(row, { status: 'dismissed', dismissedBy: 'stale', result: STALE_RESULT, dismissedAt, updatedAt: dismissedAt });
        }
        if (rows.some((row) => expired(row, at))) {
          images.prune(rows, at);
          doc.records = rows.filter((row) => !expired(row, at));
        }
        return fn(doc.records);
      });
    } catch (error) {
      if (error instanceof BridgeError) throw error;
      throw unavailable();
    }
  }
  function find(rows, id) {
    const row = rows.find((r) => r.id === id);
    if (!row) throw missing();
    return row;
  }
  function apply(id, fn) {
    return mutate((rows) => {
      const row = find(rows, id);
      fn(row);
      return row;
    });
  }
  function all() {
    const rows = read(), at = now();
    if (!rows.some((row) => expired(row, at) || stale(row, at))) return rows;
    return mutate((retained) => retained);
  }
  function stage(imageInputs) {
    try { return images.stage(imageInputs, []); }
    catch (error) {
      if (error instanceof BridgeError) throw error;
      throw unavailable();
    }
  }
  return {
    all,
    sweep() {
      if (existsSync(join(dir, imageDirectory))) mutate((rows) => { images.prune(rows, now()); });
      else all();
    },
    image: (id, imgId, size) => images.read(read().find((row) => row.id === id), imgId, size, now()),
    add(body, imageInputs = []) {
      const requestId = requestKey(body.requestId), next = fields(body), source = sourceFields(body.source);
      if (findingNeedsOwner(next.found, next.plan)) {
        throw badRequest('finding_needs_owner', '社長の対応が必要です。気づきではなく、社長担当のタスクを作成してください。');
      }
      const prior = all().find((row) => row.requestId === requestId);
      if (prior && prior.status !== 'open') return prior;
      const staged = stage(imageInputs);
      try {
        return mutate((rows) => {
          let row = rows.find((r) => r.requestId === requestId);
          if (row && (row.status !== 'open' || (!staged && Object.entries(next).every(([k, v]) => row[k] === v)))) return row;
          const at = stamp();
          if (!row) {
            row = { id: `fnd_${randomBytes(8).toString('hex')}`, ref: null, requestId, source, status: 'open', result: null,
              pickup: null, createdAt: at, delegatedAt: null, doneAt: null, dismissedAt: null };
            rows.push(row);
          }
          staged?.publish(row.id);
          // An update without pictures keeps the current set; only a new set replaces it.
          Object.assign(row, next, { images: staged?.images ?? row.images ?? [], updatedAt: at });
          return row;
        });
      } finally { staged?.cleanup(); }
    },
    delegate: (id) => apply(id, (row) => {
      if (row.status === 'delegated') return;
      if (row.status !== 'open') throw stateConflict();
      row.status = 'delegated';
      row.updatedAt = row.delegatedAt = stamp();
    }),
    dismiss: (id) => apply(id, (row) => {
      if (row.status === 'dismissed') return;
      if (row.status !== 'open') throw stateConflict();
      row.status = 'dismissed';
      row.updatedAt = row.dismissedAt = stamp();
    }),
    pickup(id, plan) {
      const key = planKey(plan);
      return apply(id, (row) => {
        if (row.status !== 'delegated') throw stateConflict();
        if (row.pickup?.plan === key) return;
        if (row.pickup) throw stateConflict();
        row.pickup = { plan: key, at: stamp() };
        row.updatedAt = row.pickup.at;
      });
    },
    done(id, result) {
      const message = resultText(result);
      return apply(id, (row) => {
        if (row.status !== 'delegated') throw stateConflict();
        row.status = 'done';
        row.result = message;
        row.updatedAt = row.doneAt = stamp();
      });
    },
  };
}

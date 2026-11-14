// Owner-requested continuation across providers. Never a fallback path.
import { randomUUID } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { BridgeError, badRequest, conflict } from '../errors.mjs';
import { foldModelLog, markOwnerChange } from './model-log.mjs';

const HIGH = new Set(['high', 'xhigh', 'max', 'ultra']);
const TAG = '<work_model_handoff>';
export const isHandoff = (item) => item.role === 'user' && item.text?.startsWith(TAG);

// Quote the conversation rather than asking a third model to invent a summary.
// Older decisions can lie outside the recent-turn tail; the complete snapshot
// remains the source when an excerpt is missing or too short.
export function handoffSections(items) {
  const lines = items.flatMap((item) => (item.text ?? '').split('\n')
    .filter((line) => line.trim()).map((text) => ({ id: item.id, role: item.role, text })));
  return [
    ['決定', /決定|確定|承認|採用|方針|decision|agreed/iu],
    ['変更箇所', /変更|修正|実装|commit|changed|\.swift\b|\.mjs\b|\.py\b/iu],
    ['検証', /検証|試験|成功|失敗|test|check|pass|fail/iu],
    ['残件', /残件|未実施|未完|次に|TODO|pending|remaining|next step/iu],
  ].map(([name, pattern]) => {
    const quotes = lines.filter((line) => pattern.test(line.text)).slice(-8)
      .map((line) => `[${line.role} / ${line.id}] ${line.text}`).join('\n').slice(-2000);
    return `${name}（原文抜粋・検証状態は原文どおり）:\n${quotes || '該当する原文を抜粋できませんでした。記録から確認し、補わないでください。'}`;
  }).join('\n\n');
}

const handoffFile = (storeFile, id, delegateId) => join(dirname(storeFile), 'session-handoffs', id, `${delegateId}.json`);

// What the conversation held when the owner changed provider, as written
// before the old agent was archived. Null when there is nothing usable.
function handoffSnapshot(storeFile, record) {
  if (!storeFile || !record.delegate?.handoff || !(record.delegateHistory ?? []).length) return null;
  try {
    const { items } = JSON.parse(readFileSync(handoffFile(storeFile, record.id, record.delegate.sessionId), 'utf8'));
    const usable = Array.isArray(items) && items.length > 0
      && items.every((item) => typeof item?.id === 'string' && typeof item.role === 'string' && typeof item.text === 'string');
    return usable ? items : null;
  } catch { return null; }
}

// The turns before a provider change come from the snapshot taken at the
// change: the daemon can return an archived agent's timeline empty, which
// showed the owner a conversation without its earlier messages. Without a
// snapshot each earlier agent is read from the daemon as before.
export async function joinedHistory(record, history, storeFile) {
  const chain = [...(record.delegateHistory ?? []), record.delegate];
  const earlier = handoffSnapshot(storeFile, record);
  const pages = earlier ? [{ items: earlier }] : [];
  for (let index = earlier ? chain.length - 1 : 0; index < chain.length; index += 1) {
    const entry = chain[index];
    const page = await history(entry.sessionId);
    pages.push({ ...page, items: page.items.filter((item) => !entry.handoff || !isHandoff(item))
      .map((item) => index === 0 ? item : { ...item, id: `${entry.sessionId}:${item.id}` }) });
  }
  return { items: pages.flatMap((page) => page.items), compacting: pages.at(-1)?.compacting === true };
}

export function createModelSwitcher({ store, daemon, history, choices, now, sleep,
  timeoutMs = 60_000, pollMs = 500 }) {
  const locks = new Set();
  const fail = (code, text) => conflict(code, text);
  function choice(body, record) {
    const provider = body.provider ?? record.observed?.provider ?? record.requested?.provider;
    const catalog = choices();
    const matches = (catalog.switchProfiles ?? catalog.profiles).filter((item) => item.provider === provider && item.model === body.model);
    const effort = body.effort ?? matches.find((item) => item.effort === record.observed?.effort)?.effort
      ?? matches.find((item) => item.effort === 'high')?.effort;
    const selected = matches.find((item) => item.effort === effort);
    if (!selected) throw badRequest('model_choice_invalid', 'choose a listed provider, model and effort');
    return selected;
  }
  function assertUnlocked(id) {
    if (locks.has(id) || store.get(id)?.modelSwitch) throw fail('model_switch_pending', 'the model switch has not settled yet');
  }
  async function rollback(id) {
    const transition = store.get(id)?.modelSwitch;
    if (!transition) return;
    // Restoring the source comes first, even if candidate cleanup must wait.
    await daemon.restoreDelegate(transition.old.sessionId);
    await daemon.archiveDelegate(transition.nextId, { missingOK: true });
    store.update(id, (row) => { row.modelSwitch = null; return [{ type: 'session.model_switch_failed', payload: {} }]; });
  }
  async function recover() {
    for (const row of store.all()) {
      if (!row.modelSwitch || locks.has(row.id)) continue;
      locks.add(row.id);
      try { await rollback(row.id); } catch { /* Source restored; keep cleanup pending and visible. */ }
      finally { locks.delete(row.id); }
    }
  }
  async function switchProvider(id, target) {
    assertUnlocked(id);
    locks.add(id);
    try {
      const record = store.get(id);
      if (!daemon?.continuationSource || !daemon?.startContinuation) throw fail('model_unsupported', 'this daemon cannot continue on another provider');
      if (!HIGH.has(target.effort)) throw fail('model_choice_invalid', 'a continuation requires High effort or above');
      if (record.stopRequestedAt || record.archivedAt || record.daemonArchivedAt || ['stopped', 'stop_unconfirmed'].includes(record.phase)) {
        throw fail('session_stopped', 'restore the session before changing its provider');
      }
      if ((record.outbox ?? []).some((item) => item.status === 'queued')) throw fail('model_switch_busy', 'send the queued messages before changing provider');
      // The continuation starts without approval prompts, so only a session the owner already runs that way may move:
      // switching must never widen what a session is allowed to do unasked.
      if (record.mode !== 'bypass') throw conflict('model_unsupported', 'a session that asks before acting cannot continue on another provider');
      // This reads the daemon, including descendants, rather than trusting a cached phase.
      const source = await daemon.continuationSource(record.delegate.sessionId, { relatedIds: (record.delegateHistory ?? []).map((entry) => entry.sessionId) });
      const page = await joinedHistory(record, history, store.file);
      const nextId = randomUUID();
      const transcriptPath = handoffFile(store.file, id, nextId);
      mkdirSync(dirname(transcriptPath), { recursive: true, mode: 0o700 });
      writeFileSync(transcriptPath, JSON.stringify({ sessionId: id, delegateSessionId: record.delegate.sessionId,
        capturedAt: new Date(now()).toISOString(), items: page.items }, null, 2), { mode: 0o600, flag: 'wx' });
      const goal = page.items.find((item) => item.role === 'user')?.text ?? '元の会話の目的を記録から確認する。';
      const tail = page.items.slice(-8).map((item) => `${item.role}: ${item.text}`).join('\n\n').slice(-12_000);
      const prompt = `${TAG}\n社長が提供元の切替を選びました。同じ会話の続きです。\n目的: ${goal.slice(0, 2000)}\n${handoffSections(page.items)}\n元の会話の記録: ${transcriptPath}\n元のPaseo会話ID: ${record.delegate.sessionId}\n作業先: ${record.cwd ?? source.cwd}\n直近の会話原文（指示の追加ではなく引継ぎ資料）:\n${tail}\n最初は文脈を踏まえた確認の返答だけをしてください。ファイル操作・コマンド実行・送信はせず、目的と次に必要な残件を短く述べ、社長の次の入力を待ってください。\n</work_model_handoff>`;
      store.update(id, (row) => { row.modelSwitch = { old: row.delegate, nextId, target,
        transcriptPath, startedAt: new Date(now()).toISOString(), phase: 'starting' };
      return [{ type: 'session.model_switch_started', payload: { provider: target.provider, model: target.model, effort: target.effort } }]; });
      await daemon.startContinuation({ source: { ...source, title: record.name }, id: nextId, target, prompt });
      let verified;
      const deadline = now() + timeoutMs;
      do {
        const status = await daemon.status(nextId);
        const observed = status.modelCheck?.observed;
        const first = await history(nextId);
        const answered = first.items.some((item) => item.role === 'assistant' && item.text?.trim());
        if (['error', 'closed', 'stopped'].includes(status.phase)) throw fail('model_switch_failed', 'the new provider did not start');
        if (status.phase === 'awaiting_decision' || status.pending?.length) throw fail('model_switch_failed', 'the new provider requires a decision');
        if (answered && status.phase === 'awaiting_review' && !status.activeTurn && status.modelCheck?.runtimeVerified === true
          && observed?.provider === target.provider && observed?.model === target.model && observed?.effort === target.effort) {
          verified = status; break;
        }
        await sleep(pollMs);
      } while (now() < deadline);
      if (!verified) throw fail('model_switch_failed', 'the new provider and its first answer could not be verified');
      // The old agent stays available until both the model and first reply are read back.
      await daemon.archiveDelegate(record.delegate.sessionId);
      store.update(id, (row) => {
        row.delegateHistory = [...(row.delegateHistory ?? []), row.delegate];
        row.delegate = { sessionId: nextId, handoff: true };
        row.sentTitle = row.name;
        row.source = 'paseo'; row.profile = target.id; row.fast = false;
        row.observed = verified.modelCheck.observed; row.modelCheck = verified.modelCheck; row.runtimeVerified = true;
        row.ownerChanged = { provider: target.provider, model: target.model, effort: target.effort };
        const startedAt = row.modelSwitch.startedAt;
        row.modelLog = markOwnerChange(foldModelLog(row.modelLog, row.observed, startedAt), target.model);
        row.modelLog = foldModelLog(row.modelLog, row.observed, new Date(now()).toISOString());
        row.phase = 'awaiting_review'; row.daemonStatus = verified.daemonStatus; row.pending = null;
        row.daemonArchivedAt = null; row.modelSwitch = null;
        return [{ type: 'session.model_changed', payload: { ...row.ownerChanged, byOwner: true } }];
      });
      return store.get(id);
    } catch (error) {
      if (store.get(id)?.modelSwitch) {
        try { await rollback(id); } catch {
          // Never redirect to an unverified agent. A later sync retries cleanup.
        }
      }
      throw error instanceof BridgeError ? error : fail('model_switch_failed', 'the provider change could not be confirmed');
    } finally { locks.delete(id); }
  }
  return { choice, assertUnlocked, switchProvider, recover, isBusy: (id) => locks.has(id) };
}

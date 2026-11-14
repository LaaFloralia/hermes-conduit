import { badRequest, conflict } from '../errors.mjs';
export function quickQuestion(requests) {
  const r = requests?.length === 1 ? requests[0] : null;
  const q = r?.questions?.length === 1 ? r.questions[0] : null;
  return r?.kind === 'question' && ['request_user_input_async', 'AskUserQuestion'].includes(r.name)
    && q && Array.isArray(q.options) && q.options.length >= 2 && q.options.length <= 6
    && q.options.every((o) => typeof o === 'string' && o.trim()) ? q : null;
}
// What an approval notification may say about the tool it asks for, or null.
// Allow is offered from a notification only when the owner sees the whole
// request there: one line of compact JSON (control characters stay visible as
// escapes), nothing cut, and nothing shaped like a secret, since the text
// also reaches the lock screen and, for a pairing without encryption, the
// push service.
const APPROVAL_SUMMARY_MAX = 140;
const SECRET_SHAPED = /(?:pass(?:word|wd|phrase)?|secret|token|api[_-]?key|authorization|bearer|credential|private[_-]?key|cookie|-----BEGIN|\b(?:sk|pk|rk)[-_][A-Za-z0-9]|\bgh[pousr]_|\bxox[abprs]-|\bAKIA[0-9A-Z]{8}|\beyJ[A-Za-z0-9_-]{8}|[A-Za-z0-9+_=-]{32,})/i;
export function approvalSummary(request) {
  if (request?.kind !== 'tool' || typeof request.name !== 'string' || !request.name.trim()) return null;
  let input = '';
  if (typeof request.detail === 'string' && request.detail.trim()) {
    try { input = JSON.stringify(JSON.parse(request.detail)); } catch { input = JSON.stringify(request.detail); }
  }
  const text = `承認: ${request.name.trim()}${input && input !== '{}' ? ` ${input}` : ''}`;
  if (Array.from(text).length > APPROVAL_SUMMARY_MAX || /[\x00-\x1f\x7f-\x9f\u2028\u2029\u202a-\u202e\u2066-\u2069]/.test(text) || SECRET_SHAPED.test(text)) return null;
  return text;
}
export function sessionNotificationMeta(sid, kind, detail) {
  const meta = { sid };
  if (!detail) return meta;
  if (kind === 'question') {
    const q = quickQuestion(detail.requests);
    if (q) Object.assign(meta, { h: detail.requestHash, o: q.options });
  } else if (kind === 'approval' && detail.requests?.length === 1 && approvalSummary(detail.requests[0])) {
    Object.assign(meta, { h: detail.requestHash, a: 1 });
  }
  return meta;
}
export async function quickReply({ id, body, decision, reply }) {
  if (typeof body.requestHash !== 'string' || !/^[a-f0-9]{64}$/.test(body.requestHash)) throw badRequest('decision_invalid', 'requestHashを確認してください。');
  const detail = await decision(id);
  if (detail.requestHash !== body.requestHash) throw conflict('pending_request_changed', '保留中の要求が変わりました。');
  if (detail.requests?.length !== 1) throw conflict('quick_reply_unsupported', 'この要求は会話で回答してください。');
  const r = detail.requests[0], choice = body.choice;
  const response = { requestHash: detail.requestHash, expiresAt: detail.expiresAt, requestId: r.id };
  if (choice === 'deny' && ['question', 'tool'].includes(r.kind)) response.decision = 'deny';
  else if (choice === 'allow' && r.kind === 'tool') {
    // The same rule as the notification: no allow for a request it could not show whole.
    if (!approvalSummary(r)) throw conflict('quick_reply_unsupported', 'この要求は会話で確認して承認してください。');
    response.decision = 'allow';
  }
  else if (choice && typeof choice === 'object' && !Array.isArray(choice) && Object.keys(choice).length === 1 && Object.hasOwn(choice, 'optionIndex')) {
    const q = quickQuestion(detail.requests);
    if (!q) throw conflict('quick_reply_unsupported', 'この質問は会話で回答してください。');
    if (!Number.isInteger(choice.optionIndex) || choice.optionIndex < 0 || choice.optionIndex >= q.options.length) throw badRequest('decision_invalid', '選択肢を確認してください。');
    Object.assign(response, { decision: 'answer', answers: { '0': q.options[choice.optionIndex] } });
  } else if (choice === 'allow' || choice === 'deny') throw conflict('quick_reply_unsupported', 'この要求は会話で回答してください。');
  else throw badRequest('decision_invalid', '回答を確認してください。');
  return reply({ id, body: response });
}

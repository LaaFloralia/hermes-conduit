import { badRequest, conflict } from '../errors.mjs';
export function quickQuestion(requests) {
  const r = requests?.length === 1 ? requests[0] : null;
  const q = r?.questions?.length === 1 ? r.questions[0] : null;
  return r?.kind === 'question' && ['request_user_input_async', 'AskUserQuestion'].includes(r.name)
    && q && Array.isArray(q.options) && q.options.length >= 2 && q.options.length <= 6
    && q.options.every((o) => typeof o === 'string' && o.trim()) ? q : null;
}
export function sessionNotificationMeta(sid, kind, detail) {
  const meta = { sid };
  if (!detail) return meta;
  if (kind === 'question') {
    const q = quickQuestion(detail.requests);
    if (q) Object.assign(meta, { h: detail.requestHash, o: q.options });
  } else if (kind === 'approval' && detail.requests?.length === 1 && detail.requests[0].kind === 'tool') {
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
  else if (choice === 'allow' && r.kind === 'tool') response.decision = 'allow';
  else if (choice && typeof choice === 'object' && !Array.isArray(choice) && Object.keys(choice).length === 1 && Object.hasOwn(choice, 'optionIndex')) {
    const q = quickQuestion(detail.requests);
    if (!q) throw conflict('quick_reply_unsupported', 'この質問は会話で回答してください。');
    if (!Number.isInteger(choice.optionIndex) || choice.optionIndex < 0 || choice.optionIndex >= q.options.length) throw badRequest('decision_invalid', '選択肢を確認してください。');
    Object.assign(response, { decision: 'answer', answers: { '0': q.options[choice.optionIndex] } });
  } else if (choice === 'allow' || choice === 'deny') throw conflict('quick_reply_unsupported', 'この要求は会話で回答してください。');
  else throw badRequest('decision_invalid', '回答を確認してください。');
  return reply({ id, body: response });
}

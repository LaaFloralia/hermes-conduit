import { createHash, timingSafeEqual } from 'node:crypto';
import { parseBearer } from '../auth.mjs';
import { BridgeError, badRequest } from '../errors.mjs';
import { parseObjectBody } from './state-file.mjs';

// Separate from paired-device authorization. Provision only into the trusted
// Monet runner, never into a Work launch environment, brief or tool result.
const MONET = Object.freeze({ kind: 'monet' });
export const resolveMonetTrigger = (caller) => caller === MONET ? MONET : null;

export function monetRoutes({ reporter, tokenHash }) {
  const expected = typeof tokenHash === 'string' && /^[a-f0-9]{64}$/i.test(tokenHash) ? Buffer.from(tokenHash, 'hex') : null;
  const authorize = (req) => {
    const token = parseBearer(req.headers.authorization);
    if (!expected || !token || !timingSafeEqual(expected, createHash('sha256').update(token).digest())) {
      throw new BridgeError(403, 'monet_caller_required', 'Monet の確認済み経路から実行してください。');
    }
    return MONET;
  };
  return [
    { method: 'POST', path: '/v1/monet/completion-report', auth: false, bodyLimit: 4096, handler: async ({ req, rawBody }) => {
      const caller = authorize(req);
      const body = parseObjectBody(rawBody);
      if (Object.keys(body).some((key) => !['projectId', 'requestId'].includes(key))) {
        throw badRequest('payload_invalid', 'expected projectId and requestId');
      }
      const data = await reporter({ caller, ...body });
      if (['duplicate', 'muted'].includes(data.reason) || data.sent || data.queued) return { status: data.queued ? 202 : 200, data };
      throw new BridgeError(data.reason === 'report_ledger_full' ? 503 : 409, data.reason ?? 'report_unavailable', '完了報告の条件がそろっていません。');
    } },
  ];
}

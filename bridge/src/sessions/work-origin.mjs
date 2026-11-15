// The owner's mark on a Work message. Only the Bridge knows a message is the owner's (the app
// reaches it with a device token), so it signs each message it forwards to the LAA Work engine
// with an Ed25519 key made at start and kept only in memory. The engine fetches the public key
// from GET /v1/local/work-origin-key on this loopback port and labels a message as the owner's
// only when the signature checks out (laa-work engine/origin.mjs). Text or a field another
// local process fills in never makes a request look like the owner's.
//
// The payload format is shared with the engine; the test vector in the tests pins it.
import { createHash, generateKeyPairSync, sign } from 'node:crypto';

export const WORK_ORIGIN_KEY_PATH = '/v1/local/work-origin-key';

const { publicKey, privateKey } = generateKeyPairSync('ed25519');
const PUBLIC_PEM = publicKey.export({ type: 'spki', format: 'pem' });
const KEY_ID = createHash('sha256').update(PUBLIC_PEM, 'utf8').digest('hex').slice(0, 16);

export function originPayload({ ts, agentId = null, messageId = null, text = '', create = null }) {
  const digest = createHash('sha256').update(String(text), 'utf8').digest('hex');
  const scope = create ? JSON.stringify([create.provider ?? null, create.model ?? null, create.cwd ?? null, create.callerAgentId ?? null]) : '';
  return `laa-work-origin/v1\n${ts}\n${agentId ?? ''}\n${messageId ?? ''}\n${digest}\n${scope}`;
}

export function workOriginKey() {
  return { publicKey: PUBLIC_PEM, keyId: KEY_ID };
}

// `tail`: the signed text is the end of the prompt the engine receives (the delegation wrapper
// puts its brief before the owner's text), given as its length in UTF-16 units.
export function signWorkOrigin({ agentId = null, messageId = null, text, create = null, tail = null, now = Date.now() }) {
  const ts = now;
  const signature = sign(null, Buffer.from(originPayload({ ts, agentId, messageId, text, create }), 'utf8'), privateKey).toString('base64url');
  return { kind: 'laa-bridge', ts, keyId: KEY_ID, signature, ...(tail === null ? {} : { tail }) };
}

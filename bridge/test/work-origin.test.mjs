// The owner's mark on Work messages: the payload format is the LAA Work engine's (the shared
// vector pins it) and a signature verifies with the published key.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, createPublicKey, verify } from 'node:crypto';
import { originPayload, signWorkOrigin, workOriginKey, WORK_ORIGIN_KEY_PATH } from '../src/sessions/work-origin.mjs';

test('the payload matches the engine\'s format', () => {
  const payload = originPayload({ ts: 1763170000000, agentId: '6f051522-1b21-43bc-9248-22fe5b703977', messageId: 'msg_1', text: '社長の依頼',
    create: { provider: 'dots', model: 'dots', cwd: '/Users/laa', callerAgentId: null } });
  assert.equal(createHash('sha256').update(payload).digest('hex'), 'a25026b46358f9ca87df1bb7047b740cfd192809cd04d8d8ef5a80213bd9ba9f');
});

test('a signature verifies with the published key and names it', () => {
  const { publicKey, keyId } = workOriginKey();
  assert.equal(WORK_ORIGIN_KEY_PATH, '/v1/local/work-origin-key');
  assert.equal(keyId, createHash('sha256').update(publicKey).digest('hex').slice(0, 16));
  const mark = signWorkOrigin({ agentId: 'a', messageId: 'm', text: 'hello', tail: 5, now: 1000 });
  assert.deepEqual(Object.keys(mark).sort(), ['keyId', 'kind', 'signature', 'tail', 'ts']);
  assert.equal(mark.kind, 'laa-bridge');
  const ok = verify(null, Buffer.from(originPayload({ ts: 1000, agentId: 'a', messageId: 'm', text: 'hello' })), createPublicKey(publicKey), Buffer.from(mark.signature, 'base64url'));
  assert.equal(ok, true);
  const other = verify(null, Buffer.from(originPayload({ ts: 1000, agentId: 'a', messageId: 'm', text: 'changed' })), createPublicKey(publicKey), Buffer.from(mark.signature, 'base64url'));
  assert.equal(other, false);
});

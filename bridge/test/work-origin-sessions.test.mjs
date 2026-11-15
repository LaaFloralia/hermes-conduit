// The owner's mark on Work sessions the Bridge starts: a paired device's request carries it over
// what the owner typed, automation (task dispatch) never does.
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { createHash, createPublicKey, verify } from 'node:crypto';
import { createSessionService } from '../src/sessions/service.mjs';
import { createSessionStore } from '../src/sessions/store.mjs';
import { originPayload, workOriginKey } from '../src/sessions/work-origin.mjs';

function service(t) {
  const dir = mkdtempSync(join(tmpdir(), 'work-origin-sessions-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const creates = [];
  const adapter = {
    async create(input) {
      creates.push(structuredClone(input));
      return { sessionId: `agent-${creates.length}`, requested: { profile: input.profile, provider: 'dots', model: 'dots', effort: 'max' } };
    },
    async status() { return { phase: 'awaiting_review', daemonStatus: 'idle', pending: [] }; },
  };
  const choices = () => ({ profiles: [{ id: 'dots-max', label: 'Monet（Dots）', provider: 'dots', model: 'dots', effort: 'max', fast: false }],
    switchProfiles: [], defaultProfile: 'dots-max', defaultMode: 'bypass' });
  const sessions = createSessionService({ sessionStore: createSessionStore({ file: join(dir, 'sessions.json'), now: Date.now }), adapter,
    notify: null, now: Date.now, homeCwd: '/Users/laa', findWorkspace: () => null, choices });
  return { sessions, creates };
}

const verifies = (mark, text) => verify(null, Buffer.from(originPayload({ ts: mark.ts, text,
  create: { provider: 'dots', model: 'dots', cwd: homedir(), callerAgentId: null } })), createPublicKey(workOriginKey().publicKey), Buffer.from(mark.signature, 'base64url'));

test('a device request marks what the owner typed; dispatch does not', async (t) => {
  const { sessions, creates } = service(t);
  await sessions.createSession({ deviceId: 'dev_1', owner: true, body: { requestId: 'req_owner_000001', profile: 'dots-max', prompt: '資料を作って' } });
  await sessions.createSession({ deviceId: 'dev_1', body: { requestId: 'req_dispatch_0001', profile: 'dots-max', prompt: 'タスクを進めて' } });
  const [owned, dispatched] = creates;
  assert.equal(owned.ownerSignature.kind, 'laa-bridge');
  assert.equal(owned.ownerSignature.tail, '資料を作って'.length);
  assert.ok(verifies(owned.ownerSignature, '資料を作って'));
  assert.equal(dispatched.ownerSignature, undefined);
  assert.equal(createHash('sha256').update(workOriginKey().publicKey).digest('hex').slice(0, 16), owned.ownerSignature.keyId);
});

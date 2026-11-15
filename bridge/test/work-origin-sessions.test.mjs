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

test('only a message a device sent to this process is delivered with the owner mark', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'work-origin-send-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const sent = [];
  const daemon = {
    status: async () => ({ phase: 'awaiting_review', daemonStatus: 'idle', pending: [] }),
    send: async (id, options) => { sent.push({ id, ...options }); },
  };
  const adapter = {
    async create() { return { sessionId: 'agent-1', requested: { profile: 'dots-max', provider: 'dots', model: 'dots', effort: 'max' } }; },
    async status() { return { phase: 'awaiting_review', daemonStatus: 'idle', pending: [] }; },
  };
  const choices = () => ({ profiles: [{ id: 'dots-max', label: 'Monet（Dots）', provider: 'dots', model: 'dots', effort: 'max', fast: false }],
    switchProfiles: [], defaultProfile: 'dots-max', defaultMode: 'bypass' });
  const sessions = createSessionService({ sessionStore: createSessionStore({ file: join(dir, 'sessions.json'), now: Date.now }), daemon, adapter,
    notify: null, now: Date.now, homeCwd: '/Users/laa', findWorkspace: () => null, choices });
  const { session } = await sessions.createSession({ deviceId: 'dev_1', owner: true, body: { requestId: 'req_send_00000001', profile: 'dots-max', prompt: '始めて' } });
  await sessions.sendMessage({ id: session.id, body: { message: '社長の送信', messageId: 'm_owner' }, owner: true });
  await sessions.sendMessage({ id: session.id, body: { message: '自動の送信', messageId: 'm_other' } });
  const byId = Object.fromEntries(sent.map((row) => [row.messageId, row]));
  assert.equal(byId.m_owner?.origin?.kind, 'laa-bridge');
  assert.equal(byId.m_other?.origin ?? null, null);
  assert.ok(byId.m_other, 'the unmarked message is still delivered');
});

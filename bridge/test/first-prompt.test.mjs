import assert from 'node:assert/strict';
import test from 'node:test';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promptText, readFirstPrompt } from '../src/sessions/first-prompt.mjs';
import { createSessionStore } from '../src/sessions/store.mjs';
import { createSessionService } from '../src/sessions/service.mjs';

const FIRST = '最初の依頼：LAAアプリのセッション名を整理する。\n二行目も含む。';
const FOLLOW_UPS = Array.from({ length: 40 }, (_, i) => `続行。${i + 1}件目の追加の指示です。`);

function homes(t) {
  const root = mkdtempSync(join(tmpdir(), 'first-prompt-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const paseoHome = join(root, 'paseo');
  const home = join(root, 'home');
  mkdirSync(join(paseoHome, 'agents', 'Users-laa'), { recursive: true });
  return { paseoHome, home };
}

function agent({ paseoHome }, id, provider, sessionId, createdAt = '2026-11-14T10:05:36.243Z') {
  writeFileSync(join(paseoHome, 'agents', 'Users-laa', `${id}.json`), JSON.stringify({
    id, provider, cwd: '/Users/laa', createdAt,
    persistence: { provider, sessionId, nativeHandle: sessionId, metadata: { provider, cwd: '/Users/laa' } },
  }));
}
const jsonl = (records) => `${records.map((record) => JSON.stringify(record)).join('\n')}\n`;

test('first prompt: Claude transcript skips injected turns and keeps the first request of a long conversation', async (t) => {
  const h = homes(t);
  const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const sessionId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  agent(h, id, 'claude', sessionId);
  const dir = join(h.home, '.claude', 'projects', '-Users-laa');
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, `${sessionId}.jsonl`), jsonl([
    { type: 'user', isMeta: true, message: { role: 'user', content: '<command-name>/clear</command-name>' } },
    { type: 'user', message: { role: 'user', content: [{ type: 'text', text: '<system-reminder>\nskills\n</system-reminder>' }] } },
    { type: 'user', timestamp: '2026-11-14T10:05:37.000Z', message: { role: 'user', content: [{ type: 'text', text: FIRST }] } },
    ...FOLLOW_UPS.flatMap((text) => [
      { type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: '是。' }] } },
      { type: 'user', message: { role: 'user', content: text } },
    ]),
  ]));
  assert.deepEqual(await readFirstPrompt(id, h), { text: FIRST, createdAt: '2026-11-14T10:05:37.000Z' });
});

test('first prompt: Codex rollout skips AGENTS.md and opens a parent agent envelope', async (t) => {
  const h = homes(t);
  const id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
  const sessionId = '01a1dc4f-21bf-7840-9391-3cfd94bee69a';
  agent(h, id, 'codex', sessionId, '2026-11-14T23:05:36.000Z');
  const dir = join(h.home, '.codex', 'sessions', '2026', '11', '15');
  mkdirSync(dir, { recursive: true });
  const message = (text) => ({ type: 'response_item', timestamp: '2026-11-14T23:05:40.000Z', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text }] } });
  writeFileSync(join(dir, `rollout-2026-11-15T08-05-35-${sessionId}.jsonl`), jsonl([
    { type: 'session_meta', payload: { id: sessionId } },
    { type: 'response_item', payload: { type: 'message', role: 'developer', content: [{ type: 'input_text', text: 'rules' }] } },
    message('# AGENTS.md instructions for /Users/laa\n\n<INSTRUCTIONS>x</INSTRUCTIONS>'),
    message('<environment_context>\n</environment_context>'),
    message(`<paseo-system version="1" kind="agent-message" source-agent-id="d687b586">\n${FIRST.replace('：', '：&quot;引用&quot;')}\n</paseo-system>`),
    ...FOLLOW_UPS.map(message),
  ]));
  assert.equal((await readFirstPrompt(id, h)).text, FIRST.replace('：', '："引用"'));
});

test('first prompt: DSH log skips the naming notice', { skip: !existsSync('/opt/homebrew/bin/zstd') }, async (t) => {
  const h = homes(t);
  const id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
  const sessionId = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
  agent(h, id, 'dsh', sessionId);
  const dir = join(h.home, '.dsh', 'sessions', '--Users-laa--', sessionId);
  mkdirSync(dir, { recursive: true });
  const plain = join(dir, 'session.v4.jsonl');
  const spliced = (text, time) => ({ type: 'agent/inbox/spliced', time, data: { inserted: [{ content: [{ type: 'text', text }] }] } });
  writeFileSync(plain, jsonl([
    { type: 'session', id: sessionId },
    spliced('会話名の自動整備：最初の社長の依頼から…', 1794687307000),
    spliced(FIRST, 1794687307811),
    ...FOLLOW_UPS.map((text, i) => spliced(text, 1794687400000 + i)),
  ]));
  execFileSync('/opt/homebrew/bin/zstd', ['-q', '--rm', plain, '-o', `${plain}.zstd`]);
  assert.deepEqual(await readFirstPrompt(id, h), { text: FIRST, createdAt: new Date(1794687307811).toISOString() });
});

test('first prompt: no transcript, no answer', async (t) => {
  const h = homes(t);
  assert.equal(await readFirstPrompt('ffffffff-ffff-4fff-8fff-ffffffffffff', h), null);
  assert.equal(await readFirstPrompt('not-a-uuid', h), null);
  assert.equal(promptText('会話名の自動整備：x'), null);
  assert.equal(promptText('  依頼  '), '依頼');
});

test('initial instruction: a follow-up saved from a partial timeline is replaced by the transcript, and the timeline is never saved', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'initial-fix-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const old = process.env.LAA_SESSION_NAMING_STATE;
  process.env.LAA_SESSION_NAMING_STATE = dir;
  t.after(() => { if (old === undefined) delete process.env.LAA_SESSION_NAMING_STATE; else process.env.LAA_SESSION_NAMING_STATE = old; });
  const store = createSessionStore({ file: join(dir, 'sessions.json') });
  const agentId = '2b58e845-6b05-4a80-9ac5-8c283240076c';
  const base = { name: 'n', source: 'paseo', cwd: '/Users/laa', delegate: { sessionId: agentId },
    createdAt: '2026-11-14T10:05:36.243Z', requested: { provider: 'codex', model: 'm', effort: 'high' } };
  const wrong = { id: 'ses_0000000000000001', ...base,
    initialInstruction: { text: FOLLOW_UPS[0], createdAt: '2026-11-14T10:10:56.953Z', source: 'Work / recovered history' } };
  const unknown = { id: 'ses_0000000000000002', ...base, delegate: { sessionId: '3c58e845-6b05-4a80-9ac5-8c283240076c' } };
  store.importDirectory([wrong, unknown]);
  // The daemon now holds only the newest turns of a long conversation.
  const history = async () => ({ items: FOLLOW_UPS.slice(-5).map((text, i) => ({ id: `u${i}`, role: 'user', text })) });
  const firstPrompt = async (id) => id === agentId ? { text: FIRST, createdAt: '2026-11-14T10:05:37.000Z' } : null;
  const service = createSessionService({ sessionStore: store, adapter: {}, history, firstPrompt, notify: async () => {} });
  t.after(() => service.close());

  const fixed = await service.initialInstruction(wrong.id);
  assert.deepEqual(fixed, { text: FIRST, createdAt: '2026-11-14T10:05:37.000Z', source: 'Work / transcript' });
  assert.deepEqual(store.get(wrong.id).initialInstruction, fixed);
  assert.deepEqual(await service.initialInstruction(wrong.id), fixed);

  // Without a transcript the timeline is shown but not kept as the first instruction.
  const shown = await service.initialInstruction(unknown.id);
  assert.equal(shown.source, 'Work / recovered history');
  assert.equal(store.get(unknown.id).initialInstruction, undefined);
});

test('first prompt: a LAA Work engine session answers from its own record', async (t) => {
  const h = homes(t);
  const workState = join(h.home, 'laa-work');
  mkdirSync(join(workState, 'agents'), { recursive: true });
  const id = '019a8c3e-1b21-8bc3-9248-22fe5b703977';
  writeFileSync(join(workState, 'agents', `${id}.json`), JSON.stringify({ id, initialPrompt: FIRST, createdAt: '2026-11-15T01:00:00.000Z' }));
  assert.deepEqual(await readFirstPrompt(id, { ...h, workState }), { text: FIRST, createdAt: '2026-11-15T01:00:00.000Z' });
});

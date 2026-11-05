import test from 'node:test';
import assert from 'node:assert/strict';
import { ownerText, readConversation } from '../src/sessions/history.mjs';

test('the owner sees the typed text, not the delivered context', () => {
  const typed = 'Laa Voiceの記号を直して\n\n二段落目';
  const legacy = 'Origin / owner: laa-bridge\nClient request ID: x\nPurpose: LAA Bridge session\nIdle means awaiting review, not verified completion.\n\n';
  const directory = 'Working directory: /Users/laa/dev — use this absolute path for files and commands.\n\n';
  const project = '<project_instructions project="p" version="1" hash="h">\n規則\n</project_instructions>\n\n<user_request>\n' + typed + '\n</user_request>';
  assert.equal(ownerText(legacy + typed), typed);
  assert.equal(ownerText(legacy.replace('\n\n', '\n') + directory + typed), typed);
  assert.equal(ownerText(directory + project), typed);
  assert.equal(ownerText('Working directory: どこ？\n\n質問'), 'Working directory: どこ？\n\n質問');
});

test('conversation exposes only user and assistant messages and closes the client', async () => {
  let closed = false;
  const connect = async () => ({
    fetchAgentTimeline: async (id, options) => ({ agentId: id, entries: [
      { item: { type: 'user_message', text: 'Hello' }, timestamp: '2026-01-01T00:00:00Z' },
      { item: { type: 'reasoning', text: 'private reasoning' } },
      { item: { type: 'tool_call', text: 'private tool data' } },
      { item: { type: 'assistant_message', text: 'Hi' } },
    ] }),
    close: async () => { closed = true; },
  });
  const messages = await readConversation('agent', connect);
  assert.deepEqual(messages.map(({ role, text }) => ({ role, text })), [
    { role: 'user', text: 'Hello' }, { role: 'assistant', text: 'Hi' },
  ]);
  assert.equal(closed, true);
});

test('only the first user message loses the delivered context', async () => {
  const delivered = 'Working directory: /x — use this absolute path.\n\n';
  const connect = async () => ({
    fetchAgentTimeline: async (id) => ({ agentId: id, entries: [
      { item: { type: 'user_message', text: `${delivered}最初` } },
      { item: { type: 'user_message', text: `${delivered}次` } },
    ] }),
    close: async () => {},
  });
  const messages = await readConversation('agent', connect);
  assert.deepEqual(messages.map(({ text }) => text), ['最初', `${delivered}次`]);
});

test('conversation rejects another agent and closes the client', async () => {
  let closed = false;
  const connect = async () => ({ fetchAgentTimeline: async () => ({ agentId: 'other', entries: [] }), close: async () => { closed = true; } });
  await assert.rejects(readConversation('agent', connect), { code: 'conversation_unavailable' });
  assert.equal(closed, true);
});

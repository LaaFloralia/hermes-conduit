import test from 'node:test';
import assert from 'node:assert/strict';
import { readConversation } from '../src/sessions/history.mjs';

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

test('conversation rejects another agent and closes the client', async () => {
  let closed = false;
  const connect = async () => ({ fetchAgentTimeline: async () => ({ agentId: 'other', entries: [] }), close: async () => { closed = true; } });
  await assert.rejects(readConversation('agent', connect), { code: 'conversation_unavailable' });
  assert.equal(closed, true);
});

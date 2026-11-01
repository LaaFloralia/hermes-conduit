import { homedir } from 'node:os';
import { join } from 'node:path';
import { BridgeError } from '../errors.mjs';

// Only expose conversation messages. Tool calls and model reasoning are not
// conversation content and may contain information unsuitable for the UI.
export async function readConversation(agentId, connect = defaultConnect) {
  let client;
  try {
    client = await connect();
    const page = await client.fetchAgentTimeline(agentId, {
      direction: 'tail', limit: 0, projection: 'projected', timeout: 15_000,
    });
    if (page.agentId !== agentId || page.error || !Array.isArray(page.entries)) throw new Error('invalid timeline');
    return page.entries.flatMap((entry, index) => {
      const item = entry?.item;
      if (!['user_message', 'assistant_message'].includes(item?.type) || typeof item.text !== 'string') return [];
      return [{ id: `${index}`, role: item.type === 'user_message' ? 'user' : 'assistant', text: item.text, timestamp: entry.timestamp ?? null }];
    });
  } catch {
    throw new BridgeError(503, 'conversation_unavailable', 'conversation history is unavailable', { retryable: true });
  } finally {
    if (client) await client.close().catch(() => {});
  }
}

async function defaultConnect() {
  const { connectToDaemon } = await import('/opt/homebrew/lib/node_modules/@getpaseo/cli/dist/utils/client.js');
  return connectToDaemon({ target: { kind: 'instance', home: join(homedir(), '.paseo') }, timeout: 15_000 });
}

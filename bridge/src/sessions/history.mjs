import { connectDaemon } from './daemon.mjs';
import { BridgeError } from '../errors.mjs';
import { splitLocalImages } from './local-images.mjs';

const DELIVERY_PREAMBLE = /^(?:Origin \/ owner: laa-bridge\n[^]*?\n|Working directory: [^\n]* — use this absolute path[^\n]*\n)\n/;
const USER_REQUEST = /^<project_(?:instructions|files) [^]*?<user_request>\n([^]*)\n<\/user_request>$/;

// The owner sees what they typed, not the context the Bridge delivered with it.
// Only the first message can carry that context, so later ones are shown verbatim.
export function ownerText(text) {
  const body = text.replace(DELIVERY_PREAMBLE, '');
  return body.match(USER_REQUEST)?.[1] ?? body;
}

// The messages the owner wrote or received, plus whether the agent is
// compacting right now. Tool calls and model reasoning never leave the daemon
// through this endpoint: the app shows that work as one status line.
export async function readConversation(agentId, connect = connectDaemon) {
  let client;
  try {
    client = await connect();
    const page = await client.fetchAgentTimeline(agentId, {
      direction: 'tail', limit: 0, projection: 'projected', timeout: 15_000,
    });
    if (page.agentId !== agentId || page.error || !Array.isArray(page.entries)) throw new Error('invalid timeline');
    const firstUser = page.entries.find((entry) => entry?.item?.type === 'user_message' && typeof entry.item.text === 'string');
    // A compaction is current only while it is the newest thing the daemon
    // reported; one left unfinished by an earlier turn is history.
    const newest = page.entries.at(-1)?.item;
    const compacting = newest?.type === 'compaction' && newest.status !== 'completed';
    const items = page.entries.flatMap((entry, index) => {
      const item = entry?.item;
      if (!['user_message', 'assistant_message'].includes(item?.type) || typeof item.text !== 'string') return [];
      // A local picture is shown as an image, not as its markdown placeholder;
      // the service registers only paths that pass the attachment boundary.
      const { text, paths } = splitLocalImages(entry === firstUser ? ownerText(item.text) : item.text);
      return [{
        id: item.clientMessageId ?? item.messageId ?? `${index}`,
        role: item.type === 'user_message' ? 'user' : 'assistant',
        text,
        timestamp: entry.timestamp ?? null,
        ...(paths.length > 0 ? { localImages: paths } : {}),
      }];
    });
    return { items, compacting };
  } catch {
    throw new BridgeError(503, 'conversation_unavailable', 'conversation history is unavailable', { retryable: true });
  } finally {
    if (client) await client.close().catch(() => {});
  }
}

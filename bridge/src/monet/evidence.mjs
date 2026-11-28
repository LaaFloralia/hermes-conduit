// The evidence packet a verification turn receives inline, so the normal case
// needs no tool call to learn what came back: the session's last reply, its
// hand-off slip as parsed fields, and the acceptance items it is checked against.
// Read at claim time (never stored in the inbox): a conversation can hold paths
// and details that do not belong in a second state file.

import { parseSlip } from '../flow/parse.mjs';

export const LAST_MESSAGE_CHARS = 6000;

const tail = (text, chars) => { const all = [...text]; return all.length > chars ? `…${all.slice(-chars).join('')}` : text; };

export function packetFor({ event, session = null, requirement = null, pkg = null, lastMessage = null, unavailable = null }) {
  const text = typeof lastMessage === 'string' ? lastMessage : '';
  const parsed = parseSlip(text);
  return {
    ...event.packet,
    title: event.packet?.title ?? session?.name ?? '',
    session: session ? { id: session.id, name: session.name, phase: session.phase, profile: session.profile ?? null, cwd: session.cwd ?? null,
      projectId: session.projectId ?? null } : null,
    requirement: requirement ? { id: requirement.id, title: requirement.title, status: requirement.status, details: requirement.details ?? null } : null,
    acceptance: (requirement?.acceptance ?? []).map(({ id, text: itemText, check, status }) => ({ id, text: itemText, check, status })),
    package: pkg ? { id: pkg.id, title: pkg.title, completion: pkg.task?.completion ?? null, owns: pkg.owns ?? [], rework: pkg.rework ?? 0 } : null,
    slip: parsed.slip, slipPresent: parsed.present, claimedResult: parsed.result, needsOwner: parsed.needsOwner,
    lastMessage: tail(text, LAST_MESSAGE_CHARS), lastMessageChars: [...text].length,
    ...(unavailable ? { unavailable } : {}),
  };
}

// The newest assistant text of a conversation page, or '' when there is none.
export function lastAssistantText(items) {
  for (let i = (items?.length ?? 0) - 1; i >= 0; i -= 1) {
    if (items[i]?.role === 'assistant' && typeof items[i].text === 'string' && items[i].text.trim()) return items[i].text;
  }
  return '';
}

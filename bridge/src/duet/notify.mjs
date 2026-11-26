import { notifyOwner } from '../notify/index.mjs';

const clip = (value, max) => value.length <= max ? value : value.slice(0, max).replace(/[\uD800-\uDBFF]$/, '');

export async function notifyDuetItem(item) {
  const result = await notifyOwner({
    kind: 'duet', dedupeKey: `duet:${item.id}`, deepLink: 'laa://chats/duet',
    title: clip(`Claude Duet: ${item.title}`, 120), body: clip(item.body, 500),
  });
  if (!(result?.delivered || result?.queued || ['muted', 'duplicate'].includes(result?.reason))) {
    throw new Error('duet_notification_unavailable');
  }
}

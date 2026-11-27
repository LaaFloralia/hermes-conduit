// No decision identifiers or text cross the relay, only the aggregate count.
export function validDecisionBadge(value) {
  return Number.isSafeInteger(value) && value >= 0 && value <= 0x7fff_ffff;
}

export function decisionBadgePush(badge, now = Date.now()) {
  if (!validDecisionBadge(badge)) throw new TypeError('invalid_decision_badge');
  return {
    payload: { aps: { badge, 'content-available': 1 }, laa_decision_badge: true },
    // APNs classifies a badge as interaction even without a banner or sound.
    // `background` is for payloads with no badge, alert or sound.
    pushType: 'alert', priority: 10, collapseId: 'laa-decision-badge',
    expiration: Math.floor(now / 1000) + 60,
  };
}

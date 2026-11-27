import assert from 'node:assert/strict';
import test from 'node:test';
import { decisionBadgePush, validDecisionBadge } from '../../scripts/laa/relay-decision-badge.mjs';

test('relay builds a badge-only APNs push even when the badge goes to zero', () => {
  assert.deepEqual(decisionBadgePush(0, 1000), {
    payload: { aps: { badge: 0, 'content-available': 1 }, laa_decision_badge: true },
    pushType: 'alert', priority: 10, collapseId: 'laa-decision-badge', expiration: 61,
  });
  assert.equal(decisionBadgePush(3).payload.aps.badge, 3);
});

test('relay rejects invalid badge counts instead of silently clearing the badge', () => {
  for (const invalid of [undefined, true, null, '0', -1, 1.5, NaN, 2 ** 31]) {
    assert.equal(validDecisionBadge(invalid), false);
    assert.throws(() => decisionBadgePush(invalid), /invalid_decision_badge/);
  }
});

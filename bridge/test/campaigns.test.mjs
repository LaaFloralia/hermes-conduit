import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startBridge } from './helpers.mjs';
import { campaignItem } from '../src/routes/campaigns.mjs';

// A stand-in for campaign-hunt's ledger.py with the same two commands and
// output: rows live in a JSON file, and `decide` refuses what it would refuse.
const FAKE = `
const fs = require('node:fs');
const [file, command, key, choice] = process.argv.slice(2);
const rows = JSON.parse(fs.readFileSync(file, 'utf8'));
if (command === 'pending') {
  const items = rows.filter((r) => ['needs_owner', 'approved', 'declined'].includes(r.status));
  console.log(JSON.stringify({ version: 1, ledger: '/private/ledger.jsonl', count: items.length, items }));
} else if (command === 'decide') {
  const row = rows.find((r) => r.key === key);
  if (!row) { console.error('NOT_FOUND ' + key); process.exit(1); }
  if (!['needs_owner', 'approved', 'declined'].includes(row.status)) { console.error('NOT_PENDING ' + key); process.exit(1); }
  row.status = choice === 'approve' ? 'approved' : 'declined';
  row.decided_at = '2026-11-15T17:30:00+09:00';
  fs.writeFileSync(file, JSON.stringify(rows));
  console.log(JSON.stringify({ key, status: row.status, decided_at: row.decided_at }));
} else process.exit(2);
`;

function fakeLedger(rows) {
  const dir = mkdtempSync(join(tmpdir(), 'laa-campaigns-test-'));
  const script = join(dir, 'ledger.js');
  const file = join(dir, 'rows.json');
  writeFileSync(script, FAKE);
  writeFileSync(file, JSON.stringify(rows));
  return { command: [process.execPath, script, file], file };
}

const row = (key, status, extra = {}) => ({
  key, status, title: `試験 ${key}`, organizer: '主催', prize: '賞品', deadline: '11月30日', reason: '理由',
  conditions: null, url: 'https://example.com/a', at: '2026-11-15T14:00:00+09:00', decided_at: null, ...extra,
});

test('campaigns: lists waiting and decided entries, then records a choice', async (t) => {
  const ledger = fakeLedger([
    row('aaaaaaaaaaaaaaaa', 'needs_owner'),
    row('bbbbbbbbbbbbbbbb', 'declined', { decided_at: '2026-11-14T10:00:00+09:00' }),
    row('cccccccccccccccc', 'applied'),
  ]);
  const api = await startBridge({ campaigns: { command: ledger.command } });
  t.after(() => api.close());
  const token = await api.token(['sessions:read', 'sessions:write']);

  const list = await api.request('/v1/campaigns', { token });
  assert.equal(list.status, 200);
  assert.equal(list.body.data.count, 1);
  assert.deepEqual(list.body.data.items.map((item) => [item.key, item.status]),
    [['aaaaaaaaaaaaaaaa', 'needs_owner'], ['bbbbbbbbbbbbbbbb', 'declined']]);
  assert.equal(list.body.data.items[1].decidedAt, '2026-11-14T10:00:00+09:00');
  // The ledger's file path stays on the Mac.
  assert.equal(JSON.stringify(list.body).includes('/private/'), false);

  const decided = await api.request('/v1/campaigns/aaaaaaaaaaaaaaaa/decide', { method: 'POST', token, key: 'k1', body: { choice: 'approve' } });
  assert.equal(decided.status, 200);
  assert.deepEqual(decided.body.data, { key: 'aaaaaaaaaaaaaaaa', status: 'approved', decidedAt: '2026-11-15T17:30:00+09:00' });
  assert.equal(JSON.parse(readFileSync(ledger.file, 'utf8'))[0].status, 'approved');

  const again = await api.request('/v1/campaigns', { token });
  assert.equal(again.body.data.count, 0);

  // A decided entry can still change before the next run.
  const changed = await api.request('/v1/campaigns/aaaaaaaaaaaaaaaa/decide', { method: 'POST', token, key: 'k2', body: { choice: 'decline' } });
  assert.equal(changed.body.data.status, 'declined');
});

test('campaigns: refusals', async (t) => {
  const ledger = fakeLedger([row('cccccccccccccccc', 'applied')]);
  const api = await startBridge({ campaigns: { command: ledger.command } });
  t.after(() => api.close());
  const token = await api.token(['sessions:read', 'sessions:write']);
  const reader = await api.token(['sessions:read']);
  const decide = (key, body, as = token, idem = 'k') => api.request(`/v1/campaigns/${key}/decide`, { method: 'POST', token: as, key: idem, body });

  assert.equal((await api.request('/v1/campaigns')).status, 401);
  assert.equal((await decide('cccccccccccccccc', { choice: 'approve' }, reader)).status, 403);
  assert.equal((await decide('dddddddddddddddd', { choice: 'approve' }, token, 'k-missing')).body.error.code, 'campaign_not_found');
  assert.equal((await decide('cccccccccccccccc', { choice: 'approve' }, token, 'k-applied')).body.error.code, 'campaign_not_pending');
  assert.equal((await decide('cccccccccccccccc', { choice: 'maybe' }, token, 'k-choice')).status, 400);
  assert.equal((await decide('cccccccccccccccc', { choice: 'approve', extra: 1 }, token, 'k-extra')).status, 400);
  assert.equal((await api.request('/v1/campaigns/CCCC/decide', { method: 'POST', token, key: 'k-bad', body: { choice: 'approve' } })).status, 404);
  assert.equal(JSON.parse(readFileSync(ledger.file, 'utf8'))[0].status, 'applied');
});

test('campaigns: an unreadable ledger is a retryable 503', async (t) => {
  const api = await startBridge();
  t.after(() => api.close());
  const token = await api.token(['sessions:read']);
  const result = await api.request('/v1/campaigns', { token });
  assert.equal(result.status, 503);
  assert.equal(result.body.error.code, 'campaigns_unavailable');
  assert.equal(result.body.error.retryable, true);
});

test('campaigns: rows without a key, title or web address are dropped', () => {
  assert.equal(campaignItem(row('short', 'needs_owner')), null);
  assert.equal(campaignItem(row('aaaaaaaaaaaaaaaa', 'needs_owner', { title: ' ' })), null);
  assert.equal(campaignItem(row('aaaaaaaaaaaaaaaa', 'needs_owner', { url: 'javascript:alert(1)' })), null);
  assert.equal(campaignItem(row('aaaaaaaaaaaaaaaa', 'applied')), null);
  const item = campaignItem(row('aaaaaaaaaaaaaaaa', 'needs_owner', { organizer: null }));
  assert.equal(item.organizer, null);
  assert.equal(item.url, 'https://example.com/a');
});

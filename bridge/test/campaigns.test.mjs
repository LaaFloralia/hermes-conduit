import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startBridge } from './helpers.mjs';
import { campaignItem } from '../src/routes/campaigns.mjs';

// A stand-in for campaign-hunt's ledger.py (version 2 output) with the same
// two commands: rows live in a JSON file, and `decide` refuses what it would.
const FAKE = `
const fs = require('node:fs');
const args = process.argv.slice(2);
const [file, command, key, choice] = args;
const kindAt = args.indexOf('--kind');
const kind = kindAt > 0 ? args[kindAt + 1] : null;
const rows = JSON.parse(fs.readFileSync(file, 'utf8'));
const waiting = { site: ['needs_owner'], x: ['candidate'], grant: ['candidate', 'needs_owner'] };
const decided = ['approved', 'declined', 'drafted'];
if (command === 'pending') {
  const items = rows.filter((r) => waiting[r.kind].includes(r.status) || decided.includes(r.status));
  console.log(JSON.stringify({ version: 2, ledger: '/private/ledger.jsonl', count: items.length, items }));
} else if (command === 'decide') {
  const hits = rows.filter((r) => r.key === key && (!kind || r.kind === kind));
  if (!hits.length) { console.error('NOT_FOUND ' + key); process.exit(1); }
  if (hits.length > 1) { console.error('AMBIGUOUS ' + key); process.exit(1); }
  const row = hits[0];
  if (![...waiting[row.kind], 'approved', 'declined'].includes(row.status)) { console.error('NOT_PENDING ' + key); process.exit(1); }
  row.status = choice === 'approve' ? 'approved' : 'declined';
  row.decided_at = '2026-11-15T17:30:00+09:00';
  fs.writeFileSync(file, JSON.stringify(rows));
  console.log(JSON.stringify({ key, kind: row.kind, status: row.status, decided_at: row.decided_at }));
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
  key, kind: 'site', action: 'agent_apply', status, title: `試験 ${key}`, organizer: '主催', benefit: '賞品', deadline: '11月30日',
  reason: '理由', next_step: null, gbizid: null, conditions: null, url: 'https://example.com/a', at: '2026-11-15T14:00:00+09:00',
  decided_at: null, ...extra,
});

test('campaigns: lists waiting and decided entries by kind, then records a choice', async (t) => {
  const ledger = fakeLedger([
    row('aaaaaaaaaaaaaaaa', 'needs_owner'),
    row('bbbbbbbbbbbbbbbb', 'declined', { decided_at: '2026-11-14T10:00:00+09:00' }),
    row('cccccccccccccccc', 'applied'),
    row('dddddddddddddddd', 'candidate', { kind: 'x', action: 'self' }),
    row('eeeeeeeeeeeeeeee', 'candidate', { kind: 'grant', action: 'draft', benefit: '上限100万円', gbizid: true, next_step: 'GビズIDを取る' }),
  ]);
  const api = await startBridge({ campaigns: { command: ledger.command } });
  t.after(() => api.close());
  const token = await api.token(['sessions:read', 'sessions:write']);

  // An app that predates the kinds gets the site entries only.
  const legacy = await api.request('/v1/campaigns', { token });
  assert.equal(legacy.status, 200);
  assert.equal(legacy.body.data.count, 1);
  assert.deepEqual(legacy.body.data.items.map((item) => [item.key, item.status]),
    [['aaaaaaaaaaaaaaaa', 'needs_owner'], ['bbbbbbbbbbbbbbbb', 'declined']]);
  assert.equal(legacy.body.data.items[0].benefit, '賞品');
  assert.equal(JSON.stringify(legacy.body).includes('/private/'), false);

  const all = await api.request('/v1/campaigns?kind=all', { token });
  assert.equal(all.body.data.count, 3);
  const grant = all.body.data.items.find((item) => item.kind === 'grant');
  assert.deepEqual([grant.action, grant.waiting, grant.gbizid, grant.nextStep, grant.benefit], ['draft', true, true, 'GビズIDを取る', '上限100万円']);
  assert.equal(all.body.data.items.find((item) => item.kind === 'x').action, 'self');
  assert.equal((await api.request('/v1/campaigns?kind=x', { token })).body.data.items.length, 1);
  assert.equal((await api.request('/v1/campaigns?kind=other', { token })).status, 400);

  const decided = await api.request('/v1/campaigns/aaaaaaaaaaaaaaaa/decide', { method: 'POST', token, key: 'k1', body: { choice: 'approve', kind: 'site' } });
  assert.equal(decided.status, 200);
  assert.deepEqual(decided.body.data, { key: 'aaaaaaaaaaaaaaaa', kind: 'site', status: 'approved', decidedAt: '2026-11-15T17:30:00+09:00' });
  assert.equal(JSON.parse(readFileSync(ledger.file, 'utf8'))[0].status, 'approved');
  assert.equal((await api.request('/v1/campaigns', { token })).body.data.count, 0);

  // A decided entry can still change before the next run.
  const changed = await api.request('/v1/campaigns/aaaaaaaaaaaaaaaa/decide', { method: 'POST', token, key: 'k2', body: { choice: 'decline' } });
  assert.equal(changed.body.data.status, 'declined');
  const x = await api.request('/v1/campaigns/dddddddddddddddd/decide', { method: 'POST', token, key: 'k3', body: { choice: 'approve', kind: 'x' } });
  assert.deepEqual([x.body.data.kind, x.body.data.status], ['x', 'approved']);
});

test('campaigns: refusals', async (t) => {
  const ledger = fakeLedger([
    row('cccccccccccccccc', 'applied'),
    row('ffffffffffffffff', 'needs_owner'),
    row('ffffffffffffffff', 'candidate', { kind: 'grant' }),
  ]);
  const api = await startBridge({ campaigns: { command: ledger.command } });
  t.after(() => api.close());
  const token = await api.token(['sessions:read', 'sessions:write']);
  const reader = await api.token(['sessions:read']);
  const decide = (key, body, as = token, idem = 'k') => api.request(`/v1/campaigns/${key}/decide`, { method: 'POST', token: as, key: idem, body });

  assert.equal((await api.request('/v1/campaigns')).status, 401);
  assert.equal((await decide('cccccccccccccccc', { choice: 'approve' }, reader)).status, 403);
  assert.equal((await decide('dddddddddddddddd', { choice: 'approve' }, token, 'k-missing')).body.error.code, 'campaign_not_found');
  assert.equal((await decide('cccccccccccccccc', { choice: 'approve' }, token, 'k-applied')).body.error.code, 'campaign_not_pending');
  assert.equal((await decide('ffffffffffffffff', { choice: 'approve' }, token, 'k-both')).body.error.code, 'campaign_kind_required');
  assert.equal((await decide('ffffffffffffffff', { choice: 'approve', kind: 'grant' }, token, 'k-grant')).body.data.kind, 'grant');
  assert.equal((await decide('cccccccccccccccc', { choice: 'maybe' }, token, 'k-choice')).status, 400);
  assert.equal((await decide('cccccccccccccccc', { choice: 'approve', kind: 'mail' }, token, 'k-kind')).status, 400);
  assert.equal((await decide('cccccccccccccccc', { choice: 'approve', extra: 1 }, token, 'k-extra')).status, 400);
  assert.equal((await api.request('/v1/campaigns/CCCC/decide', { method: 'POST', token, key: 'k-bad', body: { choice: 'approve' } })).status, 404);
  const rows = JSON.parse(readFileSync(ledger.file, 'utf8'));
  assert.deepEqual(rows.map((r) => r.status), ['applied', 'needs_owner', 'approved']);
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

test('campaigns: rows without a key, title, web address or known kind are dropped; version 1 rows read as site', () => {
  assert.equal(campaignItem(row('short', 'needs_owner')), null);
  assert.equal(campaignItem(row('aaaaaaaaaaaaaaaa', 'needs_owner', { title: ' ' })), null);
  assert.equal(campaignItem(row('aaaaaaaaaaaaaaaa', 'needs_owner', { url: 'javascript:alert(1)' })), null);
  assert.equal(campaignItem(row('aaaaaaaaaaaaaaaa', 'applied')), null);
  assert.equal(campaignItem(row('aaaaaaaaaaaaaaaa', 'won', { kind: 'win' })), null);
  const v1 = campaignItem({ key: 'aaaaaaaaaaaaaaaa', status: 'needs_owner', title: 't', url: 'https://example.com/a', prize: '豆' });
  assert.deepEqual([v1.kind, v1.action, v1.benefit, v1.waiting], ['site', 'agent_apply', '豆', true]);
  assert.equal(campaignItem(row('aaaaaaaaaaaaaaaa', 'drafted', { kind: 'grant' })).waiting, false);
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { createCapacitySource, readGoogleCapacity, readMacBookCapacity, parseMacBookCapacity } from '../src/usage/capacity.mjs';
import { usageRoutes } from '../src/routes/usage.mjs';

const G = 1024 ** 3;
const at = Date.parse('2026-11-08T00:00:00Z');
const memory = { availability: 'available', value: 6 * G, observedAt: new Date(at).toISOString(), detail: { totalBytes: 16 * G, availableBytes: 10 * G } };
const byId = items => new Map(items.map(item => [item.id, item]));
const create = (opts = {}) => createCapacitySource({ now: () => at, host: { read: async () => ({ memory }) }, diskStat: async () => ({ blocks: 100 * G, bavail: 80 * G, bsize: 1 }), google: async () => ({ totalBytes: 100, availableBytes: 40, usedBytes: 60 }), macbook: async () => ({ memory: { totalBytes: 16 * G, availableBytes: 10 * G, usedBytes: 6 * G }, ssd: { totalBytes: 100 * G, availableBytes: 50 * G, usedBytes: 50 * G } }), ...opts });
const settle = async source => { await Promise.all([0, 1, 2, 3].map(i => source.refresh(i))); };

test('capacity projects validated bytes, thresholds and unsupported devices', async t => {
  const source = create(); t.after(source.close); await settle(source);
  const items = byId(source.read());
  assert.equal(items.get('capacity.mac-mini.memory').value, 6 * G);
  assert.equal(items.get('capacity.mac-mini.ssd').detail.status, 'normal');
  assert.equal(items.get('capacity.google-drive').value, 60);
  assert.equal(items.get('capacity.google-drive').detail.resourceType, 'google-storage');
  assert.equal(items.get('capacity.mac-mini.memory').detail.status, 'unknown');
  for (const [used, status] of [[89, 'normal'], [90, 'warning'], [97, 'warning'], [98, 'critical'], [101, 'critical']]) {
    const s = create({ google: async () => ({ totalBytes: 100, usedBytes: used, availableBytes: Math.max(0, 100 - used), driveUsageBytes: 12 }) }); t.after(s.close); await settle(s);
    const item = byId(s.read()).get('capacity.google-drive');
    assert.equal(item.detail.status, status);
    assert.equal(item.detail.driveUsageBytes, 12);
  }
  assert.equal(items.get('capacity.macbook.memory').value, 6 * G);
  assert.equal(items.get('capacity.macbook.ssd').value, 50 * G);
  assert.equal(items.get('capacity.icloud').value, null);
  for (const [free, status] of [[80 * G - 1, 'warning'], [40 * G, 'warning'], [40 * G - 1, 'critical']]) {
    const s = create({ diskStat: async () => ({ blocks: 100 * G, bavail: free, bsize: 1 }) }); t.after(s.close); await settle(s);
    assert.equal(byId(s.read()).get('capacity.mac-mini.ssd').detail.status, status);
  }
});

test('failures, malformed and future samples do not become numbers; old samples are stale', async t => {
  let time = at;
  const s = create({ now: () => time, google: async () => { throw new Error('failed'); }, diskStat: async () => ({ blocks: 1, bavail: 2, bsize: 1 }) }); t.after(s.close); await settle(s);
  let items = byId(s.read());
  assert.equal(items.get('capacity.google-drive').nullReason, 'fetch_failed');
  assert.equal(items.get('capacity.mac-mini.ssd').value, null);
  time += 10_000; items = byId(s.read());
  assert.equal(items.get('capacity.mac-mini.memory').stale, false);
  time = at + 600_000; items = byId(s.read());
  assert.equal(items.get('capacity.mac-mini.memory').stale, true);
  time = at - 1; assert.equal(byId(s.read()).get('capacity.mac-mini.memory').value, null);
});

test('Google account and quota must match; requests share inflight and do not wait', async t => {
  const connection = { request: async () => ({}), json: async () => ({ user: { emailAddress: 'other@example.com' }, storageQuota: { limit: '100', usage: '1' } }) };
  await assert.rejects(readGoogleCapacity({ connection }));
  connection.json = async () => ({ user: { emailAddress: 'floralia@laa-inc.com' }, storageQuota: { limit: '100', usage: '60', usageInDrive: '15' } });
  assert.deepEqual(await readGoogleCapacity({ connection }), { totalBytes: 100, usedBytes: 60, availableBytes: 40, driveUsageBytes: 15 });
  let resolve, calls = 0;
  const s = create({ google: () => { calls++; return new Promise(r => { resolve = r; }); } }); t.after(s.close);
  assert.equal(calls, 0);
  assert.equal(byId(s.read()).get('capacity.google-drive').value, null);
  await Promise.resolve();
  assert.equal(s.refresh(2), s.refresh(2));
  assert.equal(calls, 1);
  assert.equal(byId(s.read()).get('capacity.google-drive').value, null);
  resolve({ totalBytes: 100, usedBytes: 10, availableBytes: 90 }); await s.refresh(2);
  assert.equal(byId(s.read()).get('capacity.google-drive').value, 10);
});

test('usage returns capacity independently of a failed feed', async t => {
  const capacity = create(); await settle(capacity);
  const routes = usageRoutes({ now: () => at, fetcher: async () => { throw Error('offline'); }, capacitySource: capacity });
  t.after(capacity.close);
  const result = await routes.find(route => route.path === '/v1/usage').handler();
  assert.equal(byId(result.data.items).get('capacity.mac-mini.memory').value, 6 * G);
  assert.equal(byId(result.data.items).get('provider.claude.quota').value, null);
});


test('lazy cache intervals and close do not publish pending results', async t => {
  let time = at, calls = 0, done;
  const s = create({ now: () => time, google: async () => { calls++; return { totalBytes: 100, usedBytes: 10, availableBytes: 90 }; } }); t.after(s.close);
  s.read(); await settle(s);
  time += 10_000; s.read(); await s.refresh(0); await s.refresh(1);
  assert.equal(calls, 1);
  time = at + 300_000; s.read(); await s.refresh(2); assert.equal(calls, 2);
  const closed = create({ google: () => new Promise(resolve => { done = resolve; }) });
  closed.read(); await Promise.resolve(); const pending = closed.refresh(2); closed.close();
  done({ totalBytes: 100, usedBytes: 10, availableBytes: 90 }); await pending;
  assert.equal(byId(closed.read()).get('capacity.google-drive').value, null);
});

const macbookOutput = `__MEMORY__
17179869184
__VM__
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                               100.
Pages inactive:                           200.
Pages speculative:                         50.
__DISK__
Filesystem 1024-blocks Used Available Capacity iused ifree %iused Mounted on
/dev/disk3s5 500000000 120000000 100000000 55% 100 200 10% /System/Volumes/Data
`;

test('MacBook fixture uses host memory formula and Data-volume available bytes', async () => {
  const sample = parseMacBookCapacity(macbookOutput);
  assert.deepEqual(sample.memory, { totalBytes: 17179869184, availableBytes: 350 * 16384, usedBytes: 17179869184 - 350 * 16384 });
  assert.deepEqual(sample.ssd, { totalBytes: 500000000 * 1024, availableBytes: 100000000 * 1024, usedBytes: 400000000 * 1024 });
  let seen;
  const result = await readMacBookCapacity({ exec: async (...args) => { seen = args; return { stdout: macbookOutput }; } });
  assert.deepEqual(result, sample);
  assert.equal(seen[0], '/Users/laa/.config/laa/op-run-batch.sh');
  assert.equal(seen[1].length, 2);
  assert.equal(seen[2].timeout, 35000);
});

test('MacBook parser rejects partial, malformed and overflow responses; timeout is generic', async () => {
  for (const output of ['', macbookOutput.replace('Pages inactive:', 'Pages missing:'), macbookOutput.split('__DISK__')[0], macbookOutput.replace('500000000', '99999999999999999'), macbookOutput.replace('100000000 55%', '600000000 55%')]) assert.throws(() => parseMacBookCapacity(output));
  await assert.rejects(readMacBookCapacity({ exec: async () => { throw new Error('secret stderr'); } }), { message: 'MacBook capacity unavailable' });
});

test('MacBook single-flight, five minute cache, freshness, partial and failure are paired', async t => {
  let time = at, calls = 0, resolve;
  const source = create({ now: () => time, macbook: () => { calls++; return new Promise(r => { resolve = r; }); } }); t.after(source.close);
  source.read(); await Promise.resolve();
  const pending = source.refresh(3);
  assert.equal(pending, source.refresh(3)); assert.equal(calls, 1);
  resolve(parseMacBookCapacity(macbookOutput)); await pending;
  let result = byId(source.read());
  assert.equal(result.get('capacity.macbook.memory').availability, 'available');
  assert.equal(result.get('capacity.macbook.ssd').availability, 'available');
  time += 299_999; source.read(); assert.equal(calls, 1);
  time = at + 300_000; source.read(); await Promise.resolve(); assert.equal(calls, 2);
  const second = source.refresh(3); resolve({ memory: parseMacBookCapacity(macbookOutput).memory }); await second;
  result = byId(source.read());
  assert.equal(result.get('capacity.macbook.memory').value, null); assert.equal(result.get('capacity.macbook.ssd').value, null);
  const stale = create({ now: () => time, macbook: async () => parseMacBookCapacity(macbookOutput) }); t.after(stale.close);
  stale.read(); await stale.refresh(3); time += 600_000; result = byId(stale.read());
  assert.equal(result.get('capacity.macbook.memory').stale, true); assert.equal(result.get('capacity.macbook.ssd').stale, true);
  const failed = create({ macbook: async () => { throw new Error('timeout'); } }); t.after(failed.close); failed.read(); await failed.refresh(3);
  result = byId(failed.read()); assert.equal(result.get('capacity.macbook.memory').value, null); assert.equal(result.get('capacity.macbook.ssd').value, null);
});

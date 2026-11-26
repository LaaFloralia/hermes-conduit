import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createRoutineUsage, isRoutineUsage, nextUsageRefresh, usageDay } from '../src/usage/routine.mjs';

const at = Date.parse('2026-11-25T20:00:00.000Z');
const dayMs = 86_400_000;
const balance = { id: 'provider.openai-api.balance', kind: 'balance', availability: 'available', value: 10 };
const refuseless = { ...balance, id: 'provider.refuseless.balance' };
const quota = { id: 'provider.claude.quota', kind: 'quota' };
const credits = { id: 'provider.magnific.credits', kind: 'balance' };
const capacity = { id: 'capacity.macbook.ssd', kind: 'capacity', availability: 'available', value: 40 };
const local = { id: 'capacity.mac-mini.ssd', kind: 'capacity' };

test('05:00 JST buckets are independent of host timezone', () => {
  assert.equal(nextUsageRefresh(at - 1), at);
  assert.equal(nextUsageRefresh(at), at + dayMs);
  assert.equal(usageDay(at - 1) + 1, usageDay(at));
  assert.deepEqual([balance, refuseless, quota, credits, capacity, local].map(isRoutineUsage), [true, true, false, false, true, false]);
});

test('timer, restart, and unavailable readings never overwrite the last scheduled reading with a live one', async t => {
  const root = mkdtempSync(join(tmpdir(), 'laa-usage-routine-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  let time = at - 1, tick, delay, value = 10, calls = 0;
  const make = () => createRoutineUsage({
    file: join(root, 'usage-routine.json'), now: () => time,
    schedule(fn, ms) { tick = fn; delay = ms; return 0; }, cancel() {},
    async collect(publish) {
      calls++;
      publish([{ ...balance, value, availability: value == null ? 'unavailable' : 'available' }, quota]);
      publish([capacity, local]);
    },
  });
  const before = make(); t.after(before.close);
  assert.equal(delay, 1);
  await before.runDue();
  assert.equal(calls, 1);
  assert.deepEqual(before.read(), [balance, capacity]);
  value = 19;
  before.close();
  const after = make(); t.after(after.close);
  await after.runDue();
  assert.deepEqual(after.read(), [balance, capacity]);
  assert.equal(calls, 1);
  time = at; tick(); await after.runDue();
  assert.equal(delay, dayMs);
  assert.equal(calls, 2);
  assert.equal(after.read()[0].value, 19);
  time += dayMs; value = null; tick(); await after.runDue();
  assert.equal(calls, 3);
  assert.equal(after.read()[0].value, 19);
  assert.equal(after.read()[0].stale, true);
});

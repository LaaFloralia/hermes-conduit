#!/usr/bin/env node
import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { open } from 'node:fs/promises';
import { join } from 'node:path';
import { LaneMismatch, probeLiveHealth } from '../../../bridge/src/lane/client.mjs';
import { productionStateDir } from '../../../bridge/src/lane/guard.mjs';

// No other endpoint, method, auth, directory override, or response body read.
async function main() {
  if (process.argv.length !== 3 || process.argv[2] !== '--live') throw new Error('usage: lane-negative.mjs --live');
  const file = join(productionStateDir(), 'decisions.json');
  async function snapshot() {
    const handle = await open(file, 'r');
    try {
      const stat = await handle.stat({ bigint: true });
      const digest = createHash('sha256').update(await handle.readFile()).digest('hex');
      const after = await handle.stat({ bigint: true });
      assert.equal(after.mtimeNs, stat.mtimeNs, 'production decisions changed during read');
      return { sha256: digest, mtimeNs: String(after.mtimeNs), inode: String(after.ino) };
    } finally { await handle.close(); }
  }
  const before = await snapshot();
  let refusal;
  try {
    const response = await probeLiveHealth(`negative-${randomBytes(8).toString('hex')}`);
    await response.body?.cancel();
  } catch (error) {
    if (!(error instanceof LaneMismatch)) throw error;
    refusal = error;
  } finally {
    const after = await snapshot();
    assert.deepEqual(after, before, 'production decisions file changed across the read-only probe');
  }
  assert.ok(refusal, 'production replied as the negative-probe lane');
  process.stdout.write(`${JSON.stringify({ request: 'GET http://127.0.0.1:9137/v1/health', status: refusal.status,
    client: refusal.code, decisions: { unchanged: true, ...before } })}\n`);
}
main().catch((error) => { process.stderr.write(`lane-negative: ${error.message}\n`); process.exitCode = 1; });

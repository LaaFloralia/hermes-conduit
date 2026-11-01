import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { createServer } from 'node:http';
import test from 'node:test';
import { promisify } from 'node:util';

async function runCheck(t, body) {
  const server = createServer((_request, response) => {
    response.writeHead(200, { 'Content-Type': 'application/json' });
    response.end(JSON.stringify(body));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => server.close());
  try {
    const result = await promisify(execFile)(process.execPath, ['scripts/verify-usage.mjs'], {
      cwd: new URL('..', import.meta.url),
      env: { ...process.env, LAA_BRIDGE_USAGE_FEED_URL: `http://127.0.0.1:${server.address().port}/widget`,
        LAA_BRIDGE_STORAGE_STATUS: '/dev/null/no-status.json' },
    });
    return { code: 0, ...result };
  } catch (error) {
    return { code: error.code, stdout: error.stdout, stderr: error.stderr };
  }
}

test('verification shares the future-clock tolerance with Bridge', async (t) => {
  const future = new Date(Date.now() + 119_000).toISOString();
  const feed = { version: 1, fetchedAt: future, providers: [{ id: 'claude', kind: 'quota', available: true,
    updatedAt: future, windows: [{ label: 'Session', remaining: 42 }] }] };
  const result = await runCheck(t, feed);
  assert.equal(result.code, 0, result.stdout + result.stderr);
  assert.equal(JSON.parse(result.stdout).failures.length, 0);

  const tooFuture = new Date(Date.now() + 123_000).toISOString();
  const rejectedRow = { ...feed, fetchedAt: new Date().toISOString(),
    providers: [{ ...feed.providers[0], updatedAt: tooFuture }] };
  const rejected = await runCheck(t, rejectedRow);
  assert.equal(rejected.code, 0, rejected.stdout + rejected.stderr);
  assert.equal(JSON.parse(rejected.stdout).summary.available, 0);
});

test('a rejected feed produces one failure line without a stack trace', async (t) => {
  for (const body of [
    { version: 1, fetchedAt: new Date().toISOString(), providers: [], stale: true },
    { version: 2, fetchedAt: new Date().toISOString(), providers: [] },
  ]) {
    const result = await runCheck(t, body);
    assert.equal(result.code, 1);
    assert.match(result.stdout, /^FAIL  feed \([a-z_]+\)\n$/);
    assert.equal(result.stderr, '');
  }
});

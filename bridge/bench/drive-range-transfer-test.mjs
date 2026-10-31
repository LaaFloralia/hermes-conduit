// Local fake HTTP responses; no simulator, Google credential, or real data.
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../..');
const dir = mkdtempSync(join(tmpdir(), 'laa-drive-transfer-test-'));
const payload = Buffer.from(Array.from({ length: 2048 }, (_, index) => index % 251));
let redirected = 0;
let slowClosed = false;
const server = createServer((req, res) => {
  const route = new URL(req.url, 'http://127.0.0.1').pathname;
  if (route === '/redirected') { redirected += 1; res.end(); return; }
  const match = /^bytes=(\d+)-(\d+)$/.exec(req.headers.range ?? '');
  if (!match) { res.writeHead(400); res.end(); return; }
  const start = Number(match[1]);
  const end = Math.min(Number(match[2]), payload.length - 1);
  if (route === '/ignored') { res.writeHead(200, { 'content-type': 'video/mp4' }); res.end(Buffer.alloc(100_000)); return; }
  if (route === '/unsatisfiable') { res.writeHead(416, { 'content-range': 'bytes */2048' }); res.end(); return; }
  if (route === '/redirect') { res.writeHead(302, { location: '/redirected' }); res.end(); return; }
  if (route === '/error') { res.writeHead(503); res.end(Buffer.alloc(20_000, 65)); return; }
  const range = route === '/bad-range' ? 'bytes 0-4/2048' : `bytes ${start}-${end}/2048`;
  const headers = { 'content-type': 'video/mp4', 'content-range': range };
  if (route === '/bad-length') headers['content-length'] = '99';
  else if (!['/overrun', '/short'].includes(route)) headers['content-length'] = String(end - start + 1);
  res.writeHead(206, headers);
  if (route === '/overrun') { res.end(Buffer.alloc(end - start + 2)); return; }
  if (route === '/short') { res.end(payload.subarray(start, start + 2)); return; }
  if (route === '/slow') {
    res.flushHeaders();
    const timer = setInterval(() => res.write(Buffer.alloc(100)), 40);
    res.on('close', () => { clearInterval(timer); slowClosed = true; });
    return;
  }
  const send = () => res.end(payload.subarray(start, end + 1));
  if (route === '/parallel') setTimeout(send, (20 - start) * 2);
  else send();
});

try {
  await new Promise((resolveListen) => server.listen(0, '127.0.0.1', resolveListen));
  const binary = join(dir, 'range-tests');
  execFileSync('swiftc', ['-D', 'LAA_BUILD', '-O', '-parse-as-library',
    join(here, 'drive-range-transfer-test.swift'),
    join(root, 'Conduit/LAA/Drive/LAADriveRangeTransfer.swift'), '-o', binary],
  { stdio: ['ignore', 'pipe', 'pipe'] });
  const output = await new Promise((resolveProcess, reject) => {
    const child = spawn(binary, [], { env: { ...process.env,
      LAA_BENCH_BASE: `http://127.0.0.1:${server.address().port}` }, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (data) => { stdout += data; });
    child.stderr.on('data', (data) => { stderr += data; });
    child.on('error', reject);
    child.on('close', (code) => code === 0 ? resolveProcess(stdout)
      : reject(new Error(`contract test exited ${code}: ${stderr.slice(0, 3000)}`)));
  });
  assert.equal(redirected, 0, 'credentials must not be sent to the redirect target');
  assert.equal(slowClosed, true, 'cancellation must close the upstream connection');
  process.stdout.write(output);
} finally {
  server.closeAllConnections();
  await new Promise((resolveClose) => server.close(resolveClose));
  rmSync(dir, { recursive: true, force: true });
}

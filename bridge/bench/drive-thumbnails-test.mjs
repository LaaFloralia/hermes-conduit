// Synthetic local responses; no real Drive files, credentials, or simulator.
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { once } from 'node:events';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../..');
const temporary = mkdtempSync(join(tmpdir(), 'laa-drive-thumbnail-fixture-'));
const seen = [];
let slowClosed = false;
const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x01]);
const server = createServer((req, res) => {
  seen.push({ method: req.method, url: req.url, authorization: req.headers.authorization, range: req.headers.range });
  const id = req.url.split('/')[4];
  if (id === 'file_slow') {
    res.writeHead(200, { 'content-type': 'image/png' });
    res.write(png);
    res.on('close', () => { slowClosed = true; });
    return;
  }
  if (id === 'file_redirect') {
    res.writeHead(302, { location: '/redirect-target' });
    res.end();
    return;
  }
  if (id === 'file_denied') {
    const body = JSON.stringify({ error: { code: 'thumbnail_unavailable', message: 'denied', retryable: false }, requestId: 'fixture' });
    res.writeHead(404, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) });
    res.end(body);
    return;
  }
  if (id === 'file_big') {
    res.writeHead(200, { 'content-type': 'image/png', 'content-length': String(2 * 1024 * 1024 + 1) });
    res.end(Buffer.alloc(2 * 1024 * 1024 + 1));
    return;
  }
  if (id === 'file_streambig') {
    res.writeHead(200, { 'content-type': 'image/png' });
    res.write(png);
    res.end(Buffer.alloc(2 * 1024 * 1024));
    return;
  }
  const body = id === 'file_bad' ? Buffer.from('not an image') : png;
  res.writeHead(200, { 'content-type': id === 'file_wrongmime' ? 'text/html' : 'image/png', 'content-length': body.length });
  res.end(body);
});

try {
  const transport = readFileSync(join(root, 'Conduit/LAA/Drive/LAADriveTransport.swift'), 'utf8');
  const start = transport.indexOf('enum LAADrivePaths {');
  const end = transport.indexOf('\nenum LAADriveRangeError', start);
  assert.ok(start >= 0 && end > start, 'actual Drive path validator must be present');
  const pathFile = join(temporary, 'DrivePaths.swift');
  writeFileSync(pathFile, `import Foundation\n${transport.slice(start, end)}\n`);
  const binary = join(temporary, 'fixture');
  execFileSync('swiftc', ['-swift-version', '5', '-D', 'LAA_BUILD', '-parse-as-library',
    join(root, 'Conduit/LAA/LAABridgeClient.swift'), pathFile,
    join(root, 'Conduit/LAA/Drive/LAADriveThumbnails.swift'),
    join(here, 'drive-thumbnails-test.swift'), '-o', binary], { stdio: 'inherit' });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const process = spawn(binary, [`http://127.0.0.1:${server.address().port}`], { stdio: 'inherit' });
  const [code] = await once(process, 'exit');
  assert.equal(code, 0, 'Swift fixture passed');
  assert.ok(seen.length >= 8);
  assert.ok(seen.every((item) => item.method === 'GET' && item.authorization === 'Bearer fixture-token' &&
    item.url.endsWith('/thumbnail') && !item.url.includes('fixture-token') && !item.range));
  assert.ok(!seen.some((item) => item.url === '/redirect-target'), 'redirect did not receive the bearer');
  assert.equal(slowClosed, true, 'cancellation closes the local response');
} catch (error) {
  console.error('Synthetic fixture request paths:', seen.map((item) => item.url));
  throw error;
} finally {
  server.closeAllConnections();
  server.close();
  rmSync(temporary, { recursive: true, force: true });
}

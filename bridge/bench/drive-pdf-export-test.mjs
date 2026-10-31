// Local HTTP fixture and synthetic PDF bytes; no Drive credentials or simulator.
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
const temporary = mkdtempSync(join(tmpdir(), 'laa-drive-pdf-fixture-'));
const seen = [];
let slowClosed = false;
const server = createServer((req, res) => {
  seen.push({ method: req.method, url: req.url, authorization: req.headers.authorization,
    version: req.headers['x-laa-drive-version'], range: req.headers.range });
  const id = req.url.split('/')[4];
  if (id === 'file_slow') {
    res.writeHead(200, { 'content-type': 'application/pdf', 'x-laa-drive-version': '2' });
    res.write('%PDF-');
    res.on('close', () => { slowClosed = true; });
    return;
  }
  if (id === 'file_denied') {
    const body = JSON.stringify({ error: { code: 'download_forbidden', message: 'denied', retryable: false }, requestId: 'fixture' });
    res.writeHead(403, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) });
    res.end(body);
    return;
  }
  if (id === 'file_big') {
    res.writeHead(200, { 'content-type': 'application/pdf', 'content-length': '10000001', 'x-laa-drive-version': '2' });
    res.write('%');
    return;
  }
  const body = Buffer.from(id === 'file_bad' ? 'not a pdf' : '%PDF-1.7\n%%EOF\n');
  const headers = { 'content-type': id === 'file_wrongmime' ? 'text/html' : 'application/pdf',
    'content-length': body.length, 'x-laa-drive-version': id === 'file_changed' ? '3' : '2' };
  if (id === 'file_nover') delete headers['x-laa-drive-version'];
  res.writeHead(200, headers);
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
    join(root, 'Conduit/LAA/Drive/LAADriveDocumentExport.swift'),
    join(here, 'drive-pdf-export-test.swift'), '-o', binary], { stdio: 'inherit' });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const process = spawn(binary, [`http://127.0.0.1:${server.address().port}`], { stdio: 'inherit' });
  const [code] = await once(process, 'exit');
  assert.equal(code, 0, 'Swift fixture passed');
  assert.ok(seen.length >= 7);
  assert.ok(seen.every((item) => item.method === 'GET' && item.authorization === 'Bearer fixture-token' &&
    item.url.endsWith('/export?mimeType=application%2Fpdf') && !item.url.includes('fixture-token') && !item.range));
  assert.equal(seen.find((item) => item.url.includes('/file_1/')).version, '2');
  assert.equal(slowClosed, true, 'cancellation closes the local response');
} catch (error) {
  console.error('Synthetic fixture request paths:', seen.map((item) => item.url));
  throw error;
} finally {
  server.closeAllConnections();
  server.close();
  rmSync(temporary, { recursive: true, force: true });
}

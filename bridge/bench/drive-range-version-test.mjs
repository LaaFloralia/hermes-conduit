// Synthetic local HTTP response; no Drive account, simulator, or real files.
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { once } from 'node:events';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../..');
const source = (...p) => join(root, 'Conduit/LAA', ...p);
const temporary = mkdtempSync(join(tmpdir(), 'laa-range-version-'));
const requests = [];
const server = createServer((req, res) => {
  requests.push({ path: req.url, auth: req.headers.authorization, range: req.headers.range, version: req.headers['x-laa-drive-version'] });
  const id = req.url.split('/')[4];
  const headers = { 'content-type': 'video/mp4', 'content-range': 'bytes 0-3/4', 'content-length': '4' };
  if (id !== 'file_old') headers['x-laa-drive-version'] = id === 'file_changed' ? '43' : id === 'file_bad' ? 'bad' : '42';
  res.writeHead(206, headers); res.end('test');
});
try {
  const assets = readFileSync(source('Assets/LAAAssetsData.swift'), 'utf8');
  const start = assets.indexOf('struct LAADriveItem:'), end = assets.indexOf('\nstruct LAADrivePage:', start);
  assert.ok(start >= 0 && end > start);
  const stubs = join(temporary, 'Stubs.swift');
  writeFileSync(stubs, `import Foundation\n` + assets.slice(start, end) + `\n` +
    `enum LAACopy { enum Assets { static let folder = "Folder", image = "Image", document = "Document", file = "File" } }\n` +
    `enum LAAStudioMedia { static func bridgePathIsValid(_ path: String) -> Bool { false } }\n`);
  const sources = [stubs, source('LAABridgeClient.swift'), source('LAABridgeStatus.swift'),
    source('Drive/LAADriveTransport.swift'), source('Drive/LAADriveThumbnails.swift'),
    source('Drive/LAADriveDocumentExport.swift')];
  const developer = process.env.DEVELOPER_DIR ?? '/Applications/Xcode.app/Contents/Developer';
  const swift = join(developer, 'Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc');
  const sdk = join(developer, 'Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk');
  execFileSync(swift, ['-swift-version', '5', '-D', 'LAA_BUILD', '-target', 'arm64-apple-ios17.0', '-sdk', sdk,
    '-typecheck', ...sources], { stdio: 'inherit' });
  const binary = join(temporary, 'fixture');
  execFileSync('swiftc', ['-swift-version', '5', '-D', 'LAA_BUILD', '-parse-as-library', ...sources,
    join(here, 'drive-range-version-test.swift'), '-o', binary], { stdio: 'inherit' });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const child = spawn(binary, [`http://127.0.0.1:${server.address().port}`], { stdio: 'inherit' });
  const [code] = await once(child, 'exit');
  assert.equal(code, 0);
  assert.equal(requests.length, 5);
  assert.ok(requests.every((r) => r.auth === 'Bearer fixture-token' && r.range === 'bytes=0-3'));
  assert.deepEqual(requests.map((r) => r.version), ['42', undefined, '42', '42', undefined]);
  console.log('Drive Bridge session and range iOS typecheck passed');
} finally {
  server.closeAllConnections(); server.close();
  rmSync(temporary, { recursive: true, force: true });
}

// Exercises actual shared Drive decoders with synthetic Bridge JSON.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../..');
const temporary = mkdtempSync(join(tmpdir(), 'laa-drive-browse-fixture-'));
try {
  const transport = readFileSync(join(root, 'Conduit/LAA/Drive/LAADriveTransport.swift'), 'utf8');
  const assets = readFileSync(join(root, 'Conduit/LAA/Assets/LAAAssetsData.swift'), 'utf8');
  const between = (source, first, last) => {
    const start = source.indexOf(first), end = source.indexOf(last, start);
    if (start < 0 || end <= start) throw new Error(`Missing actual model: ${first}`);
    return source.slice(start, end);
  };
  const actualModels = join(temporary, 'ActualModels.swift');
  writeFileSync(actualModels, `import Foundation\n` +
    `enum LAABridgeError: Error { case invalidResponse }\n` +
    `struct LAABridgeHTTPError: Error { let status: Int; let code: String? }\n` +
    `enum AppLocalization { static func string(_ key: String) -> String { key } }\n` +
    `enum LAACopy { enum Assets { static let folder = "Folder", image = "Image", document = "Document", file = "File" } }\n` +
    between(transport, 'enum LAADrivePaths {', '\nenum LAADriveRangeError') + '\n' +
    between(assets, 'struct LAADriveItem:', '\nstruct LAADrivePage:') + '\n');
  const binary = join(temporary, 'fixture');
  execFileSync('swiftc', ['-swift-version', '5', '-D', 'LAA_BUILD', '-parse-as-library', actualModels,
    join(root, 'Conduit/LAA/Drive/LAADriveBrowseModels.swift'),
    join(here, 'drive-browse-models-test.swift'), '-o', binary], { stdio: 'inherit' });
  execFileSync(binary, [], { stdio: 'inherit' });
  execFileSync('swiftc', ['-swift-version', '5', '-D', 'LAA_BUILD', '-parse-as-library', actualModels,
    join(root, 'Conduit/LAA/Drive/LAADriveBrowseModels.swift'),
    join(root, 'Conduit/LAA/Drive/LAADriveShortcutResolver.swift'),
    join(here, 'drive-shortcut-test.swift'), '-o', binary], { stdio: 'inherit' });
  execFileSync(binary, [], { stdio: 'inherit' });
  execFileSync('swiftc', ['-swift-version', '5', '-D', 'LAA_BUILD', '-parse-as-library', actualModels,
    join(root, 'Conduit/LAA/Drive/LAADriveBrowseModels.swift'),
    join(root, 'Conduit/LAA/Drive/LAADriveBrowseController.swift'),
    join(here, 'drive-browse-controller-test.swift'), '-o', binary], { stdio: 'inherit' });
  execFileSync(binary, [], { stdio: 'inherit' });
  execFileSync('swiftc', ['-swift-version', '5', '-D', 'LAA_BUILD', '-parse-as-library', actualModels,
    join(root, 'Conduit/LAA/Drive/LAADriveBrowseModels.swift'),
    join(root, 'Conduit/LAA/Drive/LAADriveOfflineStore.swift'),
    join(root, 'Conduit/LAA/Drive/LAADriveOfflineFolder.swift'),
    join(here, 'drive-offline-folder-test.swift'), '-o', binary], { stdio: 'inherit' });
  execFileSync(binary, [], { stdio: 'inherit' });
} finally {
  rmSync(temporary, { recursive: true, force: true });
}

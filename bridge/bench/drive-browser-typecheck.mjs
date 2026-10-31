// Check the Drive-only views against the real shared models and iOS SDK without
// invoking xcodebuild, a simulator, or any network/Drive account.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../..');
const temporary = mkdtempSync(join(tmpdir(), 'laa-drive-browser-'));
try {
  const transport = readFileSync(join(root, 'Conduit/LAA/Drive/LAADriveTransport.swift'), 'utf8');
  const assets = readFileSync(join(root, 'Conduit/LAA/Assets/LAAAssetsData.swift'), 'utf8');
  const between = (source, first, last) => {
    const start = source.indexOf(first), end = source.indexOf(last, start);
    if (start < 0 || end <= start) throw new Error(`Missing actual model: ${first}`);
    return source.slice(start, end);
  };
  const models = join(temporary, 'ActualModels.swift');
  writeFileSync(models, `import Foundation\n` +
    `enum LAABridgeError: Error { case invalidResponse }\n` +
    `enum LAACopy { enum Assets { static let folder = "Folder", image = "Image", document = "Document", file = "File" } }\n` +
    between(transport, 'enum LAADrivePaths {', '\nenum LAADriveRangeError') + '\n' +
    between(assets, 'struct LAADriveItem:', '\nstruct LAADrivePage:') + '\n');
  const developer = process.env.DEVELOPER_DIR ?? '/Applications/Xcode.app/Contents/Developer';
  const sdk = join(developer, 'Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk');
  const swift = join(developer, 'Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc');
  const source = (...parts) => join(root, 'Conduit/LAA', ...parts);
  execFileSync(swift, ['-swift-version', '5', '-D', 'LAA_BUILD', '-target', 'arm64-apple-ios17.0',
    '-sdk', sdk, '-typecheck', models, source('LAAColors.swift'), source('Design/LAATokens.swift'),
    source('Drive/LAADriveBrowseModels.swift'), source('Drive/LAADriveBrowseController.swift'),
    source('Drive/LAADriveBrowserView.swift'), source('Drive/LAADriveOfflineStore.swift'),
    source('Drive/LAADriveOfflineList.swift')], { stdio: 'inherit' });
  console.log('Drive browser and offline list iOS typecheck passed');
} finally {
  rmSync(temporary, { recursive: true, force: true });
}

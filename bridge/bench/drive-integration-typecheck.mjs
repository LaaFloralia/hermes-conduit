// Typecheck the assembled Assets, Drive, Bridge and audio code with the iOS
// SDK. UI shell and unrelated Studio dependencies are stubs; no build or simulator.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const temporary = mkdtempSync(join(tmpdir(), 'laa-drive-integration-'));
try {
  const stub = join(temporary, 'Stubs.swift');
  writeFileSync(stub, `import Foundation\nimport SwiftUI\n` +
    `enum LAAStudioMedia { static func bridgePathIsValid(_ path: String) -> Bool { true } }\n` +
    `struct LAAStudioAsset { let kind: String; let name: String }\n` +
    `enum VoicePhoneCalls { static let isOn = false }\n` +
    `enum LogRedaction { static func describing(_ error: Error) -> String { "redacted" } }\n` +
    `struct LAAStudioHomeView: View { let initialSection: Int; var body: some View { EmptyView() } }\n` +
    `struct LAAPairingView: View { var body: some View { EmptyView() } }\n` +
    `struct LAASettingsButton: View { let action: () -> Void; var body: some View { Button("Settings", action: action) } }\n` +
    `extension LAACopy { enum Brain { static let connect = "Connect", retry = "Retry" }; enum Studio { static let unsupported = "Unsupported" } }\n`);
  const source = (...parts) => join(root, 'Conduit/LAA', ...parts);
  const studioWork = readFileSync(source('Studio/LAAStudioWork.swift'), 'utf8');
  const studioStart = studioWork.indexOf('struct LAAStudioPlayerView:');
  const studioEnd = studioWork.lastIndexOf('#endif');
  if (studioStart < 0 || studioEnd <= studioStart) throw new Error('Studio player call site missing');
  const studioPlayer = join(temporary, 'StudioPlayer.swift');
  writeFileSync(studioPlayer, `import SwiftUI\n` + studioWork.slice(studioStart, studioEnd));
  const drive = ['LAADriveBrowseModels', 'LAADriveBrowseController', 'LAADriveShortcutResolver',
    'LAADriveBrowserView', 'LAADriveThumbnails', 'LAADriveDocumentExport', 'LAADriveTransport',
    'LAADrivePlayer', 'LAADrivePlayerOwner', 'LAADrivePlaybackState', 'LAADrivePlaybackCoordinator',
    'LAADriveNativePlayerSurface', 'LAADriveViews', 'LAADriveImagePager', 'LAADriveOfflineStore', 'LAADriveOfflineAccess',
    'LAADriveOfflineList', 'LAADriveOfflineFolder', 'LAADriveOfflineOperations', 'LAADriveOfflineScreen',
    'LAADriveShareFiles', 'LAADriveShareSheet'];
  const sources = [stub, studioPlayer, source('LAATab.swift'), source('LAACopy.swift'), source('LAAColors.swift'),
    source('Design/LAATokens.swift'), source('LAABridgeClient.swift'), source('LAABridgeStatus.swift'),
    source('Assets/LAAAssetsData.swift'), source('Assets/LAAAssetsView.swift'),
    ...drive.map(name => source(`Drive/${name}.swift`)),
    join(root, 'Conduit/Voice/VoiceAudioSessionCoordinator.swift'),
    join(root, 'Conduit/Voice/VoiceAudioSessionConfiguration.swift')];
  const developer = process.env.DEVELOPER_DIR ?? '/Applications/Xcode.app/Contents/Developer';
  const swift = join(developer, 'Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc');
  const sdk = join(developer, 'Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk');
  execFileSync(swift, ['-swift-version', '5', '-D', 'LAA_BUILD', '-D', 'DEBUG', '-target', 'arm64-apple-ios17.0',
    '-sdk', sdk, '-typecheck', ...sources], { stdio: 'inherit' });
  console.log('Assets, Drive, Bridge and actual audio coordinator iOS typecheck passed');
} finally { rmSync(temporary, { recursive: true, force: true }); }

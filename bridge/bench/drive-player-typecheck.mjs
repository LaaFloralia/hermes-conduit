// Typecheck the real player, ownership and native surface against the iOS SDK.
// This is not an app build or a simulator/device test.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../..');
const temporary = mkdtempSync(join(tmpdir(), 'laa-player-typecheck-'));
try {
  const source = (...parts) => join(root, 'Conduit/LAA', ...parts);
  const assets = readFileSync(source('Assets/LAAAssetsData.swift'), 'utf8');
  const first = assets.indexOf('struct LAADriveItem:');
  const last = assets.indexOf('\nstruct LAADrivePage:', first);
  if (first < 0 || last <= first) throw new Error('Drive item model missing');
  const stubs = join(temporary, 'Stubs.swift');
  writeFileSync(stubs, `import Foundation\nimport Combine\nimport AVFAudio\n` +
    `enum LAACopy { enum Assets { static let folder = "Folder", image = "Image", document = "Document", file = "File" }; enum Drive { static let invalidPreview = "Invalid" } }\n` +
    assets.slice(first, last) + `\n` +
    `enum LAABridgeError: Error { case invalidResponse, unavailable; var japaneseText: String { "Error" } }\n` +
    `enum LAADriveRangeError: Error { case invalidRange, versionChanged }\n` +
    `struct LAADriveRangeResponse { let data: Data; let total: Int64; let mimeType: String?; let version: String? }\n` +
    `enum LAADrivePaths { static func content(_ id: String) throws -> String { id }; static func validVersion(_ value: String) -> Bool { true } }\n` +
    `enum LAAStudioMedia { static func bridgePathIsValid(_ path: String) -> Bool { true } }\n` +
    `enum LAADrivePresentation { static func message(_ error: Error) -> String { "Error" } }\n` +
    `@MainActor final class LAABridgeSession: ObservableObject { var deviceID: String?; @Published var revision = 0; func driveRange(path: String, offset: Int64, length: Int) async throws -> LAADriveRangeResponse { throw LAABridgeError.unavailable } }\n` +
    `enum LAADriveContent { static let chunkSize = 256 * 1024; @MainActor static func range(_ item: LAADriveItem, offset: Int64, length: Int, bridge: LAABridgeSession, expectedVersion: String?) async throws -> LAADriveRangeResponse { throw LAABridgeError.unavailable } }\n` +
    `struct VoiceAudioLease {}\nenum VoiceAudioIntent { case standalonePlayback }\n` +
    `@MainActor final class VoiceAudioSessionCoordinator: ObservableObject { static let shared = VoiceAudioSessionCoordinator(); @Published var isInNativeCall = false; var hasOwnersOtherThanWakeListening = false; func acquire(_ intent: VoiceAudioIntent, onTakenOver: (@MainActor () -> Void)? = nil) throws -> VoiceAudioLease { VoiceAudioLease() }; func release(_ lease: VoiceAudioLease) {} }\n`);
  const developer = process.env.DEVELOPER_DIR ?? '/Applications/Xcode.app/Contents/Developer';
  const swift = join(developer, 'Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc');
  const sdk = join(developer, 'Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk');
  execFileSync(swift, ['-swift-version', '5', '-D', 'LAA_BUILD', '-target', 'arm64-apple-ios17.0', '-sdk', sdk,
    '-typecheck', stubs, source('LAAColors.swift'), source('Design/LAATokens.swift'),
    source('Drive/LAADrivePlaybackState.swift'), source('Drive/LAADrivePlaybackCoordinator.swift'), source('Drive/LAADriveOfflineStore.swift'),
    source('Drive/LAADriveNativePlayerSurface.swift'), source('Drive/LAADrivePlayerOwner.swift'),
    source('Drive/LAADrivePlayer.swift')], { stdio: 'inherit' });
  console.log('Shared native player iOS typecheck passed');
} finally {
  rmSync(temporary, { recursive: true, force: true });
}

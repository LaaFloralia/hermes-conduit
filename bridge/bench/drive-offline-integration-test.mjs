// Exercise the real offline UI adapter/store with a small in-memory Drive stub.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../..');
const temporary = mkdtempSync(join(tmpdir(), 'laa-offline-integration-'));
try {
  const source = (...p) => join(root, 'Conduit/LAA', ...p);
  const assets = readFileSync(source('Assets/LAAAssetsData.swift'), 'utf8');
  const start = assets.indexOf('struct LAADriveItem:'), end = assets.indexOf('\nstruct LAADrivePage:', start);
  if (start < 0 || end <= start) throw new Error('Drive item model missing');
  const stubs = join(temporary, 'Stubs.swift');
  writeFileSync(stubs, `import Foundation\n` + assets.slice(start, end) + `\n` + `
enum LAACopy { enum Assets { static let folder = "Folder", image = "Image", document = "Document", file = "File" } }
enum AppLocalization { static func string(_ key: String) -> String { key } }
enum LAABridgeError: Error, Equatable { case networkUnreachable }
struct LAABridgeHTTPError: Error { let status: Int; let code: String? }
enum LAADriveRangeError: Error { case versionChanged }
enum LAADrivePDFExportError: Error { case versionChanged }
struct LAADrivePDFExport { let data: Data; let version: String }
struct LAADriveRangeResponse { let data: Data; let total: Int64; let version: String? }
enum LAADrivePresentation { static func message(_ error: Error) -> String { "Error" } }
@MainActor final class LAABridgeSession {
    enum Status { case paired, unpaired }
    enum Mode { case online, offline, denied, missing }
    var status: Status = .paired
    var deviceID: String? = "fixture-pairing"
    var revision = 0
    var mode: Mode = .online
    var version = "1"
    var changeDuringRange = false
    var reads = 0
    let bytes = Data(repeating: 42, count: 600_000)
}
enum LAADriveData {
    @MainActor static func metadata(_ item: LAADriveItem, bridge: LAABridgeSession) async throws -> LAADriveItem {
        switch bridge.mode {
        case .offline: throw LAABridgeError.networkUnreachable
        case .denied: throw LAABridgeHTTPError(status: 403, code: "download_forbidden")
        case .missing: throw LAABridgeHTTPError(status: 404, code: "not_found")
        case .online: break
        }
        return LAADriveItem(id: item.id, name: item.name, mimeType: item.mimeType, kind: item.kind,
                            version: bridge.version, size: Int64(bridge.bytes.count), modifiedAt: nil,
                            downloadable: true, exportFormats: item.exportFormats, thumbnailLink: nil, owners: nil)
    }
    @MainActor static func exportPDF(_ item: LAADriveItem, bridge: LAABridgeSession, expectedVersion: String?) async throws -> LAADrivePDFExport {
        LAADrivePDFExport(data: Data("%PDF-test".utf8), version: bridge.version)
    }
}
enum LAADriveContent {
    @MainActor static func range(_ item: LAADriveItem, offset: Int64, length: Int, bridge: LAABridgeSession,
                                 expectedVersion: String?) async throws -> LAADriveRangeResponse {
        bridge.reads += 1
        if bridge.changeDuringRange && offset > 0 { bridge.version = "2" }
        guard expectedVersion == bridge.version else { throw LAADriveRangeError.versionChanged }
        let start = Int(offset), end = min(start + length, bridge.bytes.count)
        return LAADriveRangeResponse(data: bridge.bytes.subdata(in: start..<end), total: Int64(bridge.bytes.count), version: bridge.version)
    }
}
`);
  const binary = join(temporary, 'fixture');
  execFileSync('swiftc', ['-swift-version', '5', '-D', 'LAA_BUILD', '-parse-as-library', stubs,
    source('Drive/LAADriveOfflineStore.swift'), source('Drive/LAADriveOfflineAccess.swift'),
    source('Drive/LAADriveShareFiles.swift'), source('Drive/LAADriveOfflineOperations.swift'),
    join(here, 'drive-offline-integration-test.swift'), '-o', binary], { stdio: 'inherit' });
  execFileSync(binary, [temporary], { stdio: 'inherit' });
} finally { rmSync(temporary, { recursive: true, force: true }); }

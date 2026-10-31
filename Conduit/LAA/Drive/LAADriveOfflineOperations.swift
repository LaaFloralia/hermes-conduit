#if LAA_BUILD
import Foundation

/// One store and cleanup task for the process. All network operations retain the
/// original pairing and cannot commit a response from a replacement session.
@MainActor
final class LAADriveOfflineOperations {
    static let shared = LAADriveOfflineOperations()
    private let store: LAADriveOfflineStore?
    private let cleanup: Task<Void, Error>?
    let shares: LAADriveShareFiles

    init(root: URL? = try? LAADriveOfflineStore.appStorageRoot(), shareFiles: LAADriveShareFiles = LAADriveShareFiles()) {
        let storage = root.map { LAADriveOfflineStore(root: $0) }
        store = storage
        shares = shareFiles
        cleanup = storage.map { store in Task { try await store.discardIncompleteSaves() } }
        Task { try? await shareFiles.discardAbandoned() }
    }

    func pairing(_ bridge: LAABridgeSession) throws -> String {
        #if DEBUG
        if LAADriveData.fixture != nil, bridge.deviceID == nil { return "fixture" }
        #endif
        guard let id = bridge.deviceID, bridge.status == .paired else { throw LAADriveOfflineError.accessChanged }
        return id
    }

    private func preparedStore() async throws -> LAADriveOfflineStore {
        guard let store else { throw LAADriveOfflineError.unavailable }
        try await cleanup?.value
        return store
    }

    func records(bridge: LAABridgeSession) async throws -> [LAADriveOfflineRecord] {
        let id = try pairing(bridge)
        let revision = bridge.revision
        let records = try await preparedStore().records(pairingID: id)
        try ensureCurrent(bridge, pairing: id, revision: revision)
        return records
    }

    func remove(_ record: LAADriveOfflineRecord, bridge: LAABridgeSession) async throws {
        let id = try pairing(bridge)
        guard record.pairingID == id else { throw LAADriveOfflineError.accessChanged }
        _ = try await preparedStore().remove(pairingID: id, id: record.id)
    }

    func save(_ item: LAADriveItem, bridge: LAABridgeSession) async throws {
        let id = try pairing(bridge)
        let revision = bridge.revision
        let store = try await preparedStore()
        let metadata: LAADriveOfflineStore.MetadataReader = { [self] in
            try await readMetadata(item, bridge: bridge, pairing: id, revision: revision)
        }
        if item.isWorkspace {
            _ = try await store.saveWorkspacePDF(pairingID: id, id: item.id, name: item.name, metadata: metadata) { version in
                do {
                    let result = try await LAADriveData.exportPDF(item, bridge: bridge, expectedVersion: version)
                    try await self.ensureCurrent(bridge, pairing: id, revision: revision)
                    return LAADriveOfflinePDF(data: result.data, version: result.version)
                } catch { throw self.map(error) }
            }
        } else {
            _ = try await store.save(pairingID: id, id: item.id, name: item.name, mimeType: item.mimeType,
                                     metadata: metadata) { offset, length, version in
                do {
                    let result = try await LAADriveContent.range(item, offset: offset, length: length, bridge: bridge,
                                                                 expectedVersion: version)
                    try await self.ensureCurrent(bridge, pairing: id, revision: revision)
                    return LAADriveOfflineChunk(data: result.data, total: result.total, version: result.version)
                } catch { throw self.map(error) }
            }
        }
        try ensureCurrent(bridge, pairing: id, revision: revision)
    }

    func open(_ record: LAADriveOfflineRecord, bridge: LAABridgeSession) async throws -> LAADriveOfflineOpen {
        let id = try pairing(bridge)
        guard record.pairingID == id else { throw LAADriveOfflineError.accessChanged }
        let revision = bridge.revision
        let result = try await LAADriveOfflineOpener.open(pairingID: id, id: record.id, store: preparedStore()) {
            try await self.check(record, bridge: bridge, pairing: id, revision: revision)
        }
        try ensureCurrent(bridge, pairing: id, revision: revision)
        return result
    }

    /// The PiP owner calls this while a local player is alive. Unlike opening,
    /// it does not re-hash a potentially large file on every check.
    func verify(_ record: LAADriveOfflineRecord, bridge: LAABridgeSession) async throws {
        let id = try pairing(bridge)
        guard record.pairingID == id else { throw LAADriveOfflineError.accessChanged }
        let revision = bridge.revision
        let store = try await preparedStore()
        let generation = try await store.accessCheckGeneration(pairingID: id, id: record.id)
        switch try await check(record, bridge: bridge, pairing: id, revision: revision) {
        case .offline: break
        case .checked(let result):
            try await store.recordCheck(pairingID: id, id: record.id, result: result, expectedGeneration: generation)
        }
        try ensureCurrent(bridge, pairing: id, revision: revision)
        guard let current = try await store.records(pairingID: id).first(where: { $0.id == record.id }) else {
            throw LAADriveOfflineError.notFound
        }
        switch current.access {
        case .denied: throw LAADriveOfflineError.forbidden
        case .missing: throw LAADriveOfflineError.notFound
        case .unknown: throw LAADriveOfflineError.permissionUnknown
        case .verified, .stale: break
        }
    }

    func playbackItem(_ record: LAADriveOfflineRecord) -> LAADriveItem {
        LAADriveItem(id: record.id, name: record.name, mimeType: record.mimeType, kind: "file", version: record.version,
                     size: record.size, modifiedAt: nil, downloadable: true, exportFormats: nil, thumbnailLink: nil, owners: nil)
    }

    private func originalItem(_ record: LAADriveOfflineRecord) -> LAADriveItem {
        guard record.sourceFormat == .workspacePDF else { return playbackItem(record) }
        return LAADriveItem(id: record.id, name: record.name, mimeType: "application/vnd.google-apps.document",
                            kind: "workspace_document", version: record.version, size: nil, modifiedAt: nil,
                            downloadable: true, exportFormats: ["application/pdf"], thumbnailLink: nil, owners: nil)
    }

    private func check(_ record: LAADriveOfflineRecord, bridge: LAABridgeSession, pairing: String,
                       revision: Int) async throws -> LAADriveOfflineCheckAvailability {
        do {
            return .checked(.metadata(try await readMetadata(originalItem(record), bridge: bridge,
                                                              pairing: pairing, revision: revision)))
        } catch let error as LAADriveOfflineError {
            switch error {
            case .forbidden: return .checked(.denied)
            case .notFound: return .checked(.missing)
            default: throw error
            }
        } catch let error as LAABridgeError where error == .networkUnreachable {
            try ensureCurrent(bridge, pairing: pairing, revision: revision)
            return .offline
        }
    }

    private func readMetadata(_ item: LAADriveItem, bridge: LAABridgeSession, pairing: String,
                              revision: Int) async throws -> LAADriveOfflineMetadata {
        try ensureCurrent(bridge, pairing: pairing, revision: revision)
        do {
            let value = try await LAADriveData.metadata(item, bridge: bridge)
            try ensureCurrent(bridge, pairing: pairing, revision: revision)
            return LAADriveOfflineMetadata(version: value.version, size: value.size, downloadable: value.downloadable)
        } catch { throw map(error) }
    }

    private func ensureCurrent(_ bridge: LAABridgeSession, pairing: String, revision: Int) throws {
        guard bridge.revision == revision, (try? self.pairing(bridge)) == pairing else { throw LAADriveOfflineError.accessChanged }
    }

    nonisolated private func map(_ error: Error) -> Error {
        if let error = error as? LAABridgeHTTPError {
            if error.status == 404 { return LAADriveOfflineError.notFound }
            if error.status == 403 && error.code == "download_forbidden" { return LAADriveOfflineError.forbidden }
            if error.status == 403 { return LAADriveOfflineError.permissionUnknown }
            if error.status == 401 { return LAADriveOfflineError.accessChanged }
            if error.code == "version_changed" { return LAADriveOfflineError.versionChanged }
        }
        if (error as? LAADriveRangeError) == .versionChanged || (error as? LAADrivePDFExportError) == .versionChanged {
            return LAADriveOfflineError.versionChanged
        }
        return error
    }

    static func message(_ error: Error) -> String {
        guard let error = error as? LAADriveOfflineError else { return LAADrivePresentation.message(error) }
        switch error {
        case .forbidden: return "Drive no longer permits access to this file."
        case .notFound: return "This file is no longer available in Drive."
        case .permissionUnknown: return "The file's current permission could not be verified."
        case .versionUnavailable: return "Drive did not provide a file version. This copy cannot be saved safely."
        case .versionChanged: return "The file changed while saving. Try again."
        case .insufficientSpace: return "There is not enough free space. Existing saved files were kept."
        case .alreadySaving: return "This file is already being saved."
        case .accessChanged: return "The Bridge connection changed. Reopen the file."
        case .corruptIndex, .unavailable, .cleanupFailed: return "The saved file could not be read."
        default: return "This file could not be saved."
        }
    }
}
#endif

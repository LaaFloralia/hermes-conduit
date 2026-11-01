#if LAA_BUILD
import Foundation

enum LAADriveOfflineCheckAvailability {
    case checked(LAADriveOfflineCheck)
    /// Only a recognized network outage should be mapped to this case.
    case offline
}

struct LAADriveOfflineOpen {
    let record: LAADriveOfflineRecord
    let url: URL
    let checkedOnline: Bool
}

/// Resolves a saved copy after a fresh access check when online. The owner
/// must discard the result if the pairing changed and stop active playback if
/// a later check reports denial or deletion.
@MainActor
enum LAADriveOfflineOpener {
    typealias Checker = @MainActor () async throws -> LAADriveOfflineCheckAvailability

    static func open(pairingID: String, id: String, store: LAADriveOfflineStore,
                     check: Checker) async throws -> LAADriveOfflineOpen {
        let generation = try await store.accessCheckGeneration(pairingID: pairingID, id: id)
        let availability = try await check()
        try Task.checkCancellation()
        let checkedOnline: Bool
        switch availability {
        case .checked(let result):
            try await store.recordCheck(pairingID: pairingID, id: id, result: result, expectedGeneration: generation)
            checkedOnline = true
        case .offline:
            checkedOnline = false
        }
        try Task.checkCancellation()
        guard let record = try await store.records(pairingID: pairingID).first(where: { $0.id == id }) else {
            throw LAADriveOfflineError.unavailable
        }
        switch record.access {
        case .denied: throw LAADriveOfflineError.forbidden
        case .missing: throw LAADriveOfflineError.notFound
        case .unknown: throw LAADriveOfflineError.permissionUnknown
        case .verified, .stale: break
        }
        guard let copy = try await store.localCopy(pairingID: pairingID, id: id) else {
            throw LAADriveOfflineError.unavailable
        }
        try Task.checkCancellation()
        return .init(record: copy.record, url: copy.url, checkedOnline: checkedOnline)
    }
}
#endif

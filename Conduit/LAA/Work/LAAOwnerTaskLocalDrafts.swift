#if LAA_BUILD
import Foundation

/// Owner-task editor state is kept in the existing Work draft store, isolated
/// by device and task. This does not reserve or send a network operation.
@MainActor
enum LAAOwnerTaskLocalDrafts {
    private static let profile = "laa-owner-task-draft-v1"

    struct Entry {
        let key: ComposerDraftKey
        let deviceID: String?
        let taskID: UUID?
    }

    enum ReadResult: Equatable {
        case absent
        case saved(LAAOwnerTaskDraft)
        case unreadable
    }

    static func key(deviceID: String, taskID: UUID) -> ComposerDraftKey? {
        guard !deviceID.isEmpty else { return nil }
        let encodedDevice = Data(deviceID.utf8).base64EncodedString()
        return ComposerDraftKey(profile: profile, sessionID: "\(encodedDevice):\(taskID.uuidString)",
                                dashboardID: LAAWorkDrafts.dashboardID)
    }

    /// Even malformed keys remain enumerable, so the caller can quarantine
    /// them rather than treating their content as belonging to this device.
    static func entries(in store: ComposerDraftStore) -> [Entry] {
        store.keys.filter { $0.profile == profile && $0.dashboardID == LAAWorkDrafts.dashboardID }.map { key in
            let parts = key.sessionID.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let bytes = Data(base64Encoded: String(parts[0])),
                  let deviceID = String(data: bytes, encoding: .utf8), !deviceID.isEmpty,
                  let taskID = UUID(uuidString: String(parts[1])) else {
                return Entry(key: key, deviceID: nil, taskID: nil)
            }
            return Entry(key: key, deviceID: deviceID, taskID: taskID)
        }
    }

    static func read(_ store: ComposerDraftStore, deviceID: String, taskID: UUID) -> ReadResult {
        guard let key = key(deviceID: deviceID, taskID: taskID) else { return .unreadable }
        guard store.hasDraft(for: key) else { return store.persistenceFailed ? .unreadable : .absent }
        let saved = store.draft(for: key)
        guard saved.attachments.isEmpty, saved.replyReference == nil, (saved.roomRecipients?.isEmpty ?? true),
              let draft = try? LAAOwnerTaskDraftArchive.decode(saved.text), draft.id == taskID else { return .unreadable }
        return .saved(draft)
    }

    @discardableResult
    static func save(_ draft: LAAOwnerTaskDraft, in store: ComposerDraftStore, deviceID: String) -> Bool {
        guard let key = key(deviceID: deviceID, taskID: draft.id) else { return false }
        // Never replace a record that cannot be decoded; it may be the only
        // copy after a protected-data or format error.
        if case .unreadable = read(store, deviceID: deviceID, taskID: draft.id) { return false }
        guard let text = try? LAAOwnerTaskDraftArchive.encode(draft) else { return false }
        return store.save(ComposerDraft(text: text, attachments: []), for: key)
    }

    /// A response for an older edit must not clear a newer local edit.
    @discardableResult
    static func remove(_ expected: LAAOwnerTaskDraft, from store: ComposerDraftStore, deviceID: String) -> Bool {
        guard let key = key(deviceID: deviceID, taskID: expected.id),
              read(store, deviceID: deviceID, taskID: expected.id) == .saved(expected) else { return false }
        let original = store.draft(for: key)
        guard store.removeDraft(for: key) else {
            // The underlying store removes in memory before reporting a disk
            // error. Restore that copy and still report removal failure.
            _ = store.save(original, for: key)
            return false
        }
        return true
    }
}
#endif

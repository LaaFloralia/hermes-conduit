#if LAA_BUILD
import Foundation

/// This journal shares the existing protected Work draft file, but has its own
/// namespace and never replays a request under a different paired device.
@MainActor
enum LAAOwnerTaskOutbox {
    private static let marker = "laa-owner-task-request-v1:"

    static func entries(in store: ComposerDraftStore) -> [ComposerDraftStore.Submission] {
        store.submissions.filter { LAAOwnerTaskLocalDrafts.owns($0.key) }
    }

    static func request(_ item: ComposerDraftStore.Submission) -> LAAOwnerTaskRequest? {
        guard let text = item.groupOutboundText, text.hasPrefix(marker),
              let data = String(text.dropFirst(marker.count)).data(using: .utf8),
              let request = try? JSONDecoder().decode(LAAOwnerTaskRequest.self, from: data),
              request.taskID == request.draft.id,
              request.key == item.groupEventID,
              let expectedKey = LAAOwnerTaskLocalDrafts.key(deviceID: request.deviceID, taskID: request.taskID),
              expectedKey == item.key,
              (request.method == "POST" && request.path == "/v1/owner-tasks" && request.ifMatch == nil ||
               request.method == "PATCH" && request.path == "/v1/owner-tasks/\(request.taskID.uuidString.lowercased())" && request.ifMatch != nil),
              LAABridgeIdempotencyKey(restoring: request.key) != nil else { return nil }
        return request
    }

    static func reserve(_ request: LAAOwnerTaskRequest, in store: ComposerDraftStore) -> ComposerDraftStore.Submission? {
        guard let key = LAAOwnerTaskLocalDrafts.key(deviceID: request.deviceID, taskID: request.taskID),
              !store.submissions.contains(where: { $0.key == key }),
              LAAOwnerTaskLocalDrafts.read(store, deviceID: request.deviceID, taskID: request.taskID) == .saved(request.draft),
              let savedDraft = try? LAAOwnerTaskDraftArchive.encode(request.draft),
              let bytes = try? JSONEncoder().encode(request), let text = String(data: bytes, encoding: .utf8) else { return nil }
        let item = ComposerDraftStore.Submission(id: UUID(), key: key, dashboardID: LAAWorkDrafts.dashboardID,
            draft: ComposerDraft(text: savedDraft, attachments: []), pendingSendID: nil,
            screenshotID: request.ifMatch, groupEventID: request.key, groupOutboundText: marker + text)
        guard store.beginSubmission(item, clearingDraft: true) else { return nil }
        // If the app stops at any point after reservation, the outcome is
        // unknown. There is no separate, reliable proof of "not sent".
        store.markSubmissionUnknown(item.id)
        return item
    }

    /// Restore only a definite rejection, and never combine two serialized
    /// drafts. A newer draft must be resolved separately.
    static func restoreRejected(_ item: ComposerDraftStore.Submission, in store: ComposerDraftStore) -> Bool {
        guard request(item) != nil, !store.hasDraft(for: item.key) else { return false }
        return store.finishSubmission(item.id, restoring: true)
    }

    static func finish(_ item: ComposerDraftStore.Submission, in store: ComposerDraftStore) -> Bool {
        guard request(item) != nil else { return false }
        return store.finishSubmission(item.id, restoring: false)
    }

    /// A moved request remains outcome-unknown: its UUID, key, bytes and
    /// revision are unchanged and it is never replayed by this operation.
    static func move(_ item: ComposerDraftStore.Submission, to deviceID: String, in store: ComposerDraftStore) -> Bool {
        guard var request = request(item), request.deviceID != deviceID,
              let destination = LAAOwnerTaskLocalDrafts.key(deviceID: deviceID, taskID: request.taskID),
              !store.hasDraft(for: destination), !store.submissions.contains(where: { $0.key == destination }) else { return false }
        request.originalDeviceID = request.originalDeviceID ?? request.deviceID
        request.deviceID = deviceID
        guard let bytes = try? JSONEncoder().encode(request), let text = String(data: bytes, encoding: .utf8) else { return false }
        return store.rebindSubmission(item.id, to: destination, groupOutboundText: marker + text)
    }
}
#endif

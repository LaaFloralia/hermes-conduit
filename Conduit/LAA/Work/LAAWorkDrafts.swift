#if LAA_BUILD
import Foundation

/// A separate file using Task 08's durable store. The existing submission
/// envelope atomically keeps the draft, immutable request bytes and key before
/// any network call; its group fields are private to this isolated store.
enum LAAWorkDrafts {
    private struct RequestRecord: Codable {
        let body: String
        let reservedAt: Date
    }
    private static let recordPrefix = "laa-work-request-v1:"
    // The Bridge retains idempotency records for seven days. Stop offering a
    // repeat one day earlier to allow for clock differences and slow requests.
    private static let repeatWindow: TimeInterval = 6 * 24 * 60 * 60
    static let expiredMessage = "要求の照合期限を過ぎたため再送できません。現在の状態を確認してください。"
    static let dashboardID = UUID(uuidString: "4D2D24A2-68A6-4D83-8EB0-424DFEACCB3C")!
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Work", isDirectory: true)
            .appendingPathComponent("drafts-v1.json")
    }
    static func key(deviceID: String, target: String) -> ComposerDraftKey {
        ComposerDraftKey(profile: "laa-bridge", sessionID: "\(deviceID):\(target)", dashboardID: dashboardID)
    }
    @MainActor static func pending(_ store: ComposerDraftStore, key: ComposerDraftKey) -> ComposerDraftStore.Submission? {
        store.submissions.first { $0.key == key }
    }
    @MainActor static func reserve(_ store: ComposerDraftStore, key: ComposerDraftKey,
                                   text: String, body: Data, idempotency: LAABridgeIdempotencyKey,
                                   expectedVersion: String? = nil, attachments: [Attachment] = [],
                                   now: Date = Date()) -> ComposerDraftStore.Submission? {
        guard pending(store, key: key) == nil, let payload = String(data: body, encoding: .utf8),
              let record = try? JSONEncoder().encode(RequestRecord(body: payload, reservedAt: now)) else { return nil }
        let submission = ComposerDraftStore.Submission(
            id: UUID(), key: key, dashboardID: dashboardID,
            draft: ComposerDraft(text: text, attachments: attachments), pendingSendID: nil,
            screenshotID: expectedVersion, groupEventID: idempotency.value,
            groupOutboundText: recordPrefix + String(decoding: record, as: UTF8.self)
        )
        guard store.beginSubmission(submission, clearingDraft: true) else { return nil }
        return submission
    }
    static func request(_ item: ComposerDraftStore.Submission) -> (Data, LAABridgeIdempotencyKey)? {
        guard let text = item.groupOutboundText, let rawKey = item.groupEventID,
              let key = LAABridgeIdempotencyKey(restoring: rawKey) else { return nil }
        // Legacy records remain readable for reconciliation, but cannot be
        // repeated because their original reservation time is unknown.
        let payload = record(item)?.body ?? (text.hasPrefix(recordPrefix) ? nil : text)
        guard let body = payload?.data(using: .utf8) else { return nil }
        return (body, key)
    }
    static func canRepeat(_ item: ComposerDraftStore.Submission, now: Date = Date()) -> Bool {
        guard let record = record(item) else { return false }
        let age = now.timeIntervalSince(record.reservedAt)
        return age >= 0 && age < repeatWindow
    }
    private static func record(_ item: ComposerDraftStore.Submission) -> RequestRecord? {
        guard let text = item.groupOutboundText, text.hasPrefix(recordPrefix),
              let bytes = String(text.dropFirst(recordPrefix.count)).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RequestRecord.self, from: bytes)
    }
}

#endif

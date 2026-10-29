import Combine
import Foundation

struct ComposerDraft: Codable, Equatable {
    var text: String
    var attachments: [Attachment]
    /// A whole reply attached with its Quote button (#385).
    var replyReference: ComposerReplyReference? = nil
    /// A group room's explicitly selected recipients, in selection order.
    /// Optional so drafts saved by older builds remain readable.
    var roomRecipients: [String]? = nil

    static let empty = ComposerDraft(text: "", attachments: [])

    var isEmpty: Bool {
        text.isEmpty && attachments.isEmpty && replyReference == nil && (roomRecipients?.isEmpty ?? true)
    }
}

struct ComposerDraftKey: Codable, Hashable {
    static let newConversationSessionID = "new-conversation"

    var profile: String
    var sessionID: String
    var dashboardID: UUID? = nil

    var isNewConversation: Bool {
        sessionID == Self.newConversationSessionID
    }
}

struct ComposerDraftSubmissionBucket: Equatable {
    let key: ComposerDraftKey
    fileprivate let generation: UUID?
}

@MainActor
final class ComposerDraftStore: ObservableObject {
    struct Submission: Codable, Equatable, Identifiable {
        let id: UUID
        var key: ComposerDraftKey
        let dashboardID: UUID
        let draft: ComposerDraft
        let pendingSendID: UUID?
        var screenshotID: String? = nil
        var groupEventID: String? = nil
        var groupOutboundText: String? = nil
    }

    private struct Entry: Codable {
        let key: ComposerDraftKey
        let draft: ComposerDraft
    }

    private struct Snapshot: Codable {
        let version: Int
        let drafts: [Entry]
        let submissions: [Submission]
        let restoredPendingIDs: [UUID]?
    }

    private let capacity: Int
    private let fileURL: URL?
    private var drafts: [ComposerDraftKey: ComposerDraft] = [:]
    private var order: [ComposerDraftKey] = []
    private var generations: [ComposerDraftKey: UUID] = [:]
    @Published private(set) var submissions: [Submission] = []
    @Published private(set) var persistenceFailed = false
    private var activeSubmissions: Set<UUID> = []
    private var restoredPendingIDs: Set<UUID> = []
    private var unreadableSnapshot = false
    private var attachmentCopies: [String: URL] = [:]
    /// How many times `removeAll` ran: a composer loaded before a clear
    /// doesn't put its draft back after it.
    private(set) var clearCount: UInt64 = 0

    init(capacity: Int = 12, fileURL: URL? = nil) {
        self.capacity = max(0, capacity)
        self.fileURL = fileURL
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: fileURL))
            guard snapshot.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            for entry in snapshot.drafts where !entry.draft.isEmpty {
                drafts[entry.key] = entry.draft
                order.append(entry.key)
                refreshGeneration(for: entry.key)
            }
            submissions = snapshot.submissions
            restoredPendingIDs = Set(snapshot.restoredPendingIDs ?? [])
            cleanupUnreferencedAttachments()
        } catch {
            // Never overwrite a file that could not be read (including while
            // protected data is unavailable); it may contain the only copy.
            unreadableSnapshot = true
            persistenceFailed = true
        }
    }

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Composer", isDirectory: true)
            .appendingPathComponent("drafts-v1.json")
    }

    func draft(for key: ComposerDraftKey) -> ComposerDraft {
        guard let draft = drafts[key] else { return .empty }
        touch(key)
        return draft
    }

    @discardableResult
    func save(_ draft: ComposerDraft, for key: ComposerDraftKey) -> Bool {
        if draft.isEmpty {
            return removeDraft(for: key)
        }

        guard capacity > 0 else {
            return removeDraft(for: key)
        }

        guard let durable = durableDraft(draft) else { persistenceFailed = true; return false }
        drafts[key] = durable
        refreshGeneration(for: key)
        touch(key)
        evictIfNeeded()
        return persist()
    }

    func hasDraft(for key: ComposerDraftKey) -> Bool {
        drafts[key] != nil
    }

    /// The keys with a draft, most recently used first.
    var keys: [ComposerDraftKey] {
        order.reversed()
    }

    /// A submission that failed goes back into its chat's draft, above
    /// anything typed there since: neither is lost.
    func restoreFailedSubmission(_ draft: ComposerDraft, for key: ComposerDraftKey) {
        save(self.draft(for: key).restoring(draft), for: key)
    }

    func hasRestoredPending(_ id: UUID) -> Bool { restoredPendingIDs.contains(id) }

    /// The pending file and the draft snapshot are separate. Record the
    /// transfer in the same atomic write as the draft so a crash before the
    /// pending file is removed cannot insert the same words a second time.
    func saveRestoredPending(_ id: UUID, draft: ComposerDraft, for key: ComposerDraftKey) -> Bool {
        guard !restoredPendingIDs.contains(id) else { return true }
        guard let durable = durableDraft(draft) else { persistenceFailed = true; return false }
        let oldDrafts = drafts, oldOrder = order, oldGenerations = generations
        drafts[key] = durable
        refreshGeneration(for: key)
        touch(key)
        restoredPendingIDs.insert(id)
        guard persist() else {
            drafts = oldDrafts
            order = oldOrder
            generations = oldGenerations
            restoredPendingIDs.remove(id)
            return false
        }
        return true
    }

    func forgetRestoredPending(_ id: UUID) {
        guard restoredPendingIDs.remove(id) != nil else { return }
        persist()
    }

    func migrateDraft(from source: ComposerDraftKey, to destination: ComposerDraftKey) {
        guard source != destination, let draft = drafts[source] else { return }
        drafts.removeValue(forKey: source)
        generations.removeValue(forKey: source)
        order.removeAll { $0 == source }
        drafts[destination] = draft
        refreshGeneration(for: destination)
        touch(destination)
        persist()
    }

    func submissionBucket(for key: ComposerDraftKey) -> ComposerDraftSubmissionBucket {
        ComposerDraftSubmissionBucket(key: key, generation: generations[key])
    }

    @discardableResult
    func removeDraft(for key: ComposerDraftKey) -> Bool {
        drafts.removeValue(forKey: key)
        generations.removeValue(forKey: key)
        order.removeAll { $0 == key }
        return persist()
    }

    func removeDraft(for bucket: ComposerDraftSubmissionBucket) {
        guard let generation = bucket.generation,
              generations[bucket.key] == generation else { return }
        removeDraft(for: bucket.key)
    }

    func removeAll() {
        clearCount &+= 1
        drafts.removeAll()
        generations.removeAll()
        order.removeAll()
        submissions.removeAll()
        activeSubmissions.removeAll()
        restoredPendingIDs.removeAll()
        persist()
    }

    /// A server switch invalidates the mounted composer's ownership without
    /// deleting drafts scoped to the outgoing dashboard.
    func detachComposer() {
        clearCount &+= 1
    }

    func removeDashboard(_ dashboardID: UUID) {
        clearCount &+= 1
        // Legacy/unscoped drafts cannot safely be attributed to another
        // signed-in dashboard after this identity is removed.
        let removed = Set(drafts.keys.filter { $0.dashboardID == dashboardID || $0.dashboardID == nil })
        for key in removed {
            drafts.removeValue(forKey: key)
            generations.removeValue(forKey: key)
        }
        order.removeAll { removed.contains($0) }
        let removedSubmissions = submissions.filter { $0.dashboardID == dashboardID }
        submissions.removeAll { $0.dashboardID == dashboardID }
        activeSubmissions.subtract(removedSubmissions.map(\.id))
        persist()
    }

    /// Reserve the outgoing message on disk before invoking the network.
    /// On restart every surviving reservation has an unknown outcome.
    func beginSubmission(_ submission: Submission, clearingDraft: Bool, remainingDraft: ComposerDraft? = nil) -> Bool {
        guard !unreadableSnapshot, !submissions.contains(where: { $0.id == submission.id }) else { return false }
        guard let durable = durableDraft(submission.draft) else { persistenceFailed = true; return false }
        let remaining: ComposerDraft?
        if let remainingDraft, !remainingDraft.isEmpty {
            guard let copy = durableDraft(remainingDraft) else { persistenceFailed = true; return false }
            remaining = copy
        } else {
            remaining = nil
        }
        let submission = Submission(id: submission.id, key: submission.key, dashboardID: submission.dashboardID,
                                    draft: durable, pendingSendID: submission.pendingSendID, screenshotID: submission.screenshotID,
                                    groupEventID: submission.groupEventID, groupOutboundText: submission.groupOutboundText)
        let oldDrafts = drafts, oldOrder = order, oldGenerations = generations
        submissions.append(submission)
        if clearingDraft {
            drafts.removeValue(forKey: submission.key)
            generations.removeValue(forKey: submission.key)
            order.removeAll { $0 == submission.key }
            if let remaining {
                drafts[submission.key] = remaining
                refreshGeneration(for: submission.key)
                touch(submission.key)
            }
        }
        guard persist() else {
            submissions.removeAll { $0.id == submission.id }
            drafts = oldDrafts
            order = oldOrder
            generations = oldGenerations
            return false
        }
        activeSubmissions.insert(submission.id)
        return true
    }

    var unknownSubmissions: [Submission] {
        submissions.filter { !activeSubmissions.contains($0.id) }
    }

    /// Once a new conversation exists, persist its identity before any
    /// message is sent into it. The journal then remains discoverable even
    /// when a process dies before the network response.
    @discardableResult
    func rebindSubmission(_ id: UUID, to key: ComposerDraftKey) -> Bool {
        guard let index = submissions.firstIndex(where: { $0.id == id }),
              submissions[index].dashboardID == key.dashboardID else { return false }
        let oldKey = submissions[index].key
        submissions[index].key = key
        guard persist() else {
            submissions[index].key = oldKey
            return false
        }
        return true
    }

    func markSubmissionUnknown(_ id: UUID) {
        objectWillChange.send()
        activeSubmissions.remove(id)
    }

    @discardableResult
    func finishSubmission(_ id: UUID, restoring: Bool, destination: ComposerDraftKey? = nil,
                          restoreDraft: ComposerDraft? = nil) -> Bool {
        guard let index = submissions.firstIndex(where: { $0.id == id }) else { return false }
        let item = submissions[index]
        let oldDrafts = drafts, oldOrder = order, oldGenerations = generations
        submissions.remove(at: index)
        if restoring {
            let key = destination ?? item.key
            drafts[key] = (drafts[key] ?? .empty).restoring(restoreDraft ?? item.draft)
            refreshGeneration(for: key)
            touch(key)
        }
        guard persist() else {
            submissions.insert(item, at: index)
            drafts = oldDrafts
            order = oldOrder
            generations = oldGenerations
            markSubmissionUnknown(id)
            return false
        }
        activeSubmissions.remove(id)
        return true
    }

    /// Attachments are staged in a temporary folder and can be deleted by
    /// the sender or iOS. The durable snapshot owns a separate local copy.
    private func durableDraft(_ draft: ComposerDraft) -> ComposerDraft? {
        guard let fileURL else { return draft }
        var durable = draft
        let folder = fileURL.deletingLastPathComponent().appendingPathComponent("attachments", isDirectory: true)
        for index in durable.attachments.indices {
            let attachment = durable.attachments[index]
            guard let source = URL(string: attachment.uri), source.isFileURL else { continue }
            if source.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL { continue }
            if let existing = attachmentCopies[attachment.uri], FileManager.default.fileExists(atPath: existing.path) {
                durable.attachments[index].uri = existing.absoluteString
                continue
            }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = folder.appendingPathComponent("\(UUID().uuidString)-\(source.lastPathComponent)")
                try FileManager.default.copyItem(at: source, to: target)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
                attachmentCopies[attachment.uri] = target
                durable.attachments[index].uri = target.absoluteString
            } catch {
                return nil
            }
        }
        return durable
    }

    /// Remove only old, unreferenced copies after a readable snapshot has
    /// been loaded. Never clean while protected or corrupted data is unreadable.
    private func cleanupUnreferencedAttachments() {
        guard let fileURL else { return }
        let folder = fileURL.deletingLastPathComponent().appendingPathComponent("attachments", isDirectory: true)
        let retained = Set((Array(drafts.values) + submissions.map(\.draft)).flatMap(\.attachments).compactMap { attachment in
            URL(string: attachment.uri)?.standardizedFileURL.path
        })
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        DispatchQueue.global(qos: .utility).async {
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder,
                         includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return }
            for file in files where !retained.contains(file.standardizedFileURL.path) {
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true, let modified = values.contentModificationDate,
                      modified < cutoff else { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    @discardableResult
    private func persist() -> Bool {
        guard let fileURL else { return true }
        guard !unreadableSnapshot else { persistenceFailed = true; return false }
        do {
            var folder = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try folder.setResourceValues(resourceValues)
            let snapshot = Snapshot(
                version: 1,
                drafts: order.compactMap { key in drafts[key].map { Entry(key: key, draft: $0) } },
                submissions: submissions,
                restoredPendingIDs: Array(restoredPendingIDs)
            )
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            persistenceFailed = false
            return true
        } catch {
            persistenceFailed = true
            return false
        }
    }

    private func touch(_ key: ComposerDraftKey) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evictIfNeeded() {
        while order.count > capacity {
            let oldest = order.removeFirst()
            drafts.removeValue(forKey: oldest)
            generations.removeValue(forKey: oldest)
        }
    }

    private func refreshGeneration(for key: ComposerDraftKey) {
        generations[key] = UUID()
    }
}

#if LAA_BUILD
import SwiftUI

/// The Bridge uses the existing IME-safe field and full editor; it never sends
/// through ComposerBar or the Hermes AppState.
struct LAAWorkComposer: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var dictation = ComposerDictationService()
    @State private var dictationPrefix = ""
    @State private var dictatedText: String?
    @Binding var text: String
    @Binding var revision: UInt64
    let placeholder: String
    let enabled: Bool
    var canSend = true
    let onChange: (String) -> Void
    let onSubmit: () -> Void
    var submitLabel = LAACopy.WorkTab.send
    var accessibilityPrefix = "work.composer"
    var showsTextSize = true
    var onImage: ((UIImage) -> Void)? = nil
    var headerAccessory: AnyView? = nil

    @State private var focus = false
    @State private var height = ComposerPasteTextView.minimumHeight
    @State private var editorIdentity = UUID()
    @State private var fullEditor = false
    @State private var warning: String?
    @AppStorage(ChatTypography.inputPreferenceKey) private var inputSize = ChatTypography.defaultInputSize.rawValue

    private var canSubmit: Bool { enabled && canSend && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            HStack {
                Text(verbatim: placeholder).laaTextStyle(.body).fontWeight(.semibold)
                Spacer()
                headerAccessory
                if showsTextSize {
                    Menu {
                        Picker(LAACopy.WorkTab.textSize, selection: $inputSize) {
                            ForEach(ChatTextSize.allCases, id: \.rawValue) { size in
                                Text(verbatim: size.displayName).tag(size.rawValue)
                            }
                        }
                    } label: {
                        Image(systemName: "textformat.size")
                            .frame(width: LAASpacing.minimumTouchTarget, height: LAASpacing.minimumTouchTarget)
                    }
                        .accessibilityLabel(Text(verbatim: LAACopy.WorkTab.textSize))
                        .accessibilityIdentifier("\(accessibilityPrefix).textSize")
                }
                Button { fullEditor = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .frame(width: LAASpacing.minimumTouchTarget, height: LAASpacing.minimumTouchTarget)
                }
                    .accessibilityLabel(Text(verbatim: LAACopy.WorkTab.fullEditor))
                    .accessibilityIdentifier("\(accessibilityPrefix).expand")
            }
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(verbatim: placeholder).foregroundStyle(LAAColor.secondaryText)
                        .padding(.horizontal, LAASpacing.x2).padding(.vertical, LAASpacing.x2).allowsHitTesting(false)
                }
                ComposerPasteTextView(
                    text: $text, isFocused: $focus, measuredHeight: $height, enabled: enabled,
                    onPastedImage: { image in
                        if let onImage, let decoded = UIImage(data: image.data) { onImage(decoded) } else { warning = "この入力欄では画像を添付できません。" }
                    },
                    onPastedImageError: { _ in warning = "画像を追加できません。" },
                    editorIdentity: editorIdentity,
                    inputTextSize: ChatTypography.inputSize(rawValue: inputSize),
                    programmaticRevision: revision
                )
                .frame(height: height)
                .accessibilityIdentifier("\(accessibilityPrefix).field")
            }
            .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
            .overlay(RoundedRectangle(cornerRadius: LAARadius.card).stroke(LAAColor.separator))
            if let warning { Text(verbatim: warning).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention) }
            HStack {
                dictateButton
                Spacer()
                Button(action: onSubmit) {
                    Text(verbatim: submitLabel).frame(minHeight: LAASpacing.minimumTouchTarget)
                }
                    .buttonStyle(.borderedProminent).tint(LAAColor.filledButton)
                    .foregroundStyle(LAAColor.filledButtonText).disabled(!canSubmit)
                    .accessibilityIdentifier("\(accessibilityPrefix).send")
            }
        }
        .onChange(of: text) { _, value in
            if dictation.isDictating && dictatedText != value { dictation.yieldToTyping() }
            onChange(value)
        }
        .onDisappear { dictation.cancel() }
        .sheet(isPresented: $fullEditor, onDismiss: { revision &+= 1 }) {
            ComposerFullEditor(
                text: $text, placeholder: placeholder, programmaticRevision: revision,
                fieldIdentifier: "\(accessibilityPrefix).fullEditor.field", enabled: enabled,
                onUserEdit: { _ in }, onCollapse: { fullEditor = false },
                canSubmitFromReturn: false, onSubmitFromReturn: { false },
                attachments: { EmptyView() }, dictateButton: { dictateButton },
                actionButton: {
                    Button { fullEditor = false; onSubmit() } label: {
                        Text(verbatim: submitLabel).frame(minHeight: LAASpacing.minimumTouchTarget)
                    }
                        .buttonStyle(.borderedProminent).tint(LAAColor.filledButton)
                        .foregroundStyle(LAAColor.filledButtonText).disabled(!canSubmit)
                }
            ).tint(LAAColor.link)
        }
    }
    private var dictateButton: some View {
        Button {
            if dictation.isDictating { dictation.stop(); return }
            guard let token = dictation.reserveStart() else { return }
            dictationPrefix = text
            dictatedText = nil
            dictation.onTranscript = { transcript in
                guard ComposerDictation.draftIsAsDictationLeftIt(text, prefix: dictationPrefix, lastWrite: dictatedText) else {
                    dictation.cancel(); return
                }
                let next = ComposerDictation.draft(before: dictationPrefix, dictated: transcript)
                dictatedText = next
                text = next
                revision &+= 1
            }
            dictation.onFailure = { warning = $0 }
            Task {
                do { try await dictation.start(token: token, hermesGateway: { appState.makeVoiceGateway() }) }
                catch { warning = UserFacingError.message(for: error) }
            }
        } label: {
            Image(systemName: dictation.isDictating ? "stop.circle" : "mic")
                .frame(width: LAASpacing.minimumTouchTarget, height: LAASpacing.minimumTouchTarget)
        }
        .disabled(!enabled || dictation.isStarting || appState.isVoiceInUse)
        .accessibilityLabel(Text(verbatim: dictation.isDictating ? "音声入力を停止" : "音声入力"))
    }

}

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
    @MainActor static func makeStore(fileURL: URL = LAAWorkDrafts.fileURL) -> ComposerDraftStore {
        let store = ComposerDraftStore(capacity: .max, fileURL: fileURL)
        // Retired Linear writes cannot be repeated or reconciled by this version.
        // Remove their local records before the store is exposed to the UI.
        for item in store.submissions where item.key.profile == "laa-bridge"
            && item.key.dashboardID == dashboardID && item.key.sessionID.hasSuffix(":linear-owner-operation") {
            guard let (bytes, _) = request(item),
                  let mutation = try? JSONDecoder().decode(LAALinearTaskMutation.self, from: bytes),
                  mutation.isRetired else { continue }
            _ = store.finishSubmission(item.id, restoring: false)
        }
        return store
    }
    static func key(deviceID: String, target: String) -> ComposerDraftKey {
        ComposerDraftKey(profile: "laa-bridge", sessionID: "\(deviceID):\(target)", dashboardID: dashboardID)
    }
    @MainActor static func pending(_ store: ComposerDraftStore, key: ComposerDraftKey) -> ComposerDraftStore.Submission? {
        store.submissions.first { $0.key == key }
    }
    @MainActor static func personalSubmissions(_ store: ComposerDraftStore) -> [ComposerDraftStore.Submission] {
        store.submissions.filter { $0.key.dashboardID == dashboardID && $0.key.profile == "laa-bridge" &&
            $0.key.sessionID.contains(":linear:") }
    }
    enum RejectionRestore: Equatable { case restored, cleared, draftExists, missing, saveFailed }
    @MainActor static func restoreConfirmedRejection(_ store: ComposerDraftStore, item: ComposerDraftStore.Submission,
                                                      isInbox: Bool) -> RejectionRestore {
        guard store.submissions.contains(item) else { return .missing }
        guard isInbox || !store.hasDraft(for: item.key) else { return .draftExists }
        guard store.finishSubmission(item.id, restoring: !isInbox) else { return .saveFailed }
        return isInbox ? .cleared : .restored
    }
    @MainActor static func reserve(_ store: ComposerDraftStore, key: ComposerDraftKey,
                                   text: String, body: Data, idempotency: LAABridgeIdempotencyKey,
                                   attachments: [Attachment] = [],
                                   expectedVersion: String? = nil, now: Date = Date()) -> ComposerDraftStore.Submission? {
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
    // Transferred submissions are quarantined: other editors and the queue
    // cannot query or send them against the new device's ledger.
    static func request(_ item: ComposerDraftStore.Submission) -> (Data, LAABridgeIdempotencyKey)? {
        guard item.personalOrigin == nil else { return nil }
        return originalRequest(item)
    }
    static func originalRequest(_ item: ComposerDraftStore.Submission) -> (Data, LAABridgeIdempotencyKey)? {
        guard let text = item.groupOutboundText, let rawKey = item.groupEventID,
              let key = LAABridgeIdempotencyKey(restoring: rawKey) else { return nil }
        // Legacy records remain readable for reconciliation, but cannot be
        // repeated because their original reservation time is unknown.
        let payload = record(item)?.body ?? (text.hasPrefix(recordPrefix) ? nil : text)
        guard let body = payload?.data(using: .utf8) else { return nil }
        return (body, key)
    }
    static func canRepeat(_ item: ComposerDraftStore.Submission, now: Date = Date()) -> Bool {
        guard item.personalOrigin == nil, let record = record(item) else { return false }
        let age = now.timeIntervalSince(record.reservedAt)
        return age >= 0 && age < repeatWindow
    }
    struct Origin {
        let device: String
        let viewer: String
        let target: String
    }
    static func origin(_ item: ComposerDraftStore.Submission) -> Origin? {
        let key = item.personalOrigin ?? item.key
        guard key.dashboardID == dashboardID, key.profile == "laa-bridge",
              let separator = key.sessionID.range(of: ":linear:"),
              let (body, _) = originalRequest(item),
              let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let viewer = (json["expectedViewerId"] ?? json["viewerId"]) as? String else { return nil }
        let device = String(key.sessionID[..<separator.lowerBound])
        let prefix = "\(device):linear:\(viewer):"
        guard !device.isEmpty, !viewer.isEmpty, key.sessionID.hasPrefix(prefix) else { return nil }
        return Origin(device: device, viewer: viewer, target: String(key.sessionID.dropFirst(prefix.count)))
    }
    static func destination(_ item: ComposerDraftStore.Submission, device: String, viewer: String) -> ComposerDraftKey? {
        guard let origin = origin(item), !origin.target.isEmpty else { return nil }
        return key(deviceID: device, target: "linear:\(viewer):\(origin.target)")
    }
    private static func record(_ item: ComposerDraftStore.Submission) -> RequestRecord? {
        guard let text = item.groupOutboundText, text.hasPrefix(recordPrefix),
              let bytes = String(text.dropFirst(recordPrefix.count)).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RequestRecord.self, from: bytes)
    }
}

/// Preserve the fact that a particular Project write was rejected with 412.
/// A merely unknown write must never be replaced with a new key, even after an
/// app restart. The marker contains no Project content or credential.
enum LAAWorkConflictJournal {
    static var directory: URL {
        LAAWorkDrafts.fileURL.deletingLastPathComponent().appendingPathComponent("project-conflicts", isDirectory: true)
    }
    static func contains(_ id: UUID, in folder: URL = directory) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(id.uuidString).path)
    }
    static func mark(_ id: UUID, in folder: URL = directory) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("412".utf8).write(to: folder.appendingPathComponent(id.uuidString),
                                       options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch { return false }
    }
    static func clear(_ id: UUID, in folder: URL = directory) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(id.uuidString))
    }
}
#endif

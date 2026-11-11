#if LAA_BUILD
import SwiftUI

/// The Bridge uses the existing IME-safe field and full editor; it never sends
/// through ComposerBar or the Hermes AppState.
struct LAAWorkComposer: View {
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
    /// The follow-up field under a conversation: one line, no heading and no
    /// send row, because the conversation's own row carries them.
    var compact = false
    /// Bumped to put the cursor in the field (after a quote is inserted).
    var focusRequest = 0

    @State private var focus = false
    /// The height the owner dragged the compact field to; nil follows the text.
    @State private var manualHeight: CGFloat?
    @State private var dragBase: CGFloat?
    @State private var height = ComposerPasteTextView.minimumHeight
    @State private var editorIdentity = UUID()
    @State private var fullEditor = false
    @State private var warning: String?
    @AppStorage(ChatTypography.inputPreferenceKey) private var inputSize = ChatTypography.defaultInputSize.rawValue

    /// How tall the owner may drag the compact field: roomy for a long
    /// instruction, short enough that the conversation keeps a few turns.
    static let manualHeightLimit: CGFloat = 360

    private var fieldHeight: CGFloat {
        guard compact, let manualHeight else { return height }
        return min(Self.manualHeightLimit, max(height, manualHeight))
    }

    private var canSubmit: Bool { enabled && canSend && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            if !compact { header }
            field
            if let warning { Text(verbatim: warning).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention) }
            if !compact { sendRow }
        }
        .onChange(of: text) { _, value in onChange(value) }
        .sheet(isPresented: $fullEditor, onDismiss: { revision &+= 1 }) {
            ComposerFullEditor(
                text: $text, placeholder: placeholder, programmaticRevision: revision,
                fieldIdentifier: "\(accessibilityPrefix).fullEditor.field", enabled: enabled,
                onUserEdit: { _ in }, onCollapse: { fullEditor = false },
                canSubmitFromReturn: false, onSubmitFromReturn: { false },
                attachments: { EmptyView() }, dictateButton: { EmptyView() },
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

    private var header: some View {
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
            expandButton
        }
    }

    private var field: some View {
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
            .frame(height: fieldHeight)
            // The compact field carries the expand control in its top-right
            // corner, so the text stops short of it instead of running under it.
            .padding(.trailing, compact ? LAASpacing.minimumTouchTarget : 0)
            .accessibilityIdentifier("\(accessibilityPrefix).field")
        }
        .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
        .overlay(RoundedRectangle(cornerRadius: LAARadius.card).stroke(LAAColor.separator))
        // The follow-up field always offers both ways to get more room
        // (owner, 2026-11-11: it could not be enlarged): drag its top edge to
        // make it taller in place, or open the full editor.
        .overlay(alignment: .topTrailing) {
            if compact { expandButton }
        }
        .overlay(alignment: .top) {
            if compact { resizeHandle }
        }
        .onChange(of: focusRequest) { _, _ in focus = true }
    }

    /// A short grabber on the field's top edge. Up makes the field taller, down
    /// shorter; a double tap returns it to following the text.
    private var resizeHandle: some View {
        Capsule()
            .fill(LAAColor.secondaryText.opacity(manualHeight == nil ? 0.35 : 0.6))
            .frame(width: 36, height: 4)
            .frame(width: 88, height: 22)
            .contentShape(Rectangle())
            .offset(y: -12)
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    let base = dragBase ?? fieldHeight
                    if dragBase == nil { dragBase = base }
                    manualHeight = min(Self.manualHeightLimit,
                                       max(ComposerPasteTextView.minimumHeight, base - value.translation.height))
                }
                .onEnded { _ in
                    dragBase = nil
                    if let manualHeight, manualHeight <= height + 1 { self.manualHeight = nil }
                })
            .onTapGesture(count: 2) { withAnimation(.snappy) { manualHeight = nil } }
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: "入力欄の高さ"))
            .accessibilityValue(Text(verbatim: manualHeight == nil ? "自動" : "\(Int(fieldHeight))ポイント"))
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = 60
                switch direction {
                case .increment: manualHeight = min(Self.manualHeightLimit, fieldHeight + step)
                case .decrement:
                    let next = fieldHeight - step
                    manualHeight = next <= height ? nil : next
                @unknown default: break
                }
            }
            .accessibilityIdentifier("\(accessibilityPrefix).resize")
            .help(Text(verbatim: "ドラッグで入力欄の高さを変更"))
    }

    private var sendRow: some View {
        HStack {
            Spacer()
            Button(action: onSubmit) {
                Text(verbatim: submitLabel).frame(minHeight: LAASpacing.minimumTouchTarget)
            }
                .buttonStyle(.borderedProminent).tint(LAAColor.filledButton)
                .foregroundStyle(LAAColor.filledButtonText).disabled(!canSubmit)
                .accessibilityIdentifier("\(accessibilityPrefix).send")
        }
    }

    /// The full editor's one control: a small glyph with the minimum touch
    /// target around it, whichever row it is drawn in.
    private var expandButton: some View {
        Button { fullEditor = true } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LAAColor.secondaryText)
                .frame(width: LAASpacing.minimumTouchTarget, height: LAASpacing.minimumTouchTarget)
                .contentShape(Rectangle())
        }
            .accessibilityLabel(Text(verbatim: LAACopy.WorkTab.fullEditor))
            .accessibilityIdentifier("\(accessibilityPrefix).expand")
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
        #if DEBUG
        // The UI tests need a launch with no remembered conversation and no
        // draft; the store is otherwise carried across launches on purpose.
        if ProcessInfo.processInfo.arguments.contains("-LAA_UI_TEST_CLEAR_WORK_STORE") {
            try? FileManager.default.removeItem(at: fileURL)
            // The task list's filter is device state, not part of this run.
            UserDefaults.standard.removeObject(forKey: LAALinearTaskFilter.storageKey)
        }
        #endif
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

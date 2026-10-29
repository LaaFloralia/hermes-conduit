#if LAA_BUILD
import SwiftUI
#if DEBUG
import UIKit
#endif

struct LAABrainCreateView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.dismiss) private var dismiss
    @Binding var pending: LAABrainPending?
    let open: (LAABrainCreated) -> Void
    @State private var name: String
    @State private var content: String
    @State private var scopeAllowed: Bool?
    @State private var scopeError: LAABridgeError?
    @State private var saving = false
    @State private var failure: String?
    @State private var created: LAABrainCreated?
    @State private var pendingLoaded = false
    #if DEBUG
    @State private var fixtureDidMark = false
    #endif
    private let pendingStore = LAABrainPendingStore()

    init(pending: Binding<LAABrainPending?>, open: @escaping (LAABrainCreated) -> Void) {
        self._pending = pending
        self.open = open
        let existing = pending.wrappedValue?.request
        _name = State(initialValue: existing.map { String($0.path.dropFirst("Inbox/".count).dropLast(3)) } ?? "")
        _content = State(initialValue: existing?.content ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                if let created {
                    Section {
                        Label { Text(verbatim: "新規メモを保存しました") } icon: { Image(systemName: "checkmark.circle") }
                        Text(verbatim: created.path).textSelection(.enabled).accessibilityIdentifier("laa.brain.createdPath")
                        if created.suffixApplied { Text(verbatim: "同名のメモがあるため、別の名前で保存しました。") }
                        Button { open(created) } label: { Text(verbatim: "メモを開く") }
                    }
                    #if DEBUG
                    if LAABrainData.isMarkedTextFixture {
                        Text(verbatim: LAABrainData.fixtureMarkedAtSave ? "marked" : "unmarked")
                            .accessibilityIdentifier("laa.brain.fixture.markedAtSave")
                        Text(verbatim: LAABrainData.fixtureSubmittedContent ?? "missing")
                            .accessibilityIdentifier("laa.brain.fixture.submittedContent")
                    }
                    #endif
                } else {
                    Section {
                        TextField(text: $name) { Text(verbatim: "メモの名前") }
                            .accessibilityIdentifier("laa.brain.newName")
                            .disabled(pending != nil || saving)
                        TextEditor(text: $content).frame(minHeight: 180)
                            .accessibilityIdentifier("laa.brain.newContent")
                            .disabled(pending != nil || saving)
                    } header: { Text(verbatim: "新規メモ") }
                    footer: { Text(verbatim: "InboxにMarkdownとして新規保存します。同名のメモは上書きしません。本文は48 KBまでです。") }
                    if scopeAllowed == false {
                        Section { Text(verbatim: "この端末にはメモを新規作成する権限（brain:create）がありません。Macで権限を付けた接続コードを発行し、再接続してください。") }
                    } else if let scopeError, pending == nil {
                        Section {
                            Text(verbatim: scopeError.japaneseText).foregroundStyle(LAAColors.plum)
                            Button { Task { await checkScope() } } label: { Text(verbatim: "権限を再確認") }
                        }
                    }
                    if let failure {
                        Section { Text(verbatim: failure).foregroundStyle(LAAColors.plum) }
                    }
                    if pending != nil {
                        Section {
                            Text(verbatim: pending?.deviceID == LAABrainData.deviceID(bridge)
                                 ? "保存結果が不明です。同じ操作を再確認します。別のメモとして作り直す前にInboxを確認してください。"
                                 : "接続が変わったため、この操作は再送できません。別のメモとして作り直す前にInboxを確認してください。")
                            Button { _ = clearPending() } label: { Text(verbatim: "Inboxを確認して新しく作る") }
                        }
                    }
                    Section {
                        Button {
                            #if DEBUG
                            if LAABrainData.isMarkedTextFixture {
                                LAABrainData.fixtureMarkedAtSave = LAABrainMarkedTextFixture.hasMarkedText()
                            }
                            #endif
                            Task { await save() }
                        } label: {
                            if saving { ProgressView() }
                            else { Text(verbatim: pending == nil ? "新規保存" : "同じ操作を再確認") }
                        }
                        .disabled(!pendingLoaded || saving || (pending != nil && pending?.deviceID != LAABrainData.deviceID(bridge)) ||
                                  (pending == nil && (scopeAllowed != true || LAABrainCreateBody.make(name: name, content: content) == nil)))
                        .accessibilityIdentifier("laa.brain.save")
                    }
                    #if DEBUG
                    if LAABrainData.isMarkedTextFixture {
                        Text(verbatim: fixtureDidMark ? "marked" : "unmarked")
                            .accessibilityIdentifier("laa.brain.fixture.didMark")
                    }
                    #endif
                }
            }
            .navigationTitle(Text(verbatim: "新規メモ"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text(verbatim: "閉じる") }.disabled(saving)
                }
                #if DEBUG
                ToolbarItemGroup(placement: .primaryAction) {
                    if LAABrainData.isTestFixture {
                        Button("Dismiss keyboard") {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }.accessibilityIdentifier("laa.brain.fixture.dismissKeyboard")
                    }
                    if LAABrainData.isMarkedTextFixture {
                        Button("Compose") { fixtureDidMark = LAABrainMarkedTextFixture.compose() }
                            .accessibilityIdentifier("laa.brain.fixture.compose")
                    }
                }
                #endif
            }
            .interactiveDismissDisabled(saving)
            .tint(LAAColors.teal)
            .task {
                do {
                    if let saved = try pendingStore.read() {
                        pending = saved
                        name = String(saved.request.path.dropFirst("Inbox/".count).dropLast(3))
                        content = saved.request.content
                    }
                    pendingLoaded = true
                } catch { failure = LAABridgeError.keychain.japaneseText }
                await checkScope()
            }
        }
    }

    @MainActor private func checkScope() async {
        do {
            let device: LAABrainDevice = try await LAABrainData.read("/v1/me", bridge: bridge)
            scopeAllowed = device.scopes.contains("brain:create")
            scopeError = nil
        } catch is CancellationError { return }
        catch let error as LAABridgeError { scopeAllowed = nil; scopeError = error }
        catch { scopeAllowed = nil; scopeError = .invalidResponse }
    }

    @MainActor private func save() async {
        let reconciling = pending != nil
        saving = true; failure = nil
        defer { saving = false }
        do {
            let attempt: LAABrainPending
            if let pending {
                guard pending.deviceID == LAABrainData.deviceID(bridge) else { return }
                attempt = pending
            }
            else {
                guard let request = LAABrainCreateBody.make(name: name, content: content), let deviceID = LAABrainData.deviceID(bridge) else { return }
                attempt = LAABrainPending(request: request, bytes: try JSONEncoder().encode(request), keyValue: LAABridgeIdempotencyKey().value, deviceID: deviceID)
                try pendingStore.save(attempt)
                pending = attempt
            }
            guard let key = LAABridgeIdempotencyKey(restoring: attempt.keyValue) else { throw LAABridgeError.keychain }
            let result: LAABrainCreated = try await LAABrainData.write(body: attempt.bytes, key: key, bridge: bridge)
            try pendingStore.clear()
            pending = nil; created = result
        } catch let error as LAABridgeHTTPError {
            if reconciling && [400, 403, 413].contains(error.status) {
                failure = "以前の保存結果を確定できません。Inboxを確認してから次の操作を行ってください。"
            } else if error.status == 403 {
                if clearPending() {
                    failure = "この端末に新規作成の権限がないか、Inboxへの作成が許可されていません。接続権限とMac側の設定を確認してください。"
                }
            } else if error.status == 400 || error.status == 413 {
                if clearPending() { failure = "名前または本文を保存できません。名前と本文の長さを確認してください。" }
            } else if let code = error.code,
                      ["request_id_conflict", "idempotency_outcome_unknown", "brain_create_unverified", "brain_journal_incomplete"].contains(code) {
                failure = "保存結果を確定できません。Inboxを確認してから次の操作を行ってください。"
            } else {
                failure = error.legacyError.japaneseText
            }
        } catch let error as LAABridgeError {
            if reconciling {
                failure = error.japaneseText
            } else if error == .forbidden {
                if clearPending() { failure = "この端末に新規作成の権限がないか、Inboxへの作成が許可されていません。接続権限とMac側の設定を確認してください。" }
            } else if case .other(let status, _) = error, status == 400 || status == 413 {
                if clearPending() { failure = "名前または本文を保存できません。名前と本文の長さを確認してください。" }
            } else {
                failure = error.japaneseText
            }
        } catch is CancellationError { return }
        catch { failure = LAABridgeError.invalidResponse.japaneseText }
    }

    private func clearPending() -> Bool {
        do { try pendingStore.clear(); pending = nil; return true }
        catch { failure = LAABridgeError.keychain.japaneseText; return false }
    }
}

#if DEBUG
/// Exercises the same UITextInput marked range that an IME uses, without a
/// particular simulator keyboard layout or a live vault.
@MainActor private enum LAABrainMarkedTextFixture {
    private static func activeTextView(in view: UIView) -> UITextView? {
        if view.isFirstResponder { return view as? UITextView }
        for child in view.subviews {
            if let found = activeTextView(in: child) { return found }
        }
        return nil
    }

    private static func activeTextView() -> UITextView? {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                if let found = activeTextView(in: window) { return found }
            }
        }
        return nil
    }

    static func compose() -> Bool {
        guard let view = activeTextView() else { return false }
        view.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
        view.delegate?.textViewDidChange?(view)
        return view.markedTextRange != nil
    }

    static func hasMarkedText() -> Bool { activeTextView()?.markedTextRange != nil }
}
#endif
#endif

#if LAA_BUILD
import SwiftUI

struct LAABrainLocalCreateTarget: Identifiable {
    let id = UUID()
    let parent: String
    let kind: LAABrainFolderStore.Kind
}

struct LAABrainLocalCreateView: View {
    @Environment(\.dismiss) private var dismiss
    let root: URL
    let target: LAABrainLocalCreateTarget
    let created: (String, LAABrainFolderStore.Kind) -> Void
    @State private var name = ""
    @State private var bodyText = ""
    @State private var error: String?
    @State private var busy = false
    @State private var confirmDiscard = false
    private enum Field { case name, body }
    @FocusState private var focused: Field?

    private var isNote: Bool { if case .note = target.kind { return true }; return false }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(isNote ? "ノート名" : "フォルダ名", text: $name)
                        .focused($focused, equals: .name)
                        .accessibilityIdentifier("laa.brain.localCreate.name")
                        .submitLabel(isNote ? .next : .done)
                        .onSubmit {
                            if isNote { focused = .body } else { Task { await create() } }
                        }
                } footer: {
                    Text(verbatim: target.parent.isEmpty ? "Brainの直下に作成します。" : "\(target.parent) に作成します。")
                }
                if isNote {
                    Section("本文（Markdown）") {
                        TextEditor(text: $bodyText).frame(minHeight: 180)
                            .focused($focused, equals: .body)
                            .accessibilityIdentifier("laa.brain.localCreate.body")
                    }
                }
                if let error { Text(verbatim: error).foregroundStyle(LAAColor.attention) }
            }
            .navigationTitle(isNote ? "新規ノート" : "新規フォルダ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        if bodyText.isEmpty { dismiss() } else { confirmDiscard = true }
                    }.disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("作成") { Task { await create() } }
                        .disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("laa.brain.localCreate.confirm")
                }
            }
            .interactiveDismissDisabled(busy || !bodyText.isEmpty)
            .alert("下書きを破棄しますか？", isPresented: $confirmDiscard) {
                Button("編集を続ける", role: .cancel) { }
                Button("破棄", role: .destructive) { dismiss() }
            }
            .task { focused = .name }
        }
    }

    @MainActor private func create() async {
        guard !busy else { return }
        busy = true; error = nil
        let input = name, parent = target.parent, kind = target.kind, selectedRoot = root, body = Data(bodyText.utf8)
        do {
            let path = try await Task.detached(priority: .userInitiated) {
                try LAABrainFolderStore.create(root: selectedRoot, parent: parent, name: input, kind: kind, body: body)
            }.value
            busy = false
            dismiss()
            created(path, kind)
        } catch let failure as LAABrainFolderStore.Failure {
            switch failure {
            case .invalidName: error = "使えない名前です。記号や長さを確認してください。"
            case .invalidText: error = "本文をテキストとして保存できません。"
            case .tooLarge: error = "本文が大きすぎます。32 MB以内にしてください。"
            case .exists: error = "同じ名前がすでにあります。別の名前にしてください。"
            case .uncertain: error = "作成を確認できません。一覧を確認してからやり直してください。"
            case .invalidFolder, .coordination: error = "このフォルダに作成できません。保存先を確認してください。"
            case .unavailable: error = "作成できません。本文をコピーするか、保存先を確認してください。"
            }
            busy = false
        } catch {
            self.error = "作成を確認できません。一覧を確認してからやり直してください。"
            busy = false
        }
    }
}
#endif

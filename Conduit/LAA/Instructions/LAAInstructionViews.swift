#if LAA_BUILD && LAA_INSTRUCTION_EDITOR
import SwiftUI

private struct LAAInstructionDocument: Decodable {
    let id: String
    let text: String
    let etag: String
}

struct LAAInstructionsView: View {
    @StateObject private var bridge = LAABridgeSession()
    var body: some View {
        List {
            NavigationLink { LAAInstructionEditor(id: "agents", path: "~/hq/AGENTS.md") } label: { Text(verbatim: "AGENTS.md") }
                .accessibilityIdentifier("laa.instructions.agents")
            NavigationLink { LAAInstructionEditor(id: "claude", path: "~/.claude/CLAUDE.md") } label: { Text(verbatim: "CLAUDE.md") }
                .accessibilityIdentifier("laa.instructions.claude")
        }
        .environmentObject(bridge)
        .navigationTitle(Text(verbatim: "指示ファイル"))
    }
}

private struct LAAInstructionEditor: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.dismiss) private var dismiss
    let id: String
    let path: String
    @State private var document: LAAInstructionDocument?
    @State private var text = ""
    @State private var editing = false
    @State private var busy = false
    @State private var message: String?
    @State private var confirmDiscard = false
    @State private var confirmReload = false

    private var dirty: Bool { document.map { text != $0.text } ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let message {
                Text(verbatim: message).font(.callout).foregroundStyle(LAAColor.attention)
            }
            if document == nil {
                if busy { ProgressView() }
                else { Button { Task { await load() } } label: { Text(verbatim: "再読み込み") } }
            } else if editing {
                TextEditor(text: $text)
                    .disabled(busy)
                    .font(.body.monospaced())
                    .accessibilityIdentifier("laa.instructions.editor")
            } else {
                ScrollView {
                    MarkdownText(source: text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }.accessibilityIdentifier("laa.instructions.preview")
            }
            Spacer(minLength: 0)
        }
        .padding()
        .navigationTitle(Text(verbatim: id == "agents" ? "AGENTS.md" : "CLAUDE.md"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { if dirty { confirmDiscard = true } else { dismiss() } } label: { Text(verbatim: "戻る") }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if document != nil {
                    Button { editing.toggle() } label: { Text(verbatim: editing ? "プレビュー" : "編集") }.disabled(busy)
                    if editing {
                        Button { Task { await save() } } label: { Text(verbatim: "保存") }.disabled(!dirty || busy)
                            .accessibilityIdentifier("laa.instructions.save")
                    }
                    Button { if dirty { confirmReload = true } else { Task { await load() } } } label: {
                        Image(systemName: "arrow.clockwise")
                    }.disabled(busy).accessibilityLabel(Text(verbatim: "再読み込み"))
                }
            }
        }
        .confirmationDialog(Text(verbatim: "未保存の変更を破棄しますか？"), isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button(role: .destructive) { dismiss() } label: { Text(verbatim: "破棄して戻る") }
        }
        .confirmationDialog(Text(verbatim: "未保存の変更を破棄して読み直しますか？"), isPresented: $confirmReload, titleVisibility: .visible) {
            Button(role: .destructive) { Task { await load() } } label: { Text(verbatim: "破棄して再読み込み") }
        }
        .task { await load() }
    }

    @MainActor private func load() async {
        busy = true; message = nil
        defer { busy = false }
        do {
            let result: LAAInstructionDocument = try await bridge.read("/v1/instructions/\(id)")
            document = result; text = result.text
        } catch { message = "読み込めません。Macとの接続を確認してください。" }
    }
    @MainActor private func save() async {
        guard let document else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            let body = try JSONEncoder().encode(["text": text])
            let response: LAABridgeResponse<LAAInstructionDocument> = try await bridge.request(
                method: "PUT", path: "/v1/instructions/\(id)", jsonBody: body, ifMatch: document.etag)
            self.document = response.data; text = response.data.text; editing = false
            message = "保存しました。変更前のバックアップを作成しました。"
        } catch let error as LAABridgeHTTPError where error.status == 412 {
            message = "他の場所で変更されました。入力は保持しています。内容を控えて再読み込みしてください。"
        } catch {
            message = "保存結果を確認できません。入力を控えて再読み込みし、保存状態を確認してください。"
        }
    }
}
#endif

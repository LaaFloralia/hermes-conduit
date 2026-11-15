#if LAA_BUILD
import SwiftUI
import UIKit

/// Shared by the iPhone navigation title and Mac pane heading: the session
/// name and the instruction it was created with, each selectable and copyable.
struct LAAWorkInitialInstruction: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.dismiss) private var dismiss
    let sessionID: String
    let sessionName: String
    struct Instruction: Decodable {
        let text: String
        let createdAt: String
        let source: String
    }
    struct Response: Decodable { let instruction: Instruction? }
    @State private var response: Response?
    @State private var failed = false
    @State private var copied: Copied? = nil
    private enum Copied { case name, instruction }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LAASpacing.x4) {
                    Text(verbatim: "名前").laaTextStyle(.note).foregroundStyle(LAAColor.secondaryText)
                    Text(verbatim: sessionName)
                        .laaTextStyle(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("work.initialInstruction.name")
                    copyButton(.name, value: sessionName, label: "名前をコピー")
                        .accessibilityIdentifier("work.initialInstruction.copyName")
                    Divider()
                    Text(verbatim: "最初の指示").laaTextStyle(.note).foregroundStyle(LAAColor.secondaryText)
                    if let instruction = response?.instruction {
                        Text(verbatim: "作成日時: " + createdAt(instruction.createdAt)).laaTextStyle(.note)
                        Text(verbatim: "作成経路: " + sourceName(instruction.source)).laaTextStyle(.note)
                        Text(verbatim: instruction.text)
                            .laaTextStyle(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("work.initialInstruction.text")
                        copyButton(.instruction, value: instruction.text, label: "最初の指示をコピー")
                            .accessibilityIdentifier("work.initialInstruction.copy")
                    } else if response != nil {
                        Text(verbatim: "記録なし").laaTextStyle(.body)
                    } else if failed {
                        Text(verbatim: "最初の指示を取得できませんでした。").laaTextStyle(.body)
                        Button("Retry") { Task { await load() } }
                    } else {
                        ProgressView()
                    }
                }
                .padding(LAASpacing.x6)
            }
            .background(LAAColor.background)
            .foregroundStyle(LAAColor.text)
            .navigationTitle(Text(verbatim: "名前と最初の指示"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("work.initialInstruction.done") } }
        }
        .tint(LAAColor.link)
        .task(id: sessionID) { await load() }
    }

    private func copyButton(_ kind: Copied, value: String, label: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            copied = kind
        } label: {
            Label(copied == kind ? String(localized: "Copied") : String(localized: "Copy"), systemImage: "doc.on.doc")
        }
        .frame(minHeight: LAASpacing.minimumTouchTarget)
        .accessibilityLabel(Text(verbatim: copied == kind ? "コピーしました" : label))
    }

    private func createdAt(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        return date?.formatted(date: .abbreviated, time: .shortened) ?? value
    }

    private func sourceName(_ value: String) -> String {
        switch value {
        case "Bridge": "LAAアプリ"
        case "Work / recovered history": "Work（履歴から取得）"
        default: value
        }
    }

    @MainActor private func load() async {
        failed = false
        do { response = try await bridge.read("/v1/sessions/\(sessionID)/initial-instruction") }
        catch { failed = true }
    }
}
#endif

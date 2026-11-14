#if LAA_BUILD
import SwiftUI
import UIKit

/// Shared by the iPhone navigation title and Mac pane heading.
struct LAAWorkInitialInstruction: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.dismiss) private var dismiss
    let sessionID: String
    struct Instruction: Decodable {
        let text: String
        let createdAt: String
        let source: String
    }
    struct Response: Decodable { let instruction: Instruction? }
    @State private var response: Response?
    @State private var failed = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LAASpacing.x4) {
                    if let instruction = response?.instruction {
                        Text(verbatim: "作成日時: " + createdAt(instruction.createdAt)).laaTextStyle(.note)
                        Text(verbatim: "作成経路: " + sourceName(instruction.source)).laaTextStyle(.note)
                        Divider()
                        Text(verbatim: instruction.text)
                            .laaTextStyle(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("work.initialInstruction.text")
                        Button {
                            UIPasteboard.general.string = instruction.text
                            copied = true
                        } label: {
                            Label(copied ? String(localized: "Copied") : String(localized: "Copy"), systemImage: "doc.on.doc")
                        }
                        .frame(minHeight: LAASpacing.minimumTouchTarget)
                        .accessibilityLabel(copied ? "コピーしました" : "最初の指示をコピー")
                        .accessibilityIdentifier("work.initialInstruction.copy")
                    } else if response != nil {
                        Text("記録なし").laaTextStyle(.body)
                    } else if failed {
                        Text("最初の指示を取得できませんでした。").laaTextStyle(.body)
                        Button("Retry") { Task { await load() } }
                    } else {
                        ProgressView()
                    }
                }
                .padding(LAASpacing.x6)
            }
            .background(LAAColor.background)
            .foregroundStyle(LAAColor.text)
            .navigationTitle(Text(verbatim: "最初の指示"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("work.initialInstruction.done") } }
        }
        .tint(LAAColor.link)
        .task(id: sessionID) { await load() }
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

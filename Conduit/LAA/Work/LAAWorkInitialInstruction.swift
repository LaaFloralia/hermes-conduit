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
    /// The Session and the projects it can move to; nil hides the project row.
    var session: LAAWorkSession? = nil
    var projects: [LAAWorkProject] = []
    var onMoved: (LAAWorkSession) -> Void = { _ in }
    @State private var moved: LAAWorkSession?
    @State private var moveFailure: String?
    @State private var moving = false
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

    /// The project the Session is in, and 「プロジェクトを変更」.
    @ViewBuilder private func projectRow(_ current: LAAWorkSession) -> some View {
        Text(verbatim: "プロジェクト").laaTextStyle(.note).foregroundStyle(LAAColor.secondaryText)
        HStack(spacing: LAASpacing.x2) {
            Text(verbatim: projects.first { $0.id == current.projectId }?.name ?? "未確認")
                .laaTextStyle(.body)
                .accessibilityIdentifier("work.initialInstruction.project")
            Spacer(minLength: 0)
            if moving { ProgressView() }
            LAAWorkProjectMoveMenu(session: current, projects: projects) { project in
                Task { await move(current, to: project) }
            }
            .disabled(moving)
        }
        if let moveFailure {
            Text(verbatim: moveFailure).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
        }
    }

    @MainActor private func move(_ current: LAAWorkSession, to project: LAAWorkProject) async {
        moving = true; defer { moving = false }
        do {
            let updated = try await LAAWorkSessionProjects.move(current, to: project, bridge: bridge)
            moved = updated; moveFailure = nil
            onMoved(updated)
        } catch {
            moveFailure = LAAWorkSessionProjects.failure(error)
        }
    }

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
                    if let current = moved ?? session {
                        Divider()
                        projectRow(current)
                    }
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

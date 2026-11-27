#if LAA_BUILD
import SwiftUI

/// References in task text are hints, never a canonical task/session binding.
enum LAATaskSessionReferences {
    static func matches(_ session: LAAWorkSession, text: String) -> Bool {
        for id in [session.id, session.delegateSessionId].compactMap({ $0 }) where !id.isEmpty {
            let pattern = "(?<![A-Za-z0-9_-])" + NSRegularExpression.escapedPattern(for: id) + "(?![A-Za-z0-9_-])"
            if text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        }
        return session.name.hasPrefix("子｜") && text.contains(session.name)
    }
}

struct LAATaskSessionsSection: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let task: LAAPersonalTask
    @State private var sessions: [LAAWorkSession] = []
    @State private var loaded = false
    @State private var failure = false

    /// Only sessions the task's text names, or a failure to read them; with
    /// none the section is left out rather than saying so.
    var body: some View {
        Group {
            if sessions.isEmpty && !failure {
                Color.clear.frame(height: 0)
            } else {
                VStack(alignment: .leading, spacing: LAASpacing.x2) {
                    Text(verbatim: "Sessions").laaTextStyle(.section).foregroundStyle(LAAColor.secondaryText)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(sessions) { session in
                        if let url = URL(string: "laa://work/sessions/" + (session.delegateSessionId ?? session.id)) {
                            Link(destination: url) {
                                VStack(alignment: .leading, spacing: LAASpacing.x1) {
                                    Text(verbatim: session.name)
                                    Text(verbatim: "Inferred · " + LAAWorkPresentation.phase(session.phase))
                                        .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                                }
                            }
                        }
                    }
                    if sessions.isEmpty {
                        Text(verbatim: "参照先の会話が応答しません。Macとの接続を確認してください。")
                            .foregroundStyle(LAAColor.secondaryText)
                    } else {
                        Text(verbatim: "説明・コメントの会話名またはIDから推定しています。")
                            .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    }
                }.workRuled()
            }
        }
        .task(id: task.updatedAt) { await load() }
    }

    @MainActor private func load() async {
        do {
            let safe = task.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            async let comments: [LAAPersonalComment] = LAAWorkPaging.all(bridge, "/v1/personal-tasks/\(safe)/comments")
            async let available: [LAAWorkSession] = LAAWorkPaging.all(bridge, "/v1/sessions")
            let text = try await ([task.description ?? ""] + comments.map(\.body)).joined(separator: "\n")
            sessions = try await available.filter { LAATaskSessionReferences.matches($0, text: text) }
            loaded = true; failure = false
        } catch is CancellationError {
        } catch { failure = true; loaded = true }
    }
}
#endif

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

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            Text(verbatim: "作業エージェント").fontWeight(.semibold)
            ForEach(sessions) { session in
                if let url = URL(string: "laa://work/sessions/" + (session.delegateSessionId ?? session.id)) {
                    Link(destination: url) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: session.name)
                            Text(verbatim: "推定 · " + LAAWorkPresentation.phase(session.phase))
                                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        }
                    }
                }
            }
            if sessions.isEmpty {
                Text(verbatim: failure ? "会話との紐付けを取得できませんでした。" : loaded ? "参照された会話は見つかりません。" : "会話を確認中…")
                    .foregroundStyle(LAAColor.secondaryText)
            }
            if !sessions.isEmpty { Text(verbatim: "説明・コメントの会話名またはIDから推定しています。")
                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText) }
        }.workCard()
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

#if LAA_BUILD
import SwiftUI

/// Adoption is a recorded verdict. Keep its ID/body across response loss and relaunch.
struct LAAStudioAdoptButton: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let project: LAAStudioProject
    let reviews: [LAAStudioReview]
    @State private var sending = false
    @State private var adopted = false
    @State private var error: String?
    private var itemKey: String { "adopt-" + project.id + "-" + String(project.revision) }
    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x1) {
            Button(adopted ? "採用済み" : (sending ? "保存中" : "採用")) { Task { await adopt() } }
                .laaGlassButton().disabled(sending || adopted)
                .accessibilityIdentifier("laa.studio.adopt")
            if let error { Text(verbatim: error).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention) }
        }.onChange(of: project.revision) { _, _ in adopted = false }
        .onChange(of: reviews, initial: true) { _, value in
            adopted = value.first { $0.target == .project && $0.revision == project.revision }?.verdict == "adopt"
        }
    }
    @MainActor private func adopt() async {
        guard !sending else { return }
        sending = true; error = nil; defer { sending = false }
        let scope = LAAStudioCache.scope(bridge)
        do {
            var draft: LAAStudioReviewDraft
            if LAAStudioCache.exists(scope: scope, item: itemKey),
               LAAStudioCache.load(LAAStudioReviewDraft.self, scope: scope, item: itemKey) == nil {
                throw LAABridgeError.invalidResponse
            }
            if let saved = LAAStudioCache.load(LAAStudioReviewDraft.self, scope: scope, item: itemKey), saved.pending {
                guard saved.intact, saved.review.projectId == project.id,
                      saved.review.revision == project.revision, saved.review.verdict == "adopt" else { throw LAABridgeError.invalidResponse }
                let detail = try await LAAStudioData.project(project.id, bridge: bridge)
                if let found = detail.reviews.first(where: { $0.id == saved.review.id }) {
                    guard found.sameSubmission(as: saved.review) else { throw LAABridgeError.invalidResponse }
                    var resolved = saved; resolved.pending = false
                    LAAStudioCache.save(resolved, scope: scope, item: itemKey)
                    adopted = true
                    NotificationCenter.default.post(name: .laaStudioChanged, object: nil)
                    return
                }
                draft = saved
            } else {
                let id = try await LAAStudioData.requestID(bridge)
                draft = try LAAStudioReviewDraft(review: .init(id: id, projectId: project.id,
                    revision: project.revision, target: .project, verdict: "adopt", comment: nil))
            }
            draft.pending = true
            guard LAAStudioCache.save(draft, scope: scope, item: itemKey), let key = draft.submissionKey else {
                error = "保存できません。再試行してください"; return
            }
            _ = try await LAAStudioData.review(draft.review, body: draft.body, key: key, bridge: bridge)
            draft.pending = false
            LAAStudioCache.save(draft, scope: scope, item: itemKey)
            adopted = true
            NotificationCenter.default.post(name: .laaStudioChanged, object: nil)
        } catch { self.error = "採用を確認できません。もう一度押して確認してください" }
    }
}
#endif

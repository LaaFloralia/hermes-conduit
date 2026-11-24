#if LAA_BUILD
import Foundation

extension ChatContext {
    init(_ breakdown: ContextBreakdown) {
        let categories = breakdown.categories.map { Category(id: $0.id, label: $0.label, tokens: $0.tokens) }
        let fixedIDs: Set<String> = ["system_prompt", "tool_definitions", "rules", "skills", "mcp", "subagent_definitions", "memory"]
        let fixed = categories.filter { fixedIDs.contains($0.id) }
        self.init(used: breakdown.resolvedUsed, window: breakdown.contextMax > 0 ? breakdown.contextMax : nil,
                  fixed: fixed.isEmpty ? nil : fixed.reduce(0) { $0 + $1.tokens },
                  recent: categories.first { $0.id == "recent" || $0.id == "protected_recent" }?.tokens,
                  categories: categories)
    }
}

/// Translate structured gateway results; a zero token delta alone isn't
/// proof of a no-op (summary failures also leave the history unchanged).
struct HermesChatCompaction {
    static func resolve(_ receipt: SessionCompressResult, before: ChatContext?, after: ChatContext?) -> ContextCompactResult {
        if receipt.lockHeld || receipt.isPending { return .init(status: .inProgress) }
        let fields = receipt.chatNumbers
        let noop = ["nothing_to_compact", "no_compressible_window", "empty_post_handoff_window", "insufficient_messages"]
        let hasNoWindow = noop.contains(fields.failureClass ?? "")
            || (!receipt.isAborted && fields.noop && !fields.refusedWouldGrow)
        let status: ContextCompactResult.Status = hasNoWindow ? .nothingToCompact
            : receipt.isAborted || fields.refusedWouldGrow || receipt.status != .compressed ? .failed : .compacted
        let current = after ?? before
        // In a confirmed no-window result the installed breakdown's
        // conversation bucket is the retained history; it does not split
        // existing summaries or the protected tail out of that estimate.
        let retained = hasNoWindow ? current?.categories.first { $0.id == "conversation" }?.tokens : nil
        return .init(status: status,
                     beforeTokens: fields.before ?? before?.used,
                     afterTokens: fields.after ?? after?.used,
                     fixedTokens: fields.fixed ?? current?.fixed,
                     recentTokens: fields.recent ?? current?.recent ?? retained,
                     failure: status == .failed ? fields.failure : nil)
    }
}
#endif

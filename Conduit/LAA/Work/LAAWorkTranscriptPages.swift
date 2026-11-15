#if LAA_BUILD
import Foundation

/// Bounded history for a Work session, the same paging Chat uses: the page
/// opens on the newest messages, and "Load earlier messages" at its top asks
/// the Bridge for the page before the oldest one shown.
enum LAAWorkTranscriptPages {
    /// The page size Chat reads with.
    static let pageSize = PersistedTranscriptPagination.pageSize

    static func latestPath(_ id: String) -> String {
        LAAWorkPresentation.path("/v1/sessions/\(id)/conversation",
                                 query: [URLQueryItem(name: "limit", value: String(pageSize))])
    }

    static func olderPath(_ id: String, before: String) -> String {
        LAAWorkPresentation.path("/v1/sessions/\(id)/conversation",
                                 query: [URLQueryItem(name: "limit", value: String(pageSize)),
                                         URLQueryItem(name: "before", value: before)])
    }

    struct Shown {
        var messages: [LAAWorkConversationMessage]
        /// Whether "Load earlier messages" is offered.
        var canLoadOlder: Bool
        /// True once the owner loaded an older page, so the next latest page
        /// is grafted under it rather than replacing it.
        var backfilled: Bool
    }

    /// Lays a freshly read latest page onto what is shown. Older pages the
    /// owner loaded stay above it when the page still overlaps them; without
    /// that anchor (a compaction rewrote the history, or more arrived than a
    /// page holds) the shown history starts again at the latest page.
    static func latest(_ page: [LAAWorkConversationMessage], hasOlder: Bool?,
                       onto shown: Shown) -> Shown {
        guard let hasOlder else {
            // An older Bridge returned the whole conversation.
            return Shown(messages: page, canLoadOlder: false, backfilled: false)
        }
        if shown.backfilled, let first = page.first,
           let anchor = shown.messages.firstIndex(where: { $0.id == first.id }), anchor > 0 {
            return Shown(messages: Array(shown.messages[..<anchor]) + page,
                         canLoadOlder: shown.canLoadOlder, backfilled: true)
        }
        return Shown(messages: page, canLoadOlder: hasOlder, backfilled: false)
    }

    /// Puts an older page above what is shown; rows already shown are not
    /// repeated.
    static func prepend(_ older: [LAAWorkConversationMessage], hasOlder: Bool?,
                        onto shown: Shown) -> Shown {
        let known = Set(shown.messages.map(\.id))
        var seen = Set<String>()
        let fresh = older.filter { !known.contains($0.id) && seen.insert($0.id).inserted }
        return Shown(messages: fresh + shown.messages,
                     canLoadOlder: (hasOlder ?? false) && !fresh.isEmpty,
                     backfilled: shown.backfilled || !fresh.isEmpty)
    }
}
#endif

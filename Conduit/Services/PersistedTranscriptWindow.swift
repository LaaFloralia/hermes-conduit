import Foundation

/// Bounded persisted-history hydration for the active conversation, mirroring
/// Hermes Desktop's transcript window: `session.resume` stays compact and the
/// persisted transcript arrives as tail-anchored pages of
/// `GET /api/sessions/{id}/messages` instead of one unbounded payload.
enum PersistedTranscriptPagination {
    /// Small tail pages keep tool-heavy employee chats inexpensive to reopen.
    /// Older rows stay available through explicit backfill.
    static let pageSize = 40

    /// Most transcript rows held for display at once: the live transcript
    /// plus any detached earlier history. Older rows beyond it stay on the
    /// server and come back through backfill.
    static let maxHeldRows = 200

    /// Live rows kept when backfill first passes `maxHeldRows` and the
    /// loaded history detaches from the live transcript.
    static let liveTailKeep = 80

    /// Query for one tail-anchored page. The backend measures `offset` back
    /// from the NEWEST persisted row and still returns the selected page in
    /// chronological order. `include_compacted=true` keeps compaction-
    /// preserved display rows reachable; without them the transcript
    /// silently ends at the compaction boundary. `inline_images=false`
    /// leaves out the copy of every picture Hermes stores inside a message
    /// (#652: 16 MB for one chat), writing an `[image]` stand-in instead;
    /// a picture is fetched on its own when its bubble shows. A Hermes
    /// without the flag ignores it.
    static func tailQuery(offset: Int) -> String {
        "?limit=\(pageSize)&offset=\(offset)&order=latest&include_compacted=true&inline_images=false"
    }

    /// Legacy one-shot request: no paging parameters. Older Hermes builds
    /// answer it with the complete transcript, exactly as pre-pagination
    /// Conduit read them.
    static let legacyQuery = ""

    /// Pagination echo of one `/messages` response. Absent means the backend
    /// served the legacy one-shot full transcript.
    struct PageInfo: Equatable {
        let limit: Int?
        let offset: Int?
        let order: String?
        let returned: Int
        /// Rows actually present in the response — the offset bookkeeping
        /// source of truth. The echoed `returned` is retained for parity
        /// with the server's view but never trusted over the row array.
        let rawReturned: Int

        /// True only when the backend honored the tail-anchored contract by
        /// echoing the `order=latest` paging mode. Older dashboard builds
        /// that page from the OLDEST end also return a pagination object —
        /// without the order echo — so their echo must never be read as
        /// tail-truncation evidence.
        var honorsTailContract: Bool { order == "latest" }

        /// A full page means older history may still exist; a short (or
        /// empty) page means the beginning has been reached. Trusts the
        /// echoed `limit` as the backend's real page size — a lying echo
        /// only costs bounded extra no-op taps before a short or empty
        /// page retires the affordance.
        func mayHaveOlderRows(fetchedRowCount: Int) -> Bool {
            honorsTailContract && fetchedRowCount >= (limit ?? PersistedTranscriptPagination.pageSize)
        }
    }

    /// Parses the response's pagination echo. `rawRowCount` backs the
    /// `returned` field when a backend omits it — the row array itself is
    /// the direct evidence of how much was fetched.
    static func parse(_ payload: [String: Any], rawRowCount: Int) -> PageInfo? {
        guard let raw = payload["pagination"] as? [String: Any] else { return nil }
        let returned = Self.integerValue(raw["returned"])
        return PageInfo(
            limit: Self.integerValue(raw["limit"]),
            offset: Self.integerValue(raw["offset"]),
            order: raw["order"] as? String,
            returned: returned ?? rawRowCount,
            rawReturned: rawRowCount
        )
    }

    /// The app's one JSON integer reading: a JSON boolean is no count.
    private static func integerValue(_ value: Any?) -> Int? {
        AppState.integerValue(value)
    }
}

/// Identity-safe per-active-session state of the loaded persisted-transcript
/// window. One value describes "how much of this conversation's persisted
/// history is on screen and whether older pages remain" — the pagination
/// counterpart of the compact resume's runtime state, never mixed into it.
struct PersistedTranscriptWindowState: Equatable {
    /// Session ID the window was hydrated for (as requested). The resolved
    /// stored ID and the runtime ID are tracked separately because the
    /// endpoint may re-home a runtime alias and `session.resume` may answer
    /// with a fresh runtime ID.
    let requestedSessionID: String
    let profile: String
    let pageSize: Int
    /// Stored session ID the accepted hydration's `/messages` response
    /// echoed (`session_id`), when the backend supplied one — the durable
    /// identity of the persisted rows and the ID older-page requests
    /// continue against.
    var resolvedSessionID: String?
    /// Runtime session ID the same accepted `session.resume` returned —
    /// the identity `applyChatResume` made active.
    var runtimeSessionID: String?
    /// Number of newest persisted rows the local transcript already covers.
    /// Advances by the fetched row count of every page, which self-corrects
    /// the offset drift that live rows create under `order=latest` paging.
    /// Network coverage only — never used as evidence about what the visible
    /// transcript contains.
    var nextOffset: Int
    var canLoadEarlier: Bool
    var isLoadingEarlier = false
    /// The visible transcript starts with rows loaded through backfill.
    /// Explicit state because the reconnect graft must keep preserving that
    /// prefix across REPEATED reconciles, while the network coverage reset
    /// below erases the offset evidence after the first one. Set when a
    /// backfill prepends; kept by a reconcile that grafts onto the prefix;
    /// cleared when a refreshed tail is authoritative (no safe anchor).
    var hasBackfilledPrefix = false
    /// Earlier history shown above the live transcript once backfill passed
    /// `maxHeldRows`: chronological, older than every live row (its newest
    /// rows are evicted first, so a gap can sit between it and the live
    /// rows), and never part of `messages`, so the offline copy, sends, streaming
    /// and reconcile only ever see the live suffix. Bounded by evicting its
    /// newest rows; cleared with the window, on send and on jump to latest.
    var detachedEarlier: [ChatMessage] = []

    /// Every session identity the accepted hydration/resume transaction
    /// vouched for together: the requested ID, the persisted stored ID, and
    /// the runtime ID. Trusted as one conversation because they arrived in
    /// the SAME accepted transaction after the transcript ownership
    /// validation — never reconstructed from a later catalog refresh, whose
    /// freshness must not gate backfill (the production no-op regression).
    var trustedSessionIDs: Set<String> {
        PersistedTranscriptWindow.normalizingSessionIDs([
            requestedSessionID, resolvedSessionID, runtimeSessionID
        ])
    }
}

/// A legacy one-shot transcript that exceeded the client's safe response
/// bound. Distinguished from the bridge's generic oversized-response error
/// so the transcript layer can surface the compatibility copy — an old
/// backend attempting the entire transcript — without that copy leaking
/// into unrelated oversized dashboard operations.
struct LegacyTranscriptOversizedError: LocalizedError {
    let limit: Int

    var errorDescription: String? {
        AppLocalization.string("This conversation is too large to load safely with this Hermes version. Update Hermes to enable paginated conversation history.")
    }
}

/// Pure algebra for older-page backfill: row merging, reconnect grafting,
/// tool-boundary reconstruction, and conversation-identity ownership.
enum PersistedTranscriptWindow {
    /// Whether a persisted-history window belongs to a conversation — the
    /// ONE identity rule shared by the backfill action, stale-response
    /// validation, the ChatView affordance, and the reconnect graft gate.
    ///
    /// Primary truth is explicit overlap between the window's
    /// transaction-captured IDs (`trustedSessionIDs`: requested + resolved
    /// stored + runtime) and the checked conversation's IDs. Catalog alias
    /// knowledge — pre-expanded by the caller into the alias sets — remains
    /// a secondary compatibility source, but its freshness is never
    /// required: a resume re-homes `activeSessionId` to the runtime ID long
    /// before (sometimes never before) the catalog learns the alias, and
    /// requiring it silently disabled "Load earlier messages".
    static func ownershipHolds(
        window: PersistedTranscriptWindowState,
        conversationSessionIds: Set<String>,
        profile: String,
        windowAliasIds: Set<String>,
        conversationAliasIds: Set<String>
    ) -> Bool {
        guard window.profile == profile else { return false }
        let windowIDs = window.trustedSessionIDs
        if !windowIDs.isDisjoint(with: conversationSessionIds) { return true }
        if !windowIDs.isDisjoint(with: conversationAliasIds) { return true }
        if !conversationSessionIds.isDisjoint(with: windowAliasIds) { return true }
        return false
    }

    /// Session-ID candidates reduced to a trusted identity set: nil and
    /// whitespace-only entries are dropped, everything else is kept as-is.
    /// One normalization rule for every identity set compared by
    /// `ownershipHolds`.
    static func normalizingSessionIDs(_ candidates: [String?]) -> Set<String> {
        var ids: Set<String> = []
        for candidate in candidates {
            guard let candidate,
                  !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            ids.insert(candidate)
        }
        return ids
    }

    /// Prepends an older page onto the loaded transcript, dropping rows the
    /// transcript already holds. Offset drift under `order=latest` paging
    /// (rows persisted while the conversation is open shift the origin) makes
    /// overlap normal, so pages are never assumed disjoint. Deduplication
    /// keys on the durable message identity — `ChatMessage.id`, which for
    /// persisted rows is the database row id carried by the payload — never
    /// on visible text. (Rows without any payload id would fall back to a
    /// positional identity and defeat dedup; unreachable with Hermes, whose
    /// persisted rows always carry their SQLite row id.)
    ///
    /// Only the strictly-older region of the page is prepended: everything
    /// from the first already-held row onward is either duplicate or
    /// newer-side content that arrived outside the window, and prepending
    /// the latter would land it ABOVE older held rows. Newer-side rows
    /// reach the transcript through the live projection and the reconcile
    /// tail graft instead.
    ///
    /// Returns nil when nothing would change: an empty transcript means the
    /// session was swapped or wiped mid-fetch (prepending would paint the
    /// older page as the whole conversation), and a page with no fresh rows
    /// must not publish a redundant transcript replacement.
    static func prepending(
        _ olderPage: [ChatMessage],
        onto existing: [ChatMessage]
    ) -> [ChatMessage]? {
        guard !existing.isEmpty, !olderPage.isEmpty else { return nil }
        let knownIDs = Set(existing.map { $0.id })
        let olderRegion: ArraySlice<ChatMessage>
        if let firstKnown = olderPage.firstIndex(where: { knownIDs.contains($0.id) }) {
            olderRegion = olderPage[..<firstKnown]
        } else {
            olderRegion = olderPage[...]
        }
        var freshIDs = knownIDs
        var fresh: [ChatMessage] = []
        fresh.reserveCapacity(olderRegion.count)
        for message in olderRegion where freshIDs.insert(message.id).inserted {
            fresh.append(message)
        }
        guard !fresh.isEmpty else { return nil }
        return fresh + existing
    }

    /// Re-anchors a refreshed tail onto a transcript with backfilled older
    /// pages. A re-reconciliation re-reads only the newest page; replacing
    /// the transcript with it outright would silently drop everything
    /// "Load earlier messages" already loaded. The refreshed tail's first
    /// row locates where it begins inside the previous transcript and the
    /// older prefix is kept. When no anchor is found (compaction rewrite,
    /// session identity change) the refreshed tail is authoritative.
    ///
    /// Returns whether the graft applied, so the caller can carry the
    /// backfilled-prefix fact into the refreshed window and keep preserving
    /// the prefix across repeated reconciles.
    static func grafting(
        refreshedTail: [ChatMessage],
        ontoBackfilled previous: [ChatMessage],
        window: PersistedTranscriptWindowState?
    ) -> (messages: [ChatMessage], grafted: Bool) {
        guard let window, window.hasBackfilledPrefix,
              !previous.isEmpty, !refreshedTail.isEmpty,
              let first = refreshedTail.first,
              let anchor = previous.firstIndex(where: { $0.id == first.id }),
              anchor > 0 else {
            return (refreshedTail, false)
        }
        return (Array(previous[..<anchor]) + refreshedTail, true)
    }

    /// Reconciles a tool call/result pair that a page boundary split apart.
    /// The initial tail and each older page are normalized independently, so
    /// when a call row is the last row of an older page and its result row
    /// is the first row of the already-held newer page, the call normalizes
    /// to an unanswered call card and the result to a standalone result card
    /// — one logical tool run rendered as two. Both sides carry the durable
    /// tool-call identity (`ToolActivity.id` = Hermes `tool_call_id`), so
    /// the result is folded back into its call card by ID, never by visible
    /// text, and the duplicate standalone card is dropped from the held
    /// prefix.
    ///
    /// Returns the adjusted older page and how many leading held messages
    /// were folded into it. The caller must only drop those held rows when
    /// the prepend actually publishes (an empty held side means the session
    /// was swapped mid-fetch and nothing may be dropped).
    static func reconcilingToolCallsAcrossBoundary(
        olderPage: [ChatMessage],
        held: [ChatMessage]
    ) -> (olderPage: [ChatMessage], foldedFromHeld: Int) {
        var adjusted = olderPage
        var folded = 0
        // Bounded by the loaded inputs, with no arbitrary pair ceiling — a
        // single assistant turn can carry any number of tool calls. Each
        // iteration consumes exactly one held row and stops at the first
        // held row that is not a foldable result, so the scan covers only
        // the contiguous boundary region (at most the held transcript's
        // length; call cards and their results are matched by durable ID,
        // never by position or name).
        while folded < held.count {
            let heldIndex = folded
            guard held[heldIndex].role == .tool,
                  let resultTool = held[heldIndex].tool,
                  resultTool.status == .complete,
                  let callID = resultTool.id, !callID.isEmpty,
                  let callIndex = adjusted.lastIndex(where: { message in
                      guard message.role == .tool, let tool = message.tool else { return false }
                      return tool.id == callID && (tool.output?.isEmpty ?? true)
                  }),
                  adjusted[callIndex].id != held[heldIndex].id else {
                break
            }
            adjusted[callIndex].tool?.output = resultTool.output
            adjusted[callIndex].tool?.status = .complete
            folded += 1
        }
        return (adjusted, folded)
    }

    /// Paginated-contract pages are deduplicated and grafted by durable row
    /// identity, so every row must carry one. Real Hermes persisted rows
    /// always carry their SQLite `id`; a page without durable identity means
    /// normalization would fall back to page-local positional IDs that
    /// cannot survive across pages — reject it before it can silently
    /// corrupt overlap dedup.
    nonisolated static func rowsHaveDurableIdentity(_ rows: [Any]) -> Bool {
        rows.allSatisfy { row in
            guard let dict = row as? [String: Any] else { return false }
            for key in ["id", "message_id"] {
                switch dict[key] {
                case let string as String where !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                    return true
                case let number as NSNumber where number.doubleValue != 0:
                    // SQLite AUTOINCREMENT ids start at 1; zero is never a
                    // real persisted row id.
                    return true
                default:
                    continue
                }
            }
            return false
        }
    }

    // MARK: - Bounded display window

    /// Prepends an older page onto `held`: folds a tool call/result pair the
    /// page boundary split, then deduplicates by durable row identity. The
    /// same algebra the live transcript's backfill uses, so a page lands the
    /// same way on the live transcript and on detached history. Returns the
    /// new rows and how many of their leading rows came from the page, or
    /// nil when nothing would change.
    static func mergingOlderPage(
        _ page: [ChatMessage],
        onto held: [ChatMessage]
    ) -> (rows: [ChatMessage], pageCount: Int)? {
        guard !held.isEmpty, !page.isEmpty else { return nil }
        let (olderPage, folded) = reconcilingToolCallsAcrossBoundary(olderPage: page, held: held)
        if folded > 0 {
            let remaining = Array(held.dropFirst(folded))
            if remaining.isEmpty {
                // Every held row folded into the page: the folded page is
                // the whole transcript, never the unfolded duplicate.
                if !olderPage.isEmpty { return (olderPage, olderPage.count) }
            } else if let merged = prepending(olderPage, onto: remaining) {
                return (merged, merged.count - remaining.count)
            }
        }
        guard let plain = prepending(page, onto: held) else { return nil }
        return (plain, plain.count - held.count)
    }

    /// Where `rows` may be cut so the part from the returned index on keeps
    /// at most `keepingLast` rows — or, when no such cut is safe, the
    /// smallest safe overshoot. A cut lands only at the start of a turn (a
    /// user row that is not a steer), never between a tool call and its
    /// result. Returns 0 when nothing needs cutting or no cut is safe.
    static func safeSplitIndex(_ rows: [ChatMessage], keepingLast keep: Int) -> Int {
        guard rows.count > max(0, keep) else { return 0 }
        let target = rows.count - max(0, keep)
        for index in target..<rows.count where isSafeSplit(rows, at: index) {
            return index
        }
        var index = target - 1
        while index > 0 {
            if isSafeSplit(rows, at: index) { return index }
            index -= 1
        }
        return 0
    }

    /// A cut before `rows[index]` starts a turn and leaves every tool run
    /// whole on one side.
    static func isSafeSplit(_ rows: [ChatMessage], at index: Int) -> Bool {
        guard index > 0, index < rows.count,
              rows[index].role == .user, !rows[index].isSteer else { return false }
        var before: Set<String> = []
        for row in rows[..<index] where row.role == .tool {
            if let id = row.tool?.id, !id.isEmpty { before.insert(id) }
        }
        guard !before.isEmpty else { return true }
        return !rows[index...].contains { row in
            row.role == .tool && row.tool?.id.map(before.contains) == true
        }
    }

    /// Bounds detached history by dropping its newest rows until it and
    /// `liveCount` live rows fit in `cap`. The first `protecting` rows (the
    /// page just fetched) always stay, and a cut prefers a turn start.
    static func evictingNewest(
        _ detached: [ChatMessage],
        protecting: Int,
        liveCount: Int,
        cap: Int
    ) -> [ChatMessage] {
        let protected = min(max(0, protecting), detached.count)
        let allowed = max(protected, cap - liveCount)
        guard detached.count > allowed else { return detached }
        var cut = allowed
        while cut > protected, !isSafeSplit(detached, at: cut) {
            cut -= 1
        }
        return Array(detached[..<cut])
    }

    /// Lands one older page on the held transcript under the display cap.
    /// Below the cap it prepends onto the live rows as before. The first
    /// page that would pass the cap detaches: the live rows keep their last
    /// `liveTailKeep` rows from a safe cut, and the older rows move to
    /// detached history. While detached, pages prepend onto the detached
    /// rows (rows the live transcript holds never re-enter above them) and
    /// its newest rows are evicted, never the page just fetched. Nil means
    /// nothing changed.
    static func landingOlderPage(
        _ page: [ChatMessage],
        live: [ChatMessage],
        detached: [ChatMessage],
        cap: Int?,
        liveTailKeep: Int = PersistedTranscriptPagination.liveTailKeep
    ) -> (live: [ChatMessage], detached: [ChatMessage])? {
        guard let cap, !detached.isEmpty else {
            guard let merged = mergingOlderPage(page, onto: live) else { return nil }
            guard let cap, merged.rows.count > cap else { return (merged.rows, []) }
            let split = safeSplitIndex(merged.rows, keepingLast: liveTailKeep)
            guard split > 0 else { return (merged.rows, []) }
            let earlier = Array(merged.rows[..<split])
            return (
                Array(merged.rows[split...]),
                evictingNewest(earlier, protecting: merged.pageCount, liveCount: merged.rows.count - split, cap: cap)
            )
        }
        let liveIDs = Set(live.map(\.id))
        let older = Array(page.prefix { !liveIDs.contains($0.id) })
        guard let merged = mergingOlderPage(older, onto: detached) else { return nil }
        return (live, evictingNewest(merged.rows, protecting: merged.pageCount, liveCount: live.count, cap: cap))
    }
}

#if LAA_BUILD
import XCTest
@testable import Conduit

final class LAAChatsTests: XCTestCase {
    private let person = LAAChatsPerson(profile: "laa-cfo", name: "Morgan", role: "CFO", available: true)
    private var room: GroupRoom {
        GroupRoom(roomID: "r", name: "Design team", members: [
            GroupMember(memberID: "laa-cto", profile: "laa-cto", handle: "ada", displayName: "Ada", target: nil, extra: [:])
        ], authorityGatewayID: "gateway", authorityEpoch: 1, revision: 1, createdAt: 1, updatedAt: 2,
                  disbandedAt: nil, latestSeq: nil)
    }
    func testSearchMatchesNamesRolesGroupsAndMembers() {
        XCTAssertTrue(LAAChatsSearch.person(person, matches: " mOrGaN "))
        XCTAssertTrue(LAAChatsSearch.person(person, matches: "cfo"))
        XCTAssertTrue(LAAChatsSearch.room(room, matches: "DESIGN"))
        XCTAssertTrue(LAAChatsSearch.room(room, matches: "ada"))
        XCTAssertFalse(LAAChatsSearch.room(room, matches: "nothing"))
        XCTAssertTrue(LAAChatsSearch.person(person, matches: "  "))
    }

    func testSearchDoesNotClaimNoResultsBeforeGroupsAreReady() {
        XCTAssertEqual(LAAChatsSearch.emptySearchState(groups: .ready), .ready)
        XCTAssertEqual(LAAChatsSearch.emptySearchState(groups: .loading), .loading)
        XCTAssertEqual(LAAChatsSearch.emptySearchState(groups: .failed("failure")), .failed(""))
        XCTAssertEqual(LAAChatsSearch.emptySearchState(groups: .unsupported), .failed(""))
        XCTAssertEqual(LAAChatsSearch.emptySearchState(groups: .offline), .offline)
    }

    // D-16: Chat → Monet → Back showed Hermes' no-reply token as Monet's preview.

    func testSentinelMatchesOnlyTheWholeTrimmedCaseSensitiveToken() {
        XCTAssertTrue(LAAChatsPreview.isNoReplySentinel("[SILENT]"))
        XCTAssertTrue(LAAChatsPreview.isNoReplySentinel("  [SILENT]\n"))
        XCTAssertFalse(LAAChatsPreview.isNoReplySentinel("[silent]"))
        XCTAssertFalse(LAAChatsPreview.isNoReplySentinel("[SILENT] done"))
        XCTAssertFalse(LAAChatsPreview.isNoReplySentinel("Runs that answer [SILENT] never notify."))
        XCTAssertFalse(LAAChatsPreview.isNoReplySentinel("> [SILENT]"))
        XCTAssertFalse(LAAChatsPreview.isNoReplySentinel("SILENT"))
        XCTAssertFalse(LAAChatsPreview.isNoReplySentinel(""))
    }

    func testLivePreviewSkipsAnAssistantSentinelAndKeepsThePreviousRowAndTime() {
        let rows = [
            ChatMessage(id: "u1", role: .user, content: "予定を見て", timestamp: "1"),
            ChatMessage(id: "a1", role: .assistant, content: "午前は空いています。", timestamp: "2"),
            ChatMessage(id: "a2", role: .assistant, content: " [SILENT]\n", timestamp: "3")
        ]
        let chosen = LAAChatsPreview.latest(rows)
        XCTAssertEqual(chosen?.id, "a1")
        let preview = LAAChatsPreview.choose(live: chosen, cached: nil, roster: "[SILENT]")
        XCTAssertEqual(preview?.text, "午前は空いています。")
        XCTAssertEqual(preview?.timestamp, "2")
    }

    func testLivePreviewKeepsUserInlineAndQuotedText() {
        let user = ChatMessage(id: "u", role: .user, content: "[SILENT]", timestamp: "1")
        XCTAssertEqual(LAAChatsPreview.latest([user])?.id, "u")
        let inline = ChatMessage(id: "a", role: .assistant, content: "Cron replies [SILENT] when idle.", timestamp: "2")
        XCTAssertEqual(LAAChatsPreview.latest([user, inline])?.id, "a")
        let quoted = ChatMessage(id: "q", role: .user,
                                 content: "\(ReplyQuoteEnvelope.marker)\n> [SILENT]\n\nWhy?", timestamp: "3")
        XCTAssertEqual(LAAChatsPreview.latest([inline, quoted])?.id, "q")
        let notice = ChatMessage(id: "s", role: .system, content: "Model switched", timestamp: "4")
        let empty = ChatMessage(id: "e", role: .assistant, content: "", timestamp: "5")
        XCTAssertEqual(LAAChatsPreview.latest([quoted, notice, empty])?.id, "q")
    }

    func testCachedPreviewUsesTheSameRoleAwarePredicate() throws {
        let rows = try [
            ChatMessage(id: "a1", role: .assistant, content: "まとめました。", timestamp: "1"),
            ChatMessage(id: "a2", role: .assistant, content: "[SILENT]", timestamp: "2")
        ].map { try XCTUnwrap(OfflineCachedMessage($0)) }
        XCTAssertEqual(LAAChatsPreview.latest(rows)?.id, "a1")
        let user = try XCTUnwrap(OfflineCachedMessage(ChatMessage(id: "u", role: .user, content: "[SILENT]", timestamp: "3")))
        XCTAssertEqual(LAAChatsPreview.latest(rows + [user])?.id, "u")
        XCTAssertNil(LAAChatsPreview.latest([rows[1]]))
    }

    func testFallbackOrderSkipsSentinelOnlySourcesAndHidesAnExactRosterToken() throws {
        let silentLive = ChatMessage(id: "a", role: .assistant, content: "[SILENT]", timestamp: "9")
        let cached = try XCTUnwrap(OfflineCachedMessage(
            ChatMessage(id: "c", role: .assistant, content: "前回の要点です。", timestamp: "5")))
        // Live has only the token: the cached row and its time stand.
        let fromCache = LAAChatsPreview.choose(live: LAAChatsPreview.latest([silentLive]), cached: cached, roster: "[SILENT]")
        XCTAssertEqual(fromCache?.text, "前回の要点です。")
        XCTAssertEqual(fromCache?.timestamp, "5")
        // The roster's role-less preview: an exact token shows nothing, other text stays as sent.
        XCTAssertNil(LAAChatsPreview.choose(live: nil, cached: nil, roster: " [SILENT] "))
        XCTAssertNil(LAAChatsPreview.choose(live: nil, cached: nil, roster: nil))
        let roster = LAAChatsPreview.choose(live: nil, cached: nil, roster: "[SILENT] は通知しません")
        XCTAssertEqual(roster?.text, "[SILENT] は通知しません")
        XCTAssertNil(roster?.timestamp)
        // A live row wins over older sources, as before.
        let live = ChatMessage(id: "l", role: .user, content: "ありがとう", timestamp: "10")
        XCTAssertEqual(LAAChatsPreview.choose(live: live, cached: cached, roster: "older")?.text, "ありがとう")
    }

    // BUS-558: the model-change notice became the list preview.

    func testInternalNoticesNeverBecomeThePreview() throws {
        let notice = "[System: The active model for this chat has changed to claude-opus-5-5 via provider claude-subscription-directsdk-experimental. From this point forward, respond as that model.]"
        XCTAssertNil(LAAChatsPreview.choose(live: nil, cached: nil, roster: notice))
        XCTAssertNil(LAAChatsPreview.choose(live: nil, cached: nil, roster: "[System: Something internal]"))
        let rows = try [
            ChatMessage(id: "a", role: .assistant, content: "承知しました。", timestamp: "1"),
            ChatMessage(id: "n", role: .user, content: notice, timestamp: "2")
        ].map { try XCTUnwrap(OfflineCachedMessage($0)) }
        XCTAssertEqual(LAAChatsPreview.latest(rows)?.id, "a")
        XCTAssertEqual(LAAChatsPreview.choose(live: nil, cached: nil, roster: "明日の予定です")?.text, "明日の予定です")
    }
}
#endif

//
//  SessionNestingTests.swift
//  Conduit
//
//  The Sessions drawer's nested list (#556): grouping rows under the
//  session that started them, and the parent key each voice row resolves
//  to. Written as an extension of an existing Voice suite, like
//  VoiceHistoryTests: the CI test planner is at capacity for new
//  XCTestCase classes.
//

import XCTest
@testable import Conduit

extension HermesVoiceGatewayTimeoutTests {
    // MARK: - Grouping

    private func nestSession(_ id: String, title: String = "Chat", stored: String? = nil, aliases: [String] = [], activity: TimeInterval? = nil, source: SessionSource = .chat) -> SessionSummary {
        SessionSummary(
            id: id,
            storedSessionId: stored,
            alternateIds: aliases,
            title: title,
            model: "claude",
            updatedLabel: "2h",
            lastActivityAt: activity,
            profile: "default",
            source: source,
            isActive: false,
            isArchived: false
        )
    }

    private func nestIDs(_ nodes: [SessionNesting.Node]) -> [String] {
        nodes.flatMap { [$0.session.id] + nestIDs($0.children) }
    }

    func testAJobNestsUnderItsCallOnAnyIDTheCallAnswersTo() {
        let call = nestSession("call-1", stored: "st-1", aliases: ["alt-1"], source: .voice)
        let byRow = nestSession("chat-1")
        // One job names each of the call's ids: its row id, its stored id
        // and a reconciliation alias.
        let parents = ["job-row": "call-1", "job-stored": "st-1", "job-alias": "alt-1"]
        let rows = [byRow, call,
                    nestSession("job-row", source: .voiceJob),
                    nestSession("job-stored", source: .voiceJob),
                    nestSession("job-alias", source: .voiceJob)]

        let nodes = SessionNesting.group(rows, parentKeyOf: { parents[$0.id] })

        XCTAssertEqual(nestIDs(nodes), ["chat-1", "call-1", "job-row", "job-stored", "job-alias"])
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(nodes[1].children.map(\.session.id), ["job-row", "job-stored", "job-alias"])
    }

    func testARowWhoseParentIsNotInTheListStaysTopLevel() {
        // The call rolled off the listing, so its job keeps its own row.
        let rows = [nestSession("chat-1"), nestSession("job-1", source: .voiceJob)]
        let nodes = SessionNesting.group(rows, parentKeyOf: { $0.id == "job-1" ? "gone-call" : nil })
        XCTAssertEqual(nestIDs(nodes), ["chat-1", "job-1"])
        XCTAssertTrue(nodes.allSatisfy(\.children.isEmpty))
    }

    func testARowNeverNestsUnderItself() {
        let rows = [nestSession("call-1", source: .voice)]
        let nodes = SessionNesting.group(rows, parentKeyOf: { _ in "call-1" })
        XCTAssertEqual(nestIDs(nodes), ["call-1"])
    }

    func testAParentCycleKeepsEveryRowListed() {
        let rows = [nestSession("a"), nestSession("b")]
        let parents = ["a": "b", "b": "a"]
        let nodes = SessionNesting.group(rows, parentKeyOf: { parents[$0.id] })
        // The cycle is broken, not swallowed: both rows stay in the list,
        // each listed exactly once.
        XCTAssertEqual(nestIDs(nodes), ["a", "b"])
        XCTAssertEqual(Set(nestIDs(nodes)).count, nestIDs(nodes).count, "No row may be listed twice")
    }

    func testATailIntoACycleKeepsEveryRowListedOnce() {
        // c points at a cycle it is not part of; freeing the cycle's row
        // must not lose the tail.
        let rows = [nestSession("c"), nestSession("a"), nestSession("b")]
        let parents = ["c": "a", "a": "b", "b": "a"]
        let nodes = SessionNesting.group(rows, parentKeyOf: { parents[$0.id] })
        XCTAssertEqual(Set(nestIDs(nodes)), Set(["a", "b", "c"]))
        XCTAssertEqual(Set(nestIDs(nodes)).count, nestIDs(nodes).count, "No row may be listed twice")
    }

    func testAnEmptyParentKeyStaysTopLevel() {
        // A host tag can carry an empty parent_id; it names nothing.
        let rows = [nestSession("chat-1"), nestSession("job-1", source: .voiceJob)]
        let nodes = SessionNesting.group(rows, parentKeyOf: { $0.id == "job-1" ? "" : nil })
        XCTAssertEqual(nestIDs(nodes), ["chat-1", "job-1"])
        XCTAssertTrue(nodes.allSatisfy(\.children.isEmpty))
    }

    func testNarrowingTheListFlattensItToTheMatchingRows() {
        let rows = [nestSession("chat-1"),
                    nestSession("call-1", source: .voice),
                    nestSession("job-1", source: .voiceJob)]
        let parents = ["call-1": "chat-1", "job-1": "call-1"]
        let parentKeyOf: (SessionSummary) -> String? = { parents[$0.id] }

        // Browsing: the job sits under the call, the call under the chat.
        XCTAssertEqual(nestIDs(SessionNesting.rows(rows, query: "", statusFilterActive: false, parentKeyOf: parentKeyOf)),
                       ["chat-1", "call-1", "job-1"])
        // Whitespace is no search.
        XCTAssertFalse(SessionNesting.rows(rows, query: "  ", statusFilterActive: false, parentKeyOf: parentKeyOf)[0].children.isEmpty)

        // A search or a status filter is a lookup: flat, same order.
        for (query, filtering) in [("call", false), ("", true)] {
            let nodes = SessionNesting.rows(rows, query: query, statusFilterActive: filtering, parentKeyOf: parentKeyOf)
            XCTAssertEqual(nodes.map(\.session.id), ["chat-1", "call-1", "job-1"])
            XCTAssertTrue(nodes.allSatisfy(\.children.isEmpty))
        }
    }

    func testANestSurfacesItsChildrensSignals() {
        let unread: (SessionSummary) -> Bool = { $0.id == "job-1" }
        let quiet: (SessionSummary) -> SessionLiveStatus? = { _ in nil }
        let childWorking: (SessionSummary) -> SessionLiveStatus? = { $0.id == "job-1" ? .working : nil }
        let childWaiting: (SessionSummary) -> SessionLiveStatus? = { $0.id == "job-1" ? .needsInput : nil }
        // The parent itself works while a child waits: waiting wins.
        let ownWorkingWhileChildWaits: (SessionSummary) -> SessionLiveStatus? = {
            $0.id == "call-1" ? .working : $0.id == "job-1" ? .needsInput : nil
        }

        let parents = ["job-1": "call-1"]
        let nest = SessionNesting.group(
            [nestSession("call-1", source: .voice), nestSession("job-1", source: .voiceJob)],
            parentKeyOf: { parents[$0.id] }
        )[0]

        // A collapsed nest never hides activity: the parent carries its
        // children's unread dot and loudest status, and a child waiting on
        // the user outranks one still working — its own state included.
        XCTAssertTrue(SessionNesting.signals(nest, isUnread: unread, liveStatus: quiet).isUnread)
        XCTAssertEqual(SessionNesting.signals(nest, isUnread: unread, liveStatus: childWorking).liveStatus, .working)
        XCTAssertEqual(SessionNesting.signals(nest, isUnread: unread, liveStatus: childWaiting).liveStatus, .needsInput)
        XCTAssertEqual(SessionNesting.signals(nest, isUnread: unread, liveStatus: ownWorkingWhileChildWaits).liveStatus, .needsInput)
        XCTAssertNil(SessionNesting.signals(nest, isUnread: { _ in false }, liveStatus: quiet).liveStatus)
    }

    func testSignalsCarryUpAWholeChain() {
        // A job waiting two levels down still surfaces on the chat.
        let rows = [nestSession("chat-1"),
                    nestSession("call-1", source: .voice),
                    nestSession("job-1", source: .voiceJob)]
        let parents = ["call-1": "chat-1", "job-1": "call-1"]
        let chain = SessionNesting.group(rows, parentKeyOf: { parents[$0.id] })[0]
        XCTAssertEqual(chain.descendantCount, 2)
        XCTAssertEqual(
            SessionNesting.signals(chain, isUnread: { _ in false }, liveStatus: { $0.id == "job-1" ? .needsInput : nil }).liveStatus,
            .needsInput
        )
    }

    func testChildrenSortNewestFirstWhileRootsKeepTheServersOrder() {
        let call = nestSession("call-1", source: .voice)
        let rows = [nestSession("chat-1"), nestSession("old-chat", activity: 50),
                    call,
                    nestSession("job-new", activity: 300, source: .voiceJob),
                    nestSession("job-untimed", source: .voiceJob),
                    nestSession("job-mid", activity: 200, source: .voiceJob)]
        let nodes = SessionNesting.group(rows, parentKeyOf: { $0.source == .voiceJob ? "call-1" : nil })

        XCTAssertEqual(nodes.map(\.session.id), ["chat-1", "old-chat", "call-1"])
        XCTAssertEqual(nodes[2].children.map(\.session.id), ["job-new", "job-mid", "job-untimed"])
    }

    func testEqualTimestampsKeepTheListingsOrder() {
        // sorted(by:) is not guaranteed stable; the listing's order breaks
        // the tie.
        let rows = [nestSession("call-1", source: .voice),
                    nestSession("job-b", activity: 200, source: .voiceJob),
                    nestSession("job-a", activity: 200, source: .voiceJob)]
        let nodes = SessionNesting.group(rows, parentKeyOf: { $0.source == .voiceJob ? "call-1" : nil })
        XCTAssertEqual(nodes[0].children.map(\.session.id), ["job-b", "job-a"])
    }

    func testAnOwnIDBeatsAnAliasBorrowingIt() {
        // A row reconciling under its stored id must not lose its children
        // to an earlier row that merely borrows that id as an alias.
        let owner = nestSession("runtime-1", stored: "st-1", source: .voice)
        let borrower = nestSession("chat-0", aliases: ["st-1"])
        let rows = [borrower, owner, nestSession("job-1", source: .voiceJob)]

        let nodes = SessionNesting.group(rows, parentKeyOf: { $0.source == .voiceJob ? "st-1" : nil })

        XCTAssertEqual(nodes.map(\.session.id), ["chat-0", "runtime-1"])
        XCTAssertEqual(nodes[1].children.map(\.session.id), ["job-1"])
    }

    func testAChainNestsTheCallUnderItsChatAndTheJobUnderTheCall() {
        let rows = [nestSession("chat-1"),
                    nestSession("call-1", source: .voice),
                    nestSession("job-1", source: .voiceJob)]
        let parents = ["call-1": "chat-1", "job-1": "call-1"]
        let nodes = SessionNesting.group(rows, parentKeyOf: { parents[$0.id] })

        XCTAssertEqual(nestIDs(nodes), ["chat-1", "call-1", "job-1"])
        XCTAssertEqual(nodes[0].children.map(\.session.id), ["call-1"])
        XCTAssertEqual(nodes[0].children[0].children.map(\.session.id), ["job-1"])
    }

    func testTheFirstRowAnsweringToAKeyParentsTheChild() {
        // Two rows carry the same alias; the listing's earlier one wins.
        let first = nestSession("call-1", aliases: ["shared"], source: .voice)
        let second = nestSession("call-2", aliases: ["shared"], source: .voice)
        let rows = [first, second, nestSession("job-1", source: .voiceJob)]

        let nodes = SessionNesting.group(rows, parentKeyOf: { $0.source == .voiceJob ? "shared" : nil })

        XCTAssertEqual(nodes.map(\.session.id), ["call-1", "call-2"])
        XCTAssertEqual(nodes[0].children.map(\.session.id), ["job-1"])
        XCTAssertTrue(nodes[1].children.isEmpty)
    }

    // MARK: - The chat behind a saved call

    private func nestLink(call row: String, chat: String, stored: String? = nil, profile: String = "default") -> VoiceCallChatLink {
        VoiceCallChatLink(
            callID: "c-\(row)",
            callSessionID: row,
            chatRuntimeSessionID: chat,
            chatStoredSessionID: stored,
            chatTitle: "Build",
            profile: profile,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_095),
            resumed: false
        )
    }

    func testChatKeyPrefersTheStoredIDAndTheLatestMatchingLink() {
        var links = VoiceCallChatLinks()
        links.add(nestLink(call: "row-1", chat: "rt-1"))
        links.add(nestLink(call: "row-2", chat: "rt-2", stored: "st-2"))

        XCTAssertEqual(links.chatKey(forCallIDs: ["row-2"], profile: "default"), "st-2")
        // A link that never learned a stored id still names its runtime.
        XCTAssertEqual(links.chatKey(forCallIDs: ["row-1"], profile: "default"), "rt-1")
        // Two links' calls in one call's id set: the later link wins.
        links.add(nestLink(call: "row-3", chat: "rt-3", stored: "st-3"))
        XCTAssertEqual(links.chatKey(forCallIDs: ["row-1", "row-3"], profile: "default"), "st-3")
    }

    func testChatKeyStaysOnItsProfileAndNeedsALink() {
        var links = VoiceCallChatLinks()
        links.add(nestLink(call: "row-1", chat: "rt-1", stored: "st-1", profile: "work"))

        XCTAssertNil(links.chatKey(forCallIDs: ["row-1"], profile: "default"))
        XCTAssertNil(links.chatKey(forCallIDs: [], profile: "work"))
        XCTAssertNil(links.chatKey(forCallIDs: ["other-row"], profile: "work"))
        XCTAssertEqual(links.chatKey(forCallIDs: ["row-1"], profile: "work"), "st-1")
        // A link whose chat ids are all empty names nothing to nest under.
        links.add(nestLink(call: "row-2", chat: ""))
        XCTAssertNil(links.chatKey(forCallIDs: ["row-2"], profile: "default"))
    }

    // MARK: - The parent key a voice row resolves to

    func testParentKeyFollowsTheVoiceTag() {
        var links = VoiceCallChatLinks()
        links.add(nestLink(call: "call-1", chat: "rt-1", stored: "st-1"))
        let call = nestSession("call-1", source: .voice)
        let job = nestSession("job-1", source: .voiceJob)
        let classic = nestSession("chat-1")

        // A job nests under the call that started it, wherever that call
        // is listed; a saved call nests under the chat it was attached to.
        XCTAssertEqual(SessionNesting.parentKey(for: job, tag: VoiceSessionTag(kind: .job, engine: nil, parentID: "call-1", parentTitle: nil), chatLinks: links, profile: "default"), "call-1")
        XCTAssertEqual(SessionNesting.parentKey(for: call, tag: VoiceSessionTag(kind: .call, engine: "gemini-live", parentID: nil, parentTitle: nil), chatLinks: links, profile: "default"), "st-1")
        // A call this device has no link for (a standalone call, or one
        // started on another device) stays top level.
        XCTAssertNil(SessionNesting.parentKey(for: call, tag: VoiceSessionTag(kind: .call, engine: nil, parentID: nil, parentTitle: nil), chatLinks: links, profile: "work"))
        // Classic voice runs in its chat's own session; a job the host
        // never linked (issue #556's CarPlay case) stays top level too.
        XCTAssertNil(SessionNesting.parentKey(for: classic, tag: VoiceSessionTag(kind: .classic, engine: nil, parentID: nil, parentTitle: nil), chatLinks: links, profile: "default"))
        XCTAssertNil(SessionNesting.parentKey(for: job, tag: VoiceSessionTag(kind: .job, engine: nil, parentID: nil, parentTitle: nil), chatLinks: links, profile: "default"))
        XCTAssertNil(SessionNesting.parentKey(for: classic, tag: nil, chatLinks: links, profile: "default"))
    }
}

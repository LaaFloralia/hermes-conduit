#if LAA_BUILD
import XCTest
@testable import Conduit

/// D-25 addendum (2026-11-28): an employee chat whose newest page is all
/// cron reports and tool rows still opens to the last exchange between the
/// owner and the employee; compaction's second copy of each report shows
/// once; reports never push the conversation out of the display cap; a
/// report shows its routine's name and never its internal header line;
/// and a run of reports folds into one row.
@MainActor
final class LAACronReportDisplayTests: XCTestCase {
    private enum FixtureError: Error {
        case unusableSuite
    }

    // MARK: - Fixtures

    private static func cronNote(_ name: String, _ body: String) -> String {
        "[Cron job \"\(name)\" report: shown in the chat, no reply asked for]\n\n\(body)"
    }

    private static func cron(_ id: String, _ name: String = "朝の確認", body: String = "異常なし", timestamp: String = "2026-11-27T09:00:00Z") -> ChatMessage {
        ChatMessage(
            id: id,
            role: .system,
            content: cronNote(name, body),
            timestamp: timestamp,
            displayKind: ChatMessage.internalNotificationDisplayKind
        )
    }

    private static func message(_ id: String, _ role: MessageRole, _ content: String = "text", displayKind: String? = nil) -> ChatMessage {
        ChatMessage(id: id, role: role, content: content, timestamp: "2026-11-27T09:00:00Z", displayKind: displayKind)
    }

    private static func tool(_ id: String) -> ChatMessage {
        ChatMessage(
            id: id,
            role: .tool,
            content: "",
            timestamp: "2026-11-27T09:00:00Z",
            tool: ToolActivity(id: "call-\(id)", name: "terminal", input: nil, output: "ok", status: .complete)
        )
    }

    // MARK: - containsOwnerExchange

    func testOwnerExchangeNeedsAnOwnerRowAndAReply() {
        XCTAssertTrue(PersistedTranscriptWindow.containsOwnerExchange([
            Self.message("1", .user, "お願い"), Self.message("2", .assistant, "了解です")
        ]))
        XCTAssertTrue(PersistedTranscriptWindow.containsOwnerExchange([
            Self.message("1", .user, "お願い"), Self.message("2", .partial, "書いています")
        ]))
        XCTAssertFalse(PersistedTranscriptWindow.containsOwnerExchange([Self.message("1", .user, "お願い")]))
        XCTAssertFalse(PersistedTranscriptWindow.containsOwnerExchange([Self.message("2", .assistant, "了解です")]))
        XCTAssertFalse(PersistedTranscriptWindow.containsOwnerExchange([]))
    }

    func testOwnerExchangeIgnoresCronToolSteerAndCompactionRows() {
        let rows = [
            Self.cron("c1"),
            Self.tool("t1"),
            Self.message("s1", .user, "急いで", displayKind: ChatMessage.steerDisplayKind),
            Self.message("k1", .user, "[CONTEXT COMPACTION] earlier turns were summarized"),
            Self.message("k2", .user, "[CONTEXT SUMMARY] what happened"),
            Self.message("n1", .user, Self.cronNote("朝の確認", "raw note")),
            Self.message("b1", .user, "   \n"),
            Self.message("a0", .assistant, "  "),
            Self.message("a1", .assistant, "Notice", displayKind: "model_switch"),
            Self.message("r1", .reasoning, "thinking"),
            Self.message("x1", .assistant, "本当の返事")
        ]
        XCTAssertFalse(PersistedTranscriptWindow.containsOwnerExchange(rows), "No real owner row is present")
        XCTAssertTrue(PersistedTranscriptWindow.containsOwnerExchange(rows + [Self.message("u1", .user, "社長の依頼")]))
    }

    // MARK: - Cron dedup

    func testDuplicateCronReportsKeepTheNewestCopyAndLeaveOtherRowsAlone() {
        let rows = [
            Self.cron("10", "A"), Self.cron("11", "B"),
            Self.message("12", .assistant, "same"), Self.message("13", .assistant, "same"),
            Self.cron("20", "A"), Self.cron("21", "B")
        ]
        let kept = PersistedTranscriptWindow.droppingDuplicateCronReports(rows)
        XCTAssertEqual(kept.map(\.id), ["12", "13", "20", "21"], "Newest copy wins; identical replies stay")
    }

    func testDifferentTimesAreDifferentReports() {
        let rows = [Self.cron("1", timestamp: "2026-11-27T09:00:00Z"), Self.cron("2", timestamp: "2026-11-27T10:00:00Z")]
        XCTAssertEqual(PersistedTranscriptWindow.droppingDuplicateCronReports(rows).map(\.id), ["1", "2"])
    }

    func testOlderPageTwinsAreDroppedAgainstHeldKeys() {
        let held = [Self.cron("50", "A"), Self.message("51", .user, "hi")]
        let olderPage = [Self.cron("40", "A"), Self.cron("41", "Z"), Self.message("42", .assistant, "reply")]
        let kept = PersistedTranscriptWindow.droppingDuplicateCronReports(
            olderPage,
            heldKeys: PersistedTranscriptWindow.cronReportKeys(held)
        )
        XCTAssertEqual(kept.map(\.id), ["41", "42"])
    }

    // MARK: - Cap weight

    func testCapIgnoresCronRows() {
        let cap = 200
        let conversation = (0..<200).map { Self.message("m\($0)", $0.isMultiple(of: 2) ? .user : .assistant) }
        let reports = (0..<30).map { Self.cron("c\($0)", "R\($0)") }
        let rows = Array(conversation.prefix(100)) + reports + Array(conversation.suffix(100))
        XCTAssertEqual(PersistedTranscriptWindow.capCount(rows), 200)
        XCTAssertEqual(PersistedTranscriptWindow.heldWeight(rows, cap: cap), 200)
        XCTAssertFalse(PersistedTranscriptWindow.heldWeight(rows, cap: cap) > cap, "200 + 30 cron stays under the cap")
        let over = rows + [Self.message("m200", .user)]
        XCTAssertTrue(PersistedTranscriptWindow.heldWeight(over, cap: cap) > cap, "201 conversation rows pass it")
        // Backstop: a chat of nothing but reports is still bounded.
        let onlyReports = (0..<401).map { Self.cron("o\($0)", "R\($0)") }
        XCTAssertEqual(PersistedTranscriptWindow.heldWeight(onlyReports, cap: cap), 401)
    }

    func testLandingOlderPageDoesNotDetachForCronRows() {
        let live = (100..<200).map { Self.message("\($0)", $0.isMultiple(of: 2) ? .user : .assistant) }
        let page = (0..<100).map { Self.message("\($0)", $0.isMultiple(of: 2) ? .user : .assistant) }
            + (0..<30).map { Self.cron("c\($0)", "R\($0)") }
        let landed = PersistedTranscriptWindow.landingOlderPage(page, live: live, detached: [], cap: 200)
        XCTAssertEqual(landed?.detached.count, 0, "200 rows plus 30 reports stay live")
        XCTAssertEqual(landed?.live.count, 230)

        let longerPage = [Self.message("x", .user)] + page
        let detachedLanding = PersistedTranscriptWindow.landingOlderPage(longerPage, live: live, detached: [], cap: 200)
        XCTAssertFalse(detachedLanding?.detached.isEmpty ?? true, "201 conversation rows detach")
    }

    func testWeightedSplitHelpers() {
        let rows = [Self.message("0", .user), Self.cron("1"), Self.message("2", .assistant), Self.cron("3", "B")]
        XCTAssertEqual(PersistedTranscriptWindow.suffixStart(rows, keepingWeight: 1), 1)
        XCTAssertEqual(PersistedTranscriptWindow.prefixEnd(rows, weight: 1), 2)
        XCTAssertEqual(PersistedTranscriptWindow.suffixStart(rows, keepingWeight: 0), 3)
        XCTAssertEqual(PersistedTranscriptWindow.prefixEnd(rows, weight: 2), 4)
    }

    // MARK: - cronReport parsing

    private static let fixtureNote = """
    [Cron job "社員の候補" report: shown in the chat, no reply asked for]

    1枚目が比較です。

    @image:/Users/laa/.hermes/profiles/laa-monet/images/compare.jpg
    @file:/Users/laa/work/report.pdf
    > @image:/tmp/example.png
    ```
    @image:/tmp/code.png
    ```
    """

    func testCronReportReturnsTitleAndBodyWithoutTheHeader() throws {
        let report = try XCTUnwrap(MessageNormalizer.cronReport(Self.fixtureNote))
        XCTAssertEqual(report.title, "社員の候補")
        XCTAssertFalse(report.body.contains("[Cron job"))
        let lines = report.body.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "1枚目が比較です。")
        XCTAssertTrue(lines.contains("MEDIA:/Users/laa/.hermes/profiles/laa-monet/images/compare.jpg"))
        XCTAssertTrue(lines.contains("MEDIA:/Users/laa/work/report.pdf"))
        XCTAssertTrue(lines.contains("> @image:/tmp/example.png"), "Quoted lines stay")
        XCTAssertTrue(lines.contains("@image:/tmp/code.png"), "Fenced lines stay")
    }

    func testCronReportIsNilForOtherNoticesAndQuotedHeaders() {
        XCTAssertNil(MessageNormalizer.cronReport("Background watch fired.\n@image:/tmp/x.png"))
        XCTAssertNil(MessageNormalizer.cronReport("Quoted: [Cron job \"a\" report: shown in the chat, no reply asked for]"))
        XCTAssertNil(MessageNormalizer.cronReport(""))
    }

    func testCronReportEdgeCases() throws {
        let crlf = try XCTUnwrap(MessageNormalizer.cronReport(
            "[Cron job \"夜の点検\" report: shown in the chat, no reply asked for]\r\n\r\n終わりました"
        ))
        XCTAssertEqual(crlf.title, "夜の点検")
        XCTAssertEqual(crlf.body, "終わりました")
        XCTAssertTrue(MessageNormalizer.isCronReportNote(
            "[Cron job \"夜の点検\" report: shown in the chat, no reply asked for]\r\n\r\n終わりました"
        ))

        let headerOnly = try XCTUnwrap(MessageNormalizer.cronReport(
            "  [Cron job \"空\" report: shown in the chat, no reply asked for]  \n"
        ))
        XCTAssertEqual(headerOnly.title, "空")
        XCTAssertEqual(headerOnly.body, "")

        let japanese = try XCTUnwrap(MessageNormalizer.cronReport(Self.cronNote("LAA完成 v2｜社長判断待ち（J7）", "本文")))
        XCTAssertEqual(japanese.title, "LAA完成 v2｜社長判断待ち（J7）")
        XCTAssertEqual(japanese.body, "本文")
    }

    func testChatListRosterPreviewNeverShowsTheHeader() {
        let choice = LAAChatsPreview.choose(live: nil, cached: nil, roster: Self.cronNote("朝の確認", "異常なし"))
        XCTAssertEqual(choice?.text, "異常なし")
    }

    // MARK: - Run placement

    func testConsecutiveReportsSeparatedOnlyByHiddenRowsFoldIntoOneRun() throws {
        let rows = [Self.cron("c0", "A"), Self.tool("t1"), Self.cron("c2", "B"), Self.cron("c3", "C"),
                    Self.message("u4", .user, "社長"), Self.cron("c5", "D")]
        var cache = ChatMessageScrollTargetCache()
        cache.update(for: rows)
        let targets = cache.targets
        XCTAssertEqual(targets.map(\.id), rows.map(\.id), "Ids and order are unchanged")
        XCTAssertEqual(targets.map(\.order), Array(0..<rows.count))
        XCTAssertEqual(Set(targets.map(\.semanticID)).count, rows.count)

        let lead = try XCTUnwrap(targets[0].notice)
        XCTAssertEqual(lead.runID, "c0")
        XCTAssertEqual(lead.count, 3)
        XCTAssertEqual(lead.index, 0)
        XCTAssertEqual(lead.latestTitle, "C")
        XCTAssertEqual(targets[2].notice?.index, 1)
        XCTAssertEqual(targets[3].notice?.index, 2)
        XCTAssertEqual(targets[3].notice?.runID, "c0")
        XCTAssertNil(targets[1].notice, "A hidden row is no member")
        XCTAssertNil(targets[4].notice)
        XCTAssertNil(targets[5].notice, "A report on its own draws as a single card")

        let semanticIDs = targets.map(\.semanticID)
        cache.update(for: rows + [Self.cron("c6", "E")])
        XCTAssertEqual(Array(cache.targets.prefix(rows.count).map(\.semanticID)), semanticIDs)
        XCTAssertEqual(cache.targets[5].notice?.runID, "c5", "An appended report starts a run under the older one")
        XCTAssertEqual(cache.targets[6].notice?.runID, "c5")
        XCTAssertEqual(cache.targets[0].notice?.runID, "c0")
    }

    func testRunIDStaysWhenAReportIsAppended() {
        var cache = ChatMessageScrollTargetCache()
        let rows = [Self.message("u", .user, "社長"), Self.cron("c1", "A"), Self.cron("c2", "B")]
        cache.update(for: rows)
        XCTAssertEqual(cache.targets[1].notice?.runID, "c1")
        cache.update(for: rows + [Self.cron("c3", "C")])
        XCTAssertEqual(cache.targets[1].notice?.runID, "c1")
        XCTAssertEqual(cache.targets[1].notice?.count, 3)
        XCTAssertEqual(cache.targets[3].notice?.index, 2)
        XCTAssertEqual(cache.targets[3].notice?.latestTitle, "C")
    }

    func testCollapsedRunDrawsOnlyItsLead() {
        var cache = ChatMessageScrollTargetCache()
        cache.update(for: [Self.cron("c1", "A"), Self.cron("c2", "B"), Self.cron("c3", "C")])
        let disclosure = ChatRowDisclosure()
        let preferences = ProfileDisplayPreferences()
        let drawn = { cache.targets.filter { $0.drawsRow(preferences: preferences, isBusy: false, disclosure: disclosure) }.map(\.id) }
        XCTAssertEqual(drawn(), ["c1"])
        disclosure.willToggleNoticeRun("c1", to: true)
        XCTAssertEqual(drawn(), ["c1", "c2", "c3"])
        disclosure.willToggleNoticeRun("c1", to: false)
        XCTAssertEqual(drawn(), ["c1"])
    }

    // MARK: - Harness: the open walks to the last exchange

    private static let cronNames = ["朝の確認", "市場メモ", "予定", "健康", "学習", "発信", "経理", "夜の点検"]

    private static func rawCron(_ id: Int, nameIndex: Int) -> [String: Any] {
        [
            "id": id,
            "role": "user",
            "display_kind": "internal_notification",
            "content": cronNote(cronNames[nameIndex], "報告 \(nameIndex)"),
            "timestamp": String(format: "2026-11-27T%02d:00:00Z", nameIndex + 1)
        ]
    }

    private static func rawTool(_ id: Int) -> [String: Any] {
        ["id": id, "role": "tool", "tool_call_id": "call-\(id)", "content": "ok \(id)", "timestamp": "2026-11-27T08:00:00Z"]
    }

    private static func rawText(_ id: Int, _ role: String, _ content: String) -> [String: Any] {
        ["id": id, "role": role, "content": content, "timestamp": "2026-11-26T08:00:00Z"]
    }

    /// The newest 40 rows of Monet's chat on 2026-11-28: 23 tool rows, one
    /// hidden row, then compaction's copy of 8 reports and the 8 reports.
    private static var monetPageZero: [[String: Any]] {
        (46830..<46853).map(rawTool)
            + [["id": 46853, "role": "user", "display_kind": "hidden", "content": "hidden", "timestamp": "2026-11-27T08:00:00Z"] as [String: Any]]
            + (0..<8).map { rawCron(46854 + $0, nameIndex: $0) }
            + (0..<8).map { rawCron(46862 + $0, nameIndex: $0) }
    }

    /// The 120 rows before it, holding the last exchange.
    private static var monetPageOne: [[String: Any]] {
        (46710..<46830).map { id -> [String: Any] in
            switch id {
            case 46791: return rawText(id, "user", "社長の依頼")
            case 46792: return rawText(id, "assistant", "Monetの返事")
            case 46808: return rawText(id, "assistant", "続きの返事")
            default: return rawTool(id)
            }
        }
    }

    private static func payload(_ rows: [[String: Any]], offset: Int, limit: Int, sessionId: String = "stored-a") -> PersistedTranscriptFetchOutcome {
        .payload([
            "session_id": sessionId,
            "messages": rows,
            "pagination": ["offset": offset, "returned": rows.count, "limit": limit, "order": "latest"]
        ])
    }

    private static func offset(in query: String) -> Int {
        guard let item = URLComponents(string: "https://x.example/" + query)?.queryItems?.first(where: { $0.name == "offset" }),
              let value = item.value.flatMap(Int.init) else { return -1 }
        return value
    }

    private final class Queries {
        var all: [String] = []
    }

    private func makeHarness(
        queries: Queries,
        page: @escaping (Int) -> PersistedTranscriptFetchOutcome
    ) throws -> AppState {
        let suite = "LAACronReportDisplayTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite),
              let cacheDefaults = UserDefaults(suiteName: suite + ".cache") else {
            throw FixtureError.unusableSuite
        }
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            cacheDefaults.removePersistentDomain(forName: suite + ".cache")
        }
        let sessions = [SessionSummary(
            id: "stored-a", alternateIds: ["runtime-a"], title: "Monet", model: "Hermes", updatedLabel: "now",
            profile: "default", source: .chat, isActive: false, isArchived: false, lineageRootId: nil
        )]
        var operations = ChatResumeLifecycleOperations(
            openSession: { _, _, _ in
                SessionResumeResult(
                    sessionId: "runtime-a",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _, query in
                queries.all.append(query)
                return page(Self.offset(in: query))
            },
            loadEarlierTranscriptPage: { _, _, offset in
                page(offset)
            }
        )
        operations.connectClient = { _ in }
        operations.loadCatalog = { _, _ in sessions }
        operations.loadProfiles = {}
        operations.loadBusyInputMode = { _ in }
        operations.loadProfileDisplayPreferences = {}
        operations.loadSlashCommands = {}
        let appState = AppState(
            defaults: defaults,
            chatResumeCoordinator: ChatResumeCoordinator(store: ChatResumeStore(defaults: defaults)),
            recoverySequence: ChatResumeRecoverySequence(),
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            chatResumeLifecycleOperations: operations,
            sessionPresentationCache: SessionPresentationCache(defaults: cacheDefaults)
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.sessions = sessions
        appState.heldTranscriptRowCapForTesting = PersistedTranscriptPagination.maxHeldRows
        return appState
    }

    func testMonetReplicaOpensToTheLastExchangeWithEachReportOnce() async throws {
        let queries = Queries()
        let appState = try makeHarness(queries: queries) { offset in
            switch offset {
            case 0: return Self.payload(Self.monetPageZero, offset: 0, limit: 40)
            case 40: return Self.payload(Self.monetPageOne, offset: 40, limit: 120)
            default: return Self.payload([], offset: offset, limit: 120)
            }
        }
        let opened = await appState.openSession("stored-a")
        XCTAssertTrue(opened)
        XCTAssertEqual(queries.all, [
            PersistedTranscriptPagination.tailQuery(offset: 0),
            "?limit=120&offset=40&order=latest&include_compacted=true&inline_images=false"
        ])
        let ids = Set(appState.messages.map(\.id))
        XCTAssertTrue(ids.isSuperset(of: ["46791", "46792", "46808"]), "The last exchange is on screen")
        XCTAssertEqual(appState.messages.filter(\.isCronReport).count, 8, "Each report shows once")
        XCTAssertEqual(
            Set(appState.messages.filter(\.isCronReport).map(\.id)),
            Set((46862..<46870).map(String.init)),
            "The newest copy of each report stays"
        )
        XCTAssertFalse(appState.messages.contains { MessageNormalizer.cronReport($0.content) == nil && $0.content.contains("[Cron job") })
        let window = try XCTUnwrap(appState.persistedTranscriptWindow)
        XCTAssertEqual(window.nextOffset, 160)
        XCTAssertTrue(window.canLoadEarlier)
    }

    func testNormalChatMakesExactlyOneRequest() async throws {
        let queries = Queries()
        let rows = (1000..<1040).map { Self.rawText($0, $0.isMultiple(of: 2) ? "user" : "assistant", "Row \($0)") }
        let appState = try makeHarness(queries: queries) { offset in
            Self.payload(offset == 0 ? rows : [], offset: offset, limit: 40)
        }
        _ = await appState.openSession("stored-a")
        XCTAssertEqual(queries.all, [PersistedTranscriptPagination.tailQuery(offset: 0)])
        XCTAssertEqual(appState.persistedTranscriptWindow?.nextOffset, 40)
    }

    func testShortChatMakesOneRequest() async throws {
        let queries = Queries()
        let appState = try makeHarness(queries: queries) { offset in
            Self.payload(offset == 0 ? [Self.rawText(1, "user", "はじめまして")] : [], offset: offset, limit: 40)
        }
        _ = await appState.openSession("stored-a")
        XCTAssertEqual(queries.all.count, 1)
        XCTAssertEqual(appState.persistedTranscriptWindow?.canLoadEarlier, false)
    }

    func testWalkStopsAtItsBudget() async throws {
        let queries = Queries()
        let appState = try makeHarness(queries: queries) { offset in
            let limit = offset == 0 ? 40 : 120
            let upper = 10_000 - offset
            return Self.payload((upper - limit..<upper).map(Self.rawTool), offset: offset, limit: limit)
        }
        _ = await appState.openSession("stored-a")
        XCTAssertEqual(queries.all.count, 1 + PersistedTranscriptPagination.ownerTurnWalkPages)
        let window = try XCTUnwrap(appState.persistedTranscriptWindow)
        XCTAssertEqual(window.nextOffset, 400)
        XCTAssertTrue(window.canLoadEarlier, "Older rows remain past the budget")
    }

    func testShortWalkPageRetiresLoadEarlier() async throws {
        let queries = Queries()
        let appState = try makeHarness(queries: queries) { offset in
            if offset == 0 { return Self.payload((960..<1000).map(Self.rawTool), offset: 0, limit: 40) }
            return Self.payload((950..<960).map(Self.rawTool), offset: offset, limit: 120)
        }
        _ = await appState.openSession("stored-a")
        XCTAssertEqual(queries.all.count, 2)
        let window = try XCTUnwrap(appState.persistedTranscriptWindow)
        XCTAssertEqual(window.nextOffset, 50)
        XCTAssertFalse(window.canLoadEarlier, "The beginning was reached")
    }

    func testFailedWalkPageKeepsTheFirstPage() async throws {
        let queries = Queries()
        let appState = try makeHarness(queries: queries) { offset in
            if offset == 0 { return Self.payload(Self.monetPageZero, offset: 0, limit: 40) }
            return .failed(URLError(.timedOut))
        }
        let opened = await appState.openSession("stored-a")
        XCTAssertTrue(opened, "The walk never fails the open")
        XCTAssertEqual(queries.all.count, 2)
        XCTAssertEqual(appState.messages.filter(\.isCronReport).count, 8)
        let window = try XCTUnwrap(appState.persistedTranscriptWindow)
        XCTAssertEqual(window.nextOffset, 40)
        XCTAssertTrue(window.canLoadEarlier)
    }

    func testDriftOverlapIsDroppedByRowID() async throws {
        let queries = Queries()
        let appState = try makeHarness(queries: queries) { offset in
            if offset == 0 { return Self.payload(Self.monetPageZero, offset: 0, limit: 40) }
            // Rows persisted meanwhile shifted the origin by five: the page
            // repeats the five oldest rows already held.
            return Self.payload(Array(Self.monetPageOne.suffix(115)) + Array(Self.monetPageZero.prefix(5)), offset: offset, limit: 120)
        }
        _ = await appState.openSession("stored-a")
        let ids = appState.messages.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "No row shows twice")
        XCTAssertTrue(Set(ids).isSuperset(of: ["46791", "46792"]))
    }

    func testPostSendVerificationNeverWalks() async throws {
        let queries = Queries()
        let rows = (1000..<1040).map { Self.rawText($0, $0.isMultiple(of: 2) ? "user" : "assistant", "Row \($0)") }
        let appState = try makeHarness(queries: queries) { offset in
            if offset == 0 { return Self.payload(rows, offset: 0, limit: 40) }
            return Self.payload((0..<120).map { Self.rawTool(500 + $0) }, offset: offset, limit: 120)
        }
        _ = await appState.openSession("stored-a")
        let afterOpen = queries.all.count
        _ = await appState.sendMessage("Hello")
        XCTAssertFalse(
            queries.all.dropFirst(afterOpen).contains { $0.contains("limit=120") },
            "Only the open walks; a send's verification reads one tail page"
        )
    }

    // MARK: - Offline copy

    private func cacheDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private static let row = SessionSummary(
        id: "stored-a", alternateIds: [], title: "Monet", model: "Hermes", updatedLabel: "now",
        profile: "default", source: .chat, isActive: false, isArchived: false, lineageRootId: nil
    )

    func testTurnlessRecordDoesNotReplaceACopyWithTurns() {
        let store = OfflineChatCacheStore(directory: cacheDirectory())
        let dashboard = UUID()
        store.record(dashboardID: dashboard, profile: "default", sessionID: "stored-a", title: "Monet",
                     messages: [Self.message("1", .user, "社長の依頼"), Self.message("2", .assistant, "返事")],
                     sessions: [Self.row])
        store.record(dashboardID: dashboard, profile: "default", sessionID: "stored-a", title: "Monet",
                     messages: [Self.cron("c1"), Self.tool("t1")],
                     sessions: [Self.row])
        let saved = store.loadTranscript("stored-a", dashboardID: dashboard, profile: "default")
        XCTAssertEqual(saved?.messages.map(\.id), ["1", "2"])

        store.record(dashboardID: dashboard, profile: "default", sessionID: "stored-a", title: "Monet",
                     messages: [Self.message("3", .user, "次の依頼"), Self.cron("c2")],
                     sessions: [Self.row])
        XCTAssertEqual(store.loadTranscript("stored-a", dashboardID: dashboard, profile: "default")?.messages.map(\.id), ["3", "c2"],
                       "A record with turns still replaces the copy")
    }

    func testOwnerTurnSurvivesACronAndToolTail() {
        let store = OfflineChatCacheStore(directory: cacheDirectory())
        let dashboard = UUID()
        let tail = (0..<80).map { Self.tool("t\($0)") } + (0..<60).map { Self.cron("c\($0)", "R\($0)") }
        store.record(dashboardID: dashboard, profile: "default", sessionID: "stored-a", title: "Monet",
                     messages: [Self.message("u", .user, "社長の依頼"), Self.message("a", .assistant, "返事")] + tail,
                     sessions: [Self.row])
        let ids = store.loadTranscript("stored-a", dashboardID: dashboard, profile: "default")?.messages.map(\.id) ?? []
        XCTAssertTrue(ids.contains("u"))
        XCTAssertTrue(ids.contains("a"))
    }

    // MARK: - Warm copy

    private static func presentation(displayed: String?, saved: [String]) -> OfflineChatPresentation {
        let transcripts = saved.map {
            OfflineCachedTranscript(sessionID: $0, title: $0, savedAt: Date(timeIntervalSince1970: 0), messages: [])
        }
        return OfflineChatPresentation(
            dashboardID: UUID(),
            profile: "default",
            snapshot: OfflineChatSnapshot(
                lastSessionID: displayed,
                sessions: [],
                transcripts: transcripts.map(OfflineCachedTranscriptEntry.init)
            ),
            displayedTranscript: transcripts.first { $0.sessionID == displayed }
        )
    }

    func testWarmCopyShowsWhenThePreferredChatHasNoCopyOfItsOwn() {
        let warm = Self.presentation(displayed: "a", saved: ["a", "c"])
        XCTAssertTrue(LAAEmployeeChatPreview.acceptsWarmCopy(warm, preferredSessionID: nil))
        XCTAssertTrue(LAAEmployeeChatPreview.acceptsWarmCopy(warm, preferredSessionID: "a"))
        XCTAssertTrue(LAAEmployeeChatPreview.acceptsWarmCopy(warm, preferredSessionID: "b"), "No copy for b: the last chat shows, as load() falls back")
        XCTAssertFalse(LAAEmployeeChatPreview.acceptsWarmCopy(warm, preferredSessionID: "c"), "c has its own copy")
    }
}
#endif

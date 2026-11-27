#if LAA_BUILD
import XCTest
@testable import Conduit

/// D-25 display window: "Load earlier messages" past the held-row cap keeps
/// a bounded amount on screen. Older history detaches above the live rows
/// (`PersistedTranscriptWindowState.detachedEarlier`), and `messages` stays
/// the contiguous live suffix every other path reads.
@MainActor
final class LAAHeldTranscriptWindowTests: XCTestCase {
    private enum FixtureError: Error {
        case unusableSuite
    }

    private static let cap = PersistedTranscriptPagination.maxHeldRows
    private static let newestRow = 2000
    private static let tailSize = 120
    private static let pageSize = 40

    // MARK: - 1. Ten older pages stay bounded

    func testTenOlderPagesStayBoundedAndKeepTheNewestFetchedPage() async throws {
        let harness = try makeHarness()
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.count, Self.tailSize)

        var detachedOnce = false
        for tap in 0..<10 {
            let offsetBefore = try XCTUnwrap(harness.appState.persistedTranscriptWindow?.nextOffset)
            let landed = await harness.appState.loadEarlierMessages()
            XCTAssertTrue(landed, "Tap \(tap) must show something")
            let window = try XCTUnwrap(harness.appState.persistedTranscriptWindow)
            let held = window.detachedEarlier + harness.appState.messages
            XCTAssertLessThanOrEqual(held.count, Self.cap, "Tap \(tap) passed the display cap")
            let heldIDs = Set(held.map(\.id))
            let fetched = Self.pageIDs(offset: offsetBefore)
            XCTAssertTrue(fetched.isSubset(of: heldIDs), "Tap \(tap) evicted the page it just fetched")
            let numeric = held.compactMap { Int($0.id) }
            XCTAssertEqual(numeric, numeric.sorted(), "Tap \(tap) broke chronology")
            XCTAssertEqual(Set(numeric).count, numeric.count, "Tap \(tap) duplicated a row")
            XCTAssertEqual(harness.appState.messages.last?.id, "\(Self.newestRow - 1)", "The live tail stays")
            if !window.detachedEarlier.isEmpty {
                detachedOnce = true
                XCTAssertFalse(window.hasBackfilledPrefix, "A reconcile must never graft onto detached history")
            }
        }
        XCTAssertTrue(detachedOnce, "Ten pages must pass the cap and detach")
    }

    // MARK: - 2. Live delta, send and reconcile see only the live rows

    func testLiveDeltaSendAndReconcileWhileDetachedMatchARunWithoutTheBuffer() async throws {
        let refreshed = Flag()
        let detachedRun = try makeHarness(refreshedTail: refreshed)
        let plainRun = try makeHarness(cap: nil, refreshedTail: refreshed)
        _ = await detachedRun.appState.openSession("stored-a")
        _ = await plainRun.appState.openSession("stored-a")
        try await detach(detachedRun.appState)
        let detached = try XCTUnwrap(detachedRun.appState.persistedTranscriptWindow?.detachedEarlier)
        plainRun.appState.messages = detachedRun.appState.messages

        for state in [detachedRun.appState, plainRun.appState] {
            state.handleStreamEvent(.messageStart(sessionId: "runtime-a"))
            state.handleStreamEvent(.messageDelta(sessionId: "runtime-a", text: "Live reply"))
            state.handleStreamEvent(.messageComplete(sessionId: "runtime-a", messageId: "live-1", content: "Live reply", reasoning: nil))
        }
        XCTAssertEqual(detachedRun.appState.messages, plainRun.appState.messages, "A live delta lands only on the live rows")
        XCTAssertEqual(detachedRun.appState.persistedTranscriptWindow?.detachedEarlier, detached, "A live delta leaves detached history alone")

        _ = await detachedRun.appState.sendMessage("Hello")
        _ = await plainRun.appState.sendMessage("Hello")
        XCTAssertEqual(detachedRun.appState.messages, plainRun.appState.messages, "A send lands only on the live rows")
        XCTAssertEqual(detachedRun.appState.persistedTranscriptWindow?.detachedEarlier ?? [], [], "A send clears detached history")

        try await detach(detachedRun.appState)
        refreshed.isOn = true
        for run in [detachedRun, plainRun] {
            run.coordinator.rememberSession(.dashboard(profile: "default", sessionID: "stored-a"), for: "default")
            await run.appState.connect(with: HermesConnection(baseUrl: "https://one.example", ticket: "reconcile-ticket"))
        }
        XCTAssertEqual(detachedRun.appState.messages, plainRun.appState.messages, "A reconcile refreshes the live rows the same way")
        XCTAssertEqual(detachedRun.appState.persistedTranscriptWindow?.detachedEarlier ?? [], [])
    }

    // MARK: - 3. The offline copy holds only live rows

    func testOfflineCopyNeverHoldsDetachedRows() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LAAHeldTranscriptWindowTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = OfflineChatCacheStore(directory: directory)
        let dashboard = SavedDashboard(id: UUID(), label: "One", normalizedURL: "https://one.example")
        let registry = SavedDashboardRegistry(activeDashboardID: dashboard.id, dashboards: [dashboard])
        let harness = try makeHarness(registry: registry, offlineChatCache: store)
        _ = await harness.appState.openSession("stored-a")
        try await detach(harness.appState)
        let detachedIDs = Set(try XCTUnwrap(harness.appState.persistedTranscriptWindow?.detachedEarlier).map(\.id))
        XCTAssertFalse(detachedIDs.isEmpty)

        harness.appState.isConnected = true
        harness.appState.recordOfflineChatCopy()

        let copy = try XCTUnwrap(store.loadTranscript("stored-a", dashboardID: dashboard.id, profile: "default"))
        XCTAssertFalse(copy.messages.isEmpty)
        XCTAssertTrue(Set(copy.messages.map(\.id)).isDisjoint(with: detachedIDs), "Detached rows never reach the offline copy")
        XCTAssertEqual(copy.messages.map(\.id), harness.appState.messages.suffix(OfflineChatCacheStore.maxMessagesPerTranscript).map(\.id))
    }

    // MARK: - 4. A trim never splits a tool run

    func testSafeBoundaryTrimNeverSplitsAToolCallFromItsResult() throws {
        var rows: [ChatMessage] = []
        for turn in 0..<12 {
            rows.append(message("u\(turn)", .user))
            rows.append(message("a\(turn)", .assistant))
            // A run whose result arrives after a steer: no cut may land there.
            rows.append(toolRow("call\(turn)", toolID: "t\(turn)", output: nil, status: .running))
            if turn.isMultiple(of: 3) {
                rows.append(message("steer\(turn)", .user, displayKind: ChatMessage.steerDisplayKind))
            }
            if turn.isMultiple(of: 4) {
                rows.append(message("late\(turn)", .user))
            }
            rows.append(toolRow("result\(turn)", toolID: "t\(turn)", output: "done", status: .complete))
        }

        for keep in 0...(rows.count + 1) {
            let split = PersistedTranscriptWindow.safeSplitIndex(rows, keepingLast: keep)
            guard split > 0 else { continue }
            XCTAssertEqual(rows[split].role, .user, "keep \(keep)")
            XCTAssertFalse(rows[split].isSteer, "keep \(keep): a steer is mid-turn")
            assertNoToolRunSplit(Array(rows[..<split]), Array(rows[split...]), "keep \(keep)")
        }
        for liveCount in 0..<rows.count {
            let evicted = PersistedTranscriptWindow.evictingNewest(rows, protecting: 3, liveCount: liveCount, cap: rows.count - 1)
            XCTAssertGreaterThanOrEqual(evicted.count, 3, "The fetched page is never evicted")
            // Above the protected page, eviction cuts only at a safe turn start.
            guard evicted.count > 3, evicted.count < rows.count else { continue }
            assertNoToolRunSplit(evicted, Array(rows[evicted.count...]), "live \(liveCount)")
        }
        let landed = try XCTUnwrap(PersistedTranscriptWindow.landingOlderPage(
            Array(rows.dropLast(10)),
            live: Array(rows.suffix(10)),
            detached: [],
            cap: 20,
            liveTailKeep: 8
        ))
        XCTAssertFalse(landed.detached.isEmpty, "Past the cap the older rows detach")
        XCTAssertEqual(landed.live.first?.role, .user)
        XCTAssertFalse(landed.live.first?.isSteer ?? true)
        assertNoToolRunSplit(landed.detached, landed.live, "detach")
    }

    // MARK: - 5. Session switch and jump to latest clear detached history

    func testSessionSwitchAndJumpToLatestClearDetachedHistory() async throws {
        let harness = try makeHarness()
        _ = await harness.appState.openSession("stored-a")
        try await detach(harness.appState)

        harness.appState.jumpToLatestFromDetachedHistory()
        let jumped = try XCTUnwrap(harness.appState.persistedTranscriptWindow)
        XCTAssertEqual(jumped.detachedEarlier, [])
        XCTAssertEqual(jumped.nextOffset, harness.appState.messages.count, "Backfill restarts from the live rows")
        XCTAssertTrue(jumped.canLoadEarlier)
        let reloaded = await harness.appState.loadEarlierMessages()
        XCTAssertTrue(reloaded, "Load earlier works again from the live tail")

        try await detach(harness.appState)
        let openedB = await harness.appState.openSession("stored-b")
        XCTAssertTrue(openedB)
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.requestedSessionID, "stored-b")
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.detachedEarlier ?? [], [])
        XCTAssertEqual(harness.appState.messages.map(\.content), ["Row 5001", "Row 5002"], "No row of session A follows into B")
    }

    // MARK: - Helpers

    private func detach(_ appState: AppState, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<10 {
            if appState.persistedTranscriptWindow?.detachedEarlier.isEmpty == false { return }
            _ = await appState.loadEarlierMessages()
        }
        XCTAssertFalse(appState.persistedTranscriptWindow?.detachedEarlier.isEmpty ?? true, "Never detached", file: file, line: line)
    }

    private func assertNoToolRunSplit(_ before: [ChatMessage], _ after: [ChatMessage], _ label: String) {
        let beforeIDs = Set(before.compactMap { $0.role == .tool ? $0.tool?.id : nil })
        let afterIDs = Set(after.compactMap { $0.role == .tool ? $0.tool?.id : nil })
        XCTAssertTrue(beforeIDs.isDisjoint(with: afterIDs), "\(label): a tool run was split")
    }

    private static func pageIDs(offset: Int) -> Set<String> {
        let upper = newestRow - offset
        return Set((max(1, upper - pageSize)..<upper).map(String.init))
    }

    private func message(_ id: String, _ role: MessageRole, displayKind: String? = nil) -> ChatMessage {
        ChatMessage(id: id, role: role, content: id, timestamp: "1", displayKind: displayKind)
    }

    private func toolRow(_ id: String, toolID: String, output: String?, status: ToolActivity.Status) -> ChatMessage {
        ChatMessage(
            id: id,
            role: .tool,
            content: "",
            timestamp: "1",
            tool: ToolActivity(id: toolID, name: "terminal", input: nil, output: output, status: status)
        )
    }

    private final class Flag {
        var isOn = false
    }

    private func makeHarness(
        cap: Int? = PersistedTranscriptPagination.maxHeldRows,
        refreshedTail: Flag? = nil,
        registry: SavedDashboardRegistry? = nil,
        offlineChatCache: OfflineChatCacheStore? = nil
    ) throws -> (appState: AppState, coordinator: ChatResumeCoordinator) {
        let suite = "LAAHeldTranscriptWindowTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite),
              let cacheDefaults = UserDefaults(suiteName: suite + ".cache") else {
            throw FixtureError.unusableSuite
        }
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            cacheDefaults.removePersistentDomain(forName: suite + ".cache")
        }
        let sessions = [session("stored-a", runtime: "runtime-a"), session("stored-b", runtime: "runtime-b")]
        var operations = ChatResumeLifecycleOperations(
            openSession: { _, requestedID, _ in
                SessionResumeResult(
                    sessionId: requestedID == "stored-b" ? "runtime-b" : "runtime-a",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { sessionId, _, _ in
                if sessionId == "stored-b" {
                    return Self.payload(sessionId: "stored-b", rows: Self.rows(5001..<5003), offset: 0, limit: Self.tailSize)
                }
                let newest = refreshedTail?.isOn == true ? Self.newestRow + 20 : Self.newestRow
                return Self.payload(sessionId: "stored-a", rows: Self.rows((newest - Self.tailSize)..<newest), offset: 0, limit: Self.tailSize)
            },
            loadEarlierTranscriptPage: { _, _, offset in
                let upper = Self.newestRow - offset
                return Self.payload(sessionId: "stored-a", rows: Self.rows(max(1, upper - Self.pageSize)..<upper), offset: offset, limit: Self.pageSize)
            }
        )
        operations.connectClient = { _ in }
        operations.loadCatalog = { _, _ in sessions }
        operations.loadProfiles = {}
        operations.loadBusyInputMode = { _ in }
        operations.loadProfileDisplayPreferences = {}
        operations.loadSlashCommands = {}
        let coordinator = ChatResumeCoordinator(store: ChatResumeStore(defaults: defaults))
        let appState = AppState(
            defaults: defaults,
            chatResumeCoordinator: coordinator,
            recoverySequence: ChatResumeRecoverySequence(),
            loadSavedConnection: false,
            dashboardRegistry: registry,
            clearSessionPresentationCache: {},
            chatResumeLifecycleOperations: operations,
            sessionPresentationCache: SessionPresentationCache(defaults: cacheDefaults),
            offlineChatCache: offlineChatCache
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.sessions = sessions
        appState.heldTranscriptRowCapForTesting = cap
        return (appState, coordinator)
    }

    private func session(_ id: String, runtime: String) -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: [runtime],
            title: id,
            model: "Hermes",
            updatedLabel: "now",
            profile: "default",
            source: .chat,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
    }

    private static func rows(_ range: Range<Int>) -> [[String: Any]] {
        range.map { index in
            [
                "id": index,
                "role": index.isMultiple(of: 2) ? "user" : "assistant",
                "content": "Row \(index)",
                "timestamp": String(format: "2026-09-01T%02d:%02d:00Z", 10 + (index / 60) % 10, index % 60)
            ]
        }
    }

    private static func payload(sessionId: String, rows: [[String: Any]], offset: Int, limit: Int) -> PersistedTranscriptFetchOutcome {
        .payload([
            "session_id": sessionId,
            "messages": rows,
            "pagination": ["offset": offset, "returned": rows.count, "limit": limit, "order": "latest"]
        ])
    }
}
#endif

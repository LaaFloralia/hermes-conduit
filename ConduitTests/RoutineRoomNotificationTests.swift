import XCTest
@testable import Conduit

@MainActor
final class RoutineRoomNotificationTests: XCTestCase {
    func testDeliveryIdentityKeepsExactRoomAndReport() throws {
        let event = "routine:" + String(repeating: "a", count: 64)
        let report = try XCTUnwrap(RoutineRoomNotification.parse("laa-routine:laa-routines:42:" + event))
        XCTAssertEqual(report.roomID, "laa-routines")
        XCTAssertEqual(report.seq, 42)
        XCTAssertEqual(report.eventID, event)
    }

    func testMalformedRoomOrEventCannotFallIntoPersonalChat() {
        let event = "routine:" + String(repeating: "a", count: 64)
        for value in ["cron_abc", "laa-routine:other:42:" + event,
                      "laa-routine:laa-routines:0:" + event,
                      "laa-routine:laa-routines:42:wrong",
                      "laa-routine:laa-routines:42:" + event + ":extra"] {
            XCTAssertNil(RoutineRoomNotification.parse(value))
        }
    }

    func testPushOpensStoredReportAfterFreshAppStateWithoutSwitchingEmployee() async throws {
        let eventID = "routine:" + String(repeating: "b", count: 64)
        let room = GroupRoom(roomID: "laa-routines", name: "定期実行", members: [],
            authorityGatewayID: "test", authorityEpoch: 1, revision: 1,
            createdAt: 0, updatedAt: 0, disbandedAt: nil, latestSeq: 900)
        let report = GroupEvent(roomID: room.roomID, seq: 42, eventID: eventID,
            kind: "message.member", actor: GroupActor(kind: "member", id: "laa-cio",
            profile: "laa-cio", displayName: "Sherlock", connectionID: nil),
            authorityEpoch: 1, payload: ["text": AnyCodable(jsonObject: "## Daily\n担当: Sherlock · model\n\nSaved report")], createdAt: 0)
        var starts: [Int] = []
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in GroupCapabilities(protocolVersion: 2, driverReady: true,
                authorityGatewayID: "test", features: [], methods: GroupWire.requiredMethods, maxLogLimit: 500) },
            list: { _ in ([room], nil) }, state: { _, _ in (room, nil) },
            log: { _, _, since, _ in
                starts.append(since)
                return GroupLogPage(events: [report], cursor: 42, latestSeq: 900,
                    hasMore: true, authorityGatewayID: "test", authorityEpoch: 1)
            })
        // A new AppState has no kept room replay. Both the initial tap and
        // the cold reopen must read the authoritative event, even outside
        // the latest tail, without changing the personal chat's profile.
        KeychainHelper.useBackendForTesting(InMemoryKeychainBackend())
        defer { KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend()) }
        for _ in 0..<2 {
            let suite = "RoutineRoomNotificationTests-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let dashboard = SavedDashboard(id: UUID(), label: "Routines", normalizedURL: "https://routine.example")
            let state = AppState(defaults: defaults, loadSavedConnection: false,
                dashboardRegistry: SavedDashboardRegistry(activeDashboardID: dashboard.id, dashboards: [dashboard]),
                clearSessionPresentationCache: {}, groupChatOperations: operations,
                sessionPresentationCache: SessionPresentationCache(defaults: defaults))
            let connection = HermesConnection(baseUrl: dashboard.normalizedURL, ticket: "test")
            state.connection = connection
            state.client = HermesClient(connection: connection, profile: "default")
            state.isConnected = true
            let profile = state.activeProfile
            let target = ConduitNotificationTarget(profile: "laa-cio",
                sessionId: "laa-routine:laa-routines:42:" + eventID,
                dashboardID: dashboard.id, type: "response.ready")
            let outcome = await state.openNotificationTargetOutcome(target)
            XCTAssertTrue(outcome == .opened)
            XCTAssertEqual(state.activeProfile, profile)
            XCTAssertEqual(state.activeRoomSurface?.room.roomID, room.roomID)
            XCTAssertEqual(state.roomNotificationFocusEventID, eventID)
            let displayed = try XCTUnwrap(state.activeRoomReplay.events.first)
            XCTAssertEqual(displayed.messageText, report.messageText)
            state.closeGroupRoom()
        }
        XCTAssertEqual(starts, [41, 41], "each cold open loads the notified report, not just the latest tail")
    }

    func testFocusedReportSurvivesHistoryCatchupTrimming() {
        func event(_ seq: Int) -> GroupEvent {
            GroupEvent(roomID: "laa-routines", seq: seq, eventID: "report-\(seq)", kind: "message.member",
                actor: GroupActor(kind: "member", id: "laa-monet", profile: "laa-monet", displayName: "Monet", connectionID: nil),
                authorityEpoch: 1, payload: ["text": AnyCodable(jsonObject: "Report \(seq)")], createdAt: 0)
        }
        func page(_ events: [GroupEvent]) -> GroupLogPage {
            GroupLogPage(events: events, cursor: events.last?.seq ?? 0, latestSeq: 600,
                hasMore: false, authorityGatewayID: "test", authorityEpoch: 1)
        }
        var replay = GroupRoomReplay(roomID: "laa-routines")
        replay.adoptInitialTail(page: page([event(1)]))
        replay.adopt(page: page((2...600).map(event)), preserving: "report-1")
        XCTAssertEqual(replay.events.first?.eventID, "report-1")
        XCTAssertEqual(replay.cursor, 600)
        XCTAssertLessThanOrEqual(replay.events.count, GroupRoomReplay.tailWindow + 1)
    }
}

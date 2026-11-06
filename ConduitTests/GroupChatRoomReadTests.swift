import XCTest

@testable import Conduit

/// The Chats list's room read is one call: the capability probe and the room
/// list together. A failed read is its own answer (never an empty list), the
/// last rooms stay on screen, and a read that lost its dashboard or was
/// cancelled is not adopted.
@MainActor
final class GroupChatRoomReadTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuite: String!

    override func setUp() async throws {
        defaultsSuite = "GroupChatRoomReadTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: defaultsSuite)
    }

    private struct TestError: Error {}

    private final class RoomListCallCounter {
        var calls = 0
    }

    /// Holds the room read open so a switch or a cancel can land while it
    /// runs. The continuation is registered before the test is told the read
    /// started, and a release that arrives first is remembered, so neither
    /// ordering can leak the continuation.
    @MainActor
    private final class RoomReadGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isReleased = false

        func wait(_ registered: () -> Void) async {
            guard !isReleased else { return registered() }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                registered()
            }
        }

        func release() {
            isReleased = true
            continuation?.resume()
            continuation = nil
        }
    }

    private func makeAppState(operations: GroupChatLifecycleOperations) -> AppState {
        AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            chatResumeLifecycleOperations: .live,
            groupChatOperations: operations,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
    }

    private func connect(_ appState: AppState, url: String = "https://groups.example") {
        appState.client = HermesClient(
            connection: HermesConnection(baseUrl: url, ticket: "groups-test"),
            profile: "default"
        )
        appState.isConnected = true
        _ = appState.adoptDashboard(forNormalizedURL: url)
    }

    private func capabilities(supported: Bool) -> GroupCapabilities {
        let methods: Set<String> = supported
            ? ["groups.list", "groups.create", "groups.state", "groups.send", "groups.log", "groups.disband", "groups.stop"]
            : ["groups.capabilities"]
        return GroupCapabilities(
            protocolVersion: 2,
            driverReady: true,
            authorityGatewayID: "gw-a",
            features: [],
            methods: methods,
            maxLogLimit: 500
        )
    }

    private func room(id: String = "room-1", name: String = "Planning") -> GroupRoom {
        GroupRoom(
            roomID: id,
            name: name,
            members: [
                GroupMember(memberID: "researcher", profile: "researcher", handle: "research-buddy",
                            displayName: "Research Buddy", target: nil, extra: [:])
            ],
            authorityGatewayID: "gw-a",
            authorityEpoch: 1,
            revision: 1,
            createdAt: 0,
            updatedAt: 0,
            disbandedAt: nil,
            latestSeq: 0
        )
    }

    func testOneCallReadsTheRoomsAndReportsThem() async {
        let counter = RoomListCallCounter()
        let room = self.room()
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in
                counter.calls += 1
                return ([room], nil)
            }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)

        let outcome = await appState.refreshGroupChatSupport()

        XCTAssertEqual(outcome, .read([room]))
        XCTAssertEqual(counter.calls, 1, "one support refresh reads the room list once")
        XCTAssertEqual(appState.groupChatPhase, .available)
        XCTAssertEqual(appState.groupRooms, [room])
    }

    func testFirstReadFailureIsNotAnEmptyList() async {
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in throw TestError() }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)

        let outcome = await appState.refreshGroupChatSupport()

        guard case .failed(let message) = outcome else {
            return XCTFail("a failed first read must answer .failed, not \(outcome)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(appState.groupRooms, [])
        XCTAssertEqual(appState.groupChatPhase, .available,
                       "the capability probe succeeded; only the list read failed")
    }

    func testFailedRefreshKeepsTheRoomsAlreadyOnScreen() async {
        final class Box { var fail = false }
        let box = Box()
        let room = self.room()
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in
                if box.fail { throw TestError() }
                return ([room], nil)
            }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)
        let first = await appState.refreshGroupChatSupport()
        XCTAssertEqual(first, .read([room]))

        box.fail = true
        let outcome = await appState.refreshGroupChatSupport()

        guard case .failed = outcome else {
            return XCTFail("a failed refresh must answer .failed, got \(outcome)")
        }
        XCTAssertEqual(appState.groupRooms, [room], "the last known rooms stay")
        XCTAssertEqual(appState.groupChatPhase, .available)
    }

    func testUnsupportedGatewayDoesNotReadRooms() async {
        let counter = RoomListCallCounter()
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: false) },
            list: { _ in
                counter.calls += 1
                return ([], nil)
            }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)

        let outcome = await appState.refreshGroupChatSupport()

        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(appState.groupChatPhase, .gatewayUnsupported)
        XCTAssertEqual(counter.calls, 0, "a gateway without groups is not asked for rooms")
    }

    func testDashboardSwitchSupersedesAnInFlightRead() async {
        let room = self.room()
        let gate = RoomReadGate()
        let entered = expectation(description: "room list read started")
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in
                await gate.wait { entered.fulfill() }
                return ([room], nil)
            }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)

        let refresh = Task { await appState.refreshGroupChatSupport() }
        await fulfillment(of: [entered], timeout: 2)
        _ = appState.adoptDashboard(forNormalizedURL: "https://other.example")
        gate.release()
        let outcome = await refresh.value

        XCTAssertEqual(outcome, .superseded, "the outgoing dashboard's rooms are not this one's")
        XCTAssertEqual(appState.groupRooms, [])
    }

    func testCancelledReadIsNotAFailure() async {
        let room = self.room()
        let gate = RoomReadGate()
        let entered = expectation(description: "room list read started")
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in self.capabilities(supported: true) },
            list: { _ in
                await gate.wait { entered.fulfill() }
                return ([room], nil)
            }
        )
        let appState = makeAppState(operations: operations)
        connect(appState)

        let refresh = Task { await appState.refreshGroupChatSupport() }
        await fulfillment(of: [entered], timeout: 2)
        refresh.cancel()
        gate.release()
        let outcome = await refresh.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(appState.groupRooms, [])
        XCTAssertEqual(appState.groupChatPhase, .available)
    }
}

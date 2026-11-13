#if LAA_BUILD
import XCTest
@testable import Conduit

@MainActor
final class LAAEmployeeChatPreviewTests: XCTestCase {
    private var directory: URL!
    private let dashboard = UUID()

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func record(_ id: String, profile: String, source: SessionSource = .chat) {
        let row = SessionSummary(id: id, alternateIds: [], title: id, model: "Hermes", updatedLabel: "now",
                                 profile: profile, source: source, isActive: false, isArchived: false, lineageRootId: nil)
        OfflineChatCacheStore(directory: directory).record(
            dashboardID: dashboard, profile: profile, sessionID: id, title: id,
            messages: [ChatMessage(id: "m-" + id, role: .assistant, content: "saved " + id, timestamp: "1")],
            sessions: [row])
    }

    func testPreviewNeverSubstitutesAnotherEmployeeOrDashboard() {
        record("one", profile: "employee-a")
        record("two", profile: "employee-b")
        let result = LAAEmployeeChatPreview.load(workspace: .init(dashboardID: dashboard, profile: "employee-a"),
                                                  directory: directory, preferredSessionID: "two")
        XCTAssertEqual(result?.displayedSessionID, "one")
        XCTAssertEqual(result?.profile, "employee-a")
        XCTAssertNil(LAAEmployeeChatPreview.load(workspace: .init(dashboardID: UUID(), profile: "employee-a"),
                                                 directory: directory, preferredSessionID: "one"))
        XCTAssertNil(LAAEmployeeChatPreview.load(workspace: .init(dashboardID: dashboard, profile: "missing"),
                                                 directory: directory, preferredSessionID: "one"))
    }

    func testFailureRetainsSavedConversationAndReason() async throws {
        record("saved", profile: "employee-a")
        let preview = LAAEmployeeChatPreview()
        preview.begin(workspace: .init(dashboardID: dashboard, profile: "employee-a"),
                      directory: directory, preferredSessionID: nil)
        for _ in 0..<1000 where preview.presentation == nil { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(preview.presentation?.displayedSessionID, "saved")
        preview.finish(.failed("test reason"))
        XCTAssertEqual(preview.presentation?.displayedSessionID, "saved")
        XCTAssertEqual(preview.failure, "test reason")
        XCTAssertEqual(preview.workspace?.profile, "employee-a")
        preview.finish(.handled)
        XCTAssertNil(preview.presentation)
        XCTAssertNil(preview.workspace)
    }

    func testLateCacheReadCannotRestoreCancelledEmployee() async throws {
        record("saved", profile: "employee-a")
        let preview = LAAEmployeeChatPreview()
        preview.begin(workspace: .init(dashboardID: dashboard, profile: "employee-a"),
                      directory: directory, preferredSessionID: nil)
        preview.clear()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(preview.workspace)
        XCTAssertNil(preview.presentation)
    }

    func testSavedLongConversationReadFiveRuns() async throws {
        let rows = (0..<120).map {
            ChatMessage(id: "m\($0)", role: $0.isMultiple(of: 2) ? .user : .assistant,
                        content: String(repeating: "Synthetic saved conversation. ", count: 20), timestamp: "\($0)")
        }
        let session = SessionSummary(id: "long", alternateIds: [], title: "Synthetic", model: "Hermes",
            updatedLabel: "now", profile: "employee-a", source: .chat, isActive: false, isArchived: false, lineageRootId: nil)
        OfflineChatCacheStore(directory: directory).record(dashboardID: dashboard, profile: "employee-a", sessionID: "long",
            title: "Synthetic", messages: rows, sessions: [session])
        let workspace = WidgetWorkspaceID(dashboardID: dashboard, profile: "employee-a")
        let directory = directory!
        for iteration in 1...5 {
            let start = ContinuousClock.now
            let result = await Task.detached {
                LAAEmployeeChatPreview.load(workspace: workspace, directory: directory, preferredSessionID: "long")
            }.value
            let duration = start.duration(to: .now).components
            let ms = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
            XCTAssertEqual(result?.displayedTranscript?.messages.count, 120)
            print("LAA_PERF {\"metric\":\"employee_cached_120_rows_read\",\"iteration\":\(iteration),\"ms\":\(ms),\"ready\":true}")
        }
    }

    func testColdEmployeeOpenKeepsGenericBudgetAndStillExpires() async throws {
        var time: Duration = .zero
        var result: WidgetLaunchOutcome?
        let coordinator = WidgetLaunchCoordinator(now: { time }, prepare: { _, _ in .deferred },
                                                  perform: { _, _ in XCTFail("must not open"); return .handled },
                                                  finish: { result = $0 })
        let link = try XCTUnwrap(WidgetLaunchLink(action: .employeeChat,
                         workspace: .init(dashboardID: dashboard, profile: "laa-monet"), reference: nil))
        coordinator.receive(link)
        for _ in 0..<20 { await Task.yield() }
        time = .seconds(8)
        coordinator.readinessChanged()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(result, "A healthy cold connection must not be cancelled at eight seconds")
        XCTAssertTrue(coordinator.hasPendingRequest)
        time = WidgetLaunchCoordinator.launchTimeout
        coordinator.readinessChanged()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(result, .failed(LAAEmployeeChatPreview.unavailable))
        XCTAssertFalse(coordinator.hasPendingRequest)
        XCTAssertEqual(WidgetLaunchCoordinator.launchTimeout, .seconds(30))
    }
}
#endif

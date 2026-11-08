#if LAA_BUILD
import XCTest
@testable import Conduit

@MainActor
final class LAAEmployeeWidgetTests: XCTestCase {
    private let dashboardID = UUID(uuidString: "8D516B21-6B3C-4F5A-A0D6-6F6E8B73A901")!

    func testEveryEmployeeHasTheSpecifiedProfileAndArtwork() {
        let expected = [
            "monet": "Monet", "monet-uncensored": "Monet（無検閲）", "argus": "Argus", "cfo": "Morgan", "cio": "Sherlock",
            "cos": "Merlin", "cto": "Ada", "cso": "Talos"
        ]
        XCTAssertEqual(LAAWidgetEmployee.allCases.count, expected.count)
        XCTAssertEqual(LAAWidgetEmployee.defaultEmployee, .monet)
        for employee in LAAWidgetEmployee.allCases {
            XCTAssertEqual(employee.name, expected[employee.rawValue])
            XCTAssertEqual(employee.profile, "laa-\(employee.rawValue)")
            XCTAssertEqual(LAAWidgetEmployee.forProfile(employee.profile), employee)
            XCTAssertEqual(employee.heroImage, "LAAEmployee-\(employee.rawValue)-hero")
        }
        XCTAssertNil(LAAWidgetEmployee.forProfile("laa-unknown"))
        for retired in ["laa-ciel", "laa-ciel-uncensored", "laa-cmo"] {
            XCTAssertNil(LAAWidgetEmployee.forProfile(retired))
            XCTAssertNil(LAAWidgetEmployee(rawValue: String(retired.dropFirst(4))))
        }
    }

    func testEveryEmployeeLinkPreservesProfileDashboardAndAction() throws {
        let current = WidgetWorkspaceID(dashboardID: dashboardID, profile: "default")
        let snapshot = WidgetSnapshot(appLanguage: "ja", currentWorkspaceID: current, workspaces: [])
        for employee in LAAWidgetEmployee.allCases {
            for action in [WidgetLaunchAction.employeeChat, .talk] {
                let link = LAAEmployeeWidgetLinks.link(employee: employee, action: action, snapshot: snapshot)
                let decoded = try XCTUnwrap(WidgetLaunchLink(url: link.url))
                XCTAssertEqual(decoded.action, action)
                XCTAssertEqual(decoded.workspace?.dashboardID, dashboardID)
                XCTAssertEqual(decoded.workspace?.profile, employee.profile)
                XCTAssertNil(decoded.reference)
            }
        }
    }

    func testNoDashboardKeepsEmployeeAndReportsMissingDestination() async throws {
        let link = LAAEmployeeWidgetLinks.link(employee: .argus, action: .talk, snapshot: nil)
        XCTAssertEqual(link.workspace?.dashboardID, LAAEmployeeWidgetLinks.unresolvedDashboard)
        XCTAssertEqual(link.workspace?.profile, "laa-argus")
        let state = try makeState(dashboards: [])
        _ = state.handleScenePhase(.active)
        let result = await state.prepareWidgetLaunch(link, lease: WidgetLaunchLease(isCurrent: { true }))
        XCTAssertEqual(result, .failed(LAAEmployeeWidgetLinks.missingDashboardMessage))
    }

    func testMissingProfileIsExplainedRatherThanOpeningAnotherEmployee() async throws {
        let dashboard = SavedDashboard(id: dashboardID, label: "Test", normalizedURL: "https://widget-test.invalid")
        let state = try makeState(dashboards: [dashboard])
        _ = state.handleScenePhase(.active)
        state.isConnected = true
        state.profiles = ["default"]
        state.widgetSettledCatalogOwner = WidgetWorkspaceID(dashboardID: dashboardID, profile: "default")
        let snapshot = WidgetSnapshot(appLanguage: "ja", currentWorkspaceID: state.widgetSettledCatalogOwner, workspaces: [])
        let link = LAAEmployeeWidgetLinks.link(employee: .cso, action: .employeeChat, snapshot: snapshot)
        let result = await state.prepareWidgetLaunch(link, lease: WidgetLaunchLease(isCurrent: { true }))
        XCTAssertEqual(result, .failed(LAAEmployeeWidgetLinks.missingProfileMessage))
        XCTAssertNotEqual(state.activeProfile, "laa-cso")
    }

    func testOfflineReconnectDefersWithoutOpeningAnotherProfile() async throws {
        let dashboard = SavedDashboard(id: dashboardID, label: "Test", normalizedURL: "https://widget-test.invalid")
        let state = try makeState(dashboards: [dashboard])
        _ = state.handleScenePhase(.active)
        state.isConnected = false
        state.isConnecting = true
        let snapshot = WidgetSnapshot(appLanguage: "ja", currentWorkspaceID:
            WidgetWorkspaceID(dashboardID: dashboardID, profile: "default"), workspaces: [])
        let link = LAAEmployeeWidgetLinks.link(employee: .argus, action: .talk, snapshot: snapshot)

        let result = await state.prepareWidgetLaunch(link, lease: WidgetLaunchLease(isCurrent: { true }))

        XCTAssertEqual(result, .deferred)
        XCTAssertNotEqual(state.activeProfile, "laa-argus")
    }

    func testEmptyEmployeeCatalogCreatesConversationInThatProfile() async throws {
        let dashboard = SavedDashboard(id: dashboardID, label: "Test", normalizedURL: "https://widget-test.invalid")
        let state = try makeState(dashboards: [dashboard])
        state.setActiveProfileForTesting("laa-monet")
        let connection = HermesConnection(baseUrl: dashboard.normalizedURL, ticket: "test")
        state.connection = connection
        state.client = HermesClient(connection: connection, profile: "laa-monet")
        state.isConnected = true
        state.profiles = ["default", "laa-monet"]
        state.sessions = []
        let workspace = WidgetWorkspaceID(dashboardID: dashboardID, profile: "laa-monet")
        state.widgetSettledCatalogOwner = workspace
        state.widgetSessionCreatorOverride = { _, _ in ("new-monet", "new-monet", "laa-monet") }
        let link = try XCTUnwrap(WidgetLaunchLink(action: .employeeChat, workspace: workspace, reference: nil))

        let result = await state.performWidgetLaunch(link, lease: WidgetLaunchLease(isCurrent: { true }))

        XCTAssertEqual(result, .handled)
        XCTAssertEqual(state.activeSessionId, "new-monet")
        XCTAssertEqual(state.activeProfile, "laa-monet")
    }

    /// A tapped employee's chat shows at once (the opening screen) while the
    /// launch waits; backing out drops the launch so it can't come back later.
    func testEmployeeChatOpensAtOnceAndBackingOutDropsTheLaunch() throws {
        let dashboard = SavedDashboard(id: dashboardID, label: "Test", normalizedURL: "https://widget-test.invalid")
        let state = try makeState(dashboards: [dashboard])
        state.setActiveProfileForTesting("laa-monet")
        state.isConnected = false
        state.isConnecting = true
        let workspace = WidgetWorkspaceID(dashboardID: dashboardID, profile: "laa-cso")
        let link = try XCTUnwrap(WidgetLaunchLink(action: .employeeChat, workspace: workspace, reference: nil))

        XCTAssertTrue(state.routeWidgetLaunchURL(link.url))
        XCTAssertEqual(state.laaOpeningEmployeeChat, "laa-cso")

        state.laaCancelOpeningEmployeeChat()
        XCTAssertNil(state.laaOpeningEmployeeChat)
        XCTAssertNil(state.widgetLaunchCoordinator.pendingLink)
    }

    func testOnlyEmployeeChatLaunchesShowTheOpeningScreen() throws {
        let dashboard = SavedDashboard(id: dashboardID, label: "Test", normalizedURL: "https://widget-test.invalid")
        let state = try makeState(dashboards: [dashboard])
        let workspace = WidgetWorkspaceID(dashboardID: dashboardID, profile: "laa-argus")
        let newChat = try XCTUnwrap(WidgetLaunchLink(action: .newChat, workspace: workspace, reference: nil))
        let chat = try XCTUnwrap(WidgetLaunchLink(action: .employeeChat, workspace: workspace, reference: nil))

        state.widgetLaunchPendingLinkChanged(newChat)
        XCTAssertNil(state.laaOpeningEmployeeChat, "a New Chat shows as its own pending chat")
        XCTAssertEqual(state.pendingNewChat, workspace)
        state.widgetLaunchPendingLinkChanged(chat)
        XCTAssertEqual(state.laaOpeningEmployeeChat, "laa-argus")
        XCTAssertNil(state.pendingNewChat)
        state.widgetLaunchPendingLinkChanged(nil)
        XCTAssertNil(state.laaOpeningEmployeeChat)
        // Nothing pending: there is no launch to drop.
        state.laaCancelOpeningEmployeeChat()
        XCTAssertNil(state.laaOpeningEmployeeChat)
    }

    private func makeState(dashboards: [SavedDashboard]) throws -> AppState {
        let suite = "LAAEmployeeWidgetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppState(defaults: defaults, loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: dashboards.first?.id, dashboards: dashboards),
            clearSessionPresentationCache: {}, sessionPresentationCache: SessionPresentationCache(defaults: defaults))
    }
}
#endif

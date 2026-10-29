#if LAA_BUILD
import XCTest
@testable import Conduit

@MainActor
final class LAAEmployeeWidgetTests: XCTestCase {
    private let dashboardID = UUID(uuidString: "8D516B21-6B3C-4F5A-A0D6-6F6E8B73A901")!

    func testEveryEmployeeHasTheSpecifiedProfileAndArtwork() {
        let expected = [
            "ciel": "Ciel", "argus": "Argus", "cfo": "Morgan", "cio": "Sherlock",
            "cmo": "Monet", "cos": "Merlin", "cto": "Ada", "cso": "Talos"
        ]
        XCTAssertEqual(LAAWidgetEmployee.allCases.count, expected.count)
        XCTAssertEqual(LAAWidgetEmployee.defaultEmployee, .ciel)
        for employee in LAAWidgetEmployee.allCases {
            XCTAssertEqual(employee.name, expected[employee.rawValue])
            XCTAssertEqual(employee.profile, "laa-\(employee.rawValue)")
            XCTAssertEqual(LAAWidgetEmployee.forProfile(employee.profile), employee)
            XCTAssertEqual(employee.heroImage, "LAAEmployee-\(employee.rawValue)-hero")
        }
        XCTAssertNil(LAAWidgetEmployee.forProfile("laa-unknown"))
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
        state.setActiveProfileForTesting("laa-ciel")
        let connection = HermesConnection(baseUrl: dashboard.normalizedURL, ticket: "test")
        state.connection = connection
        state.client = HermesClient(connection: connection, profile: "laa-ciel")
        state.isConnected = true
        state.profiles = ["default", "laa-ciel"]
        state.sessions = []
        let workspace = WidgetWorkspaceID(dashboardID: dashboardID, profile: "laa-ciel")
        state.widgetSettledCatalogOwner = workspace
        state.widgetSessionCreatorOverride = { _, _ in ("new-ciel", "new-ciel", "laa-ciel") }
        let link = try XCTUnwrap(WidgetLaunchLink(action: .employeeChat, workspace: workspace, reference: nil))

        let result = await state.performWidgetLaunch(link, lease: WidgetLaunchLease(isCurrent: { true }))

        XCTAssertEqual(result, .handled)
        XCTAssertEqual(state.activeSessionId, "new-ciel")
        XCTAssertEqual(state.activeProfile, "laa-ciel")
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

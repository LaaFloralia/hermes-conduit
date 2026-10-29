#if LAA_BUILD && LAA_WIDGET_TEST
import WidgetKit
import XCTest
@testable import Conduit

@MainActor
final class LAAEmployeeWidgetConfigurationTests: XCTestCase {
    func testDefaultConfigurationAndSupportedFamilies() {
        let configuration = LAAEmployeeWidgetIntent()
        XCTAssertEqual(configuration.employee, .ciel)
        XCTAssertEqual(LAAEmployeeWidget.supportedFamilies, [.systemSmall, .accessoryCircular])
    }

    func testTimelineKeepsEachSelectedEmployeeAndBothDeepLinks() throws {
        let dashboard = UUID(uuidString: "8D516B21-6B3C-4F5A-A0D6-6F6E8B73A901")!
        let workspace = WidgetWorkspaceID(dashboardID: dashboard, profile: "default")
        let snapshot = WidgetSnapshot(appLanguage: "ja", currentWorkspaceID: workspace, workspaces: [])

        for employee in LAAWidgetEmployee.allCases {
            var configuration = LAAEmployeeWidgetIntent()
            configuration.employee = employee
            let timeline = LAAEmployeeTimelineProvider.makeTimeline(configuration: configuration, snapshot: snapshot)
            let entry = try XCTUnwrap(timeline.entries.first)
            XCTAssertEqual(timeline.entries.count, 1)
            XCTAssertEqual(timeline.policy, .never)
            XCTAssertEqual(entry.employee, employee)
            XCTAssertEqual(entry.employee.heroImage, "LAAEmployee-\(employee.rawValue)-hero")
            for (link, action) in [(entry.call, WidgetLaunchAction.talk), (entry.chat, .employeeChat)] {
                let decoded = try XCTUnwrap(WidgetLaunchLink(url: link.url))
                XCTAssertEqual(decoded.action, action)
                XCTAssertEqual(decoded.workspace?.dashboardID, dashboard)
                XCTAssertEqual(decoded.workspace?.profile, employee.profile)
            }
        }
    }

    func testDefaultTimelineWithoutSnapshotKeepsCielAndUnresolvedDashboard() throws {
        let timeline = LAAEmployeeTimelineProvider.makeTimeline(configuration: LAAEmployeeWidgetIntent(), snapshot: nil)
        let entry = try XCTUnwrap(timeline.entries.first)
        XCTAssertEqual(entry.employee, .ciel)
        XCTAssertEqual(entry.call.workspace?.dashboardID, LAAEmployeeWidgetLinks.unresolvedDashboard)
        XCTAssertEqual(entry.chat.workspace?.dashboardID, LAAEmployeeWidgetLinks.unresolvedDashboard)
        XCTAssertEqual(entry.call.workspace?.profile, "laa-ciel")
        XCTAssertEqual(entry.chat.workspace?.profile, "laa-ciel")
    }
}
#endif

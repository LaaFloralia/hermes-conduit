#if LAA_BUILD
import XCTest

final class LAATodayUITests: XCTestCase {
    func testTodayAndTabs() {
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "today"]
        addUIInterruptionMonitor(withDescription: "Calendar permission") { alert in
            for label in ["Allow Full Access", "Allow", "フルアクセスを許可"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        app.tap()
        XCTAssertTrue(app.staticTexts["laa.today.title"].waitForExistence(timeout: 30))
        for name in ["Chats", "Today", "Brain", "Studio", "Work"] {
            XCTAssertTrue(app.buttons[name].exists, "Missing tab \(name)")
        }
        XCTAssertTrue(app.buttons["Open tasks"].exists)
        XCTAssertTrue(app.buttons["Open Brain"].exists)
    }
}
#endif

#if LAA_BUILD
import XCTest

final class LAATodayUITests: XCTestCase {
    func testTodayAppearanceSnapshots() {
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments += ["-laa-tab", "today", "-conduit.themePreference", appearance]
            app.launch()
            addUIInterruptionMonitor(withDescription: "Calendar permission") { alert in
                let allow = alert.buttons["Allow Full Access"]
                guard allow.exists else { return false }
                allow.tap()
                return true
            }
            app.tap()
            XCTAssertTrue(app.staticTexts["laa.today.title"].waitForExistence(timeout: 30))
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "today-\(appearance)-iphone16promax"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }
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

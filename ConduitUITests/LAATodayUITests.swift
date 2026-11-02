#if LAA_BUILD
import XCTest

final class LAATodayUITests: XCTestCase {
    func testTodayAppearanceSnapshots() {
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments += ["-laa-tab", "today", "-conduit.themePreference", appearance]
            app.launch()
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
        app.launch()
        XCTAssertTrue(app.staticTexts["laa.today.title"].waitForExistence(timeout: 30))
        for name in ["Chat", "Work", "Today", "Brain", "Studio"] {
            XCTAssertTrue(app.buttons[name].exists, "Missing tab \(name)")
        }
        XCTAssertFalse(app.buttons["Open tasks"].exists)
        XCTAssertFalse(app.buttons["オープンタスク"].exists)
        XCTAssertTrue(app.buttons["Brainを開く"].exists)
    }
}
#endif

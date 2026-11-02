#if LAA_BUILD
import XCTest

/// Mac Catalyst shell checks. The phone layout is unchanged, so these tests
/// skip until the Mac shell provides `laaDesktop`.
final class LAAWorkDesktopUITests: XCTestCase {
    private func launch(tab: String, appearance: String = "light") throws -> XCUIApplication {
        guard (try? Data(contentsOf: URL(string: "http://127.0.0.1:19585/reset")!)) != nil else {
            throw XCTSkip("Start scripts/laa/work-ui-fixture.mjs")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", tab, "-LAA_UI_TEST_ISOLATED_BRIDGE",
                               "-conduit.themePreference", appearance,
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchEnvironment["LAA_BRIDGE_DEFAULT_ADDRESS"] = "http://127.0.0.1:19584"
        app.launch()
        let connect = app.buttons["work.connect"]
        guard connect.waitForExistence(timeout: 30) else {
            throw XCTSkip("Mac desktop shell is not present in this build")
        }
        connect.tap()
        let code = app.secureTextFields["laa.bridge.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        code.tap(); code.typeText("TEST-TEST")
        let pair = app.buttons["laa.bridge.pair"]
        if !pair.isHittable { app.swipeUp() }
        pair.tap()
        return app
    }

    func testTaskListSelectsIntoDetailColumn() throws {
        let app = try launch(tab: "work")
        let list = app.descendants(matching: .any)["work.desktop.tasks.list"].firstMatch
        guard list.waitForExistence(timeout: 25) else { throw XCTSkip("Work desktop layout is not active") }
        let row = app.buttons["work.task.b9d2f664-cda3-4c56-8d39-c4d6df597254"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let title = app.descendants(matching: .any)["work.task.detail.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(title.frame.minX, list.frame.midX)
    }

    func testTodayEventSelectsIntoDetailColumn() throws {
        let app = try launch(tab: "today")
        let list = app.descendants(matching: .any)["laa.today.desktop.list"].firstMatch
        guard list.waitForExistence(timeout: 25) else { throw XCTSkip("Today desktop layout is not active") }
        let row = app.buttons["laa.calendar.event.fixture-event-1"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        let title = app.descendants(matching: .any)["laa.calendar.detail.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(title.frame.minX, list.frame.midX)
    }
}
#endif

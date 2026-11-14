#if LAA_BUILD
import XCTest

final class LAATodayUITests: XCTestCase {
    func testTodayAppearanceSnapshots() {
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchEnvironment["CONDUIT_UITEST"] = "1"
            app.launchArguments += ["-laa-tab", "today", "-LAA_UI_TEST_ISOLATED_BRIDGE", "-conduit.themePreference", appearance, "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
            app.launch()
            XCTAssertTrue(app.staticTexts["laa.today.title"].waitForExistence(timeout: 30))
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "today-\(appearance)-iphone16promax"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }
    func testSettingsSectionsAndDismissal() {
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchEnvironment["CONDUIT_UITEST"] = "1"
            app.launchArguments += ["-laa-tab", "today", "-LAA_UI_TEST_ISOLATED_BRIDGE", "-conduit.themePreference", appearance,
                                    "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
            app.launch()
            let settings = app.buttons["laa.settings.open"]
            XCTAssertTrue(settings.waitForExistence(timeout: 30))
            settings.tap()
            XCTAssertTrue(app.buttons["settings.chat"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["settings.ai-usage"].exists)
            XCTAssertTrue(app.staticTexts["接続"].exists)
            XCTAssertTrue(app.staticTexts["プロフィール"].exists)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "settings-after-\(appearance)"
            shot.lifetime = .keepAlways
            add(shot)
            app.buttons["laa.settings.done"].tap()
            XCTAssertTrue(app.staticTexts["laa.today.title"].waitForExistence(timeout: 10))
            app.terminate()
        }
    }

    func testTodayAndTabs() {
        let app = XCUIApplication()
            app.launchEnvironment["CONDUIT_UITEST"] = "1"
        app.launchArguments += ["-laa-tab", "today", "-LAA_UI_TEST_ISOLATED_BRIDGE"]
        app.launch()
        XCTAssertTrue(app.staticTexts["laa.today.title"].waitForExistence(timeout: 30))
        for name in ["Chat", "Work", "Today", "Doc", "Studio"] {
            XCTAssertTrue(app.buttons[name].exists, "Missing tab \(name)")
        }
        XCTAssertFalse(app.buttons["Open tasks"].exists)
        XCTAssertFalse(app.buttons["オープンタスク"].exists)
        XCTAssertFalse(app.buttons["Docを開く"].exists)
        let modes = app.otherElements["laa.calendar.mode"]
        XCTAssertTrue(modes.waitForExistence(timeout: 5))
        XCTAssertEqual(modes.buttons.count, 4)
        XCTAssertFalse(app.activityIndicators.firstMatch.exists)
    }
}
#endif

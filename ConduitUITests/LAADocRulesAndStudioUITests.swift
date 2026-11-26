#if LAA_BUILD && DEBUG
import XCTest

final class LAADocRulesAndStudioUITests: XCTestCase {
    func testLight() { check(style: "light") }
    #if !targetEnvironment(macCatalyst)
    func testDark() { check(style: "dark") }
    #endif

    private func check(style: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "studio", "-LAA_UI_TEST_ISOLATED_BRIDGE", "-laa-studio-fixture", "grouped",
                               "-laa-drive-fixture", "browse", "-laa-doc-rules-fixture", "-conduit.themePreference", style]
        app.launchInLab()
        defer { app.terminate() }
        #if targetEnvironment(macCatalyst)
        let macStudio = app.buttons["laa.mac.section.studio"]
        XCTAssertTrue(macStudio.waitForExistence(timeout: 30)); macStudio.click()
        let variant = "mac-" + style
        #else
        let variant = style
        #endif
        let studioMenu = app.buttons["laa.studio.menu"].firstMatch
        XCTAssertTrue(studioMenu.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["laa.studio.kind.Documents"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["laa.studio.kind.Images"].exists)
        XCTAssertTrue(app.buttons["laa.studio.work.fixture-image"].exists)
        capture(app, "studio-grouped-" + variant)
        openRules(app, menu: studioMenu, entry: "laa.studio.rules")
        capture(app, "studio-rules-" + variant)
        app.buttons["Done"].firstMatch.tap()
        #if targetEnvironment(macCatalyst)
        app.buttons["laa.mac.section.drive"].click()
        #else
        app.buttons["studio.drive"].tap()
        #endif
        openRules(app, menu: app.buttons["laa.drive.browser.menu"].firstMatch, entry: "laa.drive.rules")
        capture(app, "drive-rules-" + variant)
    }

    private func openRules(_ app: XCUIApplication, menu: XCUIElement, entry: String) {
        XCTAssertTrue(menu.waitForExistence(timeout: 20)); menu.tap()
        let button = app.descendants(matching: .any).matching(identifier: entry).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15)); button.tap()
        let rendered = app.descendants(matching: .any).matching(identifier: "laa.doc.rules.body").firstMatch
        XCTAssertTrue(rendered.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["Retry"].exists)
        XCTAssertTrue(app.buttons["Done"].firstMatch.exists)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
#endif

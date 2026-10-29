#if LAA_BUILD
import XCTest

final class LAAPluginPolicyUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testReportedUpdateHasNoBannerOrSettingsAction() {
        let app = XCUIApplication()
        app.launchEnvironment["CONDUIT_UITEST"] = "1"
        app.launchArguments += ["-laa-tab", "source", "-LAA_UI_TEST_NOTIFIER_UPDATE_AVAILABLE",
                                "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD", "https://conduit-ui-test.invalid"]
        app.launch()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["pluginUpdate.update"].exists)
        XCTAssertFalse(app.buttons["pluginUpdate.showSteps"].exists)
        settings.tap()
        XCTAssertTrue(app.buttons["settings.chat"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.otherElements["settings.notifier-update"].exists)
        let plugin = app.buttons["settings.conduit-plugin"]
        for _ in 0..<5 where !plugin.isHittable { app.swipeUp() }
        XCTAssertTrue(plugin.waitForExistence(timeout: 10))
        plugin.tap()
        XCTAssertTrue(app.staticTexts["0.1.0"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["settings.plugin.connection"].exists)
        XCTAssertFalse(app.buttons["settings.plugin.update"].exists)
        XCTAssertFalse(app.buttons["settings.plugin.notices"].exists)
        XCTAssertFalse(app.buttons["Finish Update"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "update available")).firstMatch.exists)
    }

    func testCatalogSuppressesNotifierUpdateButKeepsOtherPluginUpdate() {
        let app = XCUIApplication()
        app.launchEnvironment["CONDUIT_UITEST"] = "1"
        app.launchArguments += ["-LAA_UI_TEST_PLUGIN_CATALOG"]
        app.launch()
        let notifier = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "conduit_push")).firstMatch
        XCTAssertTrue(notifier.waitForExistence(timeout: 30))
        let weather = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "weather")).firstMatch
        XCTAssertTrue(weather.exists)
        XCTAssertFalse(notifier.label.localizedCaseInsensitiveContains("update available"))
        XCTAssertTrue(weather.label.localizedCaseInsensitiveContains("update available"))
        notifier.tap()
        XCTAssertTrue(app.navigationBars["conduit_push"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Update"].exists)
        XCTAssertFalse(app.buttons["Check for Update"].exists)
        XCTAssertFalse(app.buttons["Uninstall"].exists)
    }
}
#endif

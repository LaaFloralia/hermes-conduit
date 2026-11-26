#if LAA_BUILD
import UIKit
import XCTest

final class LAAUsageUITests: XCTestCase {
    func testCapacityUsesSharedFeedAndRetainsStaleNumbersWithAge() throws {
        try requireUsageFeed()
        continueAfterFailure = false
        _ = try helper("mode/normal")
        let app = XCUIApplication()
        app.launchEnvironment["CONDUIT_UITEST"] = "1"
        app.launchArguments = ["-LAA_UI_TEST_ISOLATED_BRIDGE", "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD",
                               "https://conduit-ui-test.invalid", "-laa-tab", "work",
                               "-CONDUIT_UI_TEST_WIDGET_URL", "conduit://widget/v1/usage",
                               "-CONDUIT_UI_TEST_WIDGET_DELIVERY", "cold"]
        app.launchInLab()
        defer { app.terminate() }
        openUsage(app)
        app.buttons["laa.bridge.openPairing"].tap()
        try pair(app)
        XCTAssertTrue(app.staticTexts["Free 100 GiB"].waitForExistence(timeout: 30))
        screenshot("usage-capacity-live-fixture")
        _ = try helper("mode/stale")
        app.buttons["laa.usage.refresh"].tap()
        XCTAssertTrue(app.staticTexts["30分前"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Free 100 GiB"].exists)
        XCTAssertFalse(app.staticTexts["更新待ち"].exists)
        screenshot("usage-capacity-outage-30m")
    }

    func testWidgetUsageLinkSelectsUsageOnColdAndWarmLaunch() {
        for delivery in ["cold", "warm"] {
            let app = XCUIApplication()
            app.launchEnvironment["CONDUIT_UITEST"] = "1"
            app.launchArguments = ["-CONDUIT_UI_TEST_CONNECTED_DASHBOARD", "https://conduit-ui-test.invalid",
                                   "-CONDUIT_UI_TEST_WIDGET_URL", "conduit://widget/v1/usage",
                                   "-CONDUIT_UI_TEST_WIDGET_DELIVERY", delivery]
            app.launchInLab()
            if delivery == "warm" {
                let deliver = app.buttons["widgetUITestDeliverURL"]
                XCTAssertTrue(deliver.waitForExistence(timeout: 15))
                deliver.tap()
            }
            XCTAssertTrue(app.buttons["laa.usage.refresh"].waitForExistence(timeout: 20))
            app.terminate()
        }
    }

    private func openUsage(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["laa.usage.refresh"].waitForExistence(timeout: 30))
    }

    private func requireUsageFeed() throws {
        try XCTSkipUnless(LabUI.active, "Run suite.py run integration for the synthetic usage feed.")
        XCTAssertEqual(try helper("health"), "ok")
    }

    private func helper(_ route: String) throws -> String {
        String(decoding: try LabUI.data(LabUI.fixture("usage-control"), "/\(route)"), as: UTF8.self)
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func pair(_ app: XCUIApplication) throws {
        let address = app.textFields["laa.bridge.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 15))
        XCTAssertEqual(address.value as? String, try XCTUnwrap(LabUI.bridge))
        let code = app.secureTextFields["laa.bridge.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        code.tap(); code.typeText(try helper("fixture-code"))
        let button = app.buttons["laa.bridge.pair"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        if !button.isHittable { app.swipeUp() }
        button.tap()
    }

    private func enabled(_ element: XCUIElement, timeout: TimeInterval = 30) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)], timeout: timeout) == .completed
    }

    private func text(containing text: String, app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func testVisibleUsageFetchesAgainWithoutManualRefresh() throws {
        try requireUsageFeed()
        continueAfterFailure = false
        _ = try helper("mode/normal")
        let app = XCUIApplication()
        app.launchEnvironment["CONDUIT_UITEST"] = "1"
        app.launchArguments = ["-LAA_UI_TEST_ISOLATED_BRIDGE", "-LAA_UI_TEST_USAGE_FAST_REFRESH",
                               "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD", "https://conduit-ui-test.invalid",
                               "-laa-tab", "work",
                               "-CONDUIT_UI_TEST_WIDGET_URL", "conduit://widget/v1/usage",
                               "-CONDUIT_UI_TEST_WIDGET_DELIVERY", "cold"]
        app.launchInLab()
        defer { app.terminate() }
        openUsage(app)
        let connect = app.buttons["laa.bridge.openPairing"]
        XCTAssertTrue(connect.waitForExistence(timeout: 15))
        connect.tap()
        try pair(app)
        XCTAssertTrue(text(containing: "Claude", app: app).waitForExistence(timeout: 30))
        XCTAssertTrue(text(containing: "Claude", app: app).exists)
        XCTAssertTrue(enabled(app.buttons["laa.usage.refresh"]))

        let before = try XCTUnwrap(Int(helper("counts")))
        _ = try helper("mode/stale")
        XCTAssertTrue(text(containing: "30分前", app: app).waitForExistence(timeout: 15))
        XCTAssertGreaterThan(Int(try helper("counts")) ?? 0, before)
        XCTAssertTrue(app.staticTexts["62%"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["更新待ち"].exists)
    }

    func testUsageRefreshAndFailureStates() throws {
        try requireUsageFeed()
        continueAfterFailure = false
        _ = try helper("mode/normal")
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP",
                               "-LAA_UI_TEST_ISOLATED_BRIDGE",
                               "-conduit.themePreference", "light", "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD",
                               "https://conduit-ui-test.invalid", "-laa-tab", "work",
                               "-CONDUIT_UI_TEST_WIDGET_URL", "conduit://widget/v1/usage",
                               "-CONDUIT_UI_TEST_WIDGET_DELIVERY", "cold"]
        app.launchEnvironment["CONDUIT_UITEST"] = "1"
        app.launchInLab()
        openUsage(app)
        let connect = app.buttons["laa.bridge.openPairing"]
        XCTAssertTrue(connect.waitForExistence(timeout: 15))
        screenshot("usage-ui-unpaired")
        connect.tap()
        try pair(app)
        XCTAssertTrue(text(containing: "Claude", app: app).waitForExistence(timeout: 30))
        XCTAssertTrue(text(containing: "Claude", app: app).exists)
        let refresh = app.buttons["laa.usage.refresh"]
        XCTAssertTrue(enabled(refresh))
        XCTAssertTrue(app.staticTexts["62%"].firstMatch.waitForExistence(timeout: 15))
        screenshot("usage-ui-normal")

        _ = try helper("mode/stale")
        refresh.tap()
        XCTAssertTrue(text(containing: "30分前", app: app).waitForExistence(timeout: 30))
        screenshot("usage-ui-stale")
        XCTAssertTrue(enabled(refresh))

        _ = try helper("mode/normal")
        refresh.tap()
        XCTAssertTrue(enabled(refresh))
        _ = try helper("mode/degraded")
        refresh.tap()
        // A failed read keeps the last numbers on the cards, marked by their age.
        XCTAssertTrue(app.descendants(matching: .any)["laa.usage.card.claude"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["62%"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(enabled(refresh))

        _ = try helper("mode/error")
        refresh.tap()
        XCTAssertTrue(text(containing: "Macに接続できません", app: app).waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["62%"].firstMatch.waitForExistence(timeout: 15))
        screenshot("usage-ui-error")
        XCTAssertTrue(enabled(refresh))

        _ = try helper("mode/offline")
        refresh.tap()
        XCTAssertTrue(text(containing: "Macに接続できません", app: app).waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["62%"].firstMatch.waitForExistence(timeout: 15))
        screenshot("usage-ui-offline")
        XCTAssertTrue(enabled(refresh))

        _ = try helper("mode/empty")
        // Clear in-memory last-good usage, but keep the paired lab device.
        app.terminate()
        app.launchInLab()
        openUsage(app)
        XCTAssertFalse(app.buttons["laa.bridge.openPairing"].exists)
        // Nothing read: the cards draw empty tracks and ○, no words.
        XCTAssertTrue(app.staticTexts["○"].firstMatch.waitForExistence(timeout: 30))
        screenshot("usage-ui-empty")

        _ = try helper("mode/slow")
        let before = Int(try helper("counts")) ?? -1
        let again = app.buttons["laa.usage.refresh"]
        XCTAssertTrue(enabled(again))
        again.tap()
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == false"), object: again)], timeout: 5) == .completed)
        XCTAssertTrue(enabled(again))
        XCTAssertGreaterThanOrEqual(Int(try helper("counts")) ?? 0, before + 1)

        _ = try helper("mode/revoked")
        again.tap()
        XCTAssertTrue(app.buttons["laa.bridge.openPairing"].waitForExistence(timeout: 30))
        XCTAssertTrue(text(containing: "接続が無効", app: app).exists)
    }
}
#endif

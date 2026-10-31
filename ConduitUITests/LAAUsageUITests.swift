#if LAA_BUILD
import UIKit
import XCTest

final class LAAUsageUITests: XCTestCase {
    private func helper(_ route: String) throws -> String {
        let data = try Data(contentsOf: URL(string: "http://127.0.0.1:19493/\(route)")!)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func pair(_ app: XCUIApplication, port: Int, codeRoute: String) throws {
        let address = app.textFields["laa.bridge.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 15))
        for _ in 0..<4 {
            let value = address.value as? String ?? ""
            if value.isEmpty || value == "接続先" { break }
            address.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
            address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count + 10))
        }
        address.typeText("http://127.0.0.1:\(port)")
        XCTAssertEqual(address.value as? String, "http://127.0.0.1:\(port)")
        let code = app.secureTextFields["laa.bridge.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        UIPasteboard.general.string = try helper(codeRoute)
        code.tap()
        code.press(forDuration: 1.2)
        let paste = app.menuItems.matching(NSPredicate(format: "label IN %@", ["Paste", "ペースト"])).firstMatch
        let alternate = app.buttons.matching(NSPredicate(format: "label IN %@", ["Paste", "ペースト"])).firstMatch
        if paste.waitForExistence(timeout: 3) { paste.tap() }
        else { XCTAssertTrue(alternate.waitForExistence(timeout: 3)); alternate.tap() }
        UIPasteboard.general.string = ""
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

    func testUsageRefreshAndFailureStates() throws {
        guard (try? helper("health")) == "ok" else { throw XCTSkip("Run the local Usage fixture first.") }
        continueAfterFailure = false
        _ = try helper("mode/normal")
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP",
                               "-LAA_UI_TEST_ISOLATED_BRIDGE",
                               "-conduit.themePreference", "light", "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD",
                               "https://conduit-ui-test.invalid", "-laa-tab", "usage"]
        app.launchEnvironment["CONDUIT_UITEST"] = "1"
        app.launch()
        let connect = app.buttons["laa.bridge.openPairing"]
        if connect.waitForExistence(timeout: 15) {
            screenshot("usage-ui-unpaired")
            connect.tap()
        } else {
            XCTAssertTrue(app.buttons["laa.usage.menu"].waitForExistence(timeout: 15))
            app.buttons["laa.usage.menu"].tap()
            app.buttons["Connection"].tap()
        }
        try pair(app, port: 19492, codeRoute: "fixture-code")
        XCTAssertTrue(app.staticTexts["Claude"].waitForExistence(timeout: 30))
        let refresh = app.buttons["laa.usage.refresh"]
        XCTAssertTrue(enabled(refresh))
        XCTAssertTrue(app.staticTexts["62%"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Mac mini"].exists)
        screenshot("usage-ui-normal")

        _ = try helper("mode/stale")
        refresh.tap()
        XCTAssertTrue(text(containing: "古い値", app: app).waitForExistence(timeout: 30))
        screenshot("usage-ui-stale")
        XCTAssertTrue(enabled(refresh))

        _ = try helper("mode/normal")
        refresh.tap()
        XCTAssertTrue(enabled(refresh))
        _ = try helper("mode/degraded")
        refresh.tap()
        XCTAssertTrue(text(containing: "更新失敗・前回の値", app: app).waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["62%"].firstMatch.exists)
        XCTAssertTrue(enabled(refresh))

        _ = try helper("mode/error")
        refresh.tap()
        XCTAssertTrue(text(containing: "Mac側のサービスを利用できません。", app: app).waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["62%"].firstMatch.exists)
        screenshot("usage-ui-error")
        XCTAssertTrue(enabled(refresh))

        _ = try helper("mode/offline")
        refresh.tap()
        XCTAssertTrue(text(containing: "Macに届きません。", app: app).waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["62%"].firstMatch.exists)
        screenshot("usage-ui-offline")
        XCTAssertTrue(enabled(refresh))

        _ = try helper("mode/empty")
        refresh.tap()
        XCTAssertTrue(app.staticTexts["表示できるサービスはありません。"].waitForExistence(timeout: 30))
        screenshot("usage-ui-empty")
    }
}
#endif

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

    func testFakeStatesAndRealBridgeRevocation() throws {
        guard (try? helper("health")) == "ok" else { throw XCTSkip("Run the dedicated local Usage fixture first.") }
        defer { _ = try? helper("revoke") }
        continueAfterFailure = false
        _ = try helper("mode/normal")
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP",
                               "-conduit.themePreference", "light", "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD",
                               "https://conduit-ui-test.invalid", "-laa-tab", "usage"]
        app.launchEnvironment["CONDUIT_UITEST"] = "1"
        app.launch()
        let connect = app.buttons["laa.bridge.openPairing"]
        XCTAssertTrue(connect.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["未接続"].exists)
        screenshot("v2-4-unpaired")
        connect.tap()
        try pair(app, port: 19492, codeRoute: "fixture-code")
        XCTAssertTrue(app.staticTexts["Claude"].waitForExistence(timeout: 30))
        let refresh = app.buttons["laa.usage.refresh"]
        XCTAssertTrue(enabled(refresh))
        XCTAssertTrue(app.staticTexts["62%"].firstMatch.exists)
        screenshot("v2-4-normal-light")

        _ = try helper("mode/slow")
        let gestureCount = Int(try helper("counts")) ?? 0
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.22))
        let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.88))
        start.press(forDuration: 0.15, thenDragTo: end)
        XCTAssertTrue(enabled(refresh))
        XCTAssertEqual(Int(try helper("counts")), gestureCount + 1)
        _ = try helper("mode/normal")

        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP",
                               "-conduit.themePreference", "dark", "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD",
                               "https://conduit-ui-test.invalid", "-laa-tab", "usage"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Claude"].waitForExistence(timeout: 30))
        XCTAssertTrue(enabled(refresh))
        screenshot("v2-4-normal-dark")

        _ = try helper("mode/slow")
        let before = Int(try helper("counts")) ?? 0
        refresh.tap()
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        XCTAssertFalse(refresh.isEnabled)
        XCTAssertTrue(enabled(refresh))
        XCTAssertEqual(Int(try helper("counts")), before + 1)

        _ = try helper("mode/degraded")
        refresh.tap()
        XCTAssertTrue(text(containing: "更新失敗・前回の値", app: app).waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["62%"].firstMatch.exists)
        XCTAssertTrue(enabled(refresh))

        _ = try helper("mode/error")
        refresh.tap()
        XCTAssertTrue(text(containing: "Mac側のサービスを利用できません。", app: app).waitForExistence(timeout: 30))
        XCTAssertTrue(text(containing: "前回取得", app: app).exists)
        XCTAssertTrue(app.staticTexts["62%"].firstMatch.exists)
        XCTAssertTrue(enabled(refresh))

        _ = try helper("mode/offline")
        refresh.tap()
        XCTAssertTrue(text(containing: "Macに届きません。", app: app).waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["62%"].firstMatch.exists)
        XCTAssertTrue(enabled(refresh))

        _ = try helper("mode/empty")
        refresh.tap()
        XCTAssertTrue(app.staticTexts["表示できるサービスはありません。"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Macの状態はありません。"].exists)
        XCTAssertTrue(enabled(refresh))

        app.buttons["laa.usage.menu"].tap()
        app.buttons["Macとの接続"].tap()
        try pair(app, port: 19491, codeRoute: "real-code")
        XCTAssertTrue(app.staticTexts["Mac mini"].waitForExistence(timeout: 45))
        XCTAssertTrue(enabled(refresh, timeout: 45))
        XCTAssertTrue(app.staticTexts["CPU"].exists)
        XCTAssertTrue(app.staticTexts["メモリ"].exists)
        XCTAssertTrue(app.staticTexts["空き容量"].exists)
        screenshot("v2-4-real-bridge")
        _ = try helper("revoke")
        refresh.tap()
        XCTAssertTrue(app.staticTexts["この端末の接続が無効になりました。新しいコードで接続してください。"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["未接続"].exists)
        screenshot("v2-4-revoked")
    }

    // Run against an isolated real Bridge after its usage-feed cache is populated.
    func testRealBridgeCachedUsage() throws {
        guard (try? helper("health")) == "ok" else { throw XCTSkip("Run the dedicated local Usage fixture first.") }
        defer { _ = try? helper("revoke") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP",
                               "-conduit.themePreference", "light", "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD",
                               "https://conduit-ui-test.invalid", "-laa-tab", "usage"]
        app.launchEnvironment["CONDUIT_UITEST"] = "1"
        app.launch()
        let connect = app.buttons["laa.bridge.openPairing"]
        if connect.waitForExistence(timeout: 20) { connect.tap() }
        else {
            app.buttons["laa.usage.menu"].tap()
            app.buttons["Macとの接続"].tap()
        }
        try pair(app, port: 19491, codeRoute: "real-code")
        XCTAssertTrue(app.staticTexts["概要"].waitForExistence(timeout: 45))
        let refresh = app.buttons["laa.usage.refresh"]
        XCTAssertTrue(enabled(refresh, timeout: 45))
        screenshot("v2-4-real-cached")
        _ = try helper("revoke")
        refresh.tap()
        XCTAssertTrue(app.staticTexts["未接続"].waitForExistence(timeout: 30))
    }
}
#endif

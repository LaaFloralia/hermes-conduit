import XCTest

final class LAABridgeRealUITests: XCTestCase {
    #if LAA_BUILD
    private func launch() throws -> XCUIApplication {
        guard ProcessInfo.processInfo.environment["LAA_UI_TEST_REAL_BRIDGE"] == "1" else {
            throw XCTSkip("Real Bridge test is opt-in")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_UI_TEST_REAL_BRIDGE"]
        app.launch()
        XCTAssertTrue(app.buttons["fixture.bridge"].waitForExistence(timeout: 20))
        return app
    }

    func testPairAndVerify() throws {
        let app = try launch()
        app.buttons["fixture.bridge"].tap()
        let code = app.secureTextFields["laa.bridge.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        code.tap()
        code.press(forDuration: 1.2)
        let japanesePaste = app.menuItems["ペースト"]
        let paste = japanesePaste.waitForExistence(timeout: 3) ? japanesePaste : app.menuItems["Paste"]
        guard paste.waitForExistence(timeout: 5) else { XCTFail("Paste menu was not shown"); return }
        paste.tap()
        for label in ["ペーストを許可", "貼り付けを許可", "Allow Paste"] {
            let allow = app.buttons[label]
            if allow.waitForExistence(timeout: 1) { allow.tap(); break }
        }
        let pair = app.buttons["laa.bridge.pair"]
        XCTAssertTrue(pair.isEnabled)
        pair.tap()
        XCTAssertTrue(app.buttons["fixture.bridge.verify"].waitForExistence(timeout: 20))
        app.buttons["fixture.bridge.verify"].tap()
        XCTAssertTrue(app.staticTexts["fixture.bridge.result"].waitForExistence(timeout: 5))
        let verified = NSPredicate(format: "label == %@", "接続確認済み")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: verified, object: app.staticTexts["fixture.bridge.result"])], timeout: 20), .completed)
    }

    func testRevocation() throws {
        let app = try launch()
        app.buttons["fixture.bridge.verify"].tap()
        let revoked = NSPredicate(format: "label == %@", "失効を確認")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: revoked, object: app.staticTexts["fixture.bridge.result"])], timeout: 20), .completed)
    }
    #else
    func testOnlyAvailableInLAABuild() throws { throw XCTSkip("LAA build only") }
    #endif
}

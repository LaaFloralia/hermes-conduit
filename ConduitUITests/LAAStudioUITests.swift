#if LAA_BUILD
import XCTest

final class LAAStudioUITests: XCTestCase {
    private func helper(_ route: String) throws -> String {
        String(data: try Data(contentsOf: URL(string: "http://127.0.0.1:19583/\(route)")!), encoding: .utf8) ?? ""
    }

    func testWorksRequestsApprovalAndNewRequestThroughMockBridge() throws {
        guard (try? helper("health")) == "ok" else { throw XCTSkip("Start scripts/laa/studio-ui-fixture.mjs first") }
        _ = try helper("reset")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "source", "-LAA_UI_TEST_ISOLATED_BRIDGE"]
        app.launch()
        let studio = app.buttons["Studio"]
        XCTAssertTrue(studio.waitForExistence(timeout: 30)); studio.tap()
        let connect = app.buttons["laa.studio.pair"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10)); connect.tap()
        let address = app.textFields["laa.bridge.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        let current = address.value as? String ?? ""
        address.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 5))
        address.typeText("http://127.0.0.1:19582")
        let code = app.secureTextFields["laa.bridge.code"]
        code.tap(); code.typeText("TEST-TEST")
        let pair = app.buttons["laa.bridge.pair"]
        if !pair.isHittable { app.swipeUp() }
        pair.tap()
        let work = app.buttons["laa.studio.work.70175325-5cf4-421f-8a6f-95beae8fca92"]
        XCTAssertTrue(work.waitForExistence(timeout: 30)); work.tap()
        XCTAssertTrue(app.staticTexts["Cover"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Requests"].tap()
        let request = app.buttons["laa.studio.request.0f6b1c2e-6f1a-4c55-9d43-0d5f6f3b8a11"]
        XCTAssertTrue(request.waitForExistence(timeout: 10)); request.tap()
        let allow = app.buttons["laa.studio.approval.allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10)); allow.tap()
        XCTAssertTrue(app.staticTexts["Running"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let create = app.buttons["laa.studio.new"]
        XCTAssertTrue(create.waitForExistence(timeout: 10)); create.tap()
        let title = app.textFields["laa.studio.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10)); title.tap(); title.typeText("New presentation")
        let body = app.textViews["laa.studio.composer.field"]
        XCTAssertTrue(body.waitForExistence(timeout: 10)); body.tap(); body.typeText("Make a short overview")
        let send = app.buttons["laa.studio.composer.send"]
        if !send.isHittable { app.swipeUp() }
        XCTAssertTrue(send.waitForExistence(timeout: 10)); send.tap()
        XCTAssertTrue(app.staticTexts["依頼を受け付けました。"].waitForExistence(timeout: 15))
    }
}
#endif

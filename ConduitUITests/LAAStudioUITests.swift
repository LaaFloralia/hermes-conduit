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
        XCTAssertTrue(request.waitForExistence(timeout: 10))
        XCTAssertTrue(request.label.contains("Needs approval")); request.tap()
        XCTAssertTrue(app.staticTexts["サービス紹介資料"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["laa.studio.deliverables"].exists)
        let stop = app.buttons["laa.studio.stop"]
        if !stop.isHittable { app.swipeUp() }
        XCTAssertTrue(stop.waitForExistence(timeout: 10)); stop.tap()
        let stopConfirmation = app.sheets.firstMatch
        XCTAssertTrue(stopConfirmation.waitForExistence(timeout: 10))
        XCTAssertTrue(stopConfirmation.buttons["Stop"].exists)
        if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
        } else {
            let dismiss = app.otherElements["PopoverDismissRegion"]
            XCTAssertTrue(dismiss.exists)
            dismiss.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        XCTAssertFalse(stopConfirmation.waitForExistence(timeout: 2))
        let allow = app.buttons["laa.studio.approval.allow"]
        if !allow.isHittable { app.swipeDown() }
        _ = try helper("mode/action-fail-once")
        XCTAssertTrue(allow.waitForExistence(timeout: 10)); allow.tap()
        let retry = app.buttons["laa.studio.action.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 18))
        XCTAssertEqual(try helper("action-count"), "1")
        if !stop.isHittable { app.swipeUp() }
        XCTAssertTrue(stop.isEnabled)
        if !retry.isHittable { app.swipeDown() }
        retry.tap()
        XCTAssertTrue(app.staticTexts["Running"].waitForExistence(timeout: 10))
        XCTAssertEqual(try helper("action-count"), "2")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let create = app.buttons["laa.studio.new"]
        XCTAssertTrue(create.waitForExistence(timeout: 10)); create.tap()
        let title = app.textFields["laa.studio.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10)); title.tap(); title.typeText("New presentation")
        let body = app.textViews["laa.studio.composer.field"]
        XCTAssertTrue(body.waitForExistence(timeout: 10)); body.tap(); body.typeText("Make a short overview")
        XCTAssertFalse(app.buttons["laa.studio.composer.textSize"].exists)
        let send = app.buttons["laa.studio.composer.send"]
        if !send.isHittable { app.swipeUp() }
        XCTAssertTrue(send.waitForExistence(timeout: 10)); XCTAssertGreaterThanOrEqual(send.frame.height, 44); send.tap()
        XCTAssertTrue(app.staticTexts["依頼を受け付けました。"].waitForExistence(timeout: 15))
    }
}
#endif

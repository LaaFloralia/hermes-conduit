#if LAA_BUILD
import XCTest

/// Sending while the employee's turn is running (a steer, the wheel mark
/// on the bubble) keeps the app up and shows the sent message (owner,
/// 2026-11-16: the app quit right after such a send to Monet, over a
/// background picture).
final class LAAChatSteerSendUITests: XCTestCase {
    private func launch(dark: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_V2_CHAT_FIXTURE", "typing",
                               "-LAA_CAPTURE_SURFACE", "chat", "-LAA_CAPTURE_KIND", "paper",
                               "-LAA_FIXTURE_PUSH_CHAT", "-LAA_FIXTURE_PROFILE", "laa-monet",
                               "-LAA_FIXTURE_CONNECTED"] + (dark ? ["-LAA_V2_DARK"] : [])
        app.launch()
        XCTAssertTrue(app.staticTexts["fixture.capture.ready"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.textViews["composer.field"].waitForExistence(timeout: 15))
        return app
    }

    private func sendWhileBusy(dark: Bool) {
        let app = launch(dark: dark)
        let field = app.textViews["composer.field"]
        field.tap()
        field.typeText("あと、定期実行を巻き取れる所があれば巻き取って。")
        app.buttons["composer.action"].tap()
        // The send effect, the steer's row and the busy turn all settle in
        // these seconds; a crash ends the app before they do.
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "巻き取れる所")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the steered message shows in the chat")
        Thread.sleep(forTimeInterval: 4)
        XCTAssertEqual(app.state, .runningForeground, "the app is still running after the send")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "steer-send-\(dark ? "dark" : "light")"; shot.lifetime = .keepAlways; add(shot)
    }

    /// A hold on the owner's own bubble selects its text like a reply does.
    func testLongPressOnTheOwnersBubbleSelectsItsText() {
        let app = XCUIApplication()
        app.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_V2_CHAT_FIXTURE", "simple",
                               "-LAA_CAPTURE_SURFACE", "chat", "-LAA_CAPTURE_KIND", "paper",
                               "-LAA_FIXTURE_PUSH_CHAT"]
        app.launch()
        XCTAssertTrue(app.staticTexts["fixture.capture.ready"].waitForExistence(timeout: 30))
        let own = app.descendants(matching: .any).matching(identifier: "chat.message.user").firstMatch
        XCTAssertTrue(own.waitForExistence(timeout: 10))
        own.textViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 1.0)
        XCTAssertTrue(app.menuItems.matching(NSPredicate(format: "label IN %@", ["コピー", "Copy"])).firstMatch
            .waitForExistence(timeout: 5), "the edit menu opens")
        XCTAssertEqual(app.state, .runningForeground, "the app is still running after the long press")
    }

    /// Three follow-ups in a row into the running turn (owner, 2026-11-16:
    /// the app froze after a steer and had to be ended).
    func testSteeringThreeTimesInARowKeepsTheAppResponsive() {
        let app = launch(dark: false)
        let field = app.textViews["composer.field"]
        for index in 1...3 {
            field.tap()
            field.typeText("追い送り\(index)回目")
            app.buttons["composer.action"].tap()
            let row = app.descendants(matching: .any).matching(identifier: "chat.transcript").firstMatch
                .descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                      "追い送り\(index)回目", "追い送り\(index)回目")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "follow-up \(index) shows in the chat")
        }
        // Still answering touches: the field takes focus and text again.
        field.tap()
        field.typeText("応答確認")
        XCTAssertTrue((field.value as? String)?.contains("応答確認") == true, "the composer still takes text")
        XCTAssertFalse(app.staticTexts["composer.unknown-delivery"].exists, "each follow-up was accepted")
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testSendingWhileTheTurnRunsKeepsTheAppUp() { sendWhileBusy(dark: false) }
    func testSendingWhileTheTurnRunsKeepsTheAppUpInDark() { sendWhileBusy(dark: true) }
}
#endif

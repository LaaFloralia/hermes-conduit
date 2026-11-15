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
                               "-LAA_FIXTURE_PUSH_CHAT"] + (dark ? ["-LAA_V2_DARK"] : [])
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

    /// The owner's own bubble opens its long-press menu like a reply does.
    func testLongPressOnTheOwnersBubbleOpensItsMenu() {
        let app = XCUIApplication()
        app.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_V2_CHAT_FIXTURE", "simple",
                               "-LAA_CAPTURE_SURFACE", "chat", "-LAA_CAPTURE_KIND", "paper",
                               "-LAA_FIXTURE_PUSH_CHAT"]
        app.launch()
        XCTAssertTrue(app.staticTexts["fixture.capture.ready"].waitForExistence(timeout: 30))
        let own = app.descendants(matching: .any).matching(identifier: "chat.message.user").firstMatch
        XCTAssertTrue(own.waitForExistence(timeout: 10))
        own.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["コピー"].waitForExistence(timeout: 5), "the menu opens")
        XCTAssertEqual(app.state, .runningForeground, "the app is still running after the long press")
    }

    func testSendingWhileTheTurnRunsKeepsTheAppUp() { sendWhileBusy(dark: false) }
    func testSendingWhileTheTurnRunsKeepsTheAppUpInDark() { sendWhileBusy(dark: true) }
}
#endif

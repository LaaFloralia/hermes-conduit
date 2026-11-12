#if LAA_BUILD
import XCTest

/// Sending always brings the chat to its end, wherever the owner had
/// scrolled (owner, 2026-11-12): with the keyboard up, and from the full
/// editor.
final class LAAChatSendScrollUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_V2_CHAT_FIXTURE", "long",
                               "-LAA_CAPTURE_SURFACE", "chat", "-LAA_CAPTURE_KIND", "paper",
                               "-LAA_FIXTURE_PUSH_CHAT"]
        app.launch()
        XCTAssertTrue(app.staticTexts["fixture.capture.ready"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.textViews["composer.field"].waitForExistence(timeout: 15))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    private func transcript(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "chat.transcript").firstMatch
    }

    /// The row in the transcript, not the composer's notice of the send.
    private func row(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        transcript(app).descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Wholly in view between the top bar and the composer: inside the
    /// transcript's frame, which ends where the composer and its notices
    /// begin, and above the field.
    private func isOnScreen(_ element: XCUIElement, in app: XCUIApplication, above field: XCUIElement) -> Bool {
        element.exists && element.frame.minY > 60
            && element.frame.maxY <= min(transcript(app).frame.maxY, field.frame.minY) + 1
    }

    private func assertOnScreen(_ element: XCUIElement, in app: XCUIApplication, above field: XCUIElement,
                                _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), message, file: file, line: line)
        // Long enough for the send's notices to settle under the transcript.
        Thread.sleep(forTimeInterval: 2)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && !isOnScreen(element, in: app, above: field) {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(isOnScreen(element, in: app, above: field),
                      "\(message): \(element.frame) in \(transcript(app).frame), field at \(field.frame.minY)",
                      file: file, line: line)
    }

    /// Drags the transcript toward its start, below the floating header
    /// and above the composer, so neither the mascot nor the keyboard
    /// takes the drag.
    private func scrollUp(_ app: XCUIApplication, times: Int) {
        let list = transcript(app)
        for _ in 0..<times {
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
                .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        }
        Thread.sleep(forTimeInterval: 1)
    }

    /// Typing, then reading back up with the keyboard still up.
    func testSendingWithTheKeyboardUpShowsTheSentMessage() {
        let app = launch()
        let field = app.textViews["composer.field"]
        field.tap(); field.typeText("末尾へ戻る確認")
        scrollUp(app, times: 3)
        XCTAssertFalse(isOnScreen(row(app, "長い会話の24件目"), in: app, above: field), "the chat was scrolled up from its end")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the keyboard is still up")
        capture(app, "send-scroll-keyboard-scrolled-up")
        app.buttons["composer.action"].tap()
        assertOnScreen(row(app, "末尾へ戻る確認"), in: app, above: field, "the sent message is in view after Send")
        capture(app, "send-scroll-keyboard-after-send")
    }

    /// The chat near its start, the draft written in the full editor.
    func testSendingFromTheFullEditorShowsTheSentMessage() {
        let app = launch()
        let field = app.textViews["composer.field"]
        scrollUp(app, times: 8)
        XCTAssertFalse(isOnScreen(row(app, "長い会話の24件目"), in: app, above: field), "the chat was scrolled up from its end")
        capture(app, "send-scroll-full-editor-scrolled-up")
        app.buttons["composer.expand-editor"].tap()
        let full = app.textViews["composer.fullEditor.field"]
        XCTAssertTrue(full.waitForExistence(timeout: 5))
        full.typeText("最大化から送信")
        app.buttons.matching(identifier: "composer.action").allElementsBoundByIndex.last!.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        assertOnScreen(row(app, "最大化から送信"), in: app, above: field, "the full editor's send also shows it")
        capture(app, "send-scroll-full-editor-after-send")
    }
}
#endif

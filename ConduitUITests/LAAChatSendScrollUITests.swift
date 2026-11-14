#if LAA_BUILD
import XCTest

/// Sending always brings the chat to its end, wherever the owner had
/// scrolled (owner, 2026-11-12): with the keyboard up, and from the full
/// editor.
final class LAAChatSendScrollUITests: XCTestCase {
    private func launch(fixture: String = "long") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_V2_CHAT_FIXTURE", fixture,
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

    // MARK: - A reader scrolled up stays; otherwise the chat is at its end (owner, 2026-11-13)

    /// The first fixture row wholly on screen in the transcript's upper
    /// half, and where it sits.
    private func anchor(_ app: XCUIApplication, above field: XCUIElement,
                        among rows: ClosedRange<Int> = 1...24) -> (index: Int, minY: CGFloat)? {
        let middle = transcript(app).frame.midY
        for index in rows {
            let element = row(app, "長い会話の\(index)件目")
            if isOnScreen(element, in: app, above: field), element.frame.maxY < middle {
                return (index, element.frame.minY)
            }
        }
        return nil
    }

    private func assertStill(_ app: XCUIApplication, _ place: (index: Int, minY: CGFloat), above field: XCUIElement,
                             _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        Thread.sleep(forTimeInterval: 2)
        let element = row(app, "長い会話の\(place.index)件目")
        XCTAssertTrue(element.exists, message, file: file, line: line)
        XCTAssertEqual(element.frame.minY, place.minY, accuracy: 2,
                       "\(message): row \(place.index) moved", file: file, line: line)
        XCTAssertFalse(isOnScreen(row(app, "長い会話の24件目"), in: app, above: field),
                       "\(message): the chat went to its end", file: file, line: line)
    }

    /// Focusing the composer and the keyboard coming up leave a reader
    /// scrolled up where they were.
    func testFocusingTheComposerWhileScrolledUpKeepsThePlace() throws {
        let app = launch()
        let field = app.textViews["composer.field"]
        scrollUp(app, times: 3)
        let place = try XCTUnwrap(anchor(app, above: field), "a row to watch in the upper half")
        capture(app, "scroll-rule-reading-before-focus")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        assertStill(app, place, above: field, "focusing the composer while reading back")
        capture(app, "scroll-rule-reading-after-focus")
        field.typeText("読み戻し中の入力")
        assertStill(app, place, above: field, "typing while reading back")
    }

    /// At the end, the keyboard coming up keeps the latest message above it.
    func testFocusingTheComposerAtTheEndKeepsTheLatestMessageInView() {
        let app = launch()
        let field = app.textViews["composer.field"]
        assertOnScreen(row(app, "長い会話の24件目"), in: app, above: field, "the chat opens at its end")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        assertOnScreen(row(app, "長い会話の24件目"), in: app, above: field, "the latest message stays above the keyboard")
        capture(app, "scroll-rule-following-after-focus")
    }

    /// A chat many screens long opens on its latest message, and a reader who
    /// scrolls up from there stays where they stopped.
    func testAChatManyScreensLongOpensOnItsLatestMessage() throws {
        let app = launch(fixture: "long120")
        let field = app.textViews["composer.field"]
        assertOnScreen(row(app, "長い会話の120件目"), in: app, above: field, "a long chat opens at its end")
        capture(app, "scroll-rule-open-120-rows")
        scrollUp(app, times: 3)
        let place = try XCTUnwrap(anchor(app, above: field, among: 60...119), "a row to watch in the upper half")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(row(app, "長い会話の\(place.index)件目").frame.minY, place.minY, accuracy: 2,
                       "row \(place.index) moved while the reader rested")
        XCTAssertFalse(isOnScreen(row(app, "長い会話の120件目"), in: app, above: field), "the reader was not taken back to the end")
    }

    /// Hiding the keyboard resizes the viewport without moving a reader's row.
    func testDismissingTheKeyboardWhileScrolledUpKeepsThePlace() throws {
        let app = launch()
        let field = app.textViews["composer.field"]
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        scrollUp(app, times: 3)
        let place = try XCTUnwrap(anchor(app, above: field), "a row to watch before hiding the keyboard")
        capture(app, "scroll-rule-reading-before-dismiss")
        dismissKeyboard(app)
        assertStill(app, place, above: field, "hiding the keyboard while reading back")
        capture(app, "scroll-rule-reading-after-dismiss")
    }

    /// At the end, the enlarged viewport still ends above the composer.
    func testDismissingTheKeyboardAtTheEndKeepsTheLatestMessageInView() {
        let app = launch()
        let field = app.textViews["composer.field"]
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        assertOnScreen(row(app, "長い会話の24件目"), in: app, above: field, "at the end before hiding the keyboard")
        dismissKeyboard(app)
        assertOnScreen(row(app, "長い会話の24件目"), in: app, above: field, "at the end after hiding the keyboard")
        capture(app, "scroll-rule-following-after-dismiss")
    }

    private func dismissKeyboard(_ app: XCUIApplication) {
        // A tap, rather than a drag that would itself change the scroll position.
        transcript(app).coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 5)
    }

    /// Leaving the app and coming back: a reader scrolled up finds their
    /// place, a chat at its end is still at its end.
    func testComingBackToTheAppKeepsThePlaceOrTheEnd() throws {
        let app = launch()
        let field = app.textViews["composer.field"]
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        assertOnScreen(row(app, "長い会話の24件目"), in: app, above: field, "back at the end after returning")
        capture(app, "scroll-rule-following-after-return")

        scrollUp(app, times: 3)
        let place = try XCTUnwrap(anchor(app, above: field), "a row to watch in the upper half")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        assertStill(app, place, above: field, "returning to the app while reading back")
        capture(app, "scroll-rule-reading-after-return")
    }
}
#endif

#if LAA_BUILD
import XCTest

/// A hold on a message's text in Chat selects the word under the finger,
/// shows the handles and the system's edit menu, and Copy takes only that
/// part, as Safari and Notes do (owner, 2026-11-16). The message's own
/// actions are the row under it; there is no long-press menu.
final class LAAMessageHoldSelectUITests: XCTestCase {
    private func launch(dark: Bool, fixture: String = "simple", white: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_V2_CHAT_FIXTURE", fixture,
                               "-LAA_CAPTURE_SURFACE", "chat", "-LAA_CAPTURE_KIND", "photo",
                               "-LAA_FIXTURE_PUSH_CHAT",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
            + (dark ? ["-LAA_V2_DARK"] : []) + (white ? ["-LAA_CAPTURE_WHITE"] : [])
        app.launchInLab()
        XCTAssertTrue(app.staticTexts["fixture.capture.ready"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.textViews["composer.field"].waitForExistence(timeout: 15))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    private func copyItem(_ app: XCUIApplication) -> XCUIElement {
        app.menuItems.matching(NSPredicate(format: "label IN %@", ["コピー", "Copy"])).firstMatch
    }

    /// The message's text view: the bubble's only text.
    private func text(of speaker: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "chat.message.\(speaker)").firstMatch
            .textViews.firstMatch
    }

    /// Holds on the text, copies what the hold selected, and pastes it into
    /// the composer: the result is a part of the message, not all of it.
    private func holdCopiesPart(of speaker: String, whole: String, _ app: XCUIApplication, shot: String? = nil) {
        let target = text(of: speaker, app)
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 1.0)
        let copy = copyItem(app)
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "the hold selects text and shows the edit menu")
        XCTAssertFalse(app.buttons["テキストを選択"].exists, "no message menu")
        XCTAssertFalse(app.buttons["❤️"].exists, "no reaction strip")
        if let shot {
            Thread.sleep(forTimeInterval: 0.6)
            capture(app, shot)
        }
        copy.tap()
        let field = app.textViews["composer.field"]
        field.tap()
        field.press(forDuration: 1.2)
        let paste = app.menuItems.matching(NSPredicate(format: "label IN %@", ["ペースト", "Paste"])).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        let pasted = (field.value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(pasted.isEmpty)
        XCTAssertTrue(whole.contains(pasted), "pasted \(pasted) is a part of the message")
        XCTAssertLessThan(pasted.count, whole.count, "only the selected part is copied")
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testHoldOnAReplySelectsAndCopiesAPart() {
        let app = launch(dark: false)
        defer { app.terminate() }
        holdCopiesPart(of: "assistant", whole: "午前は予定を確認し、午後は資料を仕上げましょう。", app)
    }

    func testHoldOnTheOwnersMessageSelectsAndCopiesAPart() {
        let app = launch(dark: false)
        defer { app.terminate() }
        holdCopiesPart(of: "user", whole: "今日の予定を整理して。", app)
    }

    /// The row carries what the menu had (owner, 2026-11-16 07:00): コピー
    /// and 返信 under both sides, リアクション and グッド under a reply (読み上げ
    /// too where a voice is set up). The reaction picker adds a reaction.
    func testActionsStayInTheRowUnderTheMessage() {
        let app = launch(dark: false)
        defer { app.terminate() }
        XCTAssertTrue(text(of: "assistant", app).waitForExistence(timeout: 10))
        for id in ["copy", "reply", "react", "like"] {
            XCTAssertTrue(app.buttons.matching(identifier: "chat.message.\(id)").firstMatch.exists, id)
        }
        XCTAssertEqual(app.buttons.matching(identifier: "chat.message.copy").count, 2)
        XCTAssertEqual(app.buttons.matching(identifier: "chat.message.reply").count, 2)
        XCTAssertFalse(app.buttons.matching(identifier: "chat.message.quote").firstMatch.exists)
        app.buttons.matching(identifier: "chat.message.react").firstMatch.tap()
        let heart = app.buttons["chat.message.reaction.❤️"]
        XCTAssertTrue(heart.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chat.message.reaction.add"].exists)
        Thread.sleep(forTimeInterval: 0.5)
        capture(app, "reaction-picker-light")
        heart.tap()
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "❤️")).firstMatch.waitForExistence(timeout: 5))
        app.buttons.matching(identifier: "chat.message.reply").element(boundBy: 1).tap()
        XCTAssertTrue(app.buttons["composer.reply-reference.remove"].waitForExistence(timeout: 5))
        capture(app, "row-after-reaction-and-reply-light")
    }

    /// The selection in light and dark over a background picture (and the
    /// brightest picture the dimming allows), for the owner's review
    /// (`laa-0700-20261116/shots/select`).
    func testCaptureHoldSelection() {
        for (dark, white) in [(false, false), (true, false), (false, true), (true, true)] {
            let app = launch(dark: dark, white: white)
            holdCopiesPart(of: "assistant", whole: "午前は予定を確認し、午後は資料を仕上げましょう。", app,
                           shot: "select-\(dark ? "dark" : "light")\(white ? "-photo-white" : "")")
            app.terminate()
        }
    }
}
#endif

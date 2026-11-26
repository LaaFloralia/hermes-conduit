#if LAA_BUILD
import XCTest

/// An employee's chat says that employee's thinking word while it waits:
/// the same word for the whole wait, a fresh pick for the next one; a chat
/// that is not an employee's says Thinking (D-01, owner 2026-11-26). The
/// owner's table and a fixed seed come from the Debug fixture, so the picks
/// are known: Monet's base, then the alternative 「ひらめけ、私」.
final class LAAStaffThinkingUITests: XCTestCase {
    private func launch(profile: String, dark: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_V2_CHAT_FIXTURE", "typing",
                               "-LAA_CAPTURE_SURFACE", "chat", "-LAA_CAPTURE_KIND", "paper", "-LAA_FIXTURE_PUSH_CHAT",
                               "-LAA_FIXTURE_PROFILE", profile, "-LAA_FIXTURE_STAFF_THINKING",
                               "-LAA_FIXTURE_THINKING_SEED", "8", "-LAA_FIXTURE_WAIT_CYCLE"]
            + (dark ? ["-LAA_V2_DARK"] : [])
        app.launchInLab()
        XCTAssertTrue(app.staticTexts["fixture.capture.ready"].waitForExistence(timeout: 30))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    /// The pill's word as VoiceOver reads it: without its emoji.
    private func word(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(identifier: "chat.working.word").firstMatch
    }

    /// The transcript's typing row as VoiceOver reads it (its value).
    private func row(_ app: XCUIApplication) -> String? {
        app.buttons["chat.typing"].firstMatch.value as? String
    }

    func testEmployeeWordHoldsForTheWaitAndIsPickedAgainForTheNext() {
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            let app = launch(profile: "laa-monet", dark: dark)
            let label = word(app)
            XCTAssertTrue(label.waitForExistence(timeout: 10))
            XCTAssertEqual(label.label, "むむむ…", "Monet's base word, read without its emoji")
            XCTAssertEqual(row(app), label.label, "The typing row says the pill's word")
            capture(app, "monet-wait1-\(theme)")
            sleep(4)
            XCTAssertEqual(word(app).label, "むむむ…", "The same word later in the same wait")
            XCTAssertEqual(row(app), "むむむ…")
            capture(app, "monet-wait1-later-\(theme)")
            // The reply lands, the chat is idle, then the next wait starts.
            XCTAssertTrue(waitUntil(timeout: 20) { !self.word(app).exists }, "The pill goes when the wait ends")
            XCTAssertTrue(word(app).waitForExistence(timeout: 20), "The next wait shows the pill again")
            XCTAssertEqual(word(app).label, "ひらめけ、私", "The next wait picks again: an alternative")
            XCTAssertTrue(waitUntil(timeout: 5) { self.row(app) == "ひらめけ、私" }, "The row follows the next pick")
            capture(app, "monet-wait2-\(theme)")
            app.terminate()
        }
    }

    func testAChatThatIsNotAnEmployeesSaysThinking() {
        for dark in [false, true] {
            let app = launch(profile: "default", dark: dark)
            XCTAssertTrue(word(app).waitForExistence(timeout: 10))
            XCTAssertEqual(word(app).label, "Thinking")
            XCTAssertEqual(row(app), "考え中", "A chat with no words keeps the row's text")
            capture(app, "not-employee-thinking-\(dark ? "dark" : "light")")
            app.terminate()
        }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }
}
#endif

#if LAA_BUILD
import XCTest

/// The working capsule in a real chat (D-21 C, 2026-11-27): small while
/// thinking, large with three agents and with five (`+2`), at the largest
/// text size and with the keyboard up. It never overlaps the composer, and
/// the time and the count stay inside it. Synthetic delegate agents only
/// (`-LAA_FIXTURE_WORKING_AGENTS`); nothing reaches a Bridge.
final class LAAWorkingControlCaptureUITests: XCTestCase {
    private func launch(agents: Int, largestText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_V2_CHAT_FIXTURE", "typing",
                               "-LAA_CAPTURE_SURFACE", "chat", "-LAA_CAPTURE_KIND", "paper", "-LAA_FIXTURE_PUSH_CHAT",
                               "-LAA_FIXTURE_PROFILE", "laa-monet", "-LAA_FIXTURE_STAFF_THINKING",
                               "-LAA_FIXTURE_THINKING_SEED", "8", "-LAA_FIXTURE_WORKING_AGENTS", String(agents)]
            + (largestText ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : [])
        app.launchInLab()
        XCTAssertTrue(app.staticTexts["fixture.capture.ready"].waitForExistence(timeout: 30))
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    /// The capsule sits above the composer, and its time and count are inside it.
    private func checkPlacement(_ app: XCUIApplication, agents: Int, _ label: String) {
        let pill = element(app, "chat.working")
        XCTAssertTrue(pill.waitForExistence(timeout: 10), label)
        let field = app.textViews["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), label)
        XCTAssertLessThanOrEqual(pill.frame.maxY, field.frame.minY, "\(label): the capsule overlaps the composer")
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.contains(pill.frame), "\(label): the capsule leaves the screen \(pill.frame)")
        let elapsed = element(app, "chat.working.elapsed")
        XCTAssertTrue(elapsed.exists, label)
        XCTAssertTrue(pill.frame.contains(elapsed.frame), "\(label): the time is cut \(elapsed.frame) in \(pill.frame)")
        guard agents > 0 else {
            XCTAssertFalse(element(app, "chat.working.children").exists, label)
            return
        }
        let count = element(app, "chat.working.children")
        XCTAssertTrue(count.exists, label)
        XCTAssertEqual(count.label, agents == 1 ? "Agent 1" : "Agents \(agents)", label)
        XCTAssertTrue(pill.frame.contains(count.frame), "\(label): the count is cut \(count.frame) in \(pill.frame)")
        for index in 0..<min(agents, 3) {
            let row = element(app, "chat.working.child.\(index)")
            XCTAssertTrue(row.exists, "\(label): row \(index)")
            XCTAssertFalse(row.label.contains("子｜"), "\(label): row \(index) keeps the prefix: \(row.label)")
        }
        XCTAssertFalse(element(app, "chat.working.child.3").exists, label)
        XCTAssertEqual(element(app, "chat.working.more").exists, agents > 3, label)
        if agents > 3 { XCTAssertEqual(element(app, "chat.working.more").label, "+\(agents - 3)") }
    }

    func testThinkingThreeAndFiveAgents() {
        for agents in [0, 3, 5] {
            let app = launch(agents: agents)
            checkPlacement(app, agents: agents, "agents-\(agents)")
            capture(app, "working-agents-\(agents)")
            app.terminate()
        }
    }

    func testLargestTextKeepsTimeAndCount() {
        for agents in [0, 5] {
            let app = launch(agents: agents, largestText: true)
            checkPlacement(app, agents: agents, "ax5-agents-\(agents)")
            capture(app, "working-ax5-agents-\(agents)")
            app.terminate()
        }
    }

    func testKeyboardShownKeepsTheCapsuleAboveTheComposer() {
        let app = launch(agents: 3)
        let field = app.textViews["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        let keyboard = app.keyboards.firstMatch
        let shown = keyboard.waitForExistence(timeout: 5)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        checkPlacement(app, agents: 3, "keyboard")
        if shown { XCTAssertLessThanOrEqual(field.frame.maxY, keyboard.frame.minY + 1, "The composer stays above the keyboard") }
        let note = XCTAttachment(string: "keyboard shown: \(shown)")
        note.name = "keyboard-state"; note.lifetime = .keepAlways; add(note)
        capture(app, "working-keyboard-agents-3")
    }
}
#endif

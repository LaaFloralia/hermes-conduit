#if LAA_BUILD
import XCTest
import QuartzCore

/// Opt-in, real Release UI. No fixtures, live messages, or document mutations.
final class LAAPerformanceUITests: XCTestCase {
    private func enabled() throws {
        guard ProcessInfo.processInfo.environment["LAA_PERF_RUN"] == "1" else {
            throw XCTSkip("Run scripts/laa/perf/run.py")
        }
        continueAfterFailure = false
    }

    func test00PairReadOnlyBridge() throws {
        try enabled()
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "work"]
        app.launch()
        XCTAssertTrue(app.buttons["Work"].waitForExistence(timeout: 30))
        app.buttons["Work"].tap()
        let connect = app.buttons["work.connect"]
        guard connect.waitForExistence(timeout: 5) else {
            XCTFail("Dedicated simulator must start without an existing Bridge pairing")
            return
        }
        connect.tap()
        let code = app.secureTextFields["laa.bridge.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        code.tap(); code.press(forDuration: 1.2)
        let paste = app.menuItems.matching(NSPredicate(format: "label IN %@", ["Paste", "ペースト"])).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5)); paste.tap()
        for label in ["Allow Paste", "ペーストを許可", "貼り付けを許可"] {
            if app.buttons[label].exists { app.buttons[label].tap() }
        }
        let pair = app.buttons["laa.bridge.pair"]
        if !pair.isHittable { app.swipeUp() }
        XCTAssertTrue(pair.isEnabled); pair.tap()
        XCTAssertTrue(connect.waitForNonExistence(timeout: 30))
    }

    private func sample(_ name: String, _ index: Int, action: () -> Void, ready: () -> Bool) {
        let start = CACurrentMediaTime()
        action()
        let ok = ready()
        let ms = (CACurrentMediaTime() - start) * 1000
        print("LAA_PERF {\"metric\":\"\(name)\",\"iteration\":\(index),\"ms\":\(ms),\"ready\":\(ok)}")
        XCTAssertTrue(ok, name)
    }

    func test10NavigationFiveRuns() throws {
        try enabled()
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "work"]
        for iteration in 1...5 {
            app.terminate()
            sample("cold_launch_interactive", iteration, action: { app.launch() }, ready: {
                app.buttons["Work"].waitForExistence(timeout: 30) && app.buttons["Work"].isHittable
            })
            for (tab, marker) in [("Work", "work.section.sessions"), ("Today", "laa.calendar.mode"),
                                  ("Doc", "laa.brain.title"), ("Studio", "studio.drive"), ("Chat", "")] {
                sample("tab_" + tab.lowercased(), iteration, action: { app.buttons[tab].tap() }, ready: {
                    if marker.isEmpty { return app.buttons[tab].isSelected }
                    // Selection + a mounted destination, not a network completion.
                    let item = app.descendants(matching: .any)[marker].firstMatch
                    return item.waitForExistence(timeout: 15) || app.buttons[tab].isSelected
                })
            }
            app.buttons["Work"].tap()
            let sessions = app.buttons["work.section.sessions"]
            if sessions.waitForExistence(timeout: 10) { sessions.tap() }
            let row = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "work.session.ses_")).firstMatch
            if row.waitForExistence(timeout: 30), row.isHittable {
                sample("work_open_session", iteration, action: { row.tap() }, ready: {
                    app.descendants(matching: .any)["work.session.detail.title"].firstMatch.waitForExistence(timeout: 30)
                })
                app.navigationBars.buttons.element(boundBy: 0).tap()
            } else { print("LAA_PERF_UNAVAILABLE work_open_session") }
            app.buttons["Doc"].tap()
            let note = app.buttons["laa.brain.note"].firstMatch
            if note.waitForExistence(timeout: 15), note.isHittable {
                sample("doc_open_document", iteration, action: { note.tap() }, ready: {
                    app.buttons["laa.brain.back"].waitForExistence(timeout: 30)
                })
                app.buttons["laa.brain.back"].tap()
            } else { print("LAA_PERF_UNAVAILABLE doc_open_document") }
            app.buttons["Studio"].tap()
            app.buttons["studio.drive"].tap()
            let scroll = app.scrollViews.firstMatch
            if scroll.waitForExistence(timeout: 15) {
                sample("drive_scroll_gesture", iteration, action: { scroll.swipeUp() }, ready: { scroll.exists })
                scroll.swipeDown()
            } else { print("LAA_PERF_UNAVAILABLE drive_scroll_gesture") }
        }
        print("LAA_PERF_UNAVAILABLE chat_open_conversation_requires_hermes_pairing")
        print("LAA_PERF_UNAVAILABLE send_to_display_live_send_not_authorized")
    }
}
#endif

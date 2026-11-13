#if LAA_BUILD
import XCTest

/// Archiving from the Work list, against the synthetic Work fixture
/// (`scripts/laa/work-ui-fixture.mjs`). A short swipe from left to right
/// shows the archive button; choosing it asks first, and only OK archives.
/// A session still at work is refused by the Bridge (409 session_running):
/// its row stays and the reason is shown (2026-11-13).
final class LAAWorkArchiveUITests: XCTestCase {
    private let fixturePort = Int(ProcessInfo.processInfo.environment["LAA_WORK_FIXTURE_PORT"] ?? "") ?? 19584
    private let idleID = "ses_1111111111111111"
    private let runningID = "ses_5555555555555555"

    @discardableResult
    private func fixture(_ path: String) -> [String: Any]? {
        let done = expectation(description: "fixture \(path)")
        var payload: [String: Any]?
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(fixturePort + 1)\(path)")!) { data, _, _ in
            if let data { payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return payload
    }

    private func archiveRequests() -> [[String: Any]] {
        fixture("/state")?["archiveRequests"] as? [[String: Any]] ?? []
    }

    private func launch() throws -> XCUIApplication {
        guard fixture("/reset") != nil else { throw XCTSkip("Start scripts/laa/work-ui-fixture.mjs") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "work", "-LAA_UI_TEST_ISOLATED_BRIDGE",
                               "-conduit.themePreference", "light",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchEnvironment["LAA_BRIDGE_DEFAULT_ADDRESS"] = "http://127.0.0.1:\(fixturePort)"
        app.launch()
        XCTAssertTrue(app.buttons["work.connect"].waitForExistence(timeout: 30))
        app.buttons["work.connect"].tap()
        let code = app.secureTextFields["laa.bridge.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        code.tap(); code.typeText("TEST-TEST")
        let pair = app.buttons["laa.bridge.pair"]
        if !pair.isHittable { app.swipeUp() }
        pair.tap()
        XCTAssertTrue(app.buttons["work.section.sessions"].waitForExistence(timeout: 30))
        app.buttons["work.section.sessions"].tap()
        return app
    }

    private func row(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        let row = app.staticTexts["work.session.\(id)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "row \(id) never appeared")
        var swipes = 0
        while !row.isHittable && swipes < 4 { app.scrollViews.firstMatch.swipeUp(); swipes += 1 }
        return row
    }

    /// A short, slow drag to the right that stops well before a full swipe.
    private func partialSwipe(_ row: XCUIElement, _ app: XCUIApplication) {
        let window = app.windows.firstMatch
        let y = row.frame.midY
        let start = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 60, dy: y))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 70, dy: 0)),
                    withVelocity: XCUIGestureVelocity(120), thenHoldForDuration: 0.3)
    }

    private func archiveButton(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.buttons["work.session.archive.\(id)"].firstMatch
    }

    private func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPartialSwipeShowsArchiveAndOnlyOKArchives() throws {
        let app = try launch()
        let target = row(idleID, app)
        partialSwipe(target, app)
        shot("1-short-swipe-shows-archive", app)
        let button = archiveButton(idleID, app)
        XCTAssertTrue(button.waitForExistence(timeout: 5), "a short swipe did not show the archive button")
        XCTAssertTrue(button.isHittable, "the archive button is not on screen")
        XCTAssertTrue(archiveRequests().isEmpty, "the short swipe archived by itself")

        button.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "archiving did not ask first")
        shot("2-confirmation", app)
        alert.buttons["キャンセル"].tap()
        XCTAssertFalse(alert.waitForExistence(timeout: 1))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(archiveRequests().isEmpty, "Cancel still sent an archive")
        XCTAssertTrue(app.staticTexts["work.session.\(idleID)"].firstMatch.exists, "Cancel removed the row")

        partialSwipe(row(idleID, app), app)
        XCTAssertTrue(archiveButton(idleID, app).waitForExistence(timeout: 5))
        archiveButton(idleID, app).tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.firstMatch.buttons["work.archive.confirm"].firstMatch.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                             object: app.staticTexts["work.session.\(idleID)"].firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed, "OK did not archive the row")
        let sent = archiveRequests()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["id"] as? String, idleID)
        XCTAssertEqual(sent.first?["archived"] as? Bool, true)
        shot("3-archived", app)
    }

    /// A full swipe asks first too; it never archives on its own.
    func testFullSwipeAsksFirst() throws {
        let app = try launch()
        let target = row(idleID, app)
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 40, dy: target.frame.midY))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 300, dy: 0)))
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "a full swipe did not ask first")
        XCTAssertTrue(archiveRequests().isEmpty, "a full swipe archived before the answer")
        alert.buttons["キャンセル"].tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(archiveRequests().isEmpty)
        XCTAssertTrue(app.staticTexts["work.session.\(idleID)"].firstMatch.exists)
    }

    func testRefusedArchiveKeepsTheRowAndSaysWhy() throws {
        let app = try launch()
        partialSwipe(row(runningID, app), app)
        XCTAssertTrue(archiveButton(runningID, app).waitForExistence(timeout: 5))
        archiveButton(runningID, app).tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.firstMatch.buttons["work.archive.confirm"].firstMatch.tap()

        let refusal = app.alerts["アーカイブできませんでした"]
        XCTAssertTrue(refusal.waitForExistence(timeout: 10), "the refusal was not shown")
        XCTAssertTrue(refusal.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "実行中")).firstMatch.exists,
                      "the refusal does not say why")
        shot("4-refused", app)
        XCTAssertEqual(archiveRequests().count, 1, "the archive was not sent")
        refusal.buttons["OK"].tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(app.staticTexts["work.session.\(runningID)"].firstMatch.exists, "a refused archive removed the row")
        shot("5-row-kept", app)
    }
}
#endif

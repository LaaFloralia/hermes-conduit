#if LAA_BUILD
import XCTest

final class LAAPaseoUITests: XCTestCase {
    func testSessionListAndQuestionLight() throws { try verify("light") }
    func testSessionListAndQuestionDark() throws { try verify("dark") }

    /// The conversation's name lives in the bar, and the field under it is the
    /// one-line row: no heading card, no second title, no dictation.
    func testSessionHeaderIsTheBarAndTheRowIsOneLine() throws {
        for theme in ["light", "dark"] { try verifySessionDetail(theme) }
    }

    private func verifySessionDetail(_ theme: String) throws {
        let app = try launchFixture(theme)
        let row = app.staticTexts["work.session.ses_1111111111111111"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let title = app.descendants(matching: .any)["work.session.detail.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertLessThan(title.frame.minY, 120, "the heading belongs in the navigation bar")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '最終活動'")).firstMatch.exists)
        XCTAssertFalse(app.buttons["音声入力"].exists, "the follow-up field has no dictation")
        XCTAssertFalse(app.buttons["work.composer.textSize"].exists, "the compact field has no heading row")
        XCTAssertTrue(app.buttons["work.composer.photo"].waitForExistence(timeout: 15))
        let send = app.buttons["work.composer.send"].firstMatch
        XCTAssertTrue(send.exists)
        // This session is running, so the stop control shares Send's row.
        let stop = app.buttons["work.session.stop"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 15))
        XCTAssertEqual(stop.frame.midY, send.frame.midY, accuracy: 2)
        let records = app.buttons["work.session.records"]
        XCTAssertTrue(records.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Read"].exists, "Tool traffic stays collapsed")
        capture(app, "session-detail-closed", theme)
        records.tap()
        capture(app, "session-detail-open", theme)
        app.terminate()
    }

    func testSessionLeftSwipesKeepTheListOpen() throws {
        let app = try launchFixture("light")
        let row = app.staticTexts["work.session.ses_1111111111111111"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        let y = row.frame.midY
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width - 55, dy: y))
        // Slow enough that the row settles at the reveal width instead of
        // committing the way a fast flick does.
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -90, dy: 0)),
                    withVelocity: XCUIGestureVelocity(120), thenHoldForDuration: 0.3)
        capture(app, "partial-swipe", "light")
        XCTAssertFalse(app.descendants(matching: .any)["work.session.detail.title"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["work.create"].isHittable, "A partial swipe must not open the session")
        XCTAssertTrue(waitForFavorite(true), "A partial swipe must not change the pin")

        let fullStart = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width / 2, dy: y))
        let fullEnd = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 20, dy: y))
        fullStart.press(forDuration: 0.1, thenDragTo: fullEnd, withVelocity: XCUIGestureVelocity(900), thenHoldForDuration: 0.1)
        capture(app, "full-swipe", "light")
        XCTAssertFalse(app.descendants(matching: .any)["work.session.detail.title"].waitForExistence(timeout: 2))
        XCTAssertTrue(waitForFavorite(false), "A full swipe must pin or unpin without opening the session")
        XCTAssertTrue(app.buttons["work.create"].isHittable, "A full swipe must not open the session")

        let moved = app.staticTexts["work.session.ses_1111111111111111"].firstMatch
        XCTAssertTrue(moved.waitForExistence(timeout: 10))
        moved.tap()
        XCTAssertTrue(app.descendants(matching: .any)["work.session.detail.title"].waitForExistence(timeout: 15),
                      "A plain tap must still open the session")
    }

    func testProjectOpensAndArchivesWithASwipe() throws {
        let app = try launchFixture("light")
        app.buttons["work.sessions.menu"].tap()
        app.buttons["work.projects.manage"].tap()
        let row = app.descendants(matching: .any)["work.project.prj_aaaaaaaaaaaa"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        XCTAssertTrue(app.buttons["work.project.newSession"].waitForExistence(timeout: 15), "A plain tap must still open the project")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 15))

        func swipeRight(_ element: XCUIElement) {
            let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 300, dy: 0)),
                        withVelocity: XCUIGestureVelocity(900), thenHoldForDuration: 0.1)
        }
        swipeRight(row)
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "Archiving must take the project out of the list")
        capture(app, "project-archived", "light")
        app.buttons["work.projects.archiveToggle"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The archive must list the project")
        swipeRight(row)
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "Restoring must take it out of the archive")
        app.buttons["work.projects.archiveToggle"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "A restored project must be back in the list")
    }

    func testSessionDetailBackRestoresTabs() throws {
        let app = try launchFixture("light")
        let row = app.staticTexts["work.session.ses_1111111111111111"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Chat"].isHittable)
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["work.session.detail.title"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["Chat"].isHittable)
        app.navigationBars.buttons.firstMatch.tap()
        capture(app, "back-to-list", "light")
        for name in ["Chat", "Work", "Today", "Doc", "Studio"] {
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: app.buttons[name])
            XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed, "Tab did not return: \(name)")
        }
        app.buttons["Chat"].tap()
        XCTAssertFalse(app.buttons["work.create"].isHittable)
    }

    func testVerticalScrollDoesNotOpenOrPinSession() throws {
        let app = try launchFixture("light", longList: true)
        let last = app.staticTexts["work.session.ses_0000000000000016"].firstMatch
        XCTAssertFalse(last.isHittable)
        for _ in 0..<4 where !last.isHittable { app.swipeUp() }
        XCTAssertFalse(app.descendants(matching: .any)["work.session.detail.title"].exists)
        XCTAssertTrue(last.isHittable, "The row gesture must allow the surrounding page to scroll")
        XCTAssertTrue(waitForFavorite(true))
    }

    func testSwipeBackFromSessionDetailRestoresTabs() throws {
        let app = try launchFixture("light")
        let row = app.staticTexts["work.session.ses_1111111111111111"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["work.session.detail.title"].waitForExistence(timeout: 15))
        // The device report followed a horizontal drag, so cover the
        // interactive edge-swipe back gesture as well as the Back button.
        let edge = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 2, dy: app.frame.midY))
        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: app.frame.width * 0.85, dy: 0)))
        capture(app, "swipe-back", "light")
        assertTabsVisible(app, context: "after an edge-swipe back")
    }

    func testScrolledListDetailBackRestoresTabs() throws {
        let app = try launchFixture("light", longList: true)
        app.swipeUp()
        let row = app.staticTexts["work.session.ses_0000000000000003"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["work.session.detail.title"].waitForExistence(timeout: 15))
        app.navigationBars.buttons.firstMatch.tap()
        app.swipeDown()
        capture(app, "scrolled-back", "light")
        assertTabsVisible(app, context: "after returning from a scrolled list")
    }

    private func assertTabsVisible(_ app: XCUIApplication, context: String) {
        for name in ["Chat", "Work", "Today", "Doc", "Studio"] {
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: app.buttons[name])
            XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed, "Tab missing \(context): \(name)")
        }
    }

    private func waitForFavorite(_ value: Bool) -> Bool {
        let match = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let data = try? Data(contentsOf: URL(string: "http://127.0.0.1:19596/state")!),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = json["data"] as? [String: Any] else { return false }
            return state["favorite"] as? Bool == value
        }, object: nil)
        return XCTWaiter.wait(for: [match], timeout: 10) == .completed
    }

    private func launchFixture(_ appearance: String, longList: Bool = false) throws -> XCUIApplication {
        guard (try? Data(contentsOf: URL(string: "http://127.0.0.1:19596/reset?long=\(longList ? "1" : "0")")!)) != nil else {
            throw XCTSkip("Start scripts/laa/paseo-ui-fixture.mjs")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "work", "-LAA_UI_TEST_ISOLATED_BRIDGE", "-conduit.themePreference", appearance,
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchEnvironment["LAA_BRIDGE_DEFAULT_ADDRESS"] = "http://127.0.0.1:19596"
        app.launch()
        let connect = app.buttons["work.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 30))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: connect)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed, "The Work tab must settle before pairing")
        connect.tap()
        let code = app.secureTextFields["laa.bridge.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10)); code.tap(); code.typeText("TEST-TEST")
        let pair = app.buttons["laa.bridge.pair"]
        if !pair.isHittable { app.swipeUp() }
        pair.tap()
        let sessions = app.buttons["work.section.sessions"]
        XCTAssertTrue(sessions.waitForExistence(timeout: 15)); sessions.tap()
        let parent = app.staticTexts["work.session.ses_1111111111111111"].firstMatch
        XCTAssertTrue(parent.waitForExistence(timeout: 15))
        return app
    }

    private func verify(_ appearance: String) throws {
        let app = try launchFixture(appearance)
        let child = app.staticTexts["work.session.ses_2222222222222222"].firstMatch
        XCTAssertFalse(child.exists, "A child stays folded under its parent")
        capture(app, "list", appearance)
        let disclosure = app.buttons["work.session.ses_1111111111111111.children"]
        disclosure.tap()
        XCTAssertTrue(child.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["work.session.detail.title"].exists,
                       "Opening the children must not open the parent")
        capture(app, "list-open", appearance)
        child.tap()
        let question = app.staticTexts["どちらの構成で進めますか？"]
        XCTAssertTrue(question.waitForExistence(timeout: 15))
        capture(app, "question", appearance)
        app.buttons["A案"].tap()
        let reply = app.buttons["回答を送信"]
        XCTAssertTrue(reply.isEnabled); reply.tap()
        XCTAssertTrue(app.staticTexts["確認と回答"].waitForNonExistence(timeout: 15))
    }
    private func capture(_ app: XCUIApplication, _ name: String, _ appearance: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "paseo-\(name)-\(appearance)"; shot.lifetime = .keepAlways
        add(shot)
    }
}
#endif

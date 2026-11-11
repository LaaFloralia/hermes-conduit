#if LAA_BUILD
import XCTest

/// The screens the owner asked to compare, captured from the same Work fixture
/// as the placement tests. It only navigates and takes pictures, so the same
/// test runs against the version before the change and after it.
final class LAAWorkShotsUITests: XCTestCase {
    private let emptyID = "ses_1111111111111111"
    private let longID = "ses_3333333333333333"
    private let runningID = "ses_5555555555555555"
    /// The fixture's API port; control is the next one. `TEST_RUNNER_LAA_WORK_FIXTURE_PORT`
    /// moves both when another run holds the usual pair.
    private let port = Int(ProcessInfo.processInfo.environment["LAA_WORK_FIXTURE_PORT"] ?? "") ?? 19584

    func testShotsLight() throws { try shots("light") }
    func testShotsDark() throws { try shots("dark") }
    /// The Usage screens alone, for a comparison that needs the meters filled.
    func testUsageShotsLight() throws { try usageShots("light") }
    func testUsageShotsDark() throws { try usageShots("dark") }

    @discardableResult
    private func fixture(_ path: String) -> [String: Any]? {
        let done = expectation(description: "fixture \(path)")
        var payload: [String: Any]?
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(port + 1)\(path)")!) { data, _, _ in
            if let data { payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return payload
    }

    /// Work's four lists as the owner opens them: Sessions first, then the
    /// board, Tasks with its pulldown open, and the routines' day tree.
    func testListShotsLight() throws { try listShots("light") }
    func testListShotsDark() throws { try listShots("dark") }

    private func listShots(_ theme: String) throws {
        let app = try launch(theme, board: "normal")
        XCTAssertTrue(app.buttons["work.section.sessions"].isSelected)
        settle()
        capture(app, "list-sessions-\(theme)")

        app.buttons["work.section.decisions"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'work.decision.'")).firstMatch
            .waitForExistence(timeout: 20))
        settle(1)
        capture(app, "list-decisions-\(theme)")

        app.buttons["work.section.tasks"].tap()
        XCTAssertTrue(app.staticTexts["work.ref.T12"].waitForExistence(timeout: 20))
        settle(1)
        capture(app, "list-tasks-\(theme)")
        app.buttons["work.tasks.filter"].tap()
        XCTAssertTrue(app.buttons["work.linear.archive"].waitForExistence(timeout: 5))
        settle(1)
        capture(app, "list-tasks-menu-\(theme)")
        app.buttons["work.tasks.filter.related"].tap()

        app.buttons["work.section.routines"].tap()
        XCTAssertTrue(app.staticTexts["昼の市況メモ"].waitForExistence(timeout: 20))
        settle(1)
        capture(app, "list-routines-\(theme)")
        app.buttons.containing(.staticText, identifier: "昼の市況メモ").firstMatch.tap()
        settle(1)
        capture(app, "list-routines-open-\(theme)")
    }

    /// The task list at the owner's size (about thirty tasks in eight
    /// genres): genre sections, a folded section, the grouping menu, the due
    /// grouping, a quick filter, a ticked circle and the detail.
    func testTaskBoardShotsLight() throws { try taskBoardShots("light") }
    func testTaskBoardShotsDark() throws { try taskBoardShots("dark") }

    private func taskBoardShots(_ theme: String) throws {
        let app = try launch(theme, board: "normal", tasks: "many")
        app.buttons["work.section.tasks"].tap()
        // The first genre's first row; T12 (その他) sits further down.
        XCTAssertTrue(app.staticTexts["work.ref.T30"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["work.tasks.section.genre:app"].waitForExistence(timeout: 10))
        settle(1)
        capture(app, "tasks-genre-\(theme)")
        app.swipeUp(); settle(1)
        capture(app, "tasks-genre-scrolled-\(theme)")
        app.swipeDown(); app.swipeDown(); settle(1)

        // Fold the first section and see the next one move up.
        app.buttons["work.tasks.section.genre:app"].tap(); settle(1)
        capture(app, "tasks-genre-folded-\(theme)")
        app.buttons["work.tasks.section.genre:app"].tap(); settle(1)

        app.buttons["work.tasks.grouping"].tap()
        XCTAssertTrue(app.buttons["work.tasks.grouping.due"].waitForExistence(timeout: 5))
        settle(1)
        capture(app, "tasks-grouping-menu-\(theme)")
        app.buttons["work.tasks.grouping.due"].tap(); settle(1)
        capture(app, "tasks-due-\(theme)")
        app.buttons["work.tasks.grouping"].tap()
        app.buttons["work.tasks.grouping.assignee"].tap(); settle(1)
        capture(app, "tasks-assignee-\(theme)")
        app.buttons["work.tasks.grouping"].tap()
        app.buttons["work.tasks.grouping.genre"].tap(); settle(1)

        app.buttons["work.tasks.quick.attention"].tap(); settle(1)
        capture(app, "tasks-quick-attention-\(theme)")
        app.buttons["work.tasks.quick.all"].tap(); settle(1)

        // A ticked circle, caught inside its moment, then taken back.
        // T31, the second row of the first section.
        let check = app.buttons["work.task.check.7a1c3d5e-2222-4a2b-9c3d-000000000101"]
        if check.waitForExistence(timeout: 5), check.isHittable {
            check.tap()
            capture(app, "tasks-checked-\(theme)")
            check.tap(); settle(1)
        }

        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "タスク一覧をジャンル別に整える")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.staticTexts["work.task.detail.title"].firstMatch.waitForExistence(timeout: 15))
        settle(1)
        capture(app, "tasks-detail-\(theme)")
    }

    private func launch(_ theme: String, board: String? = nil, tasks: String? = nil) throws -> XCUIApplication {
        guard fixture("/reset") != nil else { throw XCTSkip("Start scripts/laa/work-ui-fixture.mjs") }
        if let board { fixture("/decisions/\(board)") }
        if let tasks { fixture("/tasks/\(tasks)") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "work", "-LAA_UI_TEST_ISOLATED_BRIDGE",
                               "-LAA_UI_TEST_CLEAR_WORK_STORE",
                               "-conduit.themePreference", theme,
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchEnvironment["LAA_BRIDGE_DEFAULT_ADDRESS"] = "http://127.0.0.1:\(port)"
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
        return app
    }

    private func open(_ id: String, _ app: XCUIApplication) {
        if !app.buttons["work.section.sessions"].exists { app.navigationBars.buttons.firstMatch.tap() }
        app.buttons["work.section.sessions"].tap()
        let row = app.staticTexts["work.session.\(id)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        var swipes = 0
        while !row.isHittable && swipes < 4 { app.scrollViews.firstMatch.swipeUp(); swipes += 1 }
        row.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 20))
        settle()
    }

    /// Let the conversation, its pictures and both placements finish.
    private func settle(_ seconds: TimeInterval = 3) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// An off-screen pill has no hit point, so the strip is moved with a drag
    /// on its own row rather than with `swipeLeft` on an element.
    private func scrollToUsage(_ app: XCUIApplication) {
        let usage = app.buttons["work.usage"]
        var moves = 0
        while usage.exists && usage.frame.maxX > app.frame.width - 8 && moves < 6 {
            let start = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: app.frame.width - 60, dy: usage.frame.midY))
            let end = start.withOffset(CGVector(dx: -300, dy: 0))
            start.press(forDuration: 0.05, thenDragTo: end,
                        withVelocity: XCUIGestureVelocity(500), thenHoldForDuration: 0.1)
            moves += 1
        }
        XCTAssertTrue(usage.exists, "the Usage section pill is missing")
    }

    /// The section pills scroll sideways; Usage is off the right edge until
    /// the strip is moved.
    private func openUsage(_ app: XCUIApplication) {
        scrollToUsage(app)
        app.buttons["work.usage"].tap()
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func usageShots(_ theme: String) throws {
        let app = try launch(theme)
        openUsage(app)
        XCTAssertTrue(app.staticTexts["AI"].waitForExistence(timeout: 25))
        // The screen's own refresh, which does not wait for the tab-open throttle.
        app.buttons["laa.usage.refresh"].tap()
        Thread.sleep(forTimeInterval: 3)
        capture(app, "usage-top-\(theme)")
        app.scrollViews.firstMatch.swipeUp()
        Thread.sleep(forTimeInterval: 1)
        capture(app, "usage-capacity-\(theme)")
    }

    private func shots(_ theme: String) throws {
        let app = try launch(theme)

        open(runningID, app)
        capture(app, "session-running-\(theme)")

        open(emptyID, app)
        capture(app, "session-review-\(theme)")

        open(longID, app)
        // The fixture holds the pictures for 8s; the last turn must be in the
        // shot, so wait for the end of the page to stop moving.
        Thread.sleep(forTimeInterval: 9)
        capture(app, "session-bottom-\(theme)")

        app.navigationBars.buttons.firstMatch.tap()
        openUsage(app)
        XCTAssertTrue(app.staticTexts["AI"].waitForExistence(timeout: 25))
        Thread.sleep(forTimeInterval: 3)
        capture(app, "usage-top-\(theme)")
        app.scrollViews.firstMatch.swipeUp()
        app.scrollViews.firstMatch.swipeUp()
        Thread.sleep(forTimeInterval: 1)
        capture(app, "usage-capacity-\(theme)")
    }
}
#endif

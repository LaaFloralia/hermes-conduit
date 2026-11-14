#if LAA_BUILD
import XCTest

/// Session detail placement, against the synthetic Work fixture
/// (`scripts/laa/work-ui-fixture.mjs`) instead of a live Mac conversation.
/// The fixture serves an empty session, a waiting decision, a long history
/// (65 turns, two pictures, tool calls) and the Fast variants.
final class LAAWorkSessionUITests: XCTestCase {
    private let fixturePort = Int(ProcessInfo.processInfo.environment["LAA_WORK_FIXTURE_PORT"] ?? "") ?? 19584

    private let emptyID = "ses_1111111111111111"
    private let decisionID = "ses_2222222222222222"
    private let longID = "ses_3333333333333333"
    private let staleID = "ses_4444444444444444"
    private let runningID = "ses_5555555555555555"
    private let noFastID = "ses_6666666666666666"
    private let readOnlyFastID = "ses_7777777777777777"
    private let decisionLongID = "ses_8888888888888888"
    /// The fixture's last turn; it is the marker for "the page is at its end".
    private let lastTurn = "S62M"

    /// The fixture control endpoint is reached off the main thread: a
    /// synchronous `Data(contentsOf:)` here raises the UI-unresponsiveness
    /// runtime warning.
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

    private func launchFixture(extra: [String] = []) throws -> XCUIApplication {
        guard fixture("/reset") != nil else { throw XCTSkip("Start scripts/laa/work-ui-fixture.mjs") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "work", "-LAA_UI_TEST_ISOLATED_BRIDGE",
                               "-conduit.themePreference", "light",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"] + extra
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
        return app
    }

    private func tapRow(_ id: String, _ app: XCUIApplication) {
        let row = app.staticTexts["work.session.\(id)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        var swipes = 0
        while !row.isHittable && swipes < 4 { app.scrollViews.firstMatch.swipeUp(); swipes += 1 }
        row.tap()
        XCTAssertTrue(header(app).waitForExistence(timeout: 20))
    }

    private func open(_ id: String, _ app: XCUIApplication) {
        app.buttons["work.section.sessions"].tap()
        tapRow(id, app)
    }

    private func header(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["work.session.detail.title"].firstMatch
    }

    /// The combined pill when the name Text is merged into it: match on the
    /// label rather than on which of the two elements came first.
    private func headerContaining(_ text: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "work.session.detail.title", text)).firstMatch
    }

    private func field(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["work.composer.field"].firstMatch
    }

    private func wait(_ element: XCUIElement, hittable: Bool, timeout: TimeInterval = 12) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == %@", NSNumber(value: hittable)),
            object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Wait for the fixture to have delivered the real image bytes, not just
    /// for an image view to exist in the hierarchy.
    private func waitForImageDelivery(atLeast count: Int = 1, timeout: TimeInterval = 25) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (fixture("/state")?["images"] as? Int ?? 0) >= count { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    /// Markdown is drawn in a selectable text view, so the last turn is a
    /// text view's value, not a static text.
    private func lastTurn(_ app: XCUIApplication) -> XCUIElement {
        app.textViews.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", lastTurn, lastTurn)).firstMatch
    }

    /// Opening a long conversation must land on its end without a scroll, and
    /// the row under it must be ready to send.
    private func assertOpensAtTheBottom(_ app: XCUIApplication, run: String) {
        let last = lastTurn(app)
        XCTAssertTrue(last.waitForExistence(timeout: 20), "the last turn never arrived: " + run)
        XCTAssertTrue(wait(last, hittable: true, timeout: 10), "the last turn is not on screen: " + run)
        let send = app.buttons["work.composer.send"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 10), run)
        XCTAssertTrue(field(app).isHittable, "the composer is not on screen: " + run)
        // A draft makes Send live; it must be reachable without scrolling.
        field(app).tap()
        field(app).typeText("x")
        XCTAssertTrue(wait(send, hittable: true, timeout: 5), "Send is not reachable: " + run)
        XCTAssertTrue(send.isEnabled, "Send did not become ready: " + run)
    }

    /// A new message arriving while the owner reads older turns must not pull
    /// the transcript back to the bottom.
    func testNewMessageWhileReadingHistoryKeepsThePlace() throws {
        let app = try launchFixture()
        open(longID, app)
        XCTAssertTrue(wait(field(app), hittable: true))
        app.scrollViews.firstMatch.swipeDown()
        app.scrollViews.firstMatch.swipeDown()
        XCTAssertTrue(wait(lastTurn(app), hittable: false, timeout: 5))
        XCTAssertTrue(field(app).isHittable)
        let before = fixture("/state")?["messages"] as? Int ?? 0
        fixture("/advance")
        let expected = fixture("/state")?["messages"] as? Int ?? 0
        XCTAssertEqual(expected, before + 1)
        // Wait until the fixture has actually delivered the conversation that
        // contains the new row. A client that stopped polling must fail here,
        // not pass because only the fixture's counter advanced.
        var served = fixture("/state")?["served"] as? Int ?? 0
        let deadline = Date().addingTimeInterval(12)
        while served < expected, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            served = fixture("/state")?["served"] as? Int ?? 0
        }
        XCTAssertEqual(served, expected, "The app did not fetch the conversation after /advance")
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertFalse(lastTurn(app).isHittable)
        XCTAssertTrue(field(app).isHittable)
        XCTAssertTrue(header(app).exists)
    }

    /// A failed observation keeps the last values in hand, but the bar says they
    /// are not current instead of presenting them as the live setting.
    func testFailedObservationMarksValuesAsLastConfirmed() throws {
        let app = try launchFixture()
        open(staleID, app)
        // The pill is always the menu now; its value still says "最終確認".
        let model = app.descendants(matching: .any)["work.session.effort"].firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 20))
        XCTAssertTrue((model.value as? String ?? "").contains("最終確認"))
        let fast = app.descendants(matching: .any)["work.session.fast"].firstMatch
        XCTAssertTrue(fast.waitForExistence(timeout: 10))
        XCTAssertEqual(fast.value as? String, "最終確認: オン")
        XCTAssertTrue(app.staticTexts["委譲先の状態を観測できていません。表示は最後に確認できた記録です。"].exists)
    }

    func testTitleOpensInitialInstructionAndCopies() throws {
        try verifyInitialInstruction(extra: [], screenshot: "initial-instruction-copy")
    }

    func testInitialInstructionSupportsLargeText() throws {
        try verifyInitialInstruction(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"],
                                     screenshot: "initial-instruction-large-text")
    }

    private func verifyInitialInstruction(extra: [String], screenshot: String) throws {
        let app = try launchFixture(extra: extra)
        open(emptyID, app)
        let title = app.buttons["work.session.detail.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        let text = app.descendants(matching: .any)["work.initialInstruction.text"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 15))
        XCTAssertTrue((text.label + (text.value as? String ?? "")).contains("最初の指示の全文です。"))
        let copy = app.buttons["work.initialInstruction.copy"]
        if !copy.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(copy.isHittable)
        copy.tap()
        XCTAssertEqual(copy.label, "コピーしました")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = screenshot; shot.lifetime = .keepAlways
        add(shot)
        app.buttons["work.initialInstruction.done"].tap()
        XCTAssertTrue(header(app).waitForExistence(timeout: 5))
    }

    func testEmptyConversationOpensAtTheComposer() throws {
        let app = try launchFixture()
        open(emptyID, app)
        XCTAssertTrue(app.staticTexts["会話はまだありません。"].waitForExistence(timeout: 20))
        XCTAssertTrue(wait(field(app), hittable: true))
        // A page that fits must stay at the top: a bottom-aligned short page
        // would push the heading and the composer down (the reported bug).
        let title = header(app)
        XCTAssertTrue(title.exists)
        XCTAssertLessThan(title.frame.minY, 300, "the heading belongs in the bar, above the page")
        XCTAssertTrue(headerContaining("空の会話", app).exists, "the bar must name the conversation")
    }

    func testWaitingDecisionOpensAtTheComposer() throws {
        let app = try launchFixture()
        open(decisionID, app)
        XCTAssertTrue(wait(field(app), hittable: true))
        XCTAssertTrue(app.staticTexts["判断待ち・停止中は追加送信できません。状態を確認してください。"].exists)
        XCTAssertTrue(headerContaining("判断待ち", app).exists)
    }

    /// A picture that arrives while the owner is reading older turns must not
    /// pull the transcript back to the bottom.
    func testLateImageWhileReadingHistoryDoesNotPullBack() throws {
        let app = try launchFixture()
        fixture("/hold-image")
        open(longID, app)
        XCTAssertTrue(wait(field(app), hittable: true))
        // One screen up: the last turn leaves the viewport while the fixed
        // composer remains reachable and the image row stays loaded.
        app.scrollViews.firstMatch.swipeDown()
        XCTAssertTrue(wait(lastTurn(app), hittable: false, timeout: 5))
        XCTAssertTrue(field(app).isHittable)
        XCTAssertEqual(fixture("/state")?["images"] as? Int ?? -1, 0)
        fixture("/release-image")
        XCTAssertTrue(waitForImageDelivery(timeout: 10))
        Thread.sleep(forTimeInterval: 0.5)
        // The fixture counter proves delivery; this proves the app decoded it
        // while the reader was away from the bottom.
        XCTAssertTrue(app.descendants(matching: .any)["work.session.image"].waitForExistence(timeout: 10),
                      "The released image was not decoded in the app")
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertFalse(lastTurn(app).isHittable)
        XCTAssertTrue(field(app).isHittable)
        XCTAssertTrue(header(app).exists)
    }

    func testLongHistoryOpensAtTheBottomAndKeepsThePlace() throws {
        let app = try launchFixture()
        open(longID, app)
        XCTAssertTrue(wait(field(app), hittable: true))
        // The long transcript opens at its bottom, not only "somewhere visible".
        XCTAssertGreaterThan(field(app).frame.minY, 400)
        let model = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ OR identifier == %@",
                        "work.session.effort", "work.session.model")).firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["work.session.fast"].waitForExistence(timeout: 10))
        // The fixture holds the pictures for 8s; after the real bytes arrive
        // the composer must still be on screen and at the bottom.
        XCTAssertTrue(waitForImageDelivery(timeout: 25))
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(app.descendants(matching: .any)["work.session.image"].waitForExistence(timeout: 10))
        XCTAssertTrue(wait(field(app), hittable: true, timeout: 5))
        XCTAssertGreaterThan(field(app).frame.minY, 400)
        XCTAssertTrue(header(app).exists)

        // Reading older turns leaves the fixed composer available; a later
        // events poll must not bring the last turn back into view.
        app.scrollViews.firstMatch.swipeDown()
        app.scrollViews.firstMatch.swipeDown()
        XCTAssertTrue(wait(lastTurn(app), hittable: false, timeout: 5))
        XCTAssertTrue(field(app).isHittable)
        Thread.sleep(forTimeInterval: 3.5)
        XCTAssertFalse(lastTurn(app).isHittable)
        XCTAssertTrue(field(app).isHittable)
        XCTAssertTrue(header(app).exists)
    }

    // MARK: - Opening placement, five runs in each condition

    /// (a) The app remembers the conversation: the page can be placed before
    /// the Mac answers.
    func testLongHistoryOpensAtTheBottomWithACachedConversation() throws {
        // One warm launch writes the app's saved copy; the five runs below
        // are cold launches that already have it.
        let warm = try launchFixture()
        open(longID, warm)
        XCTAssertTrue(wait(field(warm), hittable: true))
        warm.terminate()
        for run in 1...5 {
            let app = try launchFixture()
            open(longID, app)
            assertOpensAtTheBottom(app, run: "cached \(run)")
            app.terminate()
        }
    }

    /// (b) No saved copy: the page is placed when the history first arrives.
    func testLongHistoryOpensAtTheBottomWithoutACache() throws {
        for run in 1...5 {
            let app = try launchFixture(extra: ["-LAA_UI_TEST_CLEAR_WORK_STORE"])
            open(longID, app)
            assertOpensAtTheBottom(app, run: "no cache \(run)")
            app.terminate()
        }
    }

    /// (c) The Mac takes two seconds to answer the conversation read.
    func testLongHistoryOpensAtTheBottomWhenTheConversationIsSlow() throws {
        for run in 1...5 {
            let app = try launchFixture(extra: ["-LAA_UI_TEST_CLEAR_WORK_STORE"])
            fixture("/slow-conversation/on")
            open(longID, app)
            assertOpensAtTheBottom(app, run: "slow \(run)")
            app.terminate()
        }
    }

    // MARK: - The row and the heading

    /// One row under the field: picture, model, Fast, stop while running, Send.
    func testFollowUpRowKeepsEveryControlOnOneLine() throws {
        let app = try launchFixture()
        open(runningID, app)
        let photo = app.buttons["work.composer.photo"].firstMatch
        let model = app.descendants(matching: .any)["work.session.model"].firstMatch
        let effort = app.descendants(matching: .any)["work.session.effort"].firstMatch
        let fast = app.descendants(matching: .any)["work.session.fast"].firstMatch
        let stop = app.buttons["work.session.stop"].firstMatch
        let send = app.buttons["work.composer.send"].firstMatch
        for element in [photo, model, effort, fast, stop, send] {
            XCTAssertTrue(element.waitForExistence(timeout: 15), element.debugDescription)
            XCTAssertTrue(element.isHittable, element.debugDescription)
        }
        // One line: every control shares the row's centre.
        let midY = photo.frame.midY
        for element in [model, effort, fast, stop, send] {
            XCTAssertEqual(element.frame.midY, midY, accuracy: 2, "not on the row: \(element.debugDescription)")
        }
        // The model name is the only thing that gives way; the effort stays whole.
        XCTAssertLessThanOrEqual(model.frame.maxX, effort.frame.minX + 1)
        XCTAssertLessThanOrEqual(effort.frame.maxX, fast.frame.minX + 1)
        XCTAssertFalse((effort.value as? String ?? "").isEmpty)
        XCTAssertLessThanOrEqual(send.frame.maxX, app.frame.maxX - 4)
        XCTAssertGreaterThan(photo.frame.minX, 4)
        // The values stay whole: only the model text truncates.
        XCTAssertEqual(fast.label, "Fastモード")
        XCTAssertEqual(send.label, "送信")
        XCTAssertEqual(stop.label, "中断")
        // No dictation control anywhere on this screen.
        XCTAssertFalse(app.buttons["音声入力"].exists)
        XCTAssertFalse(app.buttons["音声入力を停止"].exists)
    }

    /// A model with no Fast shows no pill; one the Bridge will not change shows
    /// the value without a tap.
    func testFastPillHidesOrOnlyReadsWhereItCannotChange() throws {
        let app = try launchFixture()
        open(noFastID, app)
        XCTAssertTrue(wait(field(app), hittable: true))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(app.descendants(matching: .any)["work.session.fast"].exists,
                       "a model without Fast must not show the pill")
        app.navigationBars.buttons.firstMatch.tap()

        tapRow(readOnlyFastID, app)
        let fast = app.descendants(matching: .any)["work.session.fast"].firstMatch
        XCTAssertTrue(fast.waitForExistence(timeout: 15))
        XCTAssertEqual(fast.value as? String, "オン")
        XCTAssertFalse(app.buttons["work.session.fast"].exists, "a value the Bridge cannot change must not be a button")
        XCTAssertEqual(fast.label, "Fastモード")
        // The mismatch between request and observation is at the top of the
        // conversation, where the heading card used to be.
        XCTAssertTrue(app.descendants(matching: .any)["work.session.modelMismatch"].waitForExistence(timeout: 10))
    }

    /// Where the Bridge advertises the toggle, the pill changes the session.
    func testFastPillTogglesWhereTheBridgeAllowsIt() throws {
        let app = try launchFixture()
        open(runningID, app)
        let fast = app.buttons["work.session.fast"].firstMatch
        XCTAssertTrue(fast.waitForExistence(timeout: 15))
        XCTAssertEqual(fast.value as? String, "オフ")
        fast.tap()
        let on = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "オン"), object: fast)
        XCTAssertEqual(XCTWaiter.wait(for: [on], timeout: 15), .completed, "the Fast change was not read back")
    }

    /// The heading is the bar's pill: the name, then the short number and the
    /// phase. The transcript has no heading card of its own.
    func testHeadingIsTheBarPillWithoutTheCard() throws {
        let app = try launchFixture()
        open(longID, app)
        let title = header(app)
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertLessThan(title.frame.minY, 120, "the heading must sit in the navigation bar")
        for part in ["長い履歴", "確認待ち"] {
            XCTAssertTrue(headerContaining(part, app).exists, "the bar must read " + part)
        }
        XCTAssertFalse(headerContaining("S3", app).exists)
        // The old card's ref label is gone from the page.
        XCTAssertFalse(app.staticTexts["work.ref.S3"].exists)
    }

    /// Tool calls stay out of the transcript: no "実行 N件" row, and the
    /// messages around them still read in order.
    func testToolCallsShowNoRunRow() throws {
        let app = try launchFixture()
        open(longID, app)
        XCTAssertTrue(wait(field(app), hittable: true))
        XCTAssertFalse(app.descendants(matching: .any)["work.toolRuns"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '実行 '")).firstMatch.exists)
        XCTAssertTrue(lastTurn(app).exists)
    }

    /// A waiting decision is where the page stays, even when a late row or a
    /// picture makes the transcript taller underneath it.
    func testWaitingDecisionStaysOnTheDecisionWhenThePageGrows() throws {
        let app = try launchFixture()
        fixture("/hold-image")
        open(decisionLongID, app)
        // The first turn carries a picture, so a held image is released into
        // a row the parked page has already measured.
        let question = app.staticTexts["どちらにしますか？"].firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 20))
        XCTAssertTrue(wait(question, hittable: true, timeout: 10))
        // At the decision, not at the end of the conversation.
        XCTAssertFalse(lastTurn(app).isHittable)
        XCTAssertTrue(field(app).isHittable)
        // The two pictures land after the placement; the page grows.
        fixture("/release-image")
        XCTAssertTrue(waitForImageDelivery(timeout: 15))
        Thread.sleep(forTimeInterval: 2.0)
        XCTAssertTrue(question.isHittable, "the decision was pushed away by a height change")
        XCTAssertFalse(lastTurn(app).isHittable)
        XCTAssertTrue(field(app).isHittable)
    }

    /// Usage is a detail screen: one back control, without a root Settings button.
    func testUsageInsideWorkHasBackWithoutExtraSettingsButton() throws {
        let app = try launchFixture()
        let usage = app.buttons["work.usage"]
        var moves = 0
        while usage.exists && usage.frame.maxX > app.frame.width - 8 && moves < 6 {
            let start = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: app.frame.width - 60, dy: usage.frame.midY))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -300, dy: 0)),
                        withVelocity: XCUIGestureVelocity(500), thenHoldForDuration: 0.1)
            moves += 1
        }
        usage.tap()
        XCTAssertTrue(app.staticTexts["AI"].waitForExistence(timeout: 20))
        let gears = app.buttons.matching(identifier: "laa.settings.open")
        XCTAssertEqual(gears.count, 0, "Usage must keep the reviewed detail toolbar")
        let back = app.buttons["BackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(app.buttons["work.section.sessions"].waitForExistence(timeout: 10))
    }
}
#endif

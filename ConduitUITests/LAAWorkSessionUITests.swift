#if LAA_BUILD
import XCTest

/// Session detail placement, against the synthetic Work fixture
/// (`scripts/laa/work-ui-fixture.mjs`) instead of a live Mac conversation.
/// The fixture serves an empty session, a waiting decision and a long history.
final class LAAWorkSessionUITests: XCTestCase {
    private let emptyID = "ses_1111111111111111"
    private let decisionID = "ses_2222222222222222"
    private let longID = "ses_3333333333333333"
    private let staleID = "ses_4444444444444444"

    /// The fixture control endpoint is reached off the main thread: a
    /// synchronous `Data(contentsOf:)` here raises the UI-unresponsiveness
    /// runtime warning.
    @discardableResult
    private func fixture(_ path: String) -> [String: Any]? {
        let done = expectation(description: "fixture \(path)")
        var payload: [String: Any]?
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:19585\(path)")!) { data, _, _ in
            if let data { payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return payload
    }

    private func launchFixture() throws -> XCUIApplication {
        guard fixture("/reset") != nil else { throw XCTSkip("Start scripts/laa/work-ui-fixture.mjs") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "work", "-LAA_UI_TEST_ISOLATED_BRIDGE",
                               "-conduit.themePreference", "light",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchEnvironment["LAA_BRIDGE_DEFAULT_ADDRESS"] = "http://127.0.0.1:19584"
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
        app.buttons["work.section.sessions"].tap()
        let row = app.staticTexts["work.session.\(id)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        if !row.isHittable { app.scrollViews.firstMatch.swipeUp() }
        row.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 20))
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


    /// A new message arriving while the owner reads older turns must not pull
    /// the transcript back to the bottom.
    func testNewMessageWhileReadingHistoryKeepsThePlace() throws {
        let app = try launchFixture()
        open(longID, app)
        XCTAssertTrue(wait(field(app), hittable: true))
        app.scrollViews.firstMatch.swipeDown()
        app.scrollViews.firstMatch.swipeDown()
        XCTAssertTrue(wait(field(app), hittable: false, timeout: 5))
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
        XCTAssertFalse(field(app).isHittable)
        XCTAssertTrue(app.navigationBars["長い履歴"].exists)
    }

    /// A failed observation keeps the last values in hand, but the bar says they
    /// are not current instead of presenting them as the live setting.
    func testFailedObservationMarksValuesAsLastConfirmed() throws {
        let app = try launchFixture()
        open(staleID, app)
        let model = app.descendants(matching: .any)["work.session.model"].firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 20))
        XCTAssertTrue((model.value as? String ?? "").contains("最終確認"))
        let fast = app.descendants(matching: .any)["work.session.fast"].firstMatch
        XCTAssertTrue(fast.waitForExistence(timeout: 10))
        XCTAssertEqual(fast.value as? String, "最終確認: オン")
        XCTAssertTrue(app.staticTexts["委譲先の状態を観測できていません。表示は最後に確認できた記録です。"].exists)
    }

    func testEmptyConversationOpensAtTheComposer() throws {
        let app = try launchFixture()
        open(emptyID, app)
        XCTAssertTrue(app.staticTexts["会話はまだありません。"].waitForExistence(timeout: 20))
        XCTAssertTrue(wait(field(app), hittable: true))
        // A page that fits must stay at the top: a bottom-aligned short page
        // would push the heading and the composer down (the reported bug).
        let heading = app.staticTexts["work.session.detail.title"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        XCTAssertLessThan(heading.frame.minY, 300)
        XCTAssertTrue(app.navigationBars["空の会話"].exists)
    }

    func testWaitingDecisionOpensAtTheComposer() throws {
        let app = try launchFixture()
        open(decisionID, app)
        XCTAssertTrue(wait(field(app), hittable: true))
        XCTAssertTrue(app.staticTexts["判断待ち・停止中は追加送信できません。状態を確認してください。"].exists)
        XCTAssertTrue(app.navigationBars["判断待ち"].exists)
    }

    func testLongHistoryOpensAtTheBottomAndKeepsThePlace() throws {
        let app = try launchFixture()
        open(longID, app)
        XCTAssertTrue(wait(field(app), hittable: true))
        // The long transcript opens at its bottom, not only "somewhere visible".
        XCTAssertGreaterThan(field(app).frame.minY, 400)
        XCTAssertTrue(app.descendants(matching: .any)["work.session.settings"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["work.session.fast"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["work.session.image"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.navigationBars["長い履歴"].exists)

        // Reading older turns takes the field off screen; a later events poll
        // must not pull the view back to the bottom.
        app.scrollViews.firstMatch.swipeDown()
        app.scrollViews.firstMatch.swipeDown()
        XCTAssertTrue(wait(field(app), hittable: false, timeout: 5))
        Thread.sleep(forTimeInterval: 3.5)
        XCTAssertFalse(field(app).isHittable)
        XCTAssertTrue(app.navigationBars["長い履歴"].exists)
    }
}
#endif

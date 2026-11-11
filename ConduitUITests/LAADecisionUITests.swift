#if LAA_BUILD
import XCTest

/// The decision board against the synthetic Work fixture
/// (`scripts/laa/work-ui-fixture.mjs`): board → detail → choose → delivered,
/// an answer that did not arrive, the empty board and an older Mac.
final class LAADecisionUITests: XCTestCase {
    private let hpID = "dec_0000000000000a01"
    private let cardID = "dec_0000000000000a02"
    private let failedID = "dec_0000000000000a03"
    /// The fixture's API port; control is the next one. `TEST_RUNNER_LAA_WORK_FIXTURE_PORT`
    /// moves both when another run holds the usual pair.
    private let port = Int(ProcessInfo.processInfo.environment["LAA_WORK_FIXTURE_PORT"] ?? "") ?? 19584

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

    private func launch(board mode: String, dark: Bool = false, root: Bool = false) throws -> XCUIApplication {
        guard fixture("/reset") != nil else { throw XCTSkip("Start scripts/laa/work-ui-fixture.mjs") }
        fixture("/decisions/\(mode)")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "work", "-LAA_UI_TEST_ISOLATED_BRIDGE",
                               "-conduit.themePreference", dark ? "dark" : "light",
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
        XCTAssertTrue(app.buttons["work.sessions.menu"].waitForExistence(timeout: 20))
        if !root {
            app.buttons["work.sessions.menu"].tap()
            app.buttons["work.decisions.open"].tap()
        }
        return app
    }

    private func row(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.buttons["work.decision.\(id)"].firstMatch
    }

    private func screenshot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func answered(_ id: String) -> [String: Any]? {
        (fixture("/state")?["answered"] as? [[String: Any]])?.first { $0["id"] as? String == id }
    }

    /// The decision board sends the recommended choice, shows confirmation,
    /// and moves the row to the answered section.
    func testChooseRecommendedDeliversAndLeavesTheBoard() throws {
        let app = try launch(board: "normal")
        XCTAssertTrue(row(hpID, app).waitForExistence(timeout: 20), "The hub did not open on the board")
        XCTAssertTrue(app.descendants(matching: .any)["work.decisions"].firstMatch.exists)
        XCTAssertTrue(row(hpID, app).label.hasPrefix("判断、J1、HPの公開日を決める、推奨 11月15日（土）に公開"))
        XCTAssertTrue(app.buttons["work.decision.retry.\(failedID)"].exists, "A failed delivery shows its retry on the row")
        screenshot("ui-decisions-list-light", app)

        row(hpID, app).tap()
        let send = app.buttons["work.decision.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        XCTAssertFalse(send.isEnabled, "Nothing is sent before a choice")
        let recommended = app.buttons["work.decision.option.0"]
        XCTAssertTrue(recommended.label.hasPrefix("推奨、11月15日（土）に公開"))
        recommended.tap()
        XCTAssertTrue(recommended.isSelected)
        screenshot("ui-decisions-detail-light", app)
        XCTAssertTrue(send.isEnabled)
        send.tap()

        XCTAssertTrue(app.descendants(matching: .any)["work.decision.sent"].firstMatch.waitForExistence(timeout: 10))
        screenshot("ui-decisions-sent-light", app)
        XCTAssertTrue(row(hpID, app).waitForNonExistence(timeout: 10), "The row still awaits an answer")
        XCTAssertTrue(app.buttons["work.decision.answered.\(hpID)"].firstMatch.exists)
        XCTAssertTrue(row(cardID, app).exists)
        XCTAssertEqual(answered(hpID)?["optionIndex"] as? Int, 0)
        XCTAssertEqual(answered(hpID)?["delivery"] as? String, "delivered")
    }

    /// An answer the conversation did not receive stays, says so, and a retry
    /// from the row delivers it.
    func testUndeliveredAnswerStaysAndRetries() throws {
        let app = try launch(board: "normal")
        XCTAssertTrue(row(cardID, app).waitForExistence(timeout: 20))
        fixture("/decisions/fail-next")
        row(cardID, app).tap()
        let other = app.buttons["work.decision.option.1"]
        XCTAssertTrue(other.waitForExistence(timeout: 10))
        other.tap()
        app.buttons["work.decision.send"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["work.decision.undelivered"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["届いていません"].exists)
        XCTAssertEqual(app.buttons["work.decision.send"].label, "届け直す")
        screenshot("ui-decisions-undelivered-light", app)
        app.buttons["work.decision.close"].tap()

        let retry = app.buttons["work.decision.retry.\(cardID)"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10), "The undelivered answer left the board")
        retry.tap()
        XCTAssertTrue(row(cardID, app).waitForNonExistence(timeout: 10))
        XCTAssertEqual(answered(cardID)?["delivery"] as? String, "delivered")
    }

    func testDarkBoardAndDetail() throws {
        let app = try launch(board: "normal", dark: true)
        XCTAssertTrue(row(hpID, app).waitForExistence(timeout: 20))
        screenshot("ui-decisions-list-dark", app)
        row(hpID, app).tap()
        let recommended = app.buttons["work.decision.option.0"]
        XCTAssertTrue(recommended.waitForExistence(timeout: 10))
        recommended.tap()
        screenshot("ui-decisions-detail-dark", app)
    }

    /// An empty board keeps the hub's usual first section and reads calmly.
    func testEmptyBoard() throws {
        let app = try launch(board: "empty")
        XCTAssertFalse(app.buttons["work.section.decisions"].exists)
        XCTAssertTrue(app.staticTexts["判断待ちはありません"].waitForExistence(timeout: 10))
        screenshot("ui-decisions-empty-light", app)
    }

    /// A Mac whose Bridge predates the board answers 404: a short note, no crash.
    func testOlderMacShowsUpdateNote() throws {
        let app = try launch(board: "unsupported")
        XCTAssertTrue(app.staticTexts["Macのアップデート待ち"].waitForExistence(timeout: 10))
    }
    func testWorkOverviewSectionsAndProjectOrderLightAndDark() throws {
        for dark in [false, true] {
            let app = try launch(board: "normal", dark: dark, root: true)
            let style = dark ? "dark" : "light"
            XCTAssertTrue(app.buttons["work.decisions.all"].waitForExistence(timeout: 15))
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'work.decision.dec_'")).count, 3)
            XCTAssertFalse(app.buttons["work.section.projects"].exists)
            XCTAssertFalse(app.buttons["work.section.skills"].exists)
            XCTAssertTrue(app.buttons["work.usage"].exists)
            screenshot("work-head-after-\(style)", app)
            app.buttons["work.sessions.menu"].tap()
            app.buttons["work.sessions.byProject"].tap()
            screenshot("work-projects-after-\(style)", app)
            app.buttons["work.section.tasks"].tap()
            XCTAssertTrue(app.buttons["work.tasks.filter"].waitForExistence(timeout: 15))
            screenshot("work-tasks-after-\(style)", app)
            app.buttons["work.section.routines"].tap()
            XCTAssertTrue(app.staticTexts["朝の確認"].waitForExistence(timeout: 15))
            screenshot("work-routines-after-\(style)", app)
            XCTAssertEqual(app.activityIndicators.count, 0)
            app.buttons["work.usage"].tap()
            XCTAssertTrue(app.staticTexts["Usage"].waitForExistence(timeout: 15))
            screenshot("work-usage-entry-after-\(style)", app)
            app.terminate()
            let empty = try launch(board: "empty", dark: dark, root: true)
            XCTAssertTrue(empty.descendants(matching: .any)["work.decisions.summary"].firstMatch.waitForNonExistence(timeout: 15))
            screenshot("work-no-decisions-after-\(style)", empty)
            empty.terminate()
        }
    }

}
#endif

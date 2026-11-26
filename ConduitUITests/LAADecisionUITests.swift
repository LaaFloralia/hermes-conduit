#if LAA_BUILD
import XCTest
import UIKit

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
        guard let request = try? LabUI.request(LabUI.origin("work-control", legacyPort: port + 1), "\(path)") else { return nil }
        LabUI.session.dataTask(with: request) { data, response, _ in
            if LabUI.matches(response), let data { payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return payload
    }

    private func resetFixture() throws {
        if LabUI.active { _ = try XCTUnwrap(fixture("/reset"), "lane Work fixture is not responding") }
        else if fixture("/reset") == nil { throw XCTSkip("Start scripts/laa/work-ui-fixture.mjs") }
    }

    private func launch(board mode: String, dark: Bool = false, root: Bool = false) throws -> XCUIApplication {
        try resetFixture()
        _ = try XCTUnwrap(fixture("/decisions/\(mode)"))
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "work", "-LAA_UI_TEST_ISOLATED_BRIDGE",
                               "-conduit.themePreference", dark ? "dark" : "light",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchEnvironment["LAA_BRIDGE_DEFAULT_ADDRESS"] = LabUI.origin("work", legacyPort: port)
        app.launchInLab()
        XCTAssertTrue(app.buttons["work.connect"].waitForExistence(timeout: 30))
        app.buttons["work.connect"].tap()
        let code = app.secureTextFields["laa.bridge.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        code.tap(); code.typeText("TEST-TEST")
        let pair = app.buttons["laa.bridge.pair"]
        if !pair.isHittable { app.swipeUp() }
        pair.tap()
        XCTAssertTrue(app.buttons["work.section.projects"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.descendants(matching: .any)["work.projects"].firstMatch.waitForExistence(timeout: 20))
        if !root {
            // The board sits beside Sessions; the hub opens on Projects.
            XCTAssertTrue(app.buttons["work.section.projects"].isSelected)
            app.buttons["work.section.decisions"].tap()
        }
        return app
    }

    private func row(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.buttons["work.decision.\(id)"].firstMatch
    }

    private func openUnansweredDecision(_ id: String, _ app: XCUIApplication) {
        let card = row(id, app)
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        let tappable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: card)
        XCTAssertEqual(XCTWaiter.wait(for: [tappable], timeout: 10), .completed)
        card.tap()
        XCTAssertTrue(app.buttons["work.decision.option.0"].waitForExistence(timeout: 10))
    }

    /// Owner, 2026-11-23: a 1,000-character answer was refused and read as a
    /// lost connection. The field counts near 8000 and holds the send past it;
    /// a refusal says why, and the words stay, also after closing the decision.
    func testALongAnswerIsCountedAndARefusalKeepsIt() throws {
        let app = try launch(board: "normal")
        fixture("/decisions/note-limit-600")
        openUnansweredDecision(hpID, app)
        XCTAssertTrue(app.staticTexts["選択肢以外で答える"].waitForExistence(timeout: 10))
        let note = noteField(app)
        for _ in 0..<4 where !(note.exists && note.isHittable) { app.swipeUp() }
        let unit = "長い回答の確認です。"   // 10 characters
        paste(String(repeating: unit, count: 800) + "超", into: note, app, replacing: false)
        let count = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR label BEGINSWITH %@", "字多すぎます", "残り")).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.label, "1字多すぎます（8000字まで）")
        let send = app.buttons["work.decision.send"]
        XCTAssertFalse(send.isEnabled, "past 8000 the send waits")
        screenshot("decision-note-over-limit", app)

        paste(String(repeating: unit, count: 100), into: note, app, replacing: true)
        XCTAssertFalse(count.exists, "no count far from the limit")
        XCTAssertTrue(send.isEnabled)
        send.tap()
        let failure = app.staticTexts["work.decision.failure"].firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        XCTAssertEqual(failure.label, "回答が長すぎるか、使えない文字が含まれています。短くしてから送ってください。")
        XCTAssertFalse(failure.label.contains("Mac"), "a refusal is not a connection failure")
        XCTAssertEqual((note.value as? String)?.count, 1000, "the answer stays to send again")
        screenshot("decision-note-refused", app)

        app.buttons["work.decision.close"].tap()
        openUnansweredDecision(hpID, app)
        XCTAssertTrue(app.staticTexts["選択肢以外で答える"].waitForExistence(timeout: 10))
        let reopened = noteField(app)
        for _ in 0..<4 where !(reopened.exists && reopened.isHittable) { app.swipeUp() }
        XCTAssertEqual((reopened.value as? String)?.count, 1000, "reopening the decision finds the answer")
        XCTAssertNil(answered(hpID), "nothing was recorded")
    }

    /// The free answer, by identifier when SwiftUI exposes it; otherwise the
    /// detail's only text field.
    private func noteField(_ app: XCUIApplication) -> XCUIElement {
        let byID = app.descendants(matching: .any)["work.decision.note"].firstMatch
        if byID.exists { return byID }
        return app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
    }

    private func paste(_ text: String, into field: XCUIElement, _ app: XCUIApplication, replacing: Bool) {
        UIPasteboard.general.string = text
        defer { UIPasteboard.general.items = [] }
        if !app.keyboards.firstMatch.exists { field.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        // Use the system's edit commands without depending on iOS exposing
        // its transient touch menu (or the current language) to XCTest.
        if replacing { field.typeKey("a", modifierFlags: .command) }
        field.typeKey("v", modifierFlags: .command)
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            field.value as? String == text
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed, "pasted the full answer")
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
        XCTAssertTrue(row(cardID, app).exists)
        XCTAssertEqual(answered(hpID)?["optionIndex"] as? Int, 0)
        XCTAssertEqual(answered(hpID)?["delivery"] as? String, "delivered")
        // A delivered answer does not stay on the board: the next read (every
        // 15 seconds, or a pull) takes 回答済み away (2026-11-23).
        XCTAssertTrue(app.buttons["work.decision.answered.\(hpID)"].firstMatch.waitForNonExistence(timeout: 25),
                      "The delivered answer stayed on the board")
        XCTAssertTrue(row(cardID, app).exists)
    }

    /// Answering the last open decision leaves the calm empty board, not a
    /// 回答済み list that never goes (2026-11-23).
    func testAnsweringTheLastDecisionEmptiesTheBoard() throws {
        let app = try launch(board: "single")
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["work.section.decisions"].label.hasSuffix("1"))
        openUnansweredDecision(hpID, app)
        app.buttons["work.decision.option.0"].tap()
        app.buttons["work.decision.send"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["work.decision.sent"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(row(hpID, app).waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["判断待ちはありません"].waitForExistence(timeout: 25), "The answered row stayed")
        XCTAssertEqual(app.buttons["work.section.decisions"].label, "Decisions")
        screenshot("ui-decisions-answered-empty-light", app)
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

    func testColdLaunchToInteractiveWorkTiming() throws {
        try resetFixture()
        let app = XCUIApplication()
        app.launchEnvironment["CONDUIT_UITEST"] = "1"
        app.launchArguments = ["-LAA_UI_TEST_ISOLATED_BRIDGE", "-laa-tab", "work"]
        for run in 1...3 {
            let start = Date()
            app.launchInLab()
            XCTAssertTrue(app.buttons["work.connect"].waitForExistence(timeout: 30))
            print("LAA_COLD_LAUNCH run=\(run) interactive_seconds=\(Date().timeIntervalSince(start))")
            app.terminate()
        }
    }

    func testLostResponseReadsSavedDeliveryWithoutAnsweringTwice() throws {
        let app = try launch(board: "normal")
        defer { app.terminate() }
        fixture("/decisions/lose-next-response")
        openUnansweredDecision(hpID, app)
        app.buttons["work.decision.option.0"].tap()
        app.buttons["work.decision.send"].tap()
        // Reconciled as answered: the open row leaves (回答済み may already
        // have gone with the next read).
        XCTAssertTrue(row(hpID, app).waitForNonExistence(timeout: 15))
        XCTAssertEqual(fixture("/state")?["decisionPosts"] as? Int, 1)
        XCTAssertEqual(answered(hpID)?["delivery"] as? String, "delivered")
        screenshot("decision-lost-response-reconciled", app)
    }

    func testSavedFailureBecomesDeliveredWhileDetailIsOpenWithoutResend() throws {
        let app = try launch(board: "normal")
        defer { app.terminate() }
        fixture("/decisions/fail-next")
        openUnansweredDecision(cardID, app)
        app.buttons["work.decision.option.0"].tap()
        app.buttons["work.decision.send"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["work.decision.undelivered"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["work.decision.recorded"].exists)
        screenshot("decision-saved-delivery-failed", app)
        fixture("/decisions/deliver-saved")
        XCTAssertTrue(app.buttons["work.decision.send"].waitForNonExistence(timeout: 12))
        XCTAssertFalse(app.descendants(matching: .any)["work.decision.undelivered"].firstMatch.exists)
        screenshot("decision-later-delivered", app)
        app.buttons["work.decision.close"].tap()
        XCTAssertTrue(row(cardID, app).waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.buttons["work.decision.retry.\(cardID)"].exists)
        XCTAssertEqual(fixture("/state")?["decisionPosts"] as? Int, 1)
    }

    func testDetailRetryClearsFailureWithoutAnotherAnswer() throws {
        let app = try launch(board: "normal")
        defer { app.terminate() }
        fixture("/decisions/fail-next")
        openUnansweredDecision(cardID, app)
        app.buttons["work.decision.option.0"].tap()
        let send = app.buttons["work.decision.send"]
        send.tap()
        let failure = app.descendants(matching: .any)["work.decision.undelivered"].firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        send.tap()
        let cleared = failure.waitForNonExistence(timeout: 12)
        screenshot("decision-detail-after-retry", app)
        XCTAssertTrue(cleared, "A successful detail retry must clear its old failure")
        XCTAssertFalse(send.exists)
        XCTAssertEqual(answered(cardID)?["delivery"] as? String, "delivered")
        XCTAssertEqual(fixture("/state")?["decisionPosts"] as? Int, 2)
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

    /// An empty board reads calmly in its own section, and its segment carries
    /// no count.
    func testEmptyBoard() throws {
        let app = try launch(board: "empty")
        XCTAssertEqual(app.buttons["work.section.decisions"].label, "Decisions")
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
            // Projects opens first, with no decision card above it; the
            // board's segment says how many wait.
            XCTAssertTrue(app.buttons["work.section.projects"].isSelected)
            XCTAssertFalse(app.descendants(matching: .any)["work.decisions.summary"].exists)
            let board = app.buttons["work.section.decisions"]
            XCTAssertTrue(board.waitForExistence(timeout: 15))
            XCTAssertTrue(NSPredicate(format: "label BEGINSWITH 'Decisions '").evaluate(with: board), board.label)
            XCTAssertTrue(app.buttons["work.section.projects"].exists, "Projects is Work's first section again (owner, 2026-11-23)")
            XCTAssertFalse(app.buttons["work.section.skills"].exists)
            XCTAssertTrue(app.buttons["work.usage"].exists)
            screenshot("work-head-after-\(style)", app)
            app.buttons["work.section.sessions"].tap()
            app.buttons["work.sessions.menu"].tap()
            app.buttons["work.sessions.byProject"].tap()
            screenshot("work-projects-after-\(style)", app)
            board.tap()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'work.decision.dec_'")).firstMatch
                .waitForExistence(timeout: 15))
            screenshot("work-decisions-after-\(style)", app)
            app.buttons["work.section.tasks"].tap()
            XCTAssertTrue(app.buttons["work.tasks.quick"].waitForExistence(timeout: 15))
            screenshot("work-tasks-after-\(style)", app)
            LAAWorkSectionUI.open("routines", in: app)
            XCTAssertTrue(app.staticTexts["朝の確認"].waitForExistence(timeout: 15))
            screenshot("work-routines-after-\(style)", app)
            XCTAssertEqual(app.activityIndicators.count, 0)
            app.buttons["work.usage"].tap()
            XCTAssertTrue(app.staticTexts["Usage"].waitForExistence(timeout: 15))
            screenshot("work-usage-entry-after-\(style)", app)
            app.terminate()
            let empty = try launch(board: "empty", dark: dark, root: true)
            empty.buttons["work.section.decisions"].tap()
            XCTAssertTrue(empty.staticTexts["判断待ちはありません"].waitForExistence(timeout: 15))
            screenshot("work-no-decisions-after-\(style)", empty)
            empty.terminate()
        }
    }

}
#endif

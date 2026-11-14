#if LAA_BUILD
import XCTest

/// The task execution record against the synthetic Work fixture
/// (`scripts/laa/work-ui-fixture.mjs`): assigning a task to AI staff with a
/// model, the completion confirmation on the row and in the detail, the
/// running refusal, the status link into its session, and the free answer on a
/// long decision. The `testShots*` runs save the 440 × 956 pt pictures.
final class LAATaskRunUITests: XCTestCase {
    private let runningID = "b9d2f664-cda3-4c56-8d39-c4d6df597254"
    private let queuedID = "7a1c3d5e-1111-4a2b-9c3d-000000000014"
    private let awaitingID = "7a1c3d5e-1111-4a2b-9c3d-000000000015"
    private let longDecisionID = "dec_0000000000000a04"
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

    private func launch(dark: Bool = false, board: String = "off") throws -> XCUIApplication {
        guard fixture("/reset") != nil else { throw XCTSkip("Start scripts/laa/work-ui-fixture.mjs") }
        fixture("/decisions/\(board)")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "work", "-LAA_UI_TEST_ISOLATED_BRIDGE", "-LAA_UI_TEST_CLEAR_WORK_STORE",
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
        XCTAssertTrue(app.buttons["work.section.tasks"].waitForExistence(timeout: 30))
        return app
    }

    private func tasks(_ app: XCUIApplication) {
        if !app.buttons["work.section.tasks"].exists { app.navigationBars.buttons.firstMatch.tap() }
        app.buttons["work.section.tasks"].tap()
    }

    private func row(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func answered(_ id: String) -> [String: Any]? {
        (fixture("/state")?["answered"] as? [[String: Any]])?.first { $0["id"] as? String == id }
    }

    private func completedIDs() -> [String] {
        ((fixture("/state")?["completed"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
    }

    /// The create form starts on Monet, shows the footer and the Bridge's
    /// profiles, and sends staff + profile in the body.
    func testCreateWithAIAndModel() throws {
        let app = try launch()
        tasks(app)
        app.buttons["work.linear.add"].tap()
        let title = app.textFields["work.linear.title"].firstMatch
        let editor = title.exists ? title : app.textViews["work.linear.title"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Monetが取得して、完了まで進めます。"].waitForExistence(timeout: 10))
        let model = app.descendants(matching: .any)["work.linear.model"].firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 10), "The model rows arrive from /v1/session-options")
        XCTAssertEqual(model.value as? String, "Claude Opus 5.5")
        let effort = app.descendants(matching: .any)["work.linear.effort"].firstMatch
        XCTAssertEqual(effort.value as? String, "High")
        effort.tap()
        let xhigh = app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "XHigh", "XHigh,")).firstMatch
        XCTAssertTrue(xhigh.waitForExistence(timeout: 10))
        xhigh.tap()
        XCTAssertTrue(xhigh.waitForNonExistence(timeout: 5))
        expectation(for: NSPredicate(format: "value == %@", "XHigh"), evaluatedWith: effort)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(model.value as? String, "Claude Opus 5.5", "the effort changes alone")
        editor.tap(); editor.typeText("AI担当の確認")
        XCTAssertTrue((editor.value as? String)?.contains("AI担当の確認") == true)
        XCTAssertTrue(app.buttons["work.linear.save"].isEnabled)
        app.buttons["work.linear.save"].tap()
        let created = waitForCreated(app, "AI担当の確認")
        XCTAssertNotNil(created, "The create request reached the fixture")
        let createdRow = row(app, "AI担当の確認").waitForExistence(timeout: 15)
        if !createdRow {
            print("ROW MISSING; texts: " + app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))
        }
        XCTAssertTrue(createdRow)
        XCTAssertEqual(created?["title"] as? String, "AI担当の確認")
        XCTAssertEqual((created?["assignee"] as? [String: Any])?["kind"] as? String, "staff")
        XCTAssertEqual((created?["assignee"] as? [String: Any])?["staff"] as? String, "monet")
        XCTAssertEqual(created?["profile"] as? String, "opus-xhigh")
        XCTAssertTrue(app.staticTexts["取得待ち"].firstMatch.waitForExistence(timeout: 10))
    }

    /// A device without sessions:write is refused for a staff assignee: the
    /// form keeps its words, says why, and can still save it as 社長's own.
    /// The range is two glass toggles, 自分が作成 and 自分が担当, on the same
    /// line as the count menu and the grouping (owner, 2026-11-14). At most
    /// one is lit; neither lit shows every task, as 自分に関係 did.
    func testRangeTogglesShareOneLineWithTheCount() throws {
        let app = try launch()
        tasks(app)
        // T13 has no run record (自分が担当) and sits low in その他, off a
        // 402 pt screen until the range leaves it nearly alone; T15 was
        // created for Sherlock (自分が作成) and is the first row.
        let mine = row(app, "今週の振り返りをまとめる")
        let made = row(app, "名刺の紙を決める")
        XCTAssertTrue(made.waitForExistence(timeout: 20))
        let created = app.buttons["work.tasks.filter.created"]
        let assigned = app.buttons["work.tasks.filter.assigned"]
        let count = app.buttons["work.tasks.quick"]
        let grouping = app.buttons["work.tasks.grouping"]
        XCTAssertTrue(created.exists && assigned.exists && count.exists && grouping.exists)
        XCTAssertFalse(created.isSelected)
        XCTAssertFalse(assigned.isSelected)
        XCTAssertFalse(app.buttons["work.tasks.filter"].exists, "the old pulldown is gone")
        // One line: toggles, then the count beside the grouping; no chips under it.
        XCTAssertEqual(count.frame.midY, created.frame.midY, accuracy: 2)
        XCTAssertEqual(grouping.frame.midY, created.frame.midY, accuracy: 2)
        XCTAssertLessThan(created.frame.maxX, assigned.frame.minX)
        XCTAssertLessThan(assigned.frame.maxX, count.frame.minX)
        XCTAssertLessThanOrEqual(count.frame.maxX, grouping.frame.minX + 1)
        XCTAssertLessThanOrEqual(grouping.frame.maxX, app.frame.maxX)
        XCTAssertFalse(app.buttons["work.tasks.quick.all"].exists, "the quick filters live in the count menu")
        XCTAssertTrue(count.label.hasPrefix("表示、すべて、"), count.label)
        let everything = count.label

        assigned.tap()
        XCTAssertTrue(made.waitForNonExistence(timeout: 5))
        XCTAssertTrue(mine.waitForExistence(timeout: 5))
        XCTAssertTrue(assigned.isSelected)
        XCTAssertFalse(created.isSelected)
        XCTAssertEqual(count.label, "表示、すべて、1件")

        created.tap()
        XCTAssertTrue(mine.waitForNonExistence(timeout: 5))
        XCTAssertTrue(made.exists)
        XCTAssertTrue(created.isSelected)
        XCTAssertFalse(assigned.isSelected, "one toggle lit at a time")

        created.tap()
        XCTAssertTrue(made.waitForExistence(timeout: 5))
        XCTAssertFalse(created.isSelected)
        XCTAssertEqual(count.label, everything)

        // The archive is in the count menu; the toggles step aside there.
        count.tap()
        XCTAssertTrue(app.buttons["work.linear.archive"].waitForExistence(timeout: 5))
        app.buttons["work.linear.archive"].tap()
        XCTAssertTrue(created.waitForNonExistence(timeout: 5))
        XCTAssertTrue(count.label.hasPrefix("表示、アーカイブ、"), count.label)
        count.tap()
        XCTAssertTrue(app.buttons["work.tasks.quick.all"].waitForExistence(timeout: 5))
        app.buttons["work.tasks.quick.all"].tap()
        XCTAssertTrue(created.waitForExistence(timeout: 5))
    }

    func testStaffCreateWithoutSessionScopeKeepsTheForm() throws {
        let app = try launch()
        tasks(app)
        app.buttons["work.linear.add"].tap()
        let title = app.textFields["work.linear.title"].firstMatch
        let editor = title.exists ? title : app.textViews["work.linear.title"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["work.linear.model"].firstMatch.waitForExistence(timeout: 10))
        editor.tap(); editor.typeText("端末権限の確認")
        fixture("/tasks/refuse-staff")
        app.buttons["work.linear.save"].tap()
        XCTAssertTrue(app.staticTexts["この端末からはAI社員に任せられません。担当を自分にするか、iPhoneから作成してください。"]
            .waitForExistence(timeout: 10))
        XCTAssertTrue((editor.value as? String)?.contains("端末権限の確認") == true, "The form keeps its text")
        XCTAssertFalse(row(app, "端末権限の確認").exists, "Nothing was created")
        XCTAssertTrue(((fixture("/state")?["created"] as? [[String: Any]]) ?? []).isEmpty)

        // The same words save as 社長's own task, which needs no session.
        let assignee = app.descendants(matching: .any)["work.linear.assignee"].firstMatch
        XCTAssertTrue(assignee.waitForExistence(timeout: 5))
        assignee.tap()
        let owner = app.buttons["社長"]
        XCTAssertTrue(owner.waitForExistence(timeout: 5))
        owner.tap()
        XCTAssertTrue(app.descendants(matching: .any)["work.linear.model"].firstMatch.waitForNonExistence(timeout: 5))
        app.buttons["work.linear.save"].tap()
        let created = waitForCreated(app, "端末権限の確認")
        XCTAssertNotNil(created, "The owner create reached the fixture")
        XCTAssertTrue(row(app, "端末権限の確認").waitForExistence(timeout: 15))
        XCTAssertEqual((created?["assignee"] as? [String: Any])?["kind"] as? String, "owner")
        XCTAssertNil(created?["profile"])
    }

    /// A running task explains why it cannot be completed, in the detail and
    /// on its disabled row action.
    func testRunningTaskCannotBeCompleted() throws {
        let app = try launch()
        tasks(app)
        openDetail(app, "次の打ち合わせを確認する")
        let reason = app.staticTexts["work.task.detail.completeReason"]
        scrollTo(app, reason)
        XCTAssertTrue(reason.waitForExistence(timeout: 10))
        XCTAssertEqual(reason.label, "実施中のため、終わってから完了できます")
        XCTAssertFalse(app.buttons["work.task.detail.complete"].isEnabled)
        XCTAssertEqual(completedIDs(), [])
        // The run is in Japanese, so the sheet's close reads 閉じる.
        app.buttons["閉じる"].firstMatch.tap()

        let target = row(app, "次の打ち合わせを確認する")
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        target.swipeLeft()
        let complete = app.buttons["完了"].firstMatch
        XCTAssertTrue(complete.exists)
        complete.tap()
        XCTAssertFalse(app.staticTexts["完了にしますか？"].waitForExistence(timeout: 2),
                       "A running task's swipe action must not confirm")
    }

    /// The row's swipe completes after the confirmation and removes the row.
    func testCompleteConfirmationRemovesTheTask() throws {
        let app = try launch()
        tasks(app)
        let target = row(app, "見積りを送る")
        scrollTo(app, target)
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        target.swipeLeft()
        let complete = app.buttons["完了"].firstMatch
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        complete.tap()
        XCTAssertTrue(app.staticTexts["完了にしますか？"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["一覧から消し、記録をHQに保管します。"].exists)
        app.sheets.buttons["完了"].tap()
        XCTAssertTrue(target.waitForNonExistence(timeout: 15))
        XCTAssertTrue(completedIDs().contains(queuedID))
    }

    /// The detail's own button confirms, archives the session wording, and
    /// closes the sheet when the Bridge accepts it.
    func testDetailCompletesWithSessionWording() throws {
        let app = try launch()
        tasks(app)
        openDetail(app, "名刺の紙を決める")
        let button = app.buttons["work.task.detail.complete"]
        scrollTo(app, button)
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        XCTAssertTrue(app.staticTexts["完了にしますか？"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["一覧から消し、記録をHQに保管します。セッション（S8）はアーカイブします。"].exists)
        app.sheets.buttons["完了"].tap()
        XCTAssertTrue(row(app, "名刺の紙を決める").waitForNonExistence(timeout: 15))
        XCTAssertTrue(completedIDs().contains(awaitingID))
    }

    // MARK: Picking and the batch button (owner, 2026-11-12)

    private let reviewID = "dce58a26-2f89-4d6a-b78e-01d07d485dbd"
    private let draftID = "7a1c3d5e-1111-4a2b-9c3d-000000000016"
    private let photoID = "7a1c3d5e-1111-4a2b-9c3d-000000000017"

    private func pick(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let box = app.buttons["work.task.select.\(id)"]
        scrollTo(app, box)
        XCTAssertTrue(box.waitForExistence(timeout: 15), "box \(id)")
        box.tap()
        return box
    }

    /// The batch bar sits under the controls at the top of the list.
    private func batchButton(_ app: XCUIApplication) -> XCUIElement {
        let button = app.buttons["work.tasks.completeSelected"]
        var moves = 0
        while !(button.exists && button.isHittable) && moves < 6 { app.swipeDown(); moves += 1 }
        return button
    }

    /// A tick only picks: nothing reaches the Bridge until the button, which
    /// then completes every picked task and leaves.
    func testPickingWritesNothingAndTheButtonCompletesThem() throws {
        let app = try launch()
        tasks(app)
        XCTAssertTrue(row(app, "次の打ち合わせを確認する").waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["work.tasks.completeSelected"].exists, "Nothing picked, no button")

        // A second tap unpicks.
        let photo = pick(app, photoID)
        XCTAssertTrue(photo.isSelected)
        photo.tap()
        XCTAssertFalse(photo.isSelected)
        XCTAssertFalse(app.buttons["work.tasks.completeSelected"].waitForExistence(timeout: 2))

        let review = pick(app, reviewID)
        let draft = pick(app, draftID)
        XCTAssertTrue(review.isSelected)
        XCTAssertTrue(draft.isSelected)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(completedIDs(), [], "Picking writes nothing")

        let button = batchButton(app)
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertTrue(button.label.contains("選択した2件を完了にする"), button.label)
        XCTAssertEqual(app.staticTexts["work.tasks.selectionCount"].label, "2件を選択中")
        shot(app, "c-tasks-picked-light")
        button.tap()
        XCTAssertTrue(button.waitForNonExistence(timeout: 15))
        XCTAssertEqual(Set(completedIDs()), [reviewID, draftID])
        XCTAssertTrue(row(app, "今週の振り返りをまとめる").waitForNonExistence(timeout: 10))
        XCTAssertFalse(row(app, "週報の下書き").exists)
        XCTAssertTrue(row(app, "写真の選定").exists, "An unpicked task stays")
    }

    /// The clear button drops every pick without writing.
    func testClearDropsThePicks() throws {
        let app = try launch()
        tasks(app)
        _ = pick(app, reviewID)
        _ = pick(app, photoID)
        let clear = app.buttons["work.tasks.clearSelection"]
        var moves = 0
        while !(clear.exists && clear.isHittable) && moves < 6 { app.swipeDown(); moves += 1 }
        clear.tap()
        XCTAssertTrue(app.buttons["work.tasks.completeSelected"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(completedIDs(), [])
    }

    /// A picked task with a session asks once for all of them, naming it.
    func testPickedTaskWithASessionAsksFirst() throws {
        let app = try launch()
        tasks(app)
        _ = pick(app, awaitingID)
        _ = pick(app, reviewID)
        batchButton(app).tap()
        XCTAssertTrue(app.staticTexts["選択した2件を完了にしますか？"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["一覧から消し、記録をHQに保管します。セッション（S8）はアーカイブします。"].exists)
        XCTAssertEqual(completedIDs(), [], "Nothing is sent before the confirmation")
        shot(app, "c-tasks-picked-confirm-light")
        app.sheets.buttons["完了"].firstMatch.tap()
        XCTAssertTrue(row(app, "名刺の紙を決める").waitForNonExistence(timeout: 15))
        XCTAssertEqual(Set(completedIDs()), [awaitingID, reviewID])
    }

    /// One refusal in a batch: the others complete, the refused one stays on
    /// screen and stays picked, with the reason.
    func testOneRefusalKeepsTheOthersAndItsPick() throws {
        let app = try launch()
        fixture("/tasks/refuse-complete/\(draftID)")
        tasks(app)
        _ = pick(app, reviewID)
        let draft = pick(app, draftID)
        batchButton(app).tap()
        XCTAssertTrue(row(app, "今週の振り返りをまとめる").waitForNonExistence(timeout: 15))
        // The list row may merge the line into one element: match any kind.
        let failure = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "T16は完了できませんでした")).firstMatch
        var up = 0
        while !failure.exists && up < 6 { app.swipeDown(); up += 1 }
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        shot(app, "c-tasks-picked-refusal-light")
        XCTAssertEqual(completedIDs(), [reviewID])
        // The list is lazy: bring the refused row on screen before reading it.
        scrollTo(app, draft)
        XCTAssertTrue(row(app, "週報の下書き").exists)
        XCTAssertTrue(draft.isSelected, "The refused task stays picked for a retry")
        let count = app.staticTexts["work.tasks.selectionCount"]
        var moves = 0
        while !count.exists && moves < 6 { app.swipeDown(); moves += 1 }
        XCTAssertEqual(count.label, "1件を選択中")
    }

    /// A running task's box refuses the pick and says why.
    func testRunningTaskCannotBePicked() throws {
        let app = try launch()
        tasks(app)
        let box = pick(app, runningID)
        XCTAssertFalse(box.isSelected)
        XCTAssertTrue(app.descendants(matching: .any)["work.tasks.notice"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["work.tasks.completeSelected"].exists)
        XCTAssertEqual(completedIDs(), [])
    }

    /// The status label is a link to its session, not decoration.
    func testStatusLabelOpensItsSession() throws {
        let app = try launch()
        tasks(app)
        let status = app.descendants(matching: .any)["work.task.status.\(awaitingID)"].firstMatch
        scrollTo(app, status)
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.contains("判断待（S8）"), status.label)
        status.tap()
        let sessionTitle = app.descendants(matching: .any)["work.session.detail.title"].firstMatch
        XCTAssertTrue(sessionTitle.waitForExistence(timeout: 15))
        XCTAssertTrue(sessionTitle.label.contains("判断待ち・長い履歴"), sessionTitle.label)
        XCTAssertTrue(app.descendants(matching: .any)["work.session.decision"].firstMatch.waitForExistence(timeout: 15))
        // A native question keeps its free answer beside the options, in the
        // same words as the board.
        let free = app.descendants(matching: .any)["work.session.decision.note.0"].firstMatch
        XCTAssertTrue(free.waitForExistence(timeout: 15))
        XCTAssertTrue(free.isHittable, "The session question's free answer is visible beside its options")
        shot(app, "c-session-question-free-answer-light")
    }

    /// A production-sized decision: the free answer is visible without
    /// choosing anything, typing selects it, and it is sent as optionIndex
    /// null with the note.
    func testFreeAnswerOnALongDecision() throws {
        let app = try launch(board: "long")
        let board = app.buttons["work.section.decisions"]
        XCTAssertTrue(board.waitForExistence(timeout: 20))
        board.tap()
        let card = app.buttons["work.decision.\(longDecisionID)"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        card.tap()
        XCTAssertTrue(app.staticTexts["選択肢以外で答える"].waitForExistence(timeout: 10))
        let field = noteField(app)
        scrollTo(app, field)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertTrue(field.isHittable, "The free answer is on screen without opening a card")
        XCTAssertFalse(app.buttons["work.decision.send"].isEnabled)
        field.tap()
        field.typeText("制作を優先し、公開は11月28日にします。")
        XCTAssertTrue(app.buttons["work.decision.send"].isEnabled)
        XCTAssertFalse(app.buttons["work.decision.option.0"].isSelected)
        app.buttons["work.decision.send"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["work.decision.sent"].firstMatch.waitForExistence(timeout: 15))
        // The request carries the words in note with optionIndex null; the
        // Bridge stores a free answer in the label (note stays null there).
        let sent = fixture("/state")?["lastAnswer"] as? [String: Any]
        XCTAssertEqual(sent?["id"] as? String, longDecisionID)
        XCTAssertTrue(sent?["optionIndex"] is NSNull)
        XCTAssertEqual(sent?["note"] as? String, "制作を優先し、公開は11月28日にします。")
        let answer = answered(longDecisionID)
        XCTAssertEqual(answer?["label"] as? String, "制作を優先し、公開は11月28日にします。")
        XCTAssertEqual(answer?["delivery"] as? String, "delivered")
    }

    // MARK: Pictures

    func testTaskShotsLight() throws { try taskShots(dark: false) }
    func testTaskShotsDark() throws { try taskShots(dark: true) }
    func testDecisionShotsLight() throws { try decisionShots(dark: false) }
    func testDecisionShotsDark() throws { try decisionShots(dark: true) }

    private func taskShots(dark: Bool) throws {
        let suffix = dark ? "dark" : "light"
        let app = try launch(dark: dark)
        tasks(app)
        XCTAssertTrue(row(app, "次の打ち合わせを確認する").waitForExistence(timeout: 15))
        shot(app, "c-tasks-list-\(suffix)")
        app.scrollViews.firstMatch.swipeUp()
        shot(app, "c-tasks-states-\(suffix)")
        app.scrollViews.firstMatch.swipeDown()

        app.buttons["work.linear.add"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["work.linear.model"].firstMatch.waitForExistence(timeout: 10))
        shot(app, "c-task-create-\(suffix)")
        app.buttons["Close"].tap()

        let target = row(app, "見積りを送る")
        scrollTo(app, target)
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        target.swipeLeft()
        app.buttons["完了"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["完了にしますか？"].waitForExistence(timeout: 5))
        shot(app, "c-task-complete-confirm-\(suffix)")
        // This iOS build shows only the action in the sheet; confirming also
        // closes it (the fixture is reset by the next test).
        app.sheets.buttons["完了"].tap()
    }

    private func decisionShots(dark: Bool) throws {
        let suffix = dark ? "dark" : "light"
        let app = try launch(dark: dark, board: "long")
        let card = app.buttons["work.decision.\(longDecisionID)"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        card.tap()
        let field = noteField(app)
        scrollTo(app, field)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        shot(app, "c-decision-free-text-\(suffix)")
    }

    // MARK: Helpers

    /// The free answer, by identifier when SwiftUI exposes it; otherwise the
    /// detail's only text field (it is the note).
    private func noteField(_ app: XCUIApplication) -> XCUIElement {
        let byID = app.descendants(matching: .any)["work.decision.note"].firstMatch
        if byID.exists { return byID }
        return app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
    }

    /// Waits for the fixture to record the create. A missing request prints
    /// what the open form said, so the reason is in the test log.
    private func waitForCreated(_ app: XCUIApplication, _ title: String) -> [String: Any]? {
        for _ in 0..<24 {
            let rows = (fixture("/state")?["created"] as? [[String: Any]]) ?? []
            if let created = rows.last, created["title"] as? String == title { return created }
            Thread.sleep(forTimeInterval: 0.5)
        }
        print("CREATE MISSING for \(title); texts: " + app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))
        return nil
    }

    private func openDetail(_ app: XCUIApplication, _ title: String) {
        let target = row(app, title)
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        target.press(forDuration: 1.2)
        let detail = app.buttons["詳細・コメント"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        detail.tap()
        XCTAssertTrue(app.staticTexts["work.task.detail.title"].firstMatch.waitForExistence(timeout: 15))
    }

    private func scrollTo(_ app: XCUIApplication, _ element: XCUIElement) {
        var moves = 0
        // A field below the fold may not be in the tree yet, so scroll while
        // it is missing as well as while it is on screen but not reachable.
        while (!element.exists || !element.isHittable) && moves < 6 {
            app.swipeUp(); moves += 1
        }
    }
}
#endif

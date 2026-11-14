#if LAA_BUILD
import XCTest

/// The owner's 2026-11-12 round on a Work session, against the synthetic Work
/// fixture (`scripts/laa/work-ui-fixture.mjs`): each reply's model, the effort
/// beside the model with XHigh and Max marked, the request → running line,
/// thinking... and Compacting..., attached pictures as thumbnails with a
/// viewer, and a held follow-up shown with its pictures. Each state is
/// photographed in light and dark.
final class LAASessionModelDisplayUITests: XCTestCase {
    private let port = Int(ProcessInfo.processInfo.environment["LAA_WORK_FIXTURE_PORT"] ?? "") ?? 19584
    private let switchedID = "ses_9999999999999999"
    private let mythosID = "ses_aaaaaaaaaaaaaaaa"
    private let maxID = "ses_bbbbbbbbbbbbbbbb"

    func testModelDisplayLight() throws { try run("light") }

    /// Sending returns to the end even after reading older turns (owner,
    /// 2026-11-12): the message just sent is on screen, pictures and all,
    /// with the keyboard up.
    func testSendingReturnsToTheEndAfterScrollingUp() throws {
        let app = try launch("light")
        open("ses_3333333333333333", app)
        let field = any("work.composer.field", app)
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        app.scrollViews.firstMatch.swipeDown()
        app.scrollViews.firstMatch.swipeDown()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(app.staticTexts["最後のメッセージ S62M"].firstMatch.isHittable, "the page left the end")
        field.tap()
        field.typeText("上を読んだあとに送ります。")
        app.buttons["work.composer.send"].tap()
        let echo = any("work.session.echo", app)
        XCTAssertTrue(echo.waitForExistence(timeout: 10))
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: echo)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 5), .completed, "the sent message must be on screen")
        capture(app, "sent-returns-to-end")

        // The screen stays alive after the send: it scrolls and takes text.
        let started = Date()
        app.scrollViews.firstMatch.swipeDown()
        field.tap()
        field.typeText("続けて")
        XCTAssertTrue((field.value as? String ?? "").contains("続けて"), "the field takes text after a send")
        XCTAssertLessThan(Date().timeIntervalSince(started), 20, "the app answered slowly after the send")
    }
    func testModelDisplayDark() throws { try run("dark") }

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

    private func launch(_ theme: String) throws -> XCUIApplication {
        guard fixture("/reset") != nil else { throw XCTSkip("Start scripts/laa/work-ui-fixture.mjs") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "work", "-LAA_UI_TEST_ISOLATED_BRIDGE", "-LAA_UI_TEST_CLEAR_WORK_STORE",
                               "-LAA_UI_TEST_WORK_ATTACHMENTS",
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
        while !row.isHittable && swipes < 6 { app.scrollViews.firstMatch.swipeUp(); swipes += 1 }
        row.tap()
        XCTAssertTrue(any("work.session.detail.title", app).waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 2)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func menuRow(_ name: String, _ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + ",")).firstMatch
    }

    private func any(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func dismissMenu(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        Thread.sleep(forTimeInterval: 0.6)
    }

    private func run(_ theme: String) throws {
        let app = try launch(theme)

        // 1, 4. Started on Fable 5.2, running on Opus 4.8 after the provider's
        // own switch: each reply names the model the Bridge saw, the turn
        // before the switch only the provider, and the top says so.
        open(switchedID, app)
        XCTAssertTrue(app.staticTexts["Fable 5.2"].firstMatch.waitForExistence(timeout: 10), "the reply Fable wrote names Fable")
        XCTAssertTrue(app.staticTexts["Claude"].firstMatch.exists, "the doubtful turn names the provider only")
        XCTAssertGreaterThanOrEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "Opus 4.8")).count, 2,
                                    "every progress note names its model")
        let mismatch = any("work.session.modelMismatch", app)
        // The line leads the conversation; a composer whose capsules take a
        // line of their own can leave it just above the opened view.
        if !mismatch.exists { app.scrollViews.firstMatch.swipeDown(); Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertTrue(mismatch.waitForExistence(timeout: 5))
        XCTAssertTrue(mismatch.label.contains("Fable 5.2") && mismatch.label.contains("Opus 4.8"), mismatch.label)
        XCTAssertTrue(mismatch.label.contains("切替を確認"), "the Bridge saw the switch: say when")
        XCTAssertTrue(any("work.session.progress.thinking", app).waitForExistence(timeout: 10))
        let pill = any("work.session.model", app)
        let effort = any("work.session.effort", app)
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        XCTAssertTrue((pill.value as? String ?? "").contains("Opus 4.8"), pill.debugDescription)
        XCTAssertEqual(effort.value as? String, "XHigh", "the effort is its own capsule beside the model")
        XCTAssertEqual(pill.frame.midY, effort.frame.midY, accuracy: 1, "the two capsules share a line")
        XCTAssertEqual(pill.frame.height, effort.frame.height, accuracy: 1, "and a height")
        capture(app, "switched-\(theme)")
        app.scrollViews.firstMatch.swipeDown()
        Thread.sleep(forTimeInterval: 0.5)
        capture(app, "switched-top-\(theme)")

        // The owner's sent picture opens over the whole screen.
        let sent = any("work.session.image", app)
        XCTAssertTrue(sent.waitForExistence(timeout: 20), "the owner's picture did not load")
        // Its upper part: the composer can cover the lower half.
        sent.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        XCTAssertTrue(any("work.image.preview", app).waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.6)
        capture(app, "conversation-image-preview-\(theme)")
        app.buttons["work.image.preview.close"].tap()
        XCTAssertTrue(pill.waitForExistence(timeout: 5))

        // The model menu: the request → running line and the models, no
        // effort; the effort menu: the efforts, no model.
        pill.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "依頼 Fable 5.2")).firstMatch
            .waitForExistence(timeout: 5), "the menu names the request and what runs")
        XCTAssertFalse(menuRow("XHigh", app).exists, "the model menu lists models only")
        capture(app, "switched-menu-\(theme)")
        dismissMenu(app)
        effort.tap()
        XCTAssertTrue(menuRow("XHigh", app).waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "依頼 Fable 5.2")).firstMatch.exists,
                       "the effort menu lists efforts only")
        capture(app, "switched-effort-menu-\(theme)")
        dismissMenu(app)

        // 5. Attached pictures: thumbnails, a tap opens, only × removes.
        let thumbnail = app.buttons["work.composer.attachment.0"]
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["work.composer.attachment.1"].exists)
        capture(app, "attachments-\(theme)")
        thumbnail.tap()
        XCTAssertTrue(any("work.image.preview", app).waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.6)
        capture(app, "attachment-preview-\(theme)")
        app.buttons["work.image.preview.close"].tap()
        XCTAssertTrue(app.buttons["work.composer.attachment.1"].waitForExistence(timeout: 5), "a tap must not remove")
        app.buttons["work.composer.attachment.1.remove"].tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                             object: app.buttons["work.composer.attachment.1"])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed, "× removes the picture")

        // A follow-up sent while the turn runs is held by the Bridge; the
        // transcript shows it, picture and all, as 順番待ち.
        let field = any("work.composer.field", app)
        field.tap()
        field.typeText("この画像も参考にしてください。")
        app.buttons["work.composer.send"].tap()
        XCTAssertTrue(any("work.session.echo", app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["この画像も参考にしてください。"].firstMatch.exists)
        XCTAssertTrue(any("work.session.echo.image", app).exists, "the held message keeps its picture")
        let sentState = fixture("/state")?["followUps"] as? [[String: Any]] ?? []
        XCTAssertEqual(sentState.last?["images"] as? Int, 1, "the picture was sent with the message")
        Thread.sleep(forTimeInterval: 1)
        capture(app, "queued-echo-\(theme)")

        // 2, 3. Mythos at XHigh, which the HQ table offers at High only: the
        // menu lists the current XHigh, checked. The conversation compacts.
        app.navigationBars.buttons.firstMatch.tap()
        open(mythosID, app)
        XCTAssertTrue(any("work.session.progress.compacting", app).waitForExistence(timeout: 10))
        capture(app, "compacting-\(theme)")
        effort.tap()
        // A system menu keeps the rows' labels, not their identifiers.
        let xhigh = menuRow("XHigh", app)
        XCTAssertTrue(xhigh.waitForExistence(timeout: 5), "the applied XHigh is listed")
        XCTAssertTrue(menuRow("High", app).exists)
        capture(app, "mythos-menu-\(theme)")
        dismissMenu(app)

        // 3. Max on a GPT model.
        app.navigationBars.buttons.firstMatch.tap()
        open(maxID, app)
        XCTAssertTrue(effort.waitForExistence(timeout: 10))
        XCTAssertEqual(effort.value as? String, "Max", effort.debugDescription)
        XCTAssertFalse(any("work.session.progress.thinking", app).exists, "no progress line once the turn ended")
        capture(app, "max-\(theme)")
        effort.tap()
        XCTAssertTrue(menuRow("Max", app).waitForExistence(timeout: 5))
        capture(app, "max-menu-\(theme)")
        dismissMenu(app)

        // The list names each model as the heading and the pill do.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["work.section.sessions"].waitForExistence(timeout: 10))
        app.buttons["work.section.sessions"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Mythos 5.2")).firstMatch
            .waitForExistence(timeout: 10), "the list reads Mythos 5.2, not the id")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "claude-")).firstMatch.exists)
        capture(app, "session-list-\(theme)")

        // Every face in the launcher's model menu, DeepSeek's whale included.
        app.buttons["work.create"].tap(); app.buttons["work.sessions.new"].tap()
        let models = any("work.launch.model", app)
        XCTAssertTrue(models.waitForExistence(timeout: 10))
        models.tap()
        Thread.sleep(forTimeInterval: 0.8)
        capture(app, "launcher-models-\(theme)")

        // Another model keeps the effort when it has it, else High: Opus
        // XHigh → GPT-6 Astra keeps XHigh; → Sonnet takes High.
        let launchEffort = any("work.launch.effort", app)
        let opus = app.buttons["Opus 5.5"].firstMatch
        XCTAssertTrue(opus.waitForExistence(timeout: 5))
        XCTAssertFalse(menuRow("XHigh", app).exists, "the model menu lists models only")
        if (models.value as? String) != "Claude Opus 5.5" { opus.tap() } else { dismissMenu(app) }
        expectation(for: NSPredicate(format: "value == %@", "Claude Opus 5.5"), evaluatedWith: models)
        waitForExpectations(timeout: 5)
        launchEffort.tap()
        let xhighRow = menuRow("XHigh", app)
        XCTAssertTrue(xhighRow.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["GPT-6 Astra"].exists, "the effort menu lists efforts only")
        capture(app, "launcher-efforts-\(theme)")
        if (launchEffort.value as? String) != "XHigh" { xhighRow.tap() } else { dismissMenu(app) }
        expectation(for: NSPredicate(format: "value == %@", "XHigh"), evaluatedWith: launchEffort)
        waitForExpectations(timeout: 5)
        models.tap()
        let astra = app.buttons["GPT-6 Astra"].firstMatch
        XCTAssertTrue(astra.waitForExistence(timeout: 5))
        astra.tap()
        expectation(for: NSPredicate(format: "value == %@", "GPT-6 Astra"), evaluatedWith: models)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(launchEffort.value as? String, "XHigh", "the same effort stays")
        models.tap()
        let sonnet = app.buttons["Sonnet 5.5"].firstMatch
        XCTAssertTrue(sonnet.waitForExistence(timeout: 5))
        sonnet.tap()
        expectation(for: NSPredicate(format: "value == %@", "Claude Sonnet 5.5"), evaluatedWith: models)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(launchEffort.value as? String, "High", "else High")
        capture(app, "launcher-sonnet-\(theme)")
    }
}
#endif

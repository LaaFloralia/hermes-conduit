#if LAA_BUILD
import XCTest

/// The owner's 2026-11-11 round on Work's session detail and Usage, against the
/// synthetic Work fixture (`scripts/laa/work-ui-fixture.mjs`): every control is
/// pressed and its result read back, and each state is photographed.
final class LAAChatPolishUITests: XCTestCase {
    private let port = Int(ProcessInfo.processInfo.environment["LAA_WORK_FIXTURE_PORT"] ?? "") ?? 19584
    private let longID = "ses_3333333333333333"
    private let runningID = "ses_5555555555555555"
    private let emptyID = "ses_1111111111111111"

    func testPolishLight() throws { try polish("light") }
    func testPolishDark() throws { try polish("dark") }

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
        XCTAssertTrue(app.descendants(matching: .any)["work.session.detail.title"].firstMatch.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 2)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func lastHittable(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        let all = app.buttons.matching(identifier: id).allElementsBoundByIndex
        return all.last(where: \.isHittable) ?? all.last ?? app.buttons[id].firstMatch
    }

    private func any(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func polish(_ theme: String) throws {
        let app = try launch(theme)

        // 1, 3. A running session: the model pill opens even though this model
        // cannot be changed, and the stop sits in a ring as small as Send's.
        open(runningID, app)
        let stop = app.buttons["work.session.stop"].firstMatch
        let send = app.buttons["work.composer.send"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 15))
        XCTAssertEqual(stop.frame.width, send.frame.width, accuracy: 1, "stop and Send share one size")
        XCTAssertEqual(stop.frame.height, send.frame.height, accuracy: 1)
        capture(app, "polish-running-\(theme)")
        let pill = any("work.session.model", app)
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        pill.tap()
        let reasons = ["このセッションではモデルを変更できません。", "切り替えられるモデルがありません。"]
        let reason = app.buttons.matching(NSPredicate(format: "label IN %@", reasons)).firstMatch
        XCTAssertTrue(reason.waitForExistence(timeout: 5)
                      || app.staticTexts.matching(NSPredicate(format: "label IN %@", reasons)).firstMatch.exists,
                      "the menu must open and say why nothing can be chosen")
        capture(app, "polish-running-menu-\(theme)")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()

        // 1. A session whose provider has another model: choose it and read
        // the pill back.
        open(longID, app)
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        pill.tap()
        let sonnet = app.buttons["Sonnet 5.5"].firstMatch
        XCTAssertTrue(sonnet.waitForExistence(timeout: 5), "the model list did not open")
        capture(app, "polish-model-menu-\(theme)")
        sonnet.tap()
        let switched = NSPredicate(format: "value CONTAINS %@", "Sonnet 5.5")
        expectation(for: switched, evaluatedWith: pill)
        waitForExpectations(timeout: 10)

        // 5. Quote a reply into the field, mark it good, copy it.
        // The page opens at its end: act on the last reply on screen, not on
        // a row the lazy transcript still holds above the viewport.
        XCTAssertTrue(app.buttons["work.message.quote"].firstMatch.waitForExistence(timeout: 10))
        let likes = app.buttons.matching(identifier: "work.message.like")
        let index = likes.allElementsBoundByIndex.lastIndex(where: \.isHittable) ?? max(0, likes.count - 1)
        // Likes stay on the device across launches, so the press flips
        // whatever the previous theme's run left.
        let on = app.buttons.matching(NSPredicate(format: "identifier == %@ AND value == %@", "work.message.like", "オン"))
        let onBefore = on.count
        likes.element(boundBy: index).tap()
        expectation(for: NSPredicate(format: "count != %d", onBefore), evaluatedWith: on)
        waitForExpectations(timeout: 5)
        if on.count < onBefore { likes.element(boundBy: index).tap() }
        lastHittable("work.message.copy", app).tap()
        lastHittable("work.message.quote", app).tap()
        let field = any("work.composer.field", app)
        let quoted = NSPredicate(format: "value BEGINSWITH %@", ">")
        expectation(for: quoted, evaluatedWith: field)
        waitForExpectations(timeout: 10)
        capture(app, "polish-quote-\(theme)")

        // 2. The field grows by dragging its top edge, and opens in full.
        let handle = any("work.composer.resize", app)
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        let before = field.frame.height
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -6)))
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertGreaterThan(field.frame.height, before + 60, "dragging the edge must make the field taller")
        capture(app, "polish-field-tall-\(theme)")
        XCTAssertTrue(app.buttons["work.composer.expand"].firstMatch.exists, "the full editor is offered at one line too")

        // 6. Usage: the refresh is a button again and it answers.
        app.navigationBars.buttons.firstMatch.tap()
        var moves = 0
        let usage = app.buttons["work.usage"]
        while usage.exists && usage.frame.maxX > app.frame.width - 8 && moves < 6 {
            let start = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: app.frame.width - 60, dy: usage.frame.midY))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -300, dy: 0)),
                        withVelocity: XCUIGestureVelocity(500), thenHoldForDuration: 0.1)
            moves += 1
        }
        usage.tap()
        let refresh = app.buttons["laa.usage.refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 25))
        XCTAssertEqual(refresh.label, "今すぐ更新")
        XCTAssertTrue(app.staticTexts["今すぐ更新"].exists, "the button names itself on screen")
        refresh.tap()
        Thread.sleep(forTimeInterval: 2)
        capture(app, "polish-usage-\(theme)")
    }
}
#endif

#if LAA_BUILD
import XCTest

/// Short numbers in Work, against the synthetic fixture
/// (`scripts/laa/work-ui-fixture.mjs`): every list and detail shows its ref,
/// the Priority tab is gone, Tasks is the default, and the phone's one search
/// finds `t12` as `T12`.
final class LAAWorkRefUITests: XCTestCase {
    private let port = Int(ProcessInfo.processInfo.environment["LAA_WORK_FIXTURE_PORT"] ?? "") ?? 19584

    private func launch(_ appearance: String = "light") throws -> XCUIApplication {
        guard (try? Data(contentsOf: URL(string: "http://127.0.0.1:\(port + 1)/reset")!)) != nil else {
            throw XCTSkip("Start scripts/laa/work-ui-fixture.mjs")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "work", "-LAA_UI_TEST_ISOLATED_BRIDGE",
                               "-conduit.themePreference", appearance,
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
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
        XCTAssertTrue(app.staticTexts["次の打ち合わせを確認する"].waitForExistence(timeout: 20))
        return app
    }

    private func section(_ app: XCUIApplication, _ value: String) {
        let button = app.buttons["work.section.\(value)"]
        if button.frame.maxX > app.frame.maxX - 10 { app.buttons["work.section.projects"].tap() }
        button.tap()
    }

    private func searchField(_ app: XCUIApplication) -> XCUIElement {
        LAAWorkRefUITests.openSearch(app)
    }

    /// The hub's one search sits above the list, in the same capsule as the
    /// other sections' — no toolbar button to open first.
    static func openSearch(_ app: XCUIApplication) -> XCUIElement {
        app.textFields["laa.work.search"]
    }

    func testTasksIsTheDefaultSectionAndPriorityIsGone() throws {
        let app = try launch()
        XCTAssertTrue(app.buttons["work.section.tasks"].isSelected)
        XCTAssertFalse(app.buttons["work.section.priority"].exists)
        XCTAssertFalse(app.staticTexts["Priority"].exists)
        XCTAssertTrue(app.staticTexts["work.ref.T12"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["work.ref.T13"].exists)
    }

    func testEveryListAndDetailShowsItsShortNumber() throws {
        let app = try launch()
        // Task row, then its detail: the short number and Linear's identifier.
        let task = app.buttons.containing(.staticText, identifier: "次の打ち合わせを確認する").firstMatch
        XCTAssertTrue(task.waitForExistence(timeout: 10))
        task.press(forDuration: 1.5)
        let open = app.buttons["詳細・コメント"]
        XCTAssertTrue(open.waitForExistence(timeout: 5)); open.tap()
        let meta = app.staticTexts["work.task.detail.ref"]
        XCTAssertTrue(meta.waitForExistence(timeout: 10))
        XCTAssertEqual(meta.label, "T12 · BUS-TEST1")
        app.buttons["Close"].firstMatch.tap()

        // Sessions: every row and the session's own header.
        section(app, "sessions")
        XCTAssertTrue(app.staticTexts["work.ref.S1"].waitForExistence(timeout: 15))
        for id in ["ses_2222222222222222", "ses_3333333333333333"] {
            XCTAssertTrue(app.staticTexts["work.session.\(id)"].exists)
        }
        app.staticTexts["work.session.ses_1111111111111111"].firstMatch.tap()
        // The short number sits in the bar's heading pill, not in the page.
        let header = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ AND label CONTAINS 'S1'", "work.session.detail.title")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 15))
        app.navigationBars.buttons.firstMatch.tap()

        // Projects: the row and the project's own page.
        section(app, "projects")
        XCTAssertTrue(app.staticTexts["work.ref.P1"].waitForExistence(timeout: 15))
        app.staticTexts["work.ref.P1"].firstMatch.tap()
        XCTAssertTrue(app.buttons["work.project.newSession"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["work.ref.P1"].exists)
        app.navigationBars.buttons.firstMatch.tap()

        // Routines: the scheduled row, then the resident one.
        section(app, "routines")
        XCTAssertTrue(app.staticTexts["work.ref.R1"].waitForExistence(timeout: 20))
        // The disclosure carries one identifier for its subtree, so the
        // resident routine is matched by its label.
        app.buttons["work.routines.services"].tap()
        XCTAssertTrue(app.staticTexts["R2"].waitForExistence(timeout: 10))

        // Skills: the row and the skill's detail.
        section(app, "skills")
        XCTAssertTrue(app.staticTexts["work.ref.K1"].waitForExistence(timeout: 15))
        app.buttons.containing(.staticText, identifier: "weekly-report").firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["work.skill.detail"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["K1"].exists)
    }

    func testSearchFindsAShortNumberAndTheRowText() throws {
        let app = try launch()
        let field = searchField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText("t12")
        XCTAssertTrue(app.staticTexts["work.ref.T12"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["work.ref.T13"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["今週の振り返りをまとめる"].waitForNonExistence(timeout: 5))

        // Moving to another section clears the search and shows its rows.
        section(app, "sessions")
        XCTAssertTrue(app.staticTexts["work.ref.S1"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["work.ref.S2"].exists)
        let sessionField = searchField(app)
        sessionField.tap(); sessionField.typeText("s2")
        XCTAssertTrue(app.staticTexts["work.ref.S2"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["work.ref.S1"].waitForNonExistence(timeout: 5))

        // A word still finds the row by its text.
        section(app, "tasks")
        let taskField = searchField(app)
        taskField.tap(); taskField.typeText("振り返り")
        XCTAssertTrue(app.staticTexts["work.ref.T13"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["work.ref.T12"].waitForNonExistence(timeout: 5))
    }
}

/// 440 × 956 pt captures of the Work lists for the before/after comparison.
/// It makes no assertion about refs or search, so the same test runs against
/// master (where the field is absent) and the candidate.
final class LAAWorkRefSnapshotTests: XCTestCase {
    private let port = Int(ProcessInfo.processInfo.environment["LAA_WORK_FIXTURE_PORT"] ?? "") ?? 19584

    private func launch(_ appearance: String) throws -> XCUIApplication {
        guard (try? Data(contentsOf: URL(string: "http://127.0.0.1:\(port + 1)/reset")!)) != nil else {
            throw XCTSkip("Start scripts/laa/work-ui-fixture.mjs")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "work", "-LAA_UI_TEST_ISOLATED_BRIDGE",
                               "-conduit.themePreference", appearance,
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
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
        XCTAssertTrue(app.staticTexts["次の打ち合わせを確認する"].waitForExistence(timeout: 20))
        return app
    }

    func testWorkScreensLight() throws { try capture("light") }
    func testWorkScreensDark() throws { try capture("dark") }

    private func capture(_ appearance: String) throws {
        let app = try launch(appearance)
        attach("shots-tasks-\(appearance)")

        let sessions = app.buttons["work.section.sessions"]
        if sessions.frame.maxX > app.frame.maxX - 10 { app.buttons["work.section.projects"].tap() }
        sessions.tap()
        XCTAssertTrue(app.staticTexts["work.session.ses_1111111111111111"].waitForExistence(timeout: 20))
        attach("shots-sessions-\(appearance)")

        let tasks = app.buttons["work.section.tasks"]
        if tasks.frame.maxX > app.frame.maxX - 10 { app.buttons["work.section.projects"].tap() }
        tasks.tap()
        XCTAssertTrue(app.staticTexts["次の打ち合わせを確認する"].waitForExistence(timeout: 20))
        // The phone's search only exists from this candidate on; master shows
        // the same list, so the capture still names the state.
        let field = LAAWorkRefUITests.openSearch(app)
        if field.exists {
            field.tap(); field.typeText("t12")
            Thread.sleep(forTimeInterval: 1)
        }
        attach("shots-search-\(appearance)")
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
#endif

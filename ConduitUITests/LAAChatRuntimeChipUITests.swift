#if LAA_BUILD
import XCTest

/// The composer's model and effort pickers show what Hermes reports for each
/// employee's running agent, and 「不明」 for what it does not report; each
/// opens its own menu and changes this chat only (owner, 2026-11-12).
final class LAAChatRuntimeChipUITests: XCTestCase {
    private func launch(profile: String, runtime: String?, dark: Bool = false, models: String? = nil, offline: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_V2_CHAT_FIXTURE", "simple",
                               "-LAA_CAPTURE_SURFACE", "chat", "-LAA_CAPTURE_KIND", "paper",
                               "-LAA_FIXTURE_PUSH_CHAT", "-LAA_FIXTURE_PROFILE", profile]
            + (runtime.map { ["-LAA_FIXTURE_RUNTIME", $0] } ?? []) + (dark ? ["-LAA_V2_DARK"] : [])
            + (models.map { ["-LAA_FIXTURE_CHAT_MODELS", $0] } ?? [])
            + (offline ? ["-LAA_GROUPS_STATE", "offline"] : [])
        app.launch()
        XCTAssertTrue(app.staticTexts["fixture.capture.ready"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.textViews["composer.field"].waitForExistence(timeout: 15))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    private func any(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func chipValue(_ app: XCUIApplication) -> String {
        let model = any("composer.runtime.model", app)
        let effort = any("composer.runtime.effort", app)
        XCTAssertTrue(model.waitForExistence(timeout: 10))
        XCTAssertTrue(effort.exists)
        let field = app.textViews["composer.field"]
        XCTAssertGreaterThanOrEqual(model.frame.minY, field.frame.maxY - 1, "the pickers sit in the row under the field")
        XCTAssertEqual(model.frame.midY, effort.frame.midY, accuracy: 1, "the two capsules share a line")
        XCTAssertEqual(model.frame.height, effort.frame.height, accuracy: 1, "and a height")
        XCTAssertLessThanOrEqual(model.frame.maxX, effort.frame.minX, "the effort follows the model")
        return (model.value as? String ?? "") + " · " + (effort.value as? String ?? "")
    }

    private func menuRow(_ name: String, _ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + ",")).firstMatch
    }

    private func dismissMenu(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        Thread.sleep(forTimeInterval: 0.6)
    }

    private func waitValue(_ element: XCUIElement, _ value: String) {
        expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: element)
        waitForExpectations(timeout: 10)
    }

    func testAstraSwitchReacquiresEffortsAndSwitchesBack() {
        let app = launch(profile: "laa-monet", runtime: "claude-mythos-5-2,claude,high", models: "astra")
        let model = any("composer.runtime.model", app)
        let effort = any("composer.runtime.effort", app)
        capture(app, "mythos-before-switch")
        model.tap()
        let astra = menuRow("GPT 6 Astra", app)
        XCTAssertTrue(astra.waitForExistence(timeout: 5)); astra.tap()
        waitValue(model, "GPT 6 Astra")
        effort.tap()
        let max = menuRow("Max", app)
        XCTAssertTrue(max.waitForExistence(timeout: 5))
        XCTAssertFalse(menuRow("Ultra", app).exists)
        capture(app, "astra-efforts-after-switch")
        max.tap(); waitValue(effort, "Max")
        capture(app, "astra-max-saved")
        model.tap(); menuRow("Mythos 5.2", app).tap()
        let confirm = app.buttons["切り替える"]
        if confirm.waitForExistence(timeout: 3) { confirm.tap() }
        waitValue(model, "Mythos 5.2")
        effort.tap(); menuRow("High", app).tap(); waitValue(effort, "High")
        app.terminate()
    }

    func testKeyboardKeepsComposerControlsAboveKeyboard() {
        let app = launch(profile: "laa-monet", runtime: "gpt-6-astra,openai-codex,xhigh", models: "astra")
        let field = app.textViews["composer.field"]
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        field.typeText("今ってssdつながってる？")
        capture(app, "keyboard-composer-controls")
        let keyboardTop = app.keyboards.firstMatch.frame.minY
        for id in ["composer.action", "composer.attach", "composer.runtime.model", "composer.runtime.effort"] {
            let control = any(id, app)
            XCTAssertTrue(control.isHittable, id)
            XCTAssertLessThanOrEqual(control.frame.maxY, keyboardTop, id)
        }
        let header = app.buttons["laa.employee.header"]
        XCTAssertGreaterThan(header.frame.height, 100, "the full mascot and name reserve their own height")
        XCTAssertGreaterThanOrEqual(any("chat.transcript", app).frame.minY, header.frame.maxY - 1)
        app.terminate()
    }

    func testOfflineMultilineKeyboardKeepsControls() {
        let app = launch(profile: "laa-monet", runtime: "gpt-6-astra,openai-codex,xhigh", models: "astra", offline: true)
        let field = app.textViews["composer.field"]
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        field.typeText("1\n2\n3\n4\n5\n6\n7\n8\n9\n10")
        capture(app, "offline-multiline-keyboard-controls")
        let keyboardTop = app.keyboards.firstMatch.frame.minY
        for id in ["composer.action", "composer.attach", "composer.runtime.model", "composer.runtime.effort"] {
            let control = any(id, app)
            XCTAssertTrue(control.isHittable, id)
            XCTAssertLessThanOrEqual(control.frame.maxY, keyboardTop, id)
        }
        app.terminate()
    }

    func testFailedPreviewKeepsControlsAndDraftOnRecovery() {
        let app = XCUIApplication()
        app.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_V2_CHAT_FIXTURE", "simple",
            "-LAA_CAPTURE_SURFACE", "chat", "-LAA_CAPTURE_KIND", "paper", "-LAA_FIXTURE_PUSH_CHAT",
            "-LAA_FIXTURE_PROFILE", "laa-monet", "-LAA_FIXTURE_PREVIEW_FAILED"]
        app.launch()
        let field = app.textViews["laa.chats.preview.composer"]
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        field.tap(); field.typeText("saved draft")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        let keyboardTop = app.keyboards.firstMatch.frame.minY
        for id in ["laa.chats.preview.runtime.model", "laa.chats.preview.runtime.effort", "laa.chats.preview.send"] {
            let control = any(id, app)
            XCTAssertTrue(control.exists)
            XCTAssertLessThanOrEqual(control.frame.maxY, keyboardTop)
        }
        XCTAssertFalse(any("laa.chats.preview.send", app).isEnabled)
        XCTAssertTrue(any("laa.chats.preview.retry", app).isHittable)
        capture(app, "failed-preview-keyboard-controls")
        app.buttons["fixture.preview.recover"].tap()
        let liveField = app.textViews["composer.field"]
        XCTAssertTrue(liveField.waitForExistence(timeout: 10))
        XCTAssertEqual(liveField.value as? String, "saved draft")
        capture(app, "preview-recovered-draft")
        app.terminate()
    }

    func testClarifyKeyboardAnswerReachesSameRequestAndResumes() {
        let app = XCUIApplication()
        app.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_V2_CHAT_FIXTURE", "simple", "-LAA_CAPTURE_SURFACE", "chat", "-LAA_CAPTURE_KIND", "paper", "-LAA_FIXTURE_PUSH_CHAT", "-LAA_FIXTURE_PROFILE", "laa-monet", "-LAA_FIXTURE_CLARIFY"]
        app.launch()
        let answer = any("clarify.answer.q0", app)
        XCTAssertTrue(answer.waitForExistence(timeout: 30))
        capture(app, "clarify-pending-before-input")
        answer.tap(); answer.typeText("1200 JPY")
        let send = app.buttons["clarify.send.q0"]
        XCTAssertTrue(send.isEnabled); capture(app, "clarify-input-send-enabled")
        send.tap()
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value == %@", "同じ質問への回答を受領：1200 JPY")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(answer.exists)
        capture(app, "clarify-answered-resumed")
        app.terminate()
    }

    func testClarifyTerminalStatesHaveNoAnswerControls() {
        for end in ["timeout", "cancelled", "resolved"] {
            let app = XCUIApplication()
            app.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_V2_CHAT_FIXTURE", "simple", "-LAA_CAPTURE_SURFACE", "chat", "-LAA_CAPTURE_KIND", "paper", "-LAA_FIXTURE_PUSH_CHAT", "-LAA_FIXTURE_PROFILE", "laa-monet", "-LAA_FIXTURE_CLARIFY", "-LAA_FIXTURE_CLARIFY_END", end]
            app.launch()
            XCTAssertTrue(app.staticTexts["fixture.capture.ready"].waitForExistence(timeout: 30))
            let terminal = any(end == "resolved" ? "clarify.answeredElsewhere.q0" : "clarify.expired.q0", app)
            XCTAssertTrue(terminal.waitForExistence(timeout: 10))
            let answer = any("clarify.answer.q0", app)
            XCTAssertFalse(answer.exists)
            XCTAssertFalse(app.buttons["clarify.send.q0"].exists)
            capture(app, "clarify-terminal-" + end)
            app.terminate()
        }
    }

    /// Each capsule opens its own menu; a model Hermes takes, or one it asks
    /// to confirm first, and an effort are read back into the capsules.
    func testModelAndEffortChangeFromTheirOwnMenus() {
        for dark in [false, true] {
            let app = launch(profile: "laa-monet", runtime: "claude-opus-5-5,claude,high", dark: dark, models: "several")
            let theme = dark ? "dark" : "light"
            let model = any("composer.runtime.model", app)
            let effort = any("composer.runtime.effort", app)
            XCTAssertEqual(chipValue(app), "Opus 5.5 · High")

            model.tap()
            let fable = app.buttons["Fable 5.2"].firstMatch
            XCTAssertTrue(fable.waitForExistence(timeout: 5), "the model menu lists Hermes' models")
            XCTAssertFalse(menuRow("XHigh", app).exists, "the model menu lists models only")
            capture(app, "chat-model-menu-\(theme)")
            fable.tap()
            waitValue(model, "Fable 5.2")
            XCTAssertEqual(effort.value as? String, "High", "the effort is left alone")

            // Mythos asks first, as Hermes' confirm_required does.
            model.tap()
            app.buttons["Mythos 5.2"].firstMatch.tap()
            let confirm = app.alerts.buttons["切り替える"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the confirmation must come up")
            capture(app, "chat-model-confirm-\(theme)")
            XCTAssertEqual(model.value as? String, "Fable 5.2", "nothing changes before the confirmation")
            confirm.tap()
            waitValue(model, "Mythos 5.2")

            effort.tap()
            let xhigh = menuRow("XHigh", app)
            XCTAssertTrue(xhigh.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["Fable 5.2"].exists, "the effort menu lists efforts only")
            capture(app, "chat-effort-menu-\(theme)")
            xhigh.tap()
            waitValue(effort, "XHigh")
            XCTAssertEqual(model.value as? String, "Mythos 5.2")
            capture(app, "chat-changed-\(theme)")
            app.terminate()
        }
    }

    /// A profile with one model (Dots, the uncensored one) still opens the
    /// menu and says why; the effort stays changeable.
    func testOneModelSaysWhyAndKeepsTheEffort() {
        let app = launch(profile: "laa-monet-dots", runtime: "claude-opus-5-5,claude,high", models: "single")
        let model = any("composer.runtime.model", app)
        XCTAssertTrue(model.waitForExistence(timeout: 10))
        model.tap()
        XCTAssertTrue(app.buttons["この社員で選べるモデルはこれだけです。"].waitForExistence(timeout: 5)
                      || app.staticTexts["この社員で選べるモデルはこれだけです。"].exists)
        capture(app, "chat-single-model-menu")
        dismissMenu(app)
        let effort = any("composer.runtime.effort", app)
        effort.tap()
        let max = menuRow("Max", app)
        XCTAssertTrue(max.waitForExistence(timeout: 5))
        max.tap()
        waitValue(effort, "Max")
        app.terminate()
    }

    /// Hermes cannot be reached: the model menu still opens, says so and
    /// offers to read again.
    func testUnreachableHermesSaysWhy() {
        let app = launch(profile: "laa-monet", runtime: nil)
        let model = any("composer.runtime.model", app)
        XCTAssertTrue(model.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        model.tap()
        XCTAssertTrue(app.buttons["モデルの候補を取得できませんでした。"].waitForExistence(timeout: 10)
                      || app.staticTexts["モデルの候補を取得できませんでした。"].exists)
        XCTAssertTrue(app.buttons["読み直す"].exists)
        capture(app, "chat-unreachable-model-menu")
        app.terminate()
    }

    func testEachEmployeeShowsItsOwnRunningModelAndEffort() {
        let cases: [(profile: String, runtime: String?, expected: String)] = [
            ("laa-monet", "claude-opus-5-5,claude,high", "Opus 5.5 · High"),
            ("laa-cto", "deepseek-v4.1-flash,laa-dsh,xhigh", "DeepSeek V4.1 Flash · XHigh"),
            ("laa-cfo", "deepseek-v4.1-flash,laa-dsh,", "DeepSeek V4.1 Flash · 不明"),
            ("laa-cso", nil, "不明 · 不明"),
        ]
        for (profile, runtime, expected) in cases {
            for dark in [false, true] {
                let app = launch(profile: profile, runtime: runtime, dark: dark)
                XCTAssertEqual(chipValue(app), expected, profile)
                capture(app, "chip-\(profile)-\(dark ? "dark" : "light")")
                app.terminate()
            }
        }
    }
}
#endif

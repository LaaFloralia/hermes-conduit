#if LAA_BUILD
import XCTest

final class LAAWorkLinearUITests: XCTestCase {
    private func launch(_ appearance: String = "light") throws -> XCUIApplication {
        guard (try? Data(contentsOf: URL(string: "http://127.0.0.1:19585/reset")!)) != nil else {
            throw XCTSkip("Start scripts/laa/work-ui-fixture.mjs")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "work", "-LAA_UI_TEST_ISOLATED_BRIDGE", "-conduit.themePreference", appearance,
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
        XCTAssertTrue(app.staticTexts["次の打ち合わせを確認する"].waitForExistence(timeout: 15))
        return app
    }

    func testCreateEditCompleteAndDeleteOwnerTasks() throws {
        let app = try launch()
        XCTAssertFalse(app.buttons["今週の振り返りをまとめる"].exists)
        app.buttons["work.section.tasks"].tap()
        XCTAssertTrue(app.buttons["今週の振り返りをまとめる"].waitForExistence(timeout: 10))
        app.buttons["work.linear.add"].tap()
        let title = app.textFields["work.linear.title"].firstMatch
        let editor = title.exists ? title : app.textViews["work.linear.title"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap(); editor.typeText("UI確認タスク")
        app.buttons["保存"].tap()
        XCTAssertTrue(app.buttons["UI確認タスク"].waitForExistence(timeout: 10))
        app.buttons["UI確認タスク"].tap()
        let editing = app.textFields["work.linear.title"].firstMatch
        let field = editing.exists ? editing : app.textViews["work.linear.title"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("更新")
        let updatedTitle = try XCTUnwrap(field.value as? String)
        XCTAssertTrue(updatedTitle.contains("更新"))
        XCTAssertNotEqual(updatedTitle, "UI確認タスク")
        app.buttons["保存"].tap()
        XCTAssertTrue(app.buttons[updatedTitle].waitForExistence(timeout: 10))
        app.buttons["次の打ち合わせを確認するを完了"].tap()
        XCTAssertTrue(app.staticTexts["次の打ち合わせを確認する"].waitForNonExistence(timeout: 10))
        let row = app.buttons[updatedTitle]
        row.swipeLeft()
        app.buttons["削除"].firstMatch.tap()
        let confirm = app.sheets.buttons["削除"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(app.buttons[updatedTitle].waitForNonExistence(timeout: 10))
    }

    private func capture(_ appearance: String) throws {
        let app = try launch(appearance)
        for section in ["priority", "tasks", "sessions", "projects", "routines", "skills"] {
            let button = app.buttons["work.section.\(section)"]
            if !button.isHittable { app.scrollViews["work.segment"].swipeLeft() }
            button.tap()
            let ready = section == "routines" ? "朝の確認" : section == "skills" ? "weekly-report" : "次の打ち合わせを確認する"
            if section == "sessions" || section == "projects" {
                XCTAssertTrue(app.buttons["work.section.\(section)"].isSelected)
            } else {
                XCTAssertTrue(app.staticTexts[ready].waitForExistence(timeout: 10))
            }
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "work-\(section)-\(appearance)"; shot.lifetime = .keepAlways; add(shot)
        }
        app.buttons["laa.settings.open"].firstMatch.tap()
        let usage = app.buttons["settings.ai-usage"]
        XCTAssertTrue(usage.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "settings.ai-usage").count, 1)
        usage.tap()
        XCTAssertTrue(app.buttons["laa.usage.refresh"].waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "settings-ai-usage-\(appearance)"; shot.lifetime = .keepAlways; add(shot)
    }
    func testWorkScreensLight() throws { try capture("light") }
    func testWorkScreensDark() throws { try capture("dark") }
}
#endif

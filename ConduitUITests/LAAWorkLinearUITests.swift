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

    func testFirstProjectToolbarAllowsSharedInstructions() throws {
        let app = try launch()
        app.buttons["work.section.projects"].tap()
        let add = app.buttons["プロジェクトを追加"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        XCTAssertTrue(app.textViews["work.project.instructions"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Bridgeが指示本文を返すまで編集できません。"].exists)
    }

    func testCreateEditArchiveAndRestoreOwnerTasks() throws {
        let app = try launch()
        // Tasks is the default section now, so both open tasks are listed.
        // A row's label carries its short number, so match the title row.
        XCTAssertTrue(taskRow(app, "今週の振り返りをまとめる").waitForExistence(timeout: 10))
        app.buttons["work.section.tasks"].tap()
        XCTAssertTrue(taskRow(app, "今週の振り返りをまとめる").waitForExistence(timeout: 10))
        app.buttons["work.linear.add"].tap()
        let title = app.textFields["work.linear.title"].firstMatch
        let editor = title.exists ? title : app.textViews["work.linear.title"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap(); editor.typeText("UI確認タスク")
        // A new task defaults to an AI assignee, whose profile arrives from
        // the Bridge before the save can be sent.
        XCTAssertTrue(app.descendants(matching: .any)["work.linear.model"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["work.linear.save"].tap()
        XCTAssertTrue(app.buttons["UI確認タスク"].waitForExistence(timeout: 10))
        app.buttons["UI確認タスク"].tap()
        let editing = app.textFields["work.linear.title"].firstMatch
        let field = editing.exists ? editing : app.textViews["work.linear.title"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("更新")
        let updatedTitle = try XCTUnwrap(field.value as? String)
        XCTAssertTrue(updatedTitle.contains("更新"))
        XCTAssertNotEqual(updatedTitle, "UI確認タスク")
        app.buttons["work.linear.save"].tap()
        XCTAssertTrue(app.buttons[updatedTitle].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["work.linear.complete.b9d2f664-cda3-4c56-8d39-c4d6df597254"].exists)
        XCTAssertTrue(app.staticTexts["前の操作の結果を確認しています。入力は端末に残っています。"].waitForNonExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["保存結果を確認できませんでした。"].waitForNonExistence(timeout: 2))
        let row = app.buttons[updatedTitle]
        row.swipeLeft()
        app.buttons["削除"].firstMatch.tap()
        let confirm = app.sheets.buttons["削除"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["アーカイブに移り、あとで戻せます。"].exists)
        if app.sheets.buttons["キャンセル"].exists { app.sheets.buttons["キャンセル"].tap() }
        else { app.otherElements["PopoverDismissRegion"].tap() }
        XCTAssertTrue(app.buttons[updatedTitle].exists)
        app.buttons[updatedTitle].swipeLeft()
        app.buttons["削除"].firstMatch.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(app.buttons[updatedTitle].waitForNonExistence(timeout: 10))
        app.buttons["work.linear.archive"].tap()
        let archived = app.buttons[updatedTitle]
        XCTAssertTrue(archived.waitForExistence(timeout: 10))
        archived.swipeLeft()
        app.buttons["戻す"].tap()
        XCTAssertTrue(archived.waitForNonExistence(timeout: 10))
        app.buttons["閉じる"].tap()
        XCTAssertTrue(app.buttons[updatedTitle].waitForExistence(timeout: 10))

    }

    func testSevenSuccessfulEditsDoNotLeavePendingWarning() throws {
        let app = try launch()
        app.buttons["work.section.tasks"].tap()
        var title = "次の打ち合わせを確認する"
        for _ in 0..<7 {
            let row = taskRow(app, title)
            XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
            let text = app.textFields["work.linear.title"].firstMatch
            let field = text.exists ? text : app.textViews["work.linear.title"].firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap(); field.typeText("改")
            title = try XCTUnwrap(field.value as? String)
            app.buttons["work.linear.save"].tap()
            XCTAssertTrue(taskRow(app, title).waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["前の操作の結果を確認しています。入力は端末に残っています。"].waitForNonExistence(timeout: 2))
            XCTAssertTrue(app.staticTexts["保存結果を確認できませんでした。"].waitForNonExistence(timeout: 2))
        }
    }

    func testSkillDetailRoutineServiceFoldAndRefresh() throws {
        let app = try launch()
        selectSection(app, "skills")
        let skill = app.buttons.containing(.staticText, identifier: "weekly-report").firstMatch
        XCTAssertTrue(skill.waitForExistence(timeout: 10)); skill.tap()
        XCTAssertTrue(app.staticTexts["社長の指定内容に沿って現職の週報を入力します。"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        selectSection(app, "routines")
        XCTAssertTrue(app.staticTexts["朝の確認"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["前回"].exists)
        XCTAssertTrue(app.staticTexts["11月2日 7:30・完了"].exists)
        XCTAssertTrue(app.staticTexts["次回"].exists)
        for label in ["最終実行", "業務結果", "配信", "最終結果"] { XCTAssertFalse(app.staticTexts[label].exists) }
        XCTAssertFalse(app.staticTexts["常駐の確認用"].exists)
        app.buttons["work.routines.services"].tap()
        XCTAssertTrue(app.staticTexts["常駐の確認用"].exists)
        app.buttons["work.catalog.refresh"].tap()
        XCTAssertTrue(app.staticTexts["朝の確認"].waitForExistence(timeout: 10))
    }

    private func capture(_ appearance: String) throws {
        let app = try launch(appearance)
        for section in ["tasks", "sessions", "projects", "routines", "skills"] {
            selectSection(app, section)
            let ready = section == "routines" ? "朝の確認" : section == "skills" ? "weekly-report" : "次の打ち合わせを確認する"
            if section == "sessions" || section == "projects" {
                XCTAssertTrue(app.buttons["work.section.\(section)"].isSelected)
            } else {
                XCTAssertTrue(app.staticTexts[ready].waitForExistence(timeout: 10))
            }
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "work-\(section)-\(appearance)"; shot.lifetime = .keepAlways; add(shot)
            if section == "tasks" {
                let row = taskRow(app, "次の打ち合わせを確認する")
                row.swipeLeft(); app.buttons["削除"].firstMatch.tap()
                XCTAssertTrue(app.sheets.buttons["削除"].waitForExistence(timeout: 5))
                attach("work-delete-confirm-\(appearance)")
                app.sheets.buttons["削除"].tap()
                XCTAssertTrue(row.waitForNonExistence(timeout: 10))
                app.buttons["work.linear.archive"].tap()
                XCTAssertTrue(row.waitForExistence(timeout: 10))
                attach("work-archive-\(appearance)")
                app.buttons["閉じる"].tap()
            } else if section == "skills" {
                app.buttons.containing(.staticText, identifier: "weekly-report").firstMatch.tap()
                XCTAssertTrue(app.staticTexts["社長の指定内容に沿って現職の週報を入力します。"].waitForExistence(timeout: 5))
                attach("work-skill-detail-\(appearance)")
                app.navigationBars.buttons.firstMatch.tap()
            } else if section == "routines" {
                app.buttons["work.routines.services"].tap()
                XCTAssertTrue(app.staticTexts["常駐の確認用"].exists)
                attach("work-routine-services-\(appearance)")
            }
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
    private func taskRow(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }
    private func selectSection(_ app: XCUIApplication, _ section: String) {
        let button = app.buttons["work.section.\(section)"]
        // Selecting a visible middle section lets the hub's ScrollViewReader
        // bring the right-hand sections into view before the next tap.
        if button.frame.maxX > app.frame.maxX - 10 { app.buttons["work.section.projects"].tap() }
        button.tap()
    }
    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
#endif

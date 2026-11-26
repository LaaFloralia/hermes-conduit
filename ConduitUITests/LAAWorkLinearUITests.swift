#if LAA_BUILD
import XCTest

final class LAAWorkLinearUITests: XCTestCase {
    private let port = Int(ProcessInfo.processInfo.environment["LAA_WORK_FIXTURE_PORT"] ?? "") ?? 19584

    private func launch(_ appearance: String = "light") throws -> XCUIApplication {
        guard (try? LabUI.data(LabUI.origin("work-control", legacyPort: port + 1), "/reset")) != nil else {
            throw XCTSkip("Start scripts/laa/work-ui-fixture.mjs")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "work", "-LAA_UI_TEST_ISOLATED_BRIDGE", "-conduit.themePreference", appearance,
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
        XCTAssertTrue(app.buttons["work.section.tasks"].waitForExistence(timeout: 15)); app.buttons["work.section.tasks"].tap()
        // The title is the row's open button, so it is found by its label.
        XCTAssertTrue(taskRow(app, "次の打ち合わせを確認する").waitForExistence(timeout: 15))
        return app
    }

    func testFirstProjectToolbarAllowsSharedInstructions() throws {
        let app = try launch()
        // Projects is Work's first section; its own button starts a project.
        app.buttons["work.section.projects"].tap()
        let add = app.buttons["work.projects.new"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        XCTAssertTrue(app.textViews["work.project.instructions"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["MacのLAAアプリが指示本文を返すまで編集できません。"].exists)
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
        XCTAssertTrue(taskRow(app, "UI確認タスク").waitForExistence(timeout: 10))
        // A row's tap opens its detail; editing is in the row's menu.
        openEditor(app, taskRow(app, "UI確認タスク"))
        let editing = app.textFields["work.linear.title"].firstMatch
        let field = editing.exists ? editing : app.textViews["work.linear.title"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("更新")
        let updatedTitle = try XCTUnwrap(field.value as? String)
        XCTAssertTrue(updatedTitle.contains("更新"))
        XCTAssertNotEqual(updatedTitle, "UI確認タスク")
        app.buttons["work.linear.save"].tap()
        XCTAssertTrue(taskRow(app, updatedTitle).waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["work.linear.complete.b9d2f664-cda3-4c56-8d39-c4d6df597254"].exists)
        XCTAssertTrue(app.staticTexts["前の操作の結果を確認しています。入力は端末に残っています。"].waitForNonExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["保存結果を確認できませんでした。"].waitForNonExistence(timeout: 2))
        let row = taskRow(app, updatedTitle)
        row.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        let confirm = app.sheets.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["アーカイブに移り、あとで戻せます。"].exists)
        if app.sheets.buttons["Cancel"].exists { app.sheets.buttons["Cancel"].tap() }
        else { app.otherElements["PopoverDismissRegion"].tap() }
        XCTAssertTrue(taskRow(app, updatedTitle).exists)
        taskRow(app, updatedTitle).swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(taskRow(app, updatedTitle).waitForNonExistence(timeout: 10))
        // The archive is a choice in the count menu, shown in place.
        app.buttons["work.tasks.quick"].tap()
        app.buttons["work.linear.archive"].tap()
        let archived = taskRow(app, updatedTitle)
        XCTAssertTrue(archived.waitForExistence(timeout: 10))
        archived.swipeLeft()
        app.buttons["Restore"].tap()
        XCTAssertTrue(archived.waitForNonExistence(timeout: 10))
        app.buttons["work.tasks.quick"].tap()
        app.buttons["work.tasks.quick.all"].tap()
        XCTAssertTrue(taskRow(app, updatedTitle).waitForExistence(timeout: 10))

    }

    func testSevenSuccessfulEditsDoNotLeavePendingWarning() throws {
        let app = try launch()
        app.buttons["work.section.tasks"].tap()
        var title = "次の打ち合わせを確認する"
        for _ in 0..<7 {
            let row = taskRow(app, title)
            XCTAssertTrue(row.waitForExistence(timeout: 10)); openEditor(app, row)
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

    func testSkillDetailOpens() throws {
        let app = try launch()
        selectSection(app, "skills")
        let skill = app.buttons.containing(.staticText, identifier: "weekly-report").firstMatch
        XCTAssertTrue(skill.waitForExistence(timeout: 10)); skill.tap()
        XCTAssertTrue(app.staticTexts["社長の指定内容に沿って現職の週報を入力します。"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
    }

    private func capture(_ appearance: String) throws {
        let app = try launch(appearance)
        for section in ["tasks", "sessions", "projects", "skills"] {
            selectSection(app, section)
            switch section {
            case "sessions", "projects":
                XCTAssertTrue(app.buttons["work.section.\(section)"].isSelected)
            case "tasks":
                XCTAssertTrue(taskRow(app, "次の打ち合わせを確認する").waitForExistence(timeout: 10))
            default:
                XCTAssertTrue(app.buttons.containing(.staticText, identifier: "weekly-report").firstMatch.waitForExistence(timeout: 10))
            }
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "work-\(section)-\(appearance)"; shot.lifetime = .keepAlways; add(shot)
            if section == "tasks" {
                let row = taskRow(app, "次の打ち合わせを確認する")
                row.swipeLeft(); app.buttons["Delete"].firstMatch.tap()
                XCTAssertTrue(app.sheets.buttons["Delete"].waitForExistence(timeout: 5))
                attach("work-delete-confirm-\(appearance)")
                app.sheets.buttons["Delete"].tap()
                XCTAssertTrue(row.waitForNonExistence(timeout: 10))
                app.buttons["work.tasks.quick"].tap()
                app.buttons["work.linear.archive"].tap()
                XCTAssertTrue(row.waitForExistence(timeout: 10))
                attach("work-archive-\(appearance)")
                app.buttons["work.tasks.quick"].tap()
                app.buttons["work.tasks.quick.all"].tap()
            } else if section == "skills" {
                app.buttons.containing(.staticText, identifier: "weekly-report").firstMatch.tap()
                XCTAssertTrue(app.staticTexts["社長の指定内容に沿って現職の週報を入力します。"].waitForExistence(timeout: 5))
                attach("work-skill-detail-\(appearance)")
                app.navigationBars.buttons.firstMatch.tap()
                app.navigationBars.buttons.firstMatch.tap()
                XCTAssertFalse(app.buttons["settings.ai-usage"].exists)
                app.buttons["laa.settings.done"].tap()
            }
        }
        // Usage has one entry, in the Work toolbar, since 5babcbac.
        let usage = app.buttons["work.usage"]
        XCTAssertTrue(usage.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "work.usage").count, 1)
        usage.tap()
        XCTAssertTrue(app.buttons["laa.usage.refresh"].waitForExistence(timeout: 10))
        attach("work-usage-\(appearance)")
    }
    func testWorkScreensLight() throws { try capture("light") }
    func testWorkScreensDark() throws { try capture("dark") }
    private func openEditor(_ app: XCUIApplication, _ row: XCUIElement) {
        row.press(forDuration: 1.2)
        let identified = app.buttons["work.linear.edit"].firstMatch
        // Some OS versions drop the identifier when bridging to a native menu.
        let edit = identified.waitForExistence(timeout: 2) ? identified : app.buttons["Edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
    }
    private func taskRow(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }
    private func selectSection(_ app: XCUIApplication, _ section: String) {
        if section == "skills" {
            // Skills moved into Settings (2b5760d5).
            LAASettingsSkillsUI.open(in: app)
        } else {
            LAAWorkSectionUI.open(section, in: app)
        }
    }
    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
#endif

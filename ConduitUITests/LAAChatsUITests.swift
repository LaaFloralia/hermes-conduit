import XCTest

final class LAAChatsUITests: XCTestCase {
    #if LAA_BUILD
    private func launch(_ mode: String = "normal") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-CONDUIT_UI_TEST_CONNECTED_DASHBOARD", "https://chats-ui-test.invalid",
                               "-LAA_UI_TEST_CHATS", "-LAA_CHATS_STATE", mode]
        app.launch()
        XCTAssertTrue(app.textFields["laa.chats.search"].waitForExistence(timeout: 30))
        return app
    }

    private func closeSelection(_ app: XCUIApplication, expected: String) {
        let selected = app.staticTexts["laa.chats.fixture.selection"]
        XCTAssertTrue(selected.waitForExistence(timeout: 10))
        XCTAssertEqual(selected.label, expected)
        app.buttons["laa.chats.fixture.done"].tap()
    }

    func testEmployeeGroupConversationAndNewChatRoutes() {
        let app = launch()
        app.buttons["laa.chats.person.laa-ciel"].tap()
        closeSelection(app, expected: "person:laa-ciel")
        app.buttons["laa.chats.seeAll.employees"].tap()
        app.buttons["laa.chats.person.laa-cto"].tap()
        closeSelection(app, expected: "person:laa-cto")
        app.buttons["laa.chats.group.team"].tap()
        closeSelection(app, expected: "group:team")
        app.buttons["laa.chats.session.week"].tap()
        closeSelection(app, expected: "session:week")
        app.buttons["laa.chats.new"].tap()
        closeSelection(app, expected: "new-chat")
    }

    func testSearchAndNoResults() {
        let app = launch()
        let search = app.textFields["laa.chats.search"]
        search.tap(); search.typeText("Design")
        XCTAssertTrue(app.buttons["laa.chats.session.design"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["laa.chats.session.week"].exists)
        app.buttons["Clear search"].tap()
        search.tap()
        search.typeText("no-result-xyz")
        XCTAssertTrue(app.staticTexts["laa.chats.search.empty"].waitForExistence(timeout: 5))
    }

    func testGroupCreationUsesExistingForm() {
        let app = launch()
        app.buttons["laa.chats.group.new"].tap()
        let name = app.textFields["groups.create.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap(); name.typeText("Planning")
        app.buttons["groups.employee.laa-ciel"].tap()
        app.buttons["groups.employee.laa-cto"].tap()
        let create = app.buttons["groups.create.submit"]
        XCTAssertTrue(create.isEnabled)
        create.tap()
        let created = app.staticTexts["laa.chats.fixture.created"]
        XCTAssertTrue(created.waitForExistence(timeout: 10))
        XCTAssertEqual(created.label, "created:Planning")
    }

    func testEmptyLoadingErrorAndOffline() {
        for (mode, label) in [("empty", "グループはまだありません。"), ("loading", "読み込み中…"),
                              ("error", "Hermesから読み込めませんでした。"),
                              ("offline", "Hermesに接続できません。保存済みの会話は表示できます。"),
                              ("unsupported", "この接続先はグループに対応していません。")] {
            let app = launch(mode)
            XCTAssertTrue(app.staticTexts[label].firstMatch.waitForExistence(timeout: 10), mode)
            XCTAssertFalse(app.buttons["laa.chats.group.new"].isEnabled, mode)
            app.terminate()
        }
    }
    #else
    func testOnlyAvailableInLAABuild() throws { throw XCTSkip("LAA build only") }
    #endif
}

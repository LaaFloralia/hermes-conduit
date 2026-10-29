#if LAA_BUILD
import XCTest

final class LAABrainUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ mode: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "brain"]
        if let mode { app.launchArguments += ["-laa-brain-fixture", mode] }
        app.launch()
        return app
    }

    private func dismissKeyboard(_ app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        let dismiss = app.buttons["laa.brain.fixture.dismissKeyboard"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 10))
        dismiss.tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 10))
    }

    func testBrowseReadRawAndSearch() {
        let app = launch("normal")
        XCTAssertTrue(app.staticTexts["Start"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["Tags"].isEnabled)
        XCTAssertTrue(app.staticTexts["Tags are not available yet."].exists)
        app.staticTexts["Start"].tap()
        XCTAssertTrue(app.buttons["laa.brain.rawToggle"].waitForExistence(timeout: 10))
        app.buttons["laa.brain.rawToggle"].tap()
        XCTAssertTrue(app.staticTexts["laa.brain.raw"].waitForExistence(timeout: 5))
        let back = app.buttons["laa.brain.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        app.buttons["Folders"].tap()
        let folder = app.staticTexts["Company"]
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        folder.tap()
        XCTAssertTrue(app.staticTexts["Other"].waitForExistence(timeout: 5))
        app.staticTexts["Other"].tap()
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        let search = app.textFields["laa.brain.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("sample\n")
        XCTAssertTrue(app.buttons["laa.brain.searchResult"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["laa.brain.searchResult"].firstMatch.tap()
        XCTAssertTrue(app.buttons["laa.brain.rawToggle"].waitForExistence(timeout: 10))
    }

    func testRecentCanShowAndHideAllNotes() {
        let app = launch("many")
        let seeAll = app.buttons["See all"]
        XCTAssertTrue(seeAll.waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["Note 4"].exists)
        seeAll.tap()
        XCTAssertTrue(app.staticTexts["Note 4"].waitForExistence(timeout: 10))
        app.buttons["Show less"].tap()
        XCTAssertFalse(app.staticTexts["Note 4"].exists)
    }

    func testCreateReportsTheConflictSafePath() {
        let app = launch("normal")
        let create = app.buttons["laa.brain.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 30))
        create.tap()
        let name = app.textFields["laa.brain.newName"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap()
        name.typeText("Test")
        let editor = app.textViews["laa.brain.newContent"]
        editor.tap()
        editor.typeText("Hello")
        dismissKeyboard(app)
        app.swipeUp()
        XCTAssertEqual(editor.value as? String, "Hello")
        let save = app.buttons["laa.brain.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertTrue(save.isEnabled)
        save.tap()
        let createdPath = app.staticTexts["laa.brain.createdPath"]
        XCTAssertTrue(createdPath.waitForExistence(timeout: 10))
        XCTAssertEqual(createdPath.label, "Inbox/Test 2.md")
    }

    func testCreateWhileJapaneseTextIsMarked() {
        let app = launch("marked")
        let create = app.buttons["laa.brain.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 30))
        create.tap()
        let name = app.textFields["laa.brain.newName"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap()
        name.typeText("Marked")
        let editor = app.textViews["laa.brain.newContent"]
        editor.tap()
        editor.typeText("Before ")
        app.buttons["laa.brain.fixture.compose"].tap()
        let didMark = app.staticTexts["laa.brain.fixture.didMark"]
        XCTAssertTrue(didMark.waitForExistence(timeout: 10))
        XCTAssertEqual(didMark.label, "marked")
        let save = app.buttons["laa.brain.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertTrue(save.isEnabled)
        save.tap()
        let markedAtSave = app.staticTexts["laa.brain.fixture.markedAtSave"]
        XCTAssertTrue(markedAtSave.waitForExistence(timeout: 10))
        XCTAssertEqual(markedAtSave.label, "marked")
        XCTAssertEqual(app.staticTexts["laa.brain.fixture.submittedContent"].label, "Before かな")
    }

    func testMarkdownWikiLinkAndFrontmatter() {
        let app = launch("normal")
        XCTAssertTrue(app.staticTexts["Start"].waitForExistence(timeout: 30))
        app.staticTexts["Start"].tap()
        let metadata = app.buttons["Frontmatter"]
        XCTAssertTrue(metadata.waitForExistence(timeout: 10))
        metadata.tap()
        XCTAssertTrue(app.staticTexts["---\nstatus: draft\n---"].waitForExistence(timeout: 5))
        let link = app.links["次のメモ"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
        XCTAssertTrue(app.navigationBars["Other.md"].waitForExistence(timeout: 10))
    }

    func testMissingCreateScopeIsExplained() {
        let app = launch("denied")
        let create = app.buttons["laa.brain.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 30))
        create.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'brain:create'")).firstMatch.waitForExistence(timeout: 10))
        app.swipeUp()
        let save = app.buttons["laa.brain.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertFalse(save.isEnabled)
    }

    func testUncertainCreateRemainsPendingWhenRetryLosesPermission() {
        let app = launch("uncertain")
        let create = app.buttons["laa.brain.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 30))
        create.tap()
        let name = app.textFields["laa.brain.newName"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap()
        name.typeText("Test")
        let editor = app.textViews["laa.brain.newContent"]
        editor.tap()
        editor.typeText("Hello")
        dismissKeyboard(app)
        app.swipeUp()
        let save = app.buttons["laa.brain.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertTrue(save.isEnabled)
        save.tap()
        let acknowledge = app.buttons["Check Inbox and start again"]
        XCTAssertTrue(acknowledge.waitForExistence(timeout: 10))
        app.swipeUp()
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.staticTexts["以前の保存結果を確定できません。Inboxを確認してから次の操作を行ってください。"].waitForExistence(timeout: 10))
        XCTAssertTrue(acknowledge.exists)
        acknowledge.tap()
        XCTAssertTrue(name.isEnabled)
    }

    func testEmptyAndOfflineStates() {
        let empty = launch("empty")
        XCTAssertTrue(empty.staticTexts["表示できるメモはありません。"].waitForExistence(timeout: 30))
        empty.terminate()
        let offline = launch("offline")
        XCTAssertTrue(offline.staticTexts["Macに届きません。TailscaleとMacの接続を確認してください。"].waitForExistence(timeout: 30))
        offline.terminate()
        let failed = launch("failed")
        XCTAssertTrue(failed.staticTexts["Macからデータを取得できませんでした。"].waitForExistence(timeout: 30))
    }

    func testUnpairedStateOffersPairing() {
        let app = launch()
        XCTAssertTrue(app.buttons["laa.bridge.openPairing"].waitForExistence(timeout: 30))
    }
}
#endif

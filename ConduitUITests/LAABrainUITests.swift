#if LAA_BUILD
import XCTest

final class LAABrainUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ mode: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "brain", "-LAA_UI_TEST_ISOLATED_BRIDGE"]
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

    private func openLocalCompany(_ app: XCUIApplication) {
        let company = app.staticTexts["Company"]
        XCTAssertTrue(company.waitForExistence(timeout: 30))
        company.tap()
    }

    private func focusLocalEditor(_ editor: XCUIElement) {
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
        // The editor fills the sheet. Tap the text near its top, rather than
        // the blank center of its scrolling viewport.
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.10)).tap()
    }

    private func openLocalRecovery(_ app: XCUIApplication) {
        let options = app.buttons["laa.brain.localOptions"]
        XCTAssertTrue(options.waitForExistence(timeout: 30))
        options.tap()
        let recovery = app.buttons["laa.brain.recovery.open"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 10))
        recovery.tap()
    }

    func testManageRenameTrashAndGalleryLight() { manageRenameTrashAndGallery(style: "Light") }
    func testManageRenameTrashAndGalleryDark() { manageRenameTrashAndGallery(style: "Dark") }

    func testOwnerScopeDenialExplainsTheMacGrant() {
        let app = launch("ownerDenied")
        XCTAssertTrue(app.descendants(matching: .any)["laa.brain.ownerPermission"].firstMatch.waitForExistence(timeout: 15))
    }

    private func manageRenameTrashAndGallery(style: String) {
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "brain", "-LAA_UI_TEST_ISOLATED_BRIDGE", "-laa-brain-local-fixture", "-AppleInterfaceStyle", style]
        app.launch()
        let filters = app.buttons["laa.brain.localDisplay"]
        XCTAssertTrue(filters.waitForExistence(timeout: 30))
        filters.tap()
        app.buttons["laa.brain.filter.gallery"].tap()
        let gallery = app.buttons["laa.brain.gallery.note"].firstMatch
        XCTAssertTrue(gallery.waitForExistence(timeout: 15))
        let galleryShot = XCTAttachment(screenshot: app.screenshot())
        galleryShot.name = "brain-gallery-" + style.lowercased(); galleryShot.lifetime = .keepAlways; add(galleryShot)
        gallery.tap()
        let manage = app.buttons["laa.brain.manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 10)); manage.tap()
        let field = app.textFields["laa.brain.manage.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let manageShot = XCTAttachment(screenshot: app.screenshot())
        manageShot.name = "brain-manage-" + style.lowercased(); manageShot.lifetime = .keepAlways; add(manageShot)
        field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + "Renamed")
        app.buttons["laa.brain.manage.move"].tap()
        XCTAssertTrue(app.navigationBars["Renamed.md"].waitForExistence(timeout: 15))
        XCTAssertTrue(manage.waitForExistence(timeout: 10)); manage.tap()
        app.buttons["laa.brain.manage.trash"].tap()
        // The confirmation is one visible action expressed as two nested buttons
        // with the same label and frame, so either one is the same button.
        let confirm = app.buttons["laa.brain.manage.confirmTrash"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Trash confirmation missing. Tree:\n\(app.debugDescription)"); confirm.tap()
        XCTAssertTrue(filters.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["laa.brain.gallery.note"].firstMatch.waitForNonExistence(timeout: 15))
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
        // On recent iOS, UITextView exposes this attributed link as a text
        // view with an external-link suffix instead of as a Link element.
        let nativeLink = app.links["次のメモ"]
        let textLink = app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@", "次のメモ")).firstMatch
        let link = nativeLink.exists ? nativeLink : textLink
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
        // An unpaired Bridge opens straight on the connection view, which
        // carries the pairing button itself.
        let app = launch()
        XCTAssertTrue(app.buttons["laa.bridge.openPairing"].waitForExistence(timeout: 30))
    }

    func testLocalFixtureCanBeBrowsedWithoutMac() {
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "brain", "-LAA_UI_TEST_ISOLATED_BRIDGE", "-laa-brain-local-fixture"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["laa.brain.localSource"].waitForExistence(timeout: 30))
        openLocalCompany(app)
        XCTAssertTrue(app.staticTexts["Start"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["laa.brain.create"].exists)
        app.staticTexts["Start"].tap()
        XCTAssertTrue(app.buttons["laa.brain.rawToggle"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["laa.brain.edit"].waitForExistence(timeout: 10))
        app.buttons["laa.brain.rawToggle"].tap()
        XCTAssertTrue(app.staticTexts["laa.brain.raw"].label.contains("オフラインの検索本文"))
    }

    func testDailyShortcutCreatesEmptyNoteAndOpensEditor() {
        let app = XCUIApplication()
        app.launchArguments += ["-LAA_UI_TEST_ISOLATED_BRIDGE", "-laa-brain-local-fixture", "-laa-brain-daily-fixture"]
        app.launch()
        let editor = app.textViews["laa.brain.edit.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 30))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed)
        XCTAssertTrue((editor.value as? String ?? "").isEmpty)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Daily editor"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        focusLocalEditor(editor)
        editor.typeText("DAILY-FIXTURE")
        app.buttons["laa.brain.edit.save"].tap()
        XCTAssertTrue(app.buttons["laa.brain.rawToggle"].waitForExistence(timeout: 20))
        app.buttons["laa.brain.rawToggle"].tap()
        XCTAssertEqual(app.staticTexts["laa.brain.raw"].label, "DAILY-FIXTURE")
    }

    func testTableCellsKeepTwoEditsThroughSaveAndReload() {
        let app = XCUIApplication()
        app.launchArguments += ["-LAA_UI_TEST_ISOLATED_BRIDGE", "-laa-brain-local-fixture", "-laa-brain-table-fixture"]
        app.launch()
        openLocalCompany(app)
        let note = app.staticTexts["Table"]
        XCTAssertTrue(note.waitForExistence(timeout: 30))
        note.tap()
        let edit = app.buttons["laa.brain.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 20))
        edit.tap()
        let first = app.descendants(matching: .any)["laa.markdown.table.cell.0.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        first.tap()
        first.typeText("AAA")
        let second = app.descendants(matching: .any)["laa.markdown.table.cell.1.0"]
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        if !second.isHittable { app.swipeUp() }
        second.tap()
        second.typeText("BBB")
        XCTAssertTrue((first.value as? String ?? "").contains("AAA"), "the first cell keeps its edit")
        XCTAssertTrue((second.value as? String ?? "").contains("BBB"), "the second cell takes its own edit")
        app.buttons["laa.brain.edit.save"].tap()
        XCTAssertTrue(app.buttons["laa.brain.rawToggle"].waitForExistence(timeout: 20))
        app.buttons["laa.brain.rawToggle"].tap()
        let raw = app.staticTexts["laa.brain.raw"]
        XCTAssertTrue(raw.waitForExistence(timeout: 10))
        XCTAssertTrue(raw.label.contains("AAA"), "the saved Markdown keeps the first cell")
        XCTAssertTrue(raw.label.contains("BBB"), "the saved Markdown keeps the second cell")
        XCTAssertTrue(raw.label.contains("項目") && raw.label.contains("値"), "the header survives the save")
        XCTAssertTrue(raw.label.contains("1"), "the untouched cell survives the save")
    }

    func testEditorFormatsAListAndKeepsItOnSave() {
        let app = XCUIApplication()
        app.launchArguments += ["-LAA_UI_TEST_ISOLATED_BRIDGE", "-laa-brain-local-fixture", "-laa-brain-daily-fixture"]
        app.launch()
        let editor = app.textViews["laa.brain.edit.text"]
        focusLocalEditor(editor)
        editor.typeText("LIST-FIXTURE")
        let bullet = app.buttons["laa.markdown.format.bullet"]
        XCTAssertTrue(bullet.waitForExistence(timeout: 10))
        bullet.tap()
        let table = app.buttons["laa.markdown.format.table"]
        XCTAssertTrue(table.exists)
        app.buttons["laa.brain.edit.save"].tap()
        XCTAssertTrue(app.buttons["laa.brain.rawToggle"].waitForExistence(timeout: 20))
        app.buttons["laa.brain.rawToggle"].tap()
        let raw = app.staticTexts["laa.brain.raw"]
        XCTAssertTrue(raw.waitForExistence(timeout: 10))
        XCTAssertEqual(raw.label, "- LIST-FIXTURE")
    }

    func testInsertTableUsesTheFocusedRunAfterAnExistingTable() {
        let app = XCUIApplication()
        app.launchArguments += ["-LAA_UI_TEST_ISOLATED_BRIDGE", "-laa-brain-local-fixture", "-laa-brain-table-fixture"]
        app.launch()
        openLocalCompany(app)
        let note = app.staticTexts["Table"]
        XCTAssertTrue(note.waitForExistence(timeout: 30))
        note.tap()
        let edit = app.buttons["laa.brain.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 20))
        edit.tap()
        let runs = app.textViews.matching(identifier: "laa.brain.edit.text")
        XCTAssertTrue(runs.element(boundBy: 0).waitForExistence(timeout: 20))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "laa.markdown.table").count, 1)
        // The paragraph after the existing table is its own run; focusing it
        // must make that run the insertion target.
        let trailing = runs.element(boundBy: runs.count - 1)
        XCTAssertTrue(trailing.waitForExistence(timeout: 10))
        trailing.tap()
        app.buttons["laa.markdown.format.table"].tap()
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "laa.markdown.table").count, 2,
                       "the inserted table joins the note")
        app.buttons["laa.brain.edit.save"].tap()
        XCTAssertTrue(app.buttons["laa.brain.rawToggle"].waitForExistence(timeout: 20))
        app.buttons["laa.brain.rawToggle"].tap()
        let raw = app.staticTexts["laa.brain.raw"]
        XCTAssertTrue(raw.waitForExistence(timeout: 10))
        XCTAssertTrue(raw.label.contains("# 表"), "the run before the table was not overwritten")
        XCTAssertTrue(raw.label.contains("末尾の段落"), "the focused paragraph survives")
        XCTAssertTrue(raw.label.contains("項目"), "the existing table survives")
        XCTAssertTrue(raw.label.contains("あ"), "the existing table's cell survives")
        XCTAssertTrue(raw.label.contains("見出し1"), "the new table was written")
    }

    func testDailyShortcutWithoutVaultOffersFolderSelection() {
        let app = XCUIApplication()
        app.launchArguments += ["-LAA_UI_TEST_ISOLATED_BRIDGE", "-laa-brain-no-vault-fixture", "-laa-brain-daily-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["laa.brain.chooseFolder"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.textViews["laa.brain.edit.text"].exists)
        app.terminate()
        app.launchArguments = ["-LAA_UI_TEST_ISOLATED_BRIDGE", "-laa-brain-local-fixture"]
        app.launch()
        XCTAssertTrue(app.textViews["laa.brain.edit.text"].waitForExistence(timeout: 30))
    }

    func testDailyShortcutOpensExistingTextWithoutReplacingIt() {
        let app = XCUIApplication()
        app.launchArguments += ["-LAA_UI_TEST_ISOLATED_BRIDGE", "-laa-brain-local-fixture", "-laa-brain-daily-fixture", "-laa-brain-daily-existing-fixture"]
        app.launch()
        let editor = app.textViews["laa.brain.edit.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 30))
        let hasExisting = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS 'EXISTING-DAILY-FIXTURE'"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [hasExisting], timeout: 15), .completed)
        XCTAssertTrue(app.buttons["laa.brain.edit.save"].isEnabled)
    }

    func testLocalFixtureSearchTagsAndPin() {
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "brain", "-LAA_UI_TEST_ISOLATED_BRIDGE", "-laa-brain-local-fixture"]
        app.launch()
        let display = app.buttons["laa.brain.localDisplay"]
        XCTAssertTrue(display.waitForExistence(timeout: 30))
        display.tap()
        app.buttons["laa.brain.filter.tags"].tap()
        XCTAssertTrue(app.buttons["#garden"].waitForExistence(timeout: 30))
        app.buttons["#garden"].tap()
        XCTAssertTrue(app.staticTexts["Start"].waitForExistence(timeout: 10))
        app.staticTexts["Start"].tap()
        let pin = app.buttons["laa.brain.pin"]
        XCTAssertTrue(pin.waitForExistence(timeout: 10))
        pin.tap()
        XCTAssertEqual(pin.label, "Unpin note")
        app.buttons["laa.brain.back"].tap()
        display.tap()
        app.buttons["laa.brain.filter.recent"].tap()
        XCTAssertTrue(app.staticTexts["PINNED"].waitForExistence(timeout: 10))
        let search = app.textFields["laa.brain.search"]
        search.tap()
        search.typeText("fixture-search\n")
        XCTAssertTrue(app.buttons["laa.brain.searchResult"].firstMatch.waitForExistence(timeout: 10))
    }

    func testLocalFixtureEmbedsAndQuickSwitch() {
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "brain", "-LAA_UI_TEST_ISOLATED_BRIDGE", "-laa-brain-local-fixture"]
        app.launch()
        openLocalCompany(app)
        XCTAssertTrue(app.staticTexts["Start"].waitForExistence(timeout: 30))
        app.staticTexts["Start"].tap()
        XCTAssertTrue(app.images["laa.brain.embed.image"].waitForExistence(timeout: 15))
        let switcher = app.buttons["laa.brain.quickSwitch"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 10))
        switcher.tap()
        XCTAssertTrue(app.buttons["laa.brain.quickSwitch.note"].firstMatch.waitForExistence(timeout: 10))
    }

    func testConflictCopyOffersOriginalWithoutEditingCopy() {
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "brain", "-LAA_UI_TEST_ISOLATED_BRIDGE", "-laa-brain-local-fixture",
                                "-laa-brain-save-fixture", "-laa-brain-conflict-copy-fixture"]
        app.launch()
        openLocalCompany(app)
        let copy = app.staticTexts["Start.sync-conflict-20261101-ABC"]
        XCTAssertTrue(copy.waitForExistence(timeout: 30))
        copy.tap()
        XCTAssertTrue(app.staticTexts["laa.brain.conflictCopy"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["laa.brain.edit"].exists)
        let original = app.buttons["laa.brain.conflictOriginal"]
        XCTAssertTrue(original.waitForExistence(timeout: 10))
        original.tap()
        XCTAssertTrue(app.buttons["laa.brain.edit"].waitForExistence(timeout: 10))
    }

    func testUnsafeIgnoreOffersDraftExportWithoutReplacingNote() {
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "brain", "-LAA_UI_TEST_ISOLATED_BRIDGE", "-laa-brain-local-fixture",
                                "-laa-brain-save-fixture", "-laa-brain-unsafe-ignore-fixture", "-laa-brain-force-fallback-fixture"]
        app.launch()
        openLocalCompany(app)
        XCTAssertTrue(app.staticTexts["Start"].waitForExistence(timeout: 30))
        app.staticTexts["Start"].tap()
        XCTAssertTrue(app.buttons["laa.brain.edit"].waitForExistence(timeout: 10))
        app.buttons["laa.brain.edit"].tap()
        let editor = app.textViews["laa.brain.edit.text"]
        focusLocalEditor(editor)
        editor.typeText("\nEXPORT-DRAFT")
        app.buttons["laa.brain.edit.save"].tap()
        XCTAssertTrue(app.buttons["laa.brain.edit.exportDraft"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'ノートは変更していません'")).firstMatch.exists)
    }

    func testLocalExchangeRetainsAndRestoresInterveningVersion() {
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "brain", "-LAA_UI_TEST_ISOLATED_BRIDGE", "-laa-brain-local-fixture",
                                "-laa-brain-save-fixture", "-laa-brain-save-race-fixture"]
        app.launch()
        openLocalCompany(app)
        XCTAssertTrue(app.staticTexts["Start"].waitForExistence(timeout: 30))
        app.staticTexts["Start"].tap()
        let edit = app.buttons["laa.brain.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.tap()
        let editor = app.textViews["laa.brain.edit.text"]
        focusLocalEditor(editor)
        editor.typeText("\nMY-FIXTURE-DRAFT")
        app.buttons["laa.brain.edit.save"].tap()
        XCTAssertTrue(app.buttons["laa.brain.conflict.useDraft"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["INTERVENING-FIXTURE"].exists)
        app.buttons["laa.brain.history"].tap()
        let displaced = app.buttons["laa.brain.history.version.displaced"].firstMatch
        XCTAssertTrue(displaced.waitForExistence(timeout: 10))
        displaced.tap()
        XCTAssertTrue(app.staticTexts["INTERVENING-FIXTURE"].waitForExistence(timeout: 5))
        app.buttons["laa.brain.history.use"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, "INTERVENING-FIXTURE")
        // Typing after the restore must extend the restored version, not the
        // draft the editor was first opened with.
        focusLocalEditor(editor)
        editor.typeText("+AFTER-RESTORE")
        app.buttons["laa.brain.edit.save"].tap()
        let raw = app.buttons["laa.brain.rawToggle"]
        XCTAssertTrue(raw.waitForExistence(timeout: 15))
        raw.tap()
        let restored = app.staticTexts["laa.brain.raw"].label
        XCTAssertTrue(restored.contains("INTERVENING-FIXTURE"), "the restored version is what got saved")
        XCTAssertTrue(restored.contains("AFTER-RESTORE"), "typing after the restore is kept")
        XCTAssertFalse(restored.contains("MY-FIXTURE-DRAFT"), "the pre-restore draft is gone")
    }

    func testMissingStageRequiresExplicitReview() {
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "brain", "-LAA_UI_TEST_ISOLATED_BRIDGE", "-laa-brain-local-fixture",
                                "-laa-brain-save-fixture", "-laa-brain-save-missing-stage-fixture"]
        app.launch()
        openLocalCompany(app)
        XCTAssertTrue(app.staticTexts["Start"].waitForExistence(timeout: 30))
        app.staticTexts["Start"].tap()
        XCTAssertTrue(app.buttons["laa.brain.edit"].waitForExistence(timeout: 10))
        app.buttons["laa.brain.edit"].tap()
        let editor = app.textViews["laa.brain.edit.text"]
        focusLocalEditor(editor)
        editor.typeText("\nSAVED-DRAFT")
        app.buttons["laa.brain.edit.save"].tap()
        let preserve = app.buttons["laa.brain.recovery.preserve"]
        XCTAssertTrue(preserve.waitForExistence(timeout: 15))
        preserve.tap()
        XCTAssertTrue(app.staticTexts["laa.brain.recovery.missingStage"].waitForExistence(timeout: 10))
        app.buttons["laa.brain.recovery.viewHistory"].tap()
        let draft = app.buttons["laa.brain.history.version.draft"].firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'SAVED-DRAFT'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["laa.brain.history.use"].isEnabled)
        let backToHistory = app.navigationBars["Draft"].buttons["History"]
        XCTAssertTrue(backToHistory.waitForExistence(timeout: 10))
        backToHistory.tap()
        app.buttons["laa.brain.history.close"].tap()
        app.buttons["laa.brain.recovery.clearMissing"].tap()
        app.alerts.firstMatch.buttons["laa.brain.recovery.confirmClearMissing"].firstMatch.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        app.buttons["laa.brain.history"].tap()
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.tap()
        XCTAssertTrue(app.buttons["laa.brain.history.use"].waitForExistence(timeout: 10))
        app.buttons["laa.brain.history.use"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue((editor.value as? String ?? "").contains("SAVED-DRAFT"))
    }

    func testDeletedNoteHistoryPreservesAndRestoresInterruptedVersion() {
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "brain", "-LAA_UI_TEST_ISOLATED_BRIDGE", "-laa-brain-local-fixture",
                                "-laa-brain-save-fixture", "-laa-brain-history-fixture"]
        app.launch()
        openLocalRecovery(app)
        let deleted = app.staticTexts["Company/Deleted.md"]
        XCTAssertTrue(deleted.waitForExistence(timeout: 15))
        deleted.tap()
        let preserve = app.buttons["laa.brain.recovery.preserve"]
        XCTAssertTrue(preserve.waitForExistence(timeout: 10))
        preserve.tap()
        let interrupted = app.buttons["laa.brain.recovery.version.interrupted"].firstMatch
        XCTAssertTrue(interrupted.waitForExistence(timeout: 10))
        interrupted.tap()
        XCTAssertTrue(app.staticTexts["INTERRUPTED-FIXTURE"].waitForExistence(timeout: 10))
        app.buttons["laa.brain.recovery.restore"].tap()
        let result = app.staticTexts["laa.brain.recovery.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        XCTAssertTrue(result.label.contains("フォルダ直下にコピーを復元しました"))
    }

    func testRenamedNoteHistoryRestoresNonUTF8VersionAsCopy() {
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "brain", "-LAA_UI_TEST_ISOLATED_BRIDGE", "-laa-brain-local-fixture",
                                "-laa-brain-save-fixture", "-laa-brain-history-fixture"]
        app.launch()
        openLocalRecovery(app)
        let renamed = app.staticTexts["Company/Renamed.md"]
        XCTAssertTrue(renamed.waitForExistence(timeout: 15))
        renamed.tap()
        let displaced = app.buttons["laa.brain.recovery.version.displaced"].firstMatch
        XCTAssertTrue(displaced.waitForExistence(timeout: 10))
        displaced.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'UTF-8'")).firstMatch.waitForExistence(timeout: 10))
        app.buttons["laa.brain.recovery.restore"].tap()
        let result = app.staticTexts["laa.brain.recovery.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        XCTAssertTrue(result.label.contains("フォルダ直下にコピーを復元しました"))
    }

    func testRecoveryOffersFilesWhenExclusiveRenameIsUnavailable() {
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "brain", "-LAA_UI_TEST_ISOLATED_BRIDGE", "-laa-brain-local-fixture",
                                "-laa-brain-save-fixture", "-laa-brain-history-fixture", "-laa-brain-history-force-export-fixture"]
        app.launch()
        openLocalRecovery(app)
        let renamed = app.staticTexts["Company/Renamed.md"]
        XCTAssertTrue(renamed.waitForExistence(timeout: 15))
        renamed.tap()
        let displaced = app.buttons["laa.brain.recovery.version.displaced"].firstMatch
        XCTAssertTrue(displaced.waitForExistence(timeout: 10))
        displaced.tap()
        let restore = app.buttons["laa.brain.recovery.restore"]
        XCTAssertTrue(restore.waitForExistence(timeout: 10))
        restore.tap()
        let result = app.staticTexts["laa.brain.recovery.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        XCTAssertTrue(result.label.contains("ファイルに書き出す"))
        XCTAssertTrue(app.buttons["laa.brain.recovery.export"].exists)
    }
    func testLocalCreateFolderNoteAndEdit() {
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "brain", "-LAA_UI_TEST_ISOLATED_BRIDGE", "-laa-brain-local-fixture", "-laa-brain-save-fixture"]
        app.launch()
        openLocalCompany(app)
        XCTAssertTrue(app.staticTexts["Empty"].waitForExistence(timeout: 10))
        app.staticTexts["Empty"].tap()
        XCTAssertTrue(app.staticTexts["laa.brain.emptyFolder"].waitForExistence(timeout: 10))
        app.buttons["laa.brain.localCreate"].tap()
        app.buttons["laa.brain.localCreate.folder"].tap()
        let name = app.textFields["laa.brain.localCreate.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap(); name.typeText("Projects")
        app.buttons["laa.brain.localCreate.confirm"].tap()
        XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 15))
        app.buttons["laa.brain.localCreate"].tap()
        app.buttons["laa.brain.localCreate.note"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap(); name.typeText("Draft")
        let initialBody = app.textViews["laa.brain.localCreate.body"]
        initialBody.tap(); initialBody.typeText("First line")
        app.buttons["laa.brain.localCreate.confirm"].tap()
        XCTAssertTrue(app.navigationBars["Draft.md"].waitForExistence(timeout: 15))
        app.buttons["laa.brain.edit"].tap()
        let editor = app.textViews["laa.brain.edit.text"]
        focusLocalEditor(editor)
        editor.typeText("\nNew markdown note")
        let edited = editor.value as? String ?? ""
        XCTAssertTrue(edited.contains("First line"), edited)
        XCTAssertTrue(edited.contains("New markdown note"), edited)
        app.buttons["laa.brain.edit.save"].tap()
        XCTAssertTrue(app.buttons["laa.brain.rawToggle"].waitForExistence(timeout: 15))
        app.buttons["laa.brain.rawToggle"].tap()
        let rendered = app.staticTexts["laa.brain.raw"].label
        XCTAssertTrue(rendered.contains("First line"))
        XCTAssertTrue(rendered.contains("New markdown note"))
    }

}
#endif

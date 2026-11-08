#if LAA_BUILD && targetEnvironment(macCatalyst)
import XCTest

/// The Mac window's Brain, Studio and Drive columns: choosing a row must fill
/// the detail column and leave the list in place. The parent runs these with
/// the consolidated suite; the phone tests keep covering the compact layout.
final class LAAMacLibraryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ arguments: [String] = [], environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-LAA_UI_TEST_ISOLATED_BRIDGE"] + arguments
        app.launchEnvironment.merge(environment) { _, new in new }
        app.launch()
        return app
    }

    private func openSection(_ app: XCUIApplication, _ name: String) {
        let button = app.buttons["laa.mac.section.\(name)"]
        XCTAssertTrue(button.waitForExistence(timeout: 30), "The Mac sidebar did not show \(name)")
        button.tap()
    }

    func testBrainAndHQAreVisibleAsSeparateLocalLocations() {
        let app = launch(["-laa-brain-no-vault-fixture"])
        openSection(app, "brain")
        XCTAssertTrue(app.buttons["laa.brain.location.Brain"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["laa.brain.location.HQ"].exists)
        XCTAssertFalse(app.staticTexts["On this iPhone"].exists)
    }

    func testSwitchingLocationsClearsPreviousDetailAndShowsNewNotes() {
        let app = launch(["-laa-brain-mac-roots-fixture"])
        openSection(app, "brain")
        let brain = app.buttons["laa.brain.note"].firstMatch
        XCTAssertTrue(brain.waitForExistence(timeout: 30))
        brain.tap()
        XCTAssertTrue(app.buttons["laa.brain.rawToggle"].waitForExistence(timeout: 15))
        app.buttons["laa.brain.location.HQ"].tap()
        XCTAssertTrue(app.staticTexts["HQOnly"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["laa.brain.rawToggle"].exists)
        XCTAssertFalse(app.staticTexts["BrainOnly"].exists)
        app.buttons["laa.brain.location.Brain"].tap()
        XCTAssertTrue(app.staticTexts["BrainOnly"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["HQOnly"].exists)
    }

    func testLocationSwitchIsUnavailableWhileEditing() {
        let app = launch(["-laa-brain-mac-roots-fixture"])
        openSection(app, "brain")
        let note = app.buttons["laa.brain.note"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 30))
        note.tap()
        let edit = app.buttons["laa.brain.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 15))
        edit.tap()
        XCTAssertTrue(app.buttons["laa.brain.edit.save"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["laa.brain.location.HQ"].isEnabled)
    }

    func testBrainNoteOpensInTheDetailColumn() {
        let app = launch(["-laa-brain-fixture", "normal"])
        openSection(app, "brain")
        let note = app.buttons.matching(identifier: "laa.brain.note").firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 30))
        note.tap()
        // The note's toolbar only exists in the detail column, and the list
        // must still be there beside it.
        XCTAssertTrue(app.buttons["laa.brain.rawToggle"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["laa.brain.back"].exists, "A Mac detail column has no list to go back to")
        XCTAssertTrue(note.exists, "Choosing a note replaced the list instead of filling the detail column")
    }

    func testStudioWorkOpensInTheDetailColumn() throws {
        guard let health = try? Data(contentsOf: URL(string: "http://127.0.0.1:19583/health")!),
              String(data: health, encoding: .utf8) == "ok" else {
            throw XCTSkip("Start scripts/laa/studio-ui-fixture.mjs first")
        }
        _ = try? Data(contentsOf: URL(string: "http://127.0.0.1:19583/reset")!)
        let app = launch(environment: ["LAA_BRIDGE_DEFAULT_ADDRESS": "http://127.0.0.1:19582"])
        openSection(app, "studio")
        let connect = app.buttons["laa.studio.pair"]
        if connect.waitForExistence(timeout: 20) {
            connect.tap()
            let code = app.secureTextFields["laa.bridge.code"]
            XCTAssertTrue(code.waitForExistence(timeout: 10))
            code.tap()
            code.typeText("TEST-TEST")
            let pair = app.buttons["laa.bridge.pair"]
            if !pair.isHittable { app.swipeUp() }
            pair.tap()
        }
        let work = app.buttons["laa.studio.work.70175325-5cf4-421f-8a6f-95beae8fca92"]
        XCTAssertTrue(work.waitForExistence(timeout: 40))
        work.tap()
        XCTAssertTrue(app.staticTexts["Cover"].waitForExistence(timeout: 20))
        XCTAssertTrue(work.exists, "Choosing a work replaced the list instead of filling the detail column")
    }

    func testDriveFileOpensItsPreviewBesideTheList() {
        let app = launch(["-laa-assets-fixture", "normal"])
        openSection(app, "drive")
        let file = app.descendants(matching: .any)["laa.drive.browser.item.doc1"].buttons.firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 30))
        file.tap()
        XCTAssertTrue(app.buttons["laa.drive.open"].waitForExistence(timeout: 20))
        XCTAssertTrue(file.exists, "Choosing a file replaced the list instead of filling the detail column")
    }
}
#endif

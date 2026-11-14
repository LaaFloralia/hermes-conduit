#if LAA_BUILD
import XCTest
final class LAAHabitsUITests: XCTestCase {
    func testCreateCheckEditArchiveRestore() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchEnvironment["CONDUIT_UITEST"] = "1"
        app.launchArguments = ["-laa-tab", "today", "-LAA_UI_TEST_HABITS", "-LAA_UI_TEST_ISOLATED_BRIDGE"]
        app.launch(); defer { app.terminate() }
        let mode = app.buttons["laa.calendar.mode.habits"]
        XCTAssertTrue(mode.waitForExistence(timeout: 30)); mode.tap()
        let create = app.buttons["laa.habits.create"]; XCTAssertTrue(create.waitForExistence(timeout: 10)); create.tap()
        let title = app.textFields["laa.habits.title"]; XCTAssertTrue(title.waitForExistence(timeout: 10)); title.tap(); title.typeText("UI Habit")
        app.buttons["laa.habits.save"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "laa.habits.edit.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        let check = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "laa.habits.check.")).firstMatch
        XCTAssertTrue(check.waitForExistence(timeout: 5)); check.tap()
        row.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 10)); title.tap()
        title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "UI Edited")
        app.buttons["laa.habits.save"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        let archive = app.buttons["laa.habits.archive"]
        if !archive.isHittable { app.swipeUp() }
        XCTAssertTrue(archive.waitForExistence(timeout: 5)); archive.tap()
        app.buttons["laa.habits.archive.confirm"].firstMatch.tap()
        let history = app.buttons["laa.habits.history"]; XCTAssertTrue(history.waitForExistence(timeout: 10)); history.tap()
        let restore = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "laa.habits.restore.")).firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 10)); restore.tap()
        XCTAssertTrue(restore.waitForNonExistence(timeout: 10))
    }
}
#endif

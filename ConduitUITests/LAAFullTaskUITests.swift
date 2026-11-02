#if LAA_BUILD
import XCTest

final class LAAFullTaskUITests: XCTestCase {
    private func launch(_ appearance: String) throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["LAA_TASK_UI_ADDRESS"], let code = env["LAA_TASK_UI_" + appearance.uppercased() + "_CODE"]
            else { throw XCTSkip("Dedicated local task fixture required") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "work", "-LAA_UI_TEST_ISOLATED_BRIDGE", "-conduit.themePreference", appearance,
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchEnvironment["LAA_BRIDGE_DEFAULT_ADDRESS"] = address
        app.launch()
        XCTAssertTrue(app.buttons["work.connect"].waitForExistence(timeout: 30)); app.buttons["work.connect"].tap()
        let field = app.secureTextFields["laa.bridge.code"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText(code)
        let pair = app.buttons["laa.bridge.pair"]
        if !pair.isHittable { app.swipeUp() }; pair.tap()
        XCTAssertTrue(app.buttons["work.section.tasks"].waitForExistence(timeout: 15)); app.buttons["work.section.tasks"].tap()
        let browse = app.buttons["work.linear.browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["work.linear.inbox"].exists)
        capture("linear-owner-" + appearance)
        browse.tap()
        XCTAssertTrue(app.staticTexts["Fixture task"].firstMatch.waitForExistence(timeout: 20))
        return app
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testLightTaskAndInbox() throws { try verify("light") }
    func testDarkTaskAndInbox() throws { try verify("dark") }
    private func verify(_ appearance: String) throws {
        let app = try launch(appearance)
        capture("linear-browse-" + appearance)
        app.staticTexts["Fixture task"].firstMatch.tap()
        // The description is markdown: it is not always exposed as a static text,
        // so match the exact label on any element (the screenshot shows it).
        let description = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR value == %@", "Fixture original", "Fixture original")).firstMatch
        XCTAssertTrue(description.waitForExistence(timeout: 20))
        capture("linear-detail-" + appearance)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // Back once more to WorkHub: its inbox opens the same personal inbox
        // view, with the same read mark, one level above the browse screen.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let inbox = app.buttons["work.linear.inbox"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 10)); inbox.tap()
        XCTAssertTrue(app.staticTexts["Fixture notification"].waitForExistence(timeout: 20))
        capture("linear-inbox-" + appearance)
        // SwiftUI exposes this card's identifier on its children. Match the
        // notification and action label together, as shown by the AX snapshot.
        let notificationID = "work.inbox.item.fixture-notification-1"
        let mark = app.buttons.matching(NSPredicate(
            format: "identifier == %@ AND label IN %@",
            notificationID, ["既読にする", "未読に戻す"]
        )).firstMatch
        XCTAssertTrue(mark.waitForExistence(timeout: 10))
        if mark.label == "既読にする" {
            XCTAssertTrue(mark.isEnabled)
            mark.tap()
        }
        let readStatus = app.staticTexts.matching(NSPredicate(
            format: "identifier == %@ AND label == %@", notificationID, "既読"
        )).firstMatch
        XCTAssertTrue(readStatus.waitForExistence(timeout: 15))
        capture("linear-inbox-read-" + appearance)
    }
}
#endif

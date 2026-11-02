#if LAA_BUILD
import XCTest

final class LAAPaseoUITests: XCTestCase {
    func testSessionListAndQuestionLight() throws { try verify("light") }
    func testSessionListAndQuestionDark() throws { try verify("dark") }

    private func verify(_ appearance: String) throws {
        guard (try? Data(contentsOf: URL(string: "http://127.0.0.1:19596/reset")!)) != nil else {
            throw XCTSkip("Start scripts/laa/paseo-ui-fixture.mjs")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "work", "-LAA_UI_TEST_ISOLATED_BRIDGE", "-conduit.themePreference", appearance,
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchEnvironment["LAA_BRIDGE_DEFAULT_ADDRESS"] = "http://127.0.0.1:19596"
        app.launch()
        XCTAssertTrue(app.buttons["work.connect"].waitForExistence(timeout: 30))
        app.buttons["work.connect"].tap()
        let code = app.secureTextFields["laa.bridge.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10)); code.tap(); code.typeText("TEST-TEST")
        let pair = app.buttons["laa.bridge.pair"]
        if !pair.isHittable { app.swipeUp() }
        pair.tap()
        let sessions = app.buttons["work.section.sessions"]
        XCTAssertTrue(sessions.waitForExistence(timeout: 15)); sessions.tap()
        let child = app.staticTexts["work.session.ses_2222222222222222"].firstMatch
        XCTAssertTrue(child.waitForExistence(timeout: 15))
        capture(app, "list", appearance)
        child.tap()
        let question = app.staticTexts["どちらの構成で進めますか？"]
        XCTAssertTrue(question.waitForExistence(timeout: 15))
        capture(app, "question", appearance)
        app.buttons["A案"].tap()
        let reply = app.buttons["回答を送信"]
        XCTAssertTrue(reply.isEnabled); reply.tap()
        XCTAssertTrue(app.staticTexts["確認と回答"].waitForNonExistence(timeout: 15))
    }
    private func capture(_ app: XCUIApplication, _ name: String, _ appearance: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "paseo-\(name)-\(appearance)"; shot.lifetime = .keepAlways
        add(shot)
    }
}
#endif

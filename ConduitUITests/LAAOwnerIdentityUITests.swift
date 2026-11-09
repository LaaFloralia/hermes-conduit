#if LAA_BUILD
import XCTest

/// The owner's messages carry "LAA" and the Administration label in every
/// conversation, and no AI speaker does.
final class LAAOwnerIdentityUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func headers(_ app: XCUIApplication, _ id: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: id)
    }

    /// Every owner header reads "LAA、Administration"; every AI header has the
    /// AI's name and no role. A group names each member its own way, so
    /// `agent` is nil there and only the role is checked.
    private func assertSpeakers(_ app: XCUIApplication, agent: String?, file: StaticString = #filePath, line: UInt = #line) {
        let owner = headers(app, "chat.sender.owner")
        XCTAssertTrue(owner.firstMatch.waitForExistence(timeout: 20), "owner header", file: file, line: line)
        for element in owner.allElementsBoundByIndex where element.exists {
            XCTAssertEqual(element.label, "LAA、Administration", file: file, line: line)
        }
        let agents = headers(app, "chat.sender.agent")
        if agent != nil {
            XCTAssertTrue(agents.firstMatch.waitForExistence(timeout: 20), "agent header", file: file, line: line)
        }
        for element in agents.allElementsBoundByIndex where element.exists {
            XCTAssertEqual(element.label, agent, file: file, line: line)
            XCTAssertFalse(element.label.contains("Administration"), file: file, line: line)
        }
        // Whatever carries the role is an owner header or lies inside one.
        let ownerFrames = owner.allElementsBoundByIndex.filter(\.exists).map(\.frame)
        let roles = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Administration"))
        for element in roles.allElementsBoundByIndex where element.exists && element.identifier != "chat.sender.owner" {
            XCTAssertTrue(ownerFrames.contains { $0.insetBy(dx: -1, dy: -1).contains(element.frame) },
                          "role outside the owner header: \(element.debugDescription)", file: file, line: line)
        }
    }

    func testChatAndGroupNameTheOwnerOnly() {
        for surface in ["chat", "group"] {
            let app = XCUIApplication()
            app.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_V2_CHAT_FIXTURE", "rich",
                                   "-LAA_CAPTURE_SURFACE", surface, "-LAA_CAPTURE_KIND", "paper"]
            app.launch()
            XCTAssertTrue(app.staticTexts["fixture.capture.ready"].waitForExistence(timeout: 25))
            let transcript = app.scrollViews[surface == "chat" ? "chat.transcript" : "room.transcript"]
            XCTAssertTrue(transcript.waitForExistence(timeout: 20))
            transcript.swipeDown(velocity: .fast)
            assertSpeakers(app, agent: surface == "chat" ? "Monet" : nil)
            app.terminate()
        }
    }

    @discardableResult
    private func fixture(_ path: String) -> [String: Any]? {
        let done = expectation(description: "fixture \(path)")
        var payload: [String: Any]?
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:19585\(path)")!) { data, _, _ in
            if let data { payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return payload
    }

    private func launchWork(avatar: Bool) throws -> XCUIApplication {
        guard fixture("/reset") != nil else { throw XCTSkip("Start scripts/laa/work-ui-fixture.mjs") }
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "work", "-LAA_UI_TEST_ISOLATED_BRIDGE", "-LAA_UI_TEST_CLEAR_WORK_STORE",
                               "-conduit.themePreference", "light", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
            + (avatar ? ["-LAA_UI_TEST_OWNER_AVATAR"] : [])
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
        XCTAssertTrue(app.buttons["work.section.sessions"].waitForExistence(timeout: 30))
        return app
    }

    func testWorkConversationNamesBothSpeakers() throws {
        let app = try launchWork(avatar: false)
        app.buttons["work.section.sessions"].tap()
        let row = app.staticTexts["work.session.ses_3333333333333333"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        var swipes = 0
        while !row.isHittable && swipes < 4 { app.scrollViews.firstMatch.swipeUp(); swipes += 1 }
        row.tap()
        // The session runs on the fixture's "Claude Opus 5.5" profile.
        assertSpeakers(app, agent: "Opus 5.5")
        // The old labels are gone.
        XCTAssertFalse(app.staticTexts["あなた"].exists)
        XCTAssertFalse(app.staticTexts["回答"].exists)
    }

    func testSettingsOffersChooseAndRemove() throws {
        for avatar in [false, true] {
            let app = try launchWork(avatar: avatar)
            let settings = app.navigationBars.buttons.matching(identifier: "laa.settings.open").firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 15))
            settings.tap()
            let choose = app.buttons["laa.settings.ownerIcon.choose"]
            XCTAssertTrue(choose.waitForExistence(timeout: 15))
            XCTAssertTrue(choose.isEnabled, "a paired device can choose a photo")
            XCTAssertEqual(app.buttons["laa.settings.ownerIcon.remove"].exists, avatar,
                           "Remove only appears when a picture is set")
            XCTAssertTrue(headers(app, "chat.sender.owner").firstMatch.exists, "the card previews the signature")
            app.terminate()
        }
    }
}
#endif

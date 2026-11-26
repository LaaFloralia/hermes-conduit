#if LAA_BUILD
import XCTest

/// Pictures for comparing who-said-what before and after the owner's
/// identity: the Work conversation (long turns, short turns, tool calls in
/// between), the employee and group chats on paper and on a photo, and the
/// Settings home. It only navigates and captures, so the same file runs on the
/// version before the change. `-LAA_UI_TEST_OWNER_AVATAR` seeds a picture for
/// the "set" state; a build without the feature ignores it.
final class LAAOwnerShotsUITests: XCTestCase {
    private let longID = "ses_3333333333333333"

    override func setUpWithError() throws { continueAfterFailure = false }

    func testWorkConversationShots() throws {
        for (theme, avatar) in [("light", false), ("dark", false), ("light", true), ("dark", true)] {
            let app = try launchWork(theme, avatar: avatar)
            openLong(app)
            let suffix = "\(theme)\(avatar ? "-avatar" : "")"
            capture(app, "work-bottom-\(suffix)")
            // The two tool calls sit just above this turn in the fixture: the
            // shot shows the owner and the AI on either side of them.
            let marker = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "短い返答 30")).firstMatch
            var swipes = 0
            while !(marker.exists && marker.frame.minY > 120 && marker.frame.maxY < app.frame.height - 200) && swipes < 40 {
                app.swipeDown(velocity: marker.exists && marker.frame.minY > app.frame.height ? .slow : .default)
                swipes += 1
            }
            Thread.sleep(forTimeInterval: 1)
            capture(app, "work-middle-\(suffix)")
            app.terminate()
        }
    }

    func testSettingsShots() throws {
        for (theme, avatar) in [("light", false), ("dark", false), ("light", true), ("dark", true)] {
            let app = try launchWork(theme, avatar: avatar)
            app.openLAASettings()
            XCTAssertTrue(app.buttons["settings.chat"].waitForExistence(timeout: 10))
            Thread.sleep(forTimeInterval: 2)
            capture(app, "settings-\(theme)\(avatar ? "-avatar" : "")")
            app.terminate()
        }
    }

    func testChatShots() {
        for (surface, dark, kind, avatar) in [
            ("chat", false, "paper", true), ("chat", true, "paper", true), ("chat", false, "photo", true), ("chat", true, "photo", true),
            ("group", false, "paper", true), ("group", true, "paper", true), ("group", false, "photo", true), ("group", true, "photo", true),
            ("chat", false, "paper", false), ("group", true, "paper", false),
        ] {
            let app = XCUIApplication()
            let isGroup = surface == "group"
            app.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_V2_CHAT_FIXTURE", isGroup ? "simple" : "rich",
                                   "-LAA_CAPTURE_SURFACE", surface, "-LAA_CAPTURE_KIND", kind]
                + (dark ? ["-LAA_V2_DARK"] : []) + (avatar ? ["-LAA_UI_TEST_OWNER_AVATAR"] : [])
            app.launchInLab()
            XCTAssertTrue(app.staticTexts["fixture.capture.ready"].waitForExistence(timeout: 25))
            let transcript = app.scrollViews[isGroup ? "room.transcript" : "chat.transcript"]
            XCTAssertTrue(transcript.waitForExistence(timeout: 10))
            if isGroup {
                // Keep the owner and the members in the same frame without
                // flinging a long reply through the lazy room transcript.
                XCTAssertTrue(app.textViews["room.composer.field"].waitForExistence(timeout: 20))
                XCTAssertTrue(transcript.staticTexts["chat.sender.owner"].waitForExistence(timeout: 10))
            } else {
                // The rich reply's Copy button names the code it copies.
                XCTAssertTrue(transcript.descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS %@", "next_step")).firstMatch
                    .waitForExistence(timeout: 15))
                transcript.swipeDown(velocity: .fast)
                Thread.sleep(forTimeInterval: 1)
            }
            capture(app, "\(surface)-\(dark ? "dark" : "light")-\(kind)\(avatar ? "-avatar" : "")")
            app.terminate()
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func fixture(_ path: String) -> [String: Any]? {
        let done = expectation(description: "fixture \(path)")
        var payload: [String: Any]?
        guard let request = try? LabUI.request(LabUI.origin("work-control", legacyPort: 19585), "\(path)") else { return nil }
        LabUI.session.dataTask(with: request) { data, response, _ in
            if LabUI.matches(response), let data { payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return payload
    }

    private func launchWork(_ theme: String, avatar: Bool) throws -> XCUIApplication {
        guard fixture("/reset") != nil else { throw XCTSkip("Start scripts/laa/work-ui-fixture.mjs") }
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "work", "-LAA_UI_TEST_ISOLATED_BRIDGE",
                               "-LAA_UI_TEST_CLEAR_WORK_STORE",
                               "-conduit.themePreference", theme,
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
            + (avatar ? ["-LAA_UI_TEST_OWNER_AVATAR"] : [])
        app.launchEnvironment["LAA_BRIDGE_DEFAULT_ADDRESS"] = LabUI.origin("work", legacyPort: 19584)
        app.launchInLab()
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

    private func openLong(_ app: XCUIApplication) {
        app.buttons["work.section.sessions"].tap()
        let row = app.staticTexts["work.session.\(longID)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        var swipes = 0
        while !row.isHittable && swipes < 4 { app.scrollViews.firstMatch.swipeUp(); swipes += 1 }
        row.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 20))
        // The fixture holds its pictures for 8s; let the end of the page settle.
        Thread.sleep(forTimeInterval: 9)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
#endif

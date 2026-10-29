#if LAA_BUILD
import XCTest

final class LAAChatDesignUITests: XCTestCase {
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_V2_CHAT_FIXTURE", "rich"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["conversation.menu"].waitForExistence(timeout: 25))
        return app
    }

    func testRichMessageCopyAndEditor() {
        let app = launch()
        XCTAssertTrue(app.buttons["laa.employee.header"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["laa.employee.call"].exists)
        XCTAssertTrue(app.staticTexts["chat.date.separator"].waitForExistence(timeout: 10))
        let copy = app.buttons["chat.code.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        for (english, japanese) in [
            ("React to this response", "この応答にリアクション"),
            ("Copy response", "応答をコピー"),
            ("Read response aloud", "応答を読み上げ")
        ] {
            XCTAssertTrue(app.buttons[english].exists || app.buttons[japanese].exists,
                          "Missing reply action: \(english)")
        }
        XCTAssertTrue(app.buttons["chat.replyMoreMenu"].exists)
        XCTAssertTrue(app.buttons["Attach"].exists)
        XCTAssertTrue(app.buttons["composer.expand-editor"].exists)
        XCTAssertTrue(app.buttons["composer.action"].exists)
        copy.tap()
        XCTAssertTrue(app.buttons["chat.code.copy"].label.contains("Copied"))

        let field = app.textViews["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("draft with two lines\nsecond line")
        XCTAssertTrue(app.buttons["composer.action"].isEnabled)
        app.buttons["composer.expand-editor"].tap()
        let full = app.textViews["composer.fullEditor.field"]
        XCTAssertTrue(full.waitForExistence(timeout: 10))
        XCTAssertTrue((full.value as? String ?? "").contains("second line"))
        app.buttons["composer.collapse-editor"].tap()
        XCTAssertTrue((field.value as? String ?? "").contains("second line"))
    }

    func testGroupUsesSameRichCardsAndSendsThroughFake() {
        let app = launch()
        app.buttons["fixture.group"].tap()
        let field = app.textViews["room.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        let call = app.buttons["room.call.unavailable"]
        XCTAssertTrue(call.waitForExistence(timeout: 10))
        XCTAssertFalse(call.isEnabled)
        let copy = app.buttons["chat.code.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        let transcript = app.scrollViews["room.transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        transcript.swipeUp()
        XCTAssertTrue(copy.isHittable)
        XCTAssertLessThanOrEqual(copy.frame.maxY, field.frame.minY,
                                 "The composer must not cover the visible transcript")
        field.tap()
        field.typeText("Team update")
        let send = app.buttons["room.composer.send"]
        XCTAssertTrue(send.isEnabled)
        send.tap()
        let message = app.descendants(matching: .any).containing(NSPredicate(format: "label CONTAINS %@", "Team update")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10))
    }

    func testGroupExplainsUnavailableCall() {
        let app = launch()
        app.buttons["fixture.group"].tap()
        XCTAssertTrue(app.textViews["room.composer.field"].waitForExistence(timeout: 20))
        app.buttons["conversation.menu"].tap()
        let reason = app.buttons["room.call.reason"]
        XCTAssertTrue(reason.waitForExistence(timeout: 5))
        XCTAssertFalse(reason.isEnabled)
    }

    func testReferenceScreenshots() {
        addTeardownBlock {
            let restore = XCUIApplication()
            restore.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_V2_RESTORE_APPEARANCE"]
            restore.launch()
            XCTAssertTrue(restore.staticTexts["fixture.capture.ready"].waitForExistence(timeout: 20))
            restore.terminate()
        }
        for (fixture, surface, dark, kind) in [
            ("rich", "chat", false, "paper"), ("rich", "chat", true, "paper"),
            ("media", "chat", false, "paper"), ("media", "chat", true, "paper"),
            ("rich", "group", false, "paper"), ("rich", "group", true, "paper"),
            ("rich", "chat", true, "photo"), ("rich", "group", false, "photo")
        ] {
            let app = XCUIApplication()
            app.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_V2_CHAT_FIXTURE", fixture,
                                   "-LAA_CAPTURE_SURFACE", surface, "-LAA_CAPTURE_KIND", kind]
                + (dark ? ["-LAA_V2_DARK"] : [])
            app.launch()
            XCTAssertTrue(app.buttons["conversation.menu"].waitForExistence(timeout: 25))
            XCTAssertTrue(app.staticTexts["fixture.capture.ready"].waitForExistence(timeout: 20))
            if surface == "group" {
                XCTAssertTrue(app.textViews["room.composer.field"].waitForExistence(timeout: 20))
            }
            if fixture == "rich" {
                XCTAssertTrue(app.buttons["chat.code.copy"].waitForExistence(timeout: 15))
            } else {
                let file = app.descendants(matching: .any).containing(NSPredicate(format: "label CONTAINS %@", "design-notes.pdf")).firstMatch
                XCTAssertTrue(file.waitForExistence(timeout: 20))
            }
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "\(surface)-\(fixture)-\(dark ? "dark" : "light")\(kind == "photo" ? "-photo" : "")"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            // The Duo's short display cannot show both ends of this example
            // at once; keep the date and own message visible in a second shot.
            if fixture == "rich" && kind == "paper" {
                let transcript = app.scrollViews[surface == "chat" ? "chat.transcript" : "room.transcript"]
                XCTAssertTrue(transcript.waitForExistence(timeout: 10))
                transcript.swipeDown(velocity: .fast)
                let top = XCTAttachment(screenshot: app.screenshot())
                top.name = "\(surface)-rich-\(dark ? "dark" : "light")-top"
                top.lifetime = .keepAlways
                add(top)
            }
            app.terminate()
        }
    }
}
#endif

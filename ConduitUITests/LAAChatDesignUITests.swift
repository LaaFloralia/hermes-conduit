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

    /// Typing is plain text: no formatting bar or preview over the
    /// keyboard, and the transcript moves to its latest message, above the
    /// composer rather than behind it.
    func testComposerIsPlainTextOnTheKeyboard() {
        let app = launch(["-LAA_FORCE_COMPACT_CHAT"])
        let field = app.textViews["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("**plain**")
        XCTAssertEqual(field.value as? String, "**plain**")
        XCTAssertFalse(app.buttons["composer.markdown.format"].exists)
        XCTAssertFalse(app.buttons["composer.markdown.preview"].exists)
        let keyboard = app.keyboards.firstMatch
        if keyboard.waitForExistence(timeout: 5) {
            let send = app.buttons["composer.action"]
            XCTAssertLessThanOrEqual(send.frame.maxY, keyboard.frame.minY + 1)
        }
        let latest = app.buttons["chat.replyMoreMenu"]
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            latest.exists && latest.frame.maxY <= field.frame.minY
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed,
                       "The latest reply \(latest.frame) must sit above the composer \(field.frame)")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "composer-focused"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testCompactHeadersKeepTheirControlsTogether() {
        let app = launch(["-LAA_FORCE_COMPACT_CHAT"])
        let header = app.buttons["laa.employee.header"]
        let call = app.buttons["laa.employee.call"]
        let menu = app.buttons["conversation.menu"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        let employeeRow = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            header.exists && call.exists && menu.exists
                && abs(header.frame.midY - call.frame.midY) < 30
                && abs(call.frame.midY - menu.frame.midY) < 30
                && menu.frame.midX > header.frame.midX
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [employeeRow], timeout: 10), .completed)
        XCTAssertTrue(menu.isHittable)
        menu.tap()
        XCTAssertTrue(app.buttons["conversation.background"].waitForExistence(timeout: 5))
        app.terminate()

        let groupApp = launch(["-LAA_FORCE_COMPACT_CHAT"])
        groupApp.buttons["fixture.group"].tap()
        let groupCall = groupApp.buttons["room.call.unavailable"]
        let groupMenu = groupApp.buttons["conversation.menu"]
        XCTAssertTrue(groupCall.waitForExistence(timeout: 20))
        let groupRow = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            groupMenu.exists && abs(groupCall.frame.midY - groupMenu.frame.midY) < 30
                && groupCall.frame.midY < 100
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [groupRow], timeout: 10), .completed)
        XCTAssertFalse(groupCall.isEnabled)
        XCTAssertTrue(groupMenu.isHittable)
        groupMenu.tap()
        XCTAssertTrue(groupApp.buttons["room.call.reason"].waitForExistence(timeout: 5))
    }

    func testCompactHeaderKeepsBackAndMenuUsable() {
        let app = launch(["-LAA_FORCE_COMPACT_CHAT", "-LAA_FIXTURE_PUSH_CHAT"])
        let header = app.buttons["laa.employee.header"]
        let menu = app.buttons["conversation.menu"]
        let back = app.buttons["BackButton"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        XCTAssertTrue(back.isHittable)
        XCTAssertTrue(menu.isHittable)
        XCTAssertFalse(back.frame.intersects(header.frame), "Back \(back.frame) must not overlap the employee header \(header.frame)")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "header-pushed"
        shot.lifetime = .keepAlways
        add(shot)
        let screen = app.windows.firstMatch.frame
        XCTAssertEqual(header.frame.midX, screen.midX, accuracy: 2, "The name \(header.frame) must sit on the screen's center")
        XCTAssertEqual(screen.maxX - menu.frame.maxX, back.frame.minX - screen.minX, accuracy: 4,
                       "The menu \(menu.frame) must keep Back's \(back.frame) margin")
        back.tap()
        XCTAssertTrue(app.buttons["fixture.group"].waitForExistence(timeout: 10))
    }

    func testCompactGroupHeaderKeepsBackAndMenuUsable() {
        let app = launch(["-LAA_FORCE_COMPACT_CHAT", "-LAA_FIXTURE_PUSH_CHAT", "-LAA_FIXTURE_PUSH_GROUP"])
        let groupCall = app.buttons["room.call.unavailable"]
        let menu = app.buttons["conversation.menu"]
        let back = app.buttons["BackButton"]
        XCTAssertTrue(groupCall.waitForExistence(timeout: 20))
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        XCTAssertTrue(back.isHittable)
        XCTAssertTrue(menu.isHittable)
        XCTAssertFalse(back.frame.intersects(groupCall.frame), "Back must not overlap the group controls")
        back.tap()
        XCTAssertTrue(app.buttons["fixture.group"].waitForExistence(timeout: 10))
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

    /// The input row in Liquid Glass on paper and on a photo, in both
    /// appearances: empty, on the keyboard, and grown to its scroll cap.
    func testComposerGlassScreenshots() {
        for (dark, kind) in [(false, "paper"), (true, "paper"), (false, "photo"), (true, "photo")] {
            let app = XCUIApplication()
            app.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_V2_CHAT_FIXTURE", "rich",
                                   "-LAA_CAPTURE_SURFACE", "chat", "-LAA_CAPTURE_KIND", kind]
                + (dark ? ["-LAA_V2_DARK"] : [])
            app.launch()
            XCTAssertTrue(app.staticTexts["fixture.capture.ready"].waitForExistence(timeout: 25))
            let field = app.textViews["composer.field"]
            XCTAssertTrue(field.waitForExistence(timeout: 15))
            XCTAssertTrue(app.buttons["chat.code.copy"].waitForExistence(timeout: 15))
            let name = "composer-\(dark ? "dark" : "light")-\(kind)"
            capture(app, "\(name)-empty")
            field.tap()
            field.typeText("明日の打ち合わせの資料")
            let keyboard = app.keyboards.firstMatch
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
            XCTAssertLessThanOrEqual(app.buttons["composer.action"].frame.maxY, keyboard.frame.minY + 1)
            let latest = app.buttons["chat.replyMoreMenu"]
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                latest.exists && latest.frame.maxY <= field.frame.minY
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed, "The latest reply sits above the composer")
            capture(app, "\(name)-keyboard")
            let short = field.frame.height
            field.typeText((1...9).map { "\n\($0)行目の確認事項" }.joined())
            let grown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in field.frame.height > short + 40 }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [grown], timeout: 5), .completed, "The field grows with the draft")
            XCTAssertTrue(app.buttons["composer.expand-editor"].isHittable)
            XCTAssertTrue(app.buttons["composer.action"].isEnabled)
            capture(app, "\(name)-multiline")
            app.terminate()
        }
    }

    /// The worst photo (white, no dim or blur): typed text on the field
    /// keeps 4.5:1 against the glass behind it.
    func testComposerGlassKeepsContrastOnWhitePhoto() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_CAPTURE_SURFACE", "chat",
                               "-LAA_CAPTURE_KIND", "photo", "-LAA_CAPTURE_WHITE"]
        app.launch()
        defer { app.terminate() }
        let field = app.textViews["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 25))
        Thread.sleep(forTimeInterval: 2)
        let shot = app.screenshot()
        let frame = field.frame
        let screen = app.windows.firstMatch.frame
        // An empty spot inside the field: right of the placeholder, under the expand button.
        let x = (frame.maxX - 24) / screen.width
        let y = (frame.maxY - 12) / screen.height
        let image = try XCTUnwrap(shot.image.cgImage)
        let px = try XCTUnwrap(image.cropping(to: CGRect(x: Int(Double(image.width) * x), y: Int(Double(image.height) * y), width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(px, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        func linear(_ v: UInt8) -> Double {
            let c = Double(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(bytes[0]) + 0.7152 * linear(bytes[1]) + 0.0722 * linear(bytes[2])
        // The field's text is light on a photo (white in the dark appearance).
        XCTAssertGreaterThanOrEqual(1.05 / (luminance + 0.05), 4.5, "Field background \(bytes) is too light for its text")
        capture(app, "composer-photo-white")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
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

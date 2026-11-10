#if LAA_BUILD
import XCTest

final class LAAChatDesignUITests: XCTestCase {
    private func launch(_ fixture: String = "simple", dark: Bool = false, group: Bool = false, pushed: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_V2_CHAT_FIXTURE", fixture,
                               "-LAA_CAPTURE_SURFACE", group ? "group" : "chat", "-LAA_CAPTURE_KIND", "paper"]
            + (dark ? ["-LAA_V2_DARK"] : []) + (pushed ? ["-LAA_FIXTURE_PUSH_CHAT"] : [])
        app.launch()
        XCTAssertTrue(app.staticTexts["fixture.capture.ready"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.textViews[group ? "room.composer.field" : "composer.field"].waitForExistence(timeout: 15))
        return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    private func bubble(_ app: XCUIApplication, _ speaker: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "chat.message.\(speaker)").firstMatch
    }

    func testNativeMenuReplyReactionAndComposerScreenshots() {
        for dark in [false, true] {
            let app = launch(dark: dark)
            let theme = dark ? "dark" : "light"
            XCTAssertTrue(app.buttons["laa.employee.header"].exists)
            XCTAssertTrue(app.buttons["laa.employee.call"].exists)
            XCTAssertFalse(app.buttons["conversation.menu"].exists)
            XCTAssertFalse(app.buttons["chat.replyMoreMenu"].exists)
            XCTAssertFalse(app.buttons["chat.message.quote.assistant"].exists)
            XCTAssertFalse(app.buttons["composer.expand-editor"].exists)
            XCTAssertFalse(app.buttons["composer.action"].exists)
            XCTAssertTrue(app.staticTexts["chat.delivery.read"].exists)
            capture(app, "conversation-after-\(theme)")

            let reply = bubble(app, "assistant")
            XCTAssertTrue(reply.waitForExistence(timeout: 10))
            reply.press(forDuration: 0.8)
            XCTAssertTrue(app.buttons["コピー"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["テキストを選択"].exists)
            XCTAssertTrue(app.buttons["返信"].exists)
            capture(app, "message-menu-after-\(theme)")
            let reaction = app.buttons["chat.reaction.❤️"]
            XCTAssertTrue(reaction.exists)
            reaction.tap()
            reply.press(forDuration: 0.8)
            app.buttons["テキストを選択"].tap()
            let selected = app.textViews["chat.message.selection"]
            XCTAssertTrue(selected.waitForExistence(timeout: 5))
            XCTAssertTrue((selected.value as? String ?? "").contains("午前"))
            app.buttons["完了"].tap()
            reply.press(forDuration: 0.8)
            app.buttons["返信"].tap()
            XCTAssertTrue(app.buttons["composer.reply-reference.remove"].waitForExistence(timeout: 5))
            capture(app, "reply-after-\(theme)")

            let field = app.textViews["composer.field"]
            field.tap(); field.typeText("確認します")
            let send = app.buttons["composer.action"]
            XCTAssertTrue(send.waitForExistence(timeout: 5))
            XCTAssertTrue(send.isEnabled)
            XCTAssertGreaterThan(send.frame.minX, field.frame.midX)
            XCTAssertLessThan(abs(send.frame.maxY - field.frame.maxY), 20)
            capture(app, "composer-one-line-after-\(theme)")
            let short = field.frame.height
            field.typeText("\n二行目\n三行目")
            XCTAssertTrue(app.buttons["composer.expand-editor"].waitForExistence(timeout: 5))
            XCTAssertGreaterThan(field.frame.height, short + 20)
            capture(app, "composer-multiline-after-\(theme)")
            app.buttons["composer.expand-editor"].tap()
            let full = app.textViews["composer.fullEditor.field"]
            XCTAssertTrue(full.waitForExistence(timeout: 5))
            XCTAssertTrue((full.value as? String ?? "").contains("三行目"))
            app.buttons["composer.collapse-editor"].tap()
            XCTAssertTrue((field.value as? String ?? "").contains("三行目"))
            app.terminate()
        }
    }

    func testTypingOnlyRevealsWorkOnRequest() {
        for dark in [false, true] {
            let app = launch("typing", dark: dark)
            let dots = app.buttons["chat.typing"]
            XCTAssertTrue(dots.waitForExistence(timeout: 10))
            XCTAssertFalse(app.staticTexts["Responding…"].exists)
            XCTAssertFalse(app.staticTexts["予定を確認しています。"].exists)
            capture(app, "typing-after-\(dark ? "dark" : "light")")
            dots.tap()
            XCTAssertTrue(app.staticTexts["作業の記録"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["予定を確認しています。"].exists)
            app.terminate()
        }
    }

    func testGroupSharesHeaderAndComposerWithoutUnsupportedPhone() {
        for dark in [false, true] {
            let app = launch(dark: dark, group: true)
            XCTAssertTrue(app.buttons["room.header"].exists)
            XCTAssertFalse(app.buttons["room.call.unavailable"].exists)
            XCTAssertFalse(app.buttons["conversation.menu"].exists)
            XCTAssertFalse(app.buttons["room.composer.send"].exists)
            capture(app, "group-after-\(dark ? "dark" : "light")")
            let field = app.textViews["room.composer.field"]
            field.tap(); field.typeText("Team update\nSecond line\nThird line")
            capture(app, "group-composer-multiline-after-\(dark ? "dark" : "light")")
            let send = app.buttons["room.composer.send"]
            XCTAssertTrue(send.isEnabled)
            send.tap()
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Team update")).firstMatch.waitForExistence(timeout: 10))
            app.terminate()
        }
    }

    func testEmptyConversationsOnlyShowMascotsAndNames() {
        for group in [false, true] {
            for dark in [false, true] {
                let app = launch("empty", dark: dark, group: group)
                XCTAssertFalse(app.staticTexts["話しかけてみましょう"].exists)
                XCTAssertFalse(app.staticTexts["チャットを開いています…"].exists)
                capture(app, "\(group ? "group" : "conversation")-empty-after-\(dark ? "dark" : "light")")
                app.terminate()
            }
        }
    }

    func testNameOpensInformationAndBackground() {
        let app = launch(pushed: true)
        let header = app.buttons["laa.employee.header"]
        let back = app.buttons["BackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        XCTAssertTrue(back.isHittable)
        XCTAssertFalse(back.frame.intersects(header.frame))
        XCTAssertEqual(header.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 8)
        header.tap()
        XCTAssertTrue(app.staticTexts["会話の情報"].waitForExistence(timeout: 5))
        app.buttons["conversation.background"].tap()
        XCTAssertTrue(app.buttons["background.choice.paper"].waitForExistence(timeout: 5))
        app.buttons["完了"].tap()
        XCTAssertTrue(app.buttons["会話内を検索"].waitForExistence(timeout: 5))
    }
}
#endif

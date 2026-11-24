#if LAA_BUILD
import XCTest

final class LAAChatDesignUITests: XCTestCase {
    private func launch(_ fixture: String = "simple", dark: Bool = false, group: Bool = false, pushed: Bool = true,
                        callable: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_V2_CHAT_FIXTURE", fixture,
                               "-LAA_CAPTURE_SURFACE", group ? "group" : "chat", "-LAA_CAPTURE_KIND", "paper"]
            + (dark ? ["-LAA_V2_DARK"] : []) + (pushed ? ["-LAA_FIXTURE_PUSH_CHAT"] : [])
        if callable { app.launchArguments.append("-LAA_FIXTURE_CALLABLE") }
        app.launchInLab()
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

    func testRowReplyReactionAndComposerScreenshots() {
        for dark in [false, true] {
            let app = launch(dark: dark)
            let theme = dark ? "dark" : "light"
            XCTAssertTrue(app.buttons["laa.employee.header"].exists)
            XCTAssertTrue(app.buttons["BackButton"].exists)
            XCTAssertFalse(app.buttons["laa.employee.call"].exists)
            XCTAssertFalse(app.buttons["conversation.menu"].exists)
            XCTAssertFalse(app.buttons["chat.replyMoreMenu"].exists)
            XCTAssertFalse(app.buttons["chat.message.quote.assistant"].exists)
            XCTAssertTrue(app.buttons["composer.expand-editor"].exists)
            XCTAssertTrue(app.buttons["composer.action"].exists)
            XCTAssertFalse(app.buttons["composer.action"].isEnabled)
            XCTAssertTrue(app.staticTexts["chat.delivery.read"].exists)
            capture(app, "conversation-after-\(theme)")

            // Reply is in the row under the message; the hold selects text.
            let reply = bubble(app, "assistant")
            XCTAssertTrue(reply.waitForExistence(timeout: 10))
            app.buttons.matching(identifier: "chat.message.reply").firstMatch.tap()
            XCTAssertTrue(app.buttons["composer.reply-reference.remove"].waitForExistence(timeout: 5))
            capture(app, "reply-after-\(theme)")

            let field = app.textViews["composer.field"]
            field.tap(); field.typeText("確認します")
            let send = app.buttons["composer.action"]
            XCTAssertTrue(send.waitForExistence(timeout: 5))
            XCTAssertTrue(send.isEnabled)
            XCTAssertGreaterThan(send.frame.minX, field.frame.midX)
            // Send ends the row under the field, as in Work (owner, 2026-11-12).
            XCTAssertGreaterThanOrEqual(send.frame.minY, field.frame.maxY - 1)
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

            // Good is the row's 👍, the reaction Hermes keeps.
            let reactionApp = launch(dark: dark)
            let like = reactionApp.buttons.matching(identifier: "chat.message.like").firstMatch
            XCTAssertTrue(like.waitForExistence(timeout: 5))
            like.tap()
            XCTAssertTrue(reactionApp.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "👍")).firstMatch.waitForExistence(timeout: 5))
            capture(reactionApp, "reaction-after-\(theme)")
            reactionApp.terminate()
        }
    }

    func testRichConversationScreenshots() {
        for dark in [false, true] {
            let app = launch("rich", dark: dark)
            let theme = dark ? "dark" : "light"
            XCTAssertTrue(bubble(app, "assistant").waitForExistence(timeout: 10))
            capture(app, "conversation-rich-after-\(theme)")
            app.swipeDown()
            capture(app, "conversation-rich-opening-after-\(theme)")
            app.terminate()
        }
    }

    func testCallableMonetScreenshots() {
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            for fixture in ["simple", "rich"] {
                let app = launch(fixture, dark: dark, callable: true)
                XCTAssertTrue(bubble(app, "assistant").waitForExistence(timeout: 10))
                let call = app.buttons["laa.employee.call"]
                XCTAssertTrue(call.isHittable && call.isEnabled)
                capture(app, "conversation\(fixture == "rich" ? "-rich" : "")-after-\(theme)")
                if fixture == "rich" {
                    app.swipeDown()
                    capture(app, "conversation-rich-opening-after-\(theme)")
                }
                app.terminate()
            }
        }
    }

    /// The mascot opens the employee's introduction, and the conversation's
    /// information is one row inside it (owner, 2026-11-11).
    func testMascotOpensTheIntroduction() {
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            let app = launch("rich", dark: dark, callable: true)
            XCTAssertTrue(bubble(app, "assistant").waitForExistence(timeout: 10))
            capture(app, "conversation-width-after-\(theme)")
            app.buttons["laa.employee.header"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["laa.staff.intro.motto"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["社長秘書・総合アドバイザー"].exists)
            Thread.sleep(forTimeInterval: 1)
            capture(app, "intro-after-\(theme)")
            let conversation = app.buttons["laa.staff.intro.conversation"]
            if !conversation.isHittable { app.swipeUp() }
            conversation.tap()
            XCTAssertTrue(app.navigationBars["会話の情報"].waitForExistence(timeout: 5))
            capture(app, "intro-conversation-after-\(theme)")
            app.navigationBars["会話の情報"].buttons["完了"].tap()
            XCTAssertTrue(app.buttons["laa.employee.header"].waitForExistence(timeout: 5))
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
            XCTAssertTrue(app.buttons["room.composer.send"].exists)
            XCTAssertFalse(app.buttons["room.composer.send"].isEnabled)
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

    /// The name opens the introduction (owner, 2026-11-11); the
    /// conversation's information and its background are one row inside it.
    func testNameOpensTheIntroductionThenInformationAndBackground() {
        for dark in [false, true] {
            let app = launch(dark: dark, pushed: true)
            let header = app.buttons["laa.employee.header"]
            let back = app.buttons["BackButton"]
            XCTAssertTrue(back.waitForExistence(timeout: 10))
            XCTAssertTrue(back.isHittable)
            XCTAssertFalse(back.frame.intersects(header.frame))
            XCTAssertEqual(header.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 8)
            header.tap()
            XCTAssertTrue(app.descendants(matching: .any)["laa.staff.intro.motto"].waitForExistence(timeout: 5))
            let conversation = app.buttons["laa.staff.intro.conversation"]
            if !conversation.isHittable { app.swipeUp() }
            conversation.tap()
            XCTAssertTrue(app.buttons["conversation.background"].waitForExistence(timeout: 10))
            capture(app, "conversation-information-after-\(dark ? "dark" : "light")")
            app.buttons["conversation.background"].tap()
            XCTAssertTrue(app.buttons["background.choice.paper"].waitForExistence(timeout: 5))
            app.navigationBars["背景"].buttons["完了"].tap()
            XCTAssertTrue(app.buttons["会話内を検索"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }
}
#endif

#if LAA_BUILD
import XCTest

/// The conversation's bubble choice beside its background (owner,
/// 2026-11-16): the standard bubbles or Liquid Glass.
final class LAABubbleGlassUITests: XCTestCase {
    private func launch(bubble: String, dark: Bool, kind: String, white: Bool = false,
                        thinking: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_V2_CHAT_FIXTURE", thinking ? "typing" : "simple",
                               "-LAA_CAPTURE_SURFACE", "chat", "-LAA_CAPTURE_KIND", kind,
                               "-LAA_CAPTURE_BUBBLE", bubble, "-LAA_FIXTURE_PUSH_CHAT"]
            + (dark ? ["-LAA_V2_DARK"] : []) + (white ? ["-LAA_CAPTURE_WHITE"] : [])
        app.launch()
        XCTAssertTrue(app.staticTexts["fixture.capture.ready"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.textViews["composer.field"].waitForExistence(timeout: 15))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    private func bubble(_ app: XCUIApplication, _ speaker: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "chat.message.\(speaker)").firstMatch
    }

    func testBubbleChoiceSitsInTheBackgroundSheetAndKeepsTheMessageMenu() {
        let app = launch(bubble: "standard", dark: false, kind: "paper")
        defer { app.terminate() }
        let background = app.buttons["laa.employee.background"]
        XCTAssertTrue(background.waitForExistence(timeout: 10))
        background.tap()
        let standard = app.buttons["bubble.choice.standard"], glass = app.buttons["bubble.choice.glass"]
        XCTAssertTrue(standard.waitForExistence(timeout: 5))
        XCTAssertEqual(standard.value as? String, "選択中")
        XCTAssertNotEqual(glass.value as? String, "選択中")
        glass.tap()
        XCTAssertEqual(glass.value as? String, "選択中")
        XCTAssertNotEqual(standard.value as? String, "選択中")
        capture(app, "picker-glass-light")
        app.navigationBars["背景"].buttons["完了"].tap()

        // The glass reply still opens its long-press menu, and the choice
        // is still there when the sheet opens again. (The owner's bubble is
        // covered by LAAChatSteerSendUITests.)
        let reply = bubble(app, "assistant")
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        reply.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["コピー"].waitForExistence(timeout: 5))
        capture(app, "menu-glass-assistant-light")
        app.buttons["返信"].tap()
        XCTAssertTrue(app.buttons["composer.reply-reference.remove"].waitForExistence(timeout: 5))
        app.buttons["composer.reply-reference.remove"].tap()
        background.tap()
        XCTAssertTrue(glass.waitForExistence(timeout: 5))
        XCTAssertEqual(glass.value as? String, "選択中")
        standard.tap()
        XCTAssertEqual(standard.value as? String, "選択中")
        app.navigationBars["背景"].buttons["完了"].tap()
    }

    /// Both bubbles × light and dark × no picture and a photo, for the
    /// design review (`laa-0016-20261116/shots/glass`). `photo-white` is the
    /// brightest photo the dimming allows, the contrast's worst case.
    func testCaptureBubbleMatrix() {
        for bubble in ["standard", "glass"] {
            for dark in [false, true] {
                for (kind, white) in [("paper", false), ("photo", false), ("photo", true)] {
                    let app = launch(bubble: bubble, dark: dark, kind: kind, white: white)
                    XCTAssertTrue(self.bubble(app, "assistant").waitForExistence(timeout: 10))
                    XCTAssertTrue(self.bubble(app, "user").exists)
                    // Let the glass settle over the photo.
                    Thread.sleep(forTimeInterval: 1.5)
                    capture(app, "\(bubble)-\(dark ? "dark" : "light")-\(white ? "photo-white" : kind)")
                    app.terminate()
                }
            }
        }
    }

    /// A real busy-turn fixture uses the same foreground and bubble as Chat.
    /// A white picture exercises the highest luminance the photo dimming allows.
    func testThinkingStaysReadableAcrossBackgroundsAndBubbleChoices() {
        for bubble in ["standard", "glass"] {
            for dark in [false, true] {
                for kind in ["paper", "photo"] {
                    let app = launch(bubble: bubble, dark: dark, kind: kind,
                                     white: kind == "photo", thinking: true)
                    let activity = app.buttons["chat.typing"]
                    XCTAssertTrue(activity.waitForExistence(timeout: 10))
                    XCTAssertEqual(activity.value as? String, "Thinking")
                    Thread.sleep(forTimeInterval: 1)
                    capture(app, "thinking-\(bubble)-\(dark ? "dark" : "light")-\(kind)")
                    app.terminate()
                }
            }
        }
    }

}
#endif

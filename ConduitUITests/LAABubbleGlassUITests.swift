#if LAA_BUILD
import XCTest

/// The conversation's bubble choice beside its background (owner,
/// 2026-11-16): the standard bubbles or Liquid Glass, glass by default over
/// a picture (owner, 2026-11-16 07:00).
final class LAABubbleGlassUITests: XCTestCase {
    /// `bubble` nil leaves the bubbles to follow the background.
    private func launch(bubble: String?, dark: Bool, kind: String, white: Bool = false,
                        extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_V2_CHAT_FIXTURE", "simple",
                               "-LAA_CAPTURE_SURFACE", "chat", "-LAA_CAPTURE_KIND", kind,
                               "-LAA_FIXTURE_PUSH_CHAT", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
            + (bubble.map { ["-LAA_CAPTURE_BUBBLE", $0] } ?? [])
            + (dark ? ["-LAA_V2_DARK"] : []) + (white ? ["-LAA_CAPTURE_WHITE"] : []) + extra
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

    /// A picture with no choice made draws glass, and the sheet says so;
    /// choosing いまの見た目 there keeps the opaque bubbles over it.
    func testAPictureDefaultsToGlassUntilTheOwnerChooses() {
        let app = launch(bubble: nil, dark: false, kind: "photo")
        defer { app.terminate() }
        let background = app.buttons["laa.employee.background"]
        XCTAssertTrue(background.waitForExistence(timeout: 10))
        background.tap()
        let standard = app.buttons["bubble.choice.standard"], glass = app.buttons["bubble.choice.glass"]
        XCTAssertTrue(glass.waitForExistence(timeout: 5))
        XCTAssertEqual(glass.value as? String, "選択中")
        standard.tap()
        XCTAssertEqual(standard.value as? String, "選択中")
        app.navigationBars["背景"].buttons["完了"].tap()
        background.tap()
        XCTAssertTrue(standard.waitForExistence(timeout: 5))
        XCTAssertEqual(standard.value as? String, "選択中")
        app.navigationBars["背景"].buttons["完了"].tap()
    }

    /// Sending, a streamed reply and a long press over the glass, for the
    /// console check of glassEffect's per-frame updates (owner, 2026-11-16:
    /// "glassEffect() tried to update multiple times per frame").
    /// `TEST_RUNNER_LAA_STREAM_BUBBLE=standard` runs it over the opaque
    /// bubbles, to tell the bubbles' messages from the rest of the screen's.
    func testSendStreamAndLongPressOverGlass() {
        let choice = ProcessInfo.processInfo.environment["LAA_STREAM_BUBBLE"]
        let app = launch(bubble: choice, dark: true, kind: "photo", extra: ["-LAA_FIXTURE_STREAM"])
        defer { app.terminate() }
        let field = app.textViews["composer.field"]
        field.tap()
        field.typeText("ガラスの確認")
        app.buttons["composer.action"].tap()
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "ガラスの確認")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        // The fixture's reply streams for about five seconds from here.
        Thread.sleep(forTimeInterval: 3)
        capture(app, "glass-streaming-dark-photo")
        Thread.sleep(forTimeInterval: 6)
        let reply = bubble(app, "assistant")
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        reply.press(forDuration: 0.8)
        Thread.sleep(forTimeInterval: 1.5)
        capture(app, "glass-longpress-dark-photo")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// The bubbles × light and dark × a photo, the brightest photo the
    /// dimming allows (`photo-white`, the contrast's worst case) and paper,
    /// for the design review (`laa-0700-20261116/shots/glass`). The photos
    /// are left to their default; paper chooses glass.
    func testCaptureBubbleMatrix() {
        let cases: [(String?, String, Bool, String)] = [
            (nil, "photo", false, "glass"), (nil, "photo", true, "glass"),
            ("standard", "photo", false, "standard"),
            ("glass", "paper", false, "glass"),
        ]
        for (bubble, kind, white, name) in cases {
            for dark in [false, true] {
                let app = launch(bubble: bubble, dark: dark, kind: kind, white: white)
                XCTAssertTrue(self.bubble(app, "assistant").waitForExistence(timeout: 10))
                XCTAssertTrue(self.bubble(app, "user").exists)
                // Let the glass settle over the photo.
                Thread.sleep(forTimeInterval: 1.5)
                capture(app, "\(name)-\(dark ? "dark" : "light")-\(white ? "photo-white" : kind)")
                app.terminate()
            }
        }
    }
}
#endif

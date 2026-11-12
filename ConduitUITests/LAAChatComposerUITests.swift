#if LAA_BUILD
import XCTest
import UIKit

/// The employee chat's composer and leaving the chat (owner, 2026-11-12):
/// Messages-sized + and Send that keep their colour while typing, the
/// expand control at every height, and the system's edge swipe back.
final class LAAChatComposerUITests: XCTestCase {
    private func launchChat(dark: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_V2_CHAT_FIXTURE", "simple",
                               "-LAA_CAPTURE_SURFACE", "chat", "-LAA_CAPTURE_KIND", "paper", "-LAA_FIXTURE_PUSH_CHAT"]
            + (dark ? ["-LAA_V2_DARK"] : [])
        app.launch()
        XCTAssertTrue(app.staticTexts["fixture.capture.ready"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.textViews["composer.field"].waitForExistence(timeout: 15))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    private func note(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    /// The glyph's ink: the pixels of the control's middle 18 pt that stand
    /// furthest from that square's mean, so the glass behind (which takes
    /// whatever scrolls under it) barely counts.
    private func meanColour(of element: XCUIElement, in app: XCUIApplication) -> (r: Double, g: Double, b: Double)? {
        let image = app.screenshot().image
        guard let cg = image.cgImage else { return nil }
        let scale = CGFloat(cg.width) / app.frame.width
        let frame = CGRect(x: element.frame.midX - 9, y: element.frame.midY - 9, width: 18, height: 18)
        let rect = CGRect(x: frame.minX * scale, y: frame.minY * scale,
                          width: frame.width * scale, height: frame.height * scale).integral
        guard let crop = cg.cropping(to: rect) else { return nil }
        let width = crop.width, height = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        let all = stride(from: 0, to: pixels.count, by: 4).map {
            (Double(pixels[$0]), Double(pixels[$0 + 1]), Double(pixels[$0 + 2]))
        }
        let mean = all.reduce((0.0, 0.0, 0.0)) { ($0.0 + $1.0, $0.1 + $1.1, $0.2 + $1.2) }
        let centre = (mean.0 / Double(all.count), mean.1 / Double(all.count), mean.2 / Double(all.count))
        func distance(_ p: (Double, Double, Double)) -> Double {
            abs(p.0 - centre.0) + abs(p.1 - centre.1) + abs(p.2 - centre.2)
        }
        let ink = all.sorted { distance($0) > distance($1) }.prefix(max(1, all.count / 8))
        let sum = ink.reduce((0.0, 0.0, 0.0)) { ($0.0 + $1.0, $0.1 + $1.1, $0.2 + $1.2) }
        let count = Double(ink.count)
        return (sum.0 / count, sum.1 / count, sum.2 / count)
    }

    func testComposerControlsKeepTheirSizeColourAndExpand() {
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            let app = launchChat(dark: dark)
            let field = app.textViews["composer.field"]
            let send = app.buttons["composer.action"]
            let attach = app.buttons["composer.attach"]
            let expand = app.buttons["composer.expand-editor"]
            XCTAssertTrue(send.exists)
            XCTAssertTrue(attach.exists)
            XCTAssertFalse(send.isEnabled, "Send is off with nothing to send")
            XCTAssertTrue(expand.exists, "the expand control shows on the empty field")
            // Work's 36 pt glass in the row under the field; the element is
            // its touch area, 36 to 44 pt.
            for control in [send, attach] {
                XCTAssertTrue((35...45).contains(control.frame.width), "\(control.frame)")
                XCTAssertTrue((35...45).contains(control.frame.height), "\(control.frame)")
                XCTAssertGreaterThanOrEqual(control.frame.midY, field.frame.maxY + 17)
            }
            XCTAssertLessThan(attach.frame.maxX, send.frame.minX)
            capture(app, "composer-empty-\(theme)")
            // The touch reaches 44 pt: 20 pt left of the glass's centre is
            // outside the 36 pt circle and still opens +.
            attach.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .withOffset(CGVector(dx: -20, dy: 0)).tap()
            let library = app.buttons.matching(NSPredicate(format: "label IN %@", ["Photo Library", "写真ライブラリ"])).firstMatch
            XCTAssertTrue(library.waitForExistence(timeout: 5), "a tap just outside + still opens it")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
            Thread.sleep(forTimeInterval: 1)

            field.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            Thread.sleep(forTimeInterval: 2)
            let before = meanColour(of: send, in: app)
            capture(app, "composer-focused-\(theme)")

            field.typeText("確認します")
            XCTAssertTrue(send.isEnabled, "Send turns on for a draft")
            XCTAssertTrue(expand.exists, "the expand control shows at one line")
            Thread.sleep(forTimeInterval: 2)
            let after = meanColour(of: send, in: app)
            capture(app, "composer-one-line-\(theme)")
            if let before, let after {
                let change = max(abs(before.r - after.r), abs(before.g - after.g), abs(before.b - after.b))
                note("send-colour-\(theme)", "before \(before) after \(after) change \(change)")
                XCTAssertLessThan(change, 12, "Send keeps the colour it had before typing")
            } else {
                XCTFail("could not read Send's colour")
            }

            field.typeText("\n二行目\n三行目\n四行目")
            XCTAssertTrue(expand.exists, "the expand control shows on a tall draft")
            capture(app, "composer-multiline-\(theme)")
            note("frames-\(theme)", "attach \(attach.frame) send \(send.frame) field \(field.frame) expand \(expand.frame)")
            expand.tap()
            XCTAssertTrue(app.textViews["composer.fullEditor.field"].waitForExistence(timeout: 5))
            app.buttons["composer.collapse-editor"].tap()
            app.terminate()
        }
    }

    /// The left-edge swipe goes back to the list, as the Back button does,
    /// and does nothing at the list itself.
    func testLeftEdgeSwipeReturnsToTheList() {
        let app = XCUIApplication()
        app.launchEnvironment["CONDUIT_UITEST"] = "1"
        let link = "conduit://widget/v1/resume?dashboard=8d516b21-6b3c-4f5a-a0d6-6f6e8b73a901&profile=work&kind=dashboard&scope=work&session=widget-ui-test-session&unverified=false"
        app.launchArguments += ["-CONDUIT_UI_TEST_CONNECTED_DASHBOARD", "https://conduit-ui-test.invalid",
                                "-CONDUIT_UI_TEST_PROFILES", "work,staging",
                                "-CONDUIT_UI_TEST_WIDGET_URL", link]
        app.launch()
        let field = app.textViews["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["BackButton"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Work"].exists)
        Thread.sleep(forTimeInterval: 1)
        capture(app, "edge-swipe-chat")

        // Slow, held halfway, so a recording shows the list under the chat.
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.45))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.45)),
                   withVelocity: .slow, thenHoldForDuration: 1.5)
        let work = app.buttons["Work"]
        XCTAssertTrue(work.waitForExistence(timeout: 10), "the swipe returned to the list and its tab bar")
        XCTAssertFalse(field.exists)
        Thread.sleep(forTimeInterval: 1)
        capture(app, "edge-swipe-list")

        // At the list there is nothing to go back to.
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45)))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(work.exists)
        XCTAssertTrue(app.buttons["Chat"].exists)
        capture(app, "edge-swipe-root")
    }
}
#endif

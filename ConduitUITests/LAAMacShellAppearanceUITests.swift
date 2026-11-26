#if LAA_BUILD
import UIKit
import XCTest

final class LAAMacShellAppearanceUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testAppearanceRecolorsInPlaceAndPersists() throws {
        try verifyAppearance(dark: false)
    }

    #if !targetEnvironment(macCatalyst)
    func testDarkAppearanceRecolorsInPlaceAndPersists() throws {
        try verifyAppearance(dark: true)
    }
    #endif

    private func verifyAppearance(dark: Bool) throws {
        let app = XCUIApplication()
        app.launchEnvironment["CONDUIT_UITEST"] = "1"
        app.launchEnvironment["LAA_UI_TEST_THEME_SUITE"] = "laa.appearance-test.\(UUID().uuidString)"
        app.launchEnvironment["LAA_UI_TEST_APPEARANCE_SCHEME"] = dark ? "Dark" : "Light"
        app.launchArguments += ["-LAA_UI_TEST_ISOLATED_BRIDGE", "-laa-tab", "today", "-laa-mac-section", "today",
                                "-laa.work.decisionCount", "5"]
        app.launchInLab()
        let prefix = dark ? "dark" : "light"
        let today = app.staticTexts["laa.today.title"]
        XCTAssertTrue(today.waitForExistence(timeout: 20))
        let shellShot = app.screenshot()
        attach(shellShot, as: "shell-\(prefix)")
        let mainBefore = try paperSample(shellShot)
        let brightness = (mainBefore >> 16 & 255) + (mainBefore >> 8 & 255) + (mainBefore & 255)
        XCTAssertEqual(brightness < 384, dark, "The actual canvas follows the requested system appearance")
        #if !targetEnvironment(macCatalyst)
        for label in ["Chat", "Work", "Today", "Doc", "Studio"] {
            let tab = app.laaTab(label)
            XCTAssertTrue(tab.waitForExistence(timeout: 5), label)
            XCTAssertEqual(tab.isSelected, label == "Today")
        }
        let work = app.laaTab("Work")
        XCTAssertTrue(String(describing: work.value ?? "").contains("5"), "The Work badge survives the custom glyph")
        #endif

        openAppearance(app)
        let laa = app.buttons["settings.theme.laa"]
        let cacao = app.buttons["settings.theme.cacao-rose"]
        XCTAssertTrue(laa.waitForExistence(timeout: 10))
        XCTAssertTrue(laa.isSelected)
        let window = app.windows.containing(.button, identifier: "settings.theme.laa").firstMatch
        func settingsShot() -> XCUIScreenshot { window.exists ? window.screenshot() : app.screenshot() }
        attach(settingsShot(), as: "appearance-laa-\(prefix)")
        let paperBefore = try paperSample(settingsShot())
        cacao.tap()
        XCTAssertTrue(cacao.isSelected)
        XCTAssertTrue(laa.exists, "Appearance did not pop on theme change")
        let after = settingsShot()
        XCTAssertNotEqual(try paperSample(after), paperBefore)
        attach(after, as: "appearance-cacao-rose-\(prefix)")

        #if targetEnvironment(macCatalyst)
        app.typeKey("w", modifierFlags: .command)
        #else
        let done = app.buttons["laa.settings.done"].firstMatch
        if !done.isHittable {
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            back.tap()
        }
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        #endif
        XCTAssertTrue(today.waitForExistence(timeout: 10), "The selected screen did not change")
        XCTAssertNotEqual(try paperSample(app.screenshot()), mainBefore, "Theme reached the main app")
        app.terminate()
        app.launchInLab()
        XCTAssertTrue(today.waitForExistence(timeout: 20))
        openAppearance(app)
        XCTAssertTrue(cacao.waitForExistence(timeout: 10))
        XCTAssertTrue(cacao.isSelected, "The app group theme survives relaunch")
    }

    private func openAppearance(_ app: XCUIApplication) {
        app.openLAASettings()
        let appearance = app.buttons["settings.appearance"].firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 10))
        #if !targetEnvironment(macCatalyst)
        let scroller = app.scrollViews.containing(.button, identifier: "settings.appearance").firstMatch
        for _ in 0..<3 {
            if appearance.isHittable && appearance.frame.maxY < scroller.frame.maxY { break }
            scroller.swipeUp()
        }
        #endif
        appearance.tap()
    }

    private func attach(_ image: XCUIScreenshot, as name: String) {
        let shot = XCTAttachment(screenshot: image)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Mode of interior sRGB samples; text, glyphs and other small features cannot spoof a palette change.
    private func paperSample(_ screenshot: XCUIScreenshot) throws -> UInt32 {
        let source = try XCTUnwrap(screenshot.image.cgImage)
        let side = 24
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        return try bytes.withUnsafeMutableBytes { raw in
            let ctx = try XCTUnwrap(CGContext(data: raw.baseAddress, width: side, height: side,
                                             bitsPerComponent: 8, bytesPerRow: side * 4,
                                             space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.interpolationQuality = .none
            ctx.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
            var counts: [UInt32: Int] = [:]
            for y in 3..<(side - 3) {
                for x in 2..<(side - 2) {
                    let i = (y * side + x) * 4
                    let color = UInt32(raw[i]) << 16 | UInt32(raw[i + 1]) << 8 | UInt32(raw[i + 2])
                    counts[color, default: 0] += 1
                }
            }
            return try XCTUnwrap(counts.max(by: { $0.value < $1.value })?.key)
        }
    }
}
#endif

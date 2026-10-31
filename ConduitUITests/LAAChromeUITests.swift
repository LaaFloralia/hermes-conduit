#if LAA_BUILD
import XCTest

final class LAAChromeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ appearance: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CONDUIT_UITEST"] = "1"
        app.launchArguments = ["-AppleLanguages", "(en)", "-conduit.appLanguage", "en",
                               "-conduit.themePreference", appearance,
                               "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD", "https://chats-ui-test.invalid",
                               "-LAA_UI_TEST_ISOLATED_BRIDGE", "-LAA_UI_TEST_CHATS"] + extra
        app.launch()
        return app
    }

    @discardableResult
    private func capture(_ name: String) -> XCUIScreenshot {
        let screenshot = XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        return screenshot
    }

    private func assertBackground(_ screenshot: XCUIScreenshot, appearance: String) throws {
        let background = try LAAScreenPixel.sideBackground(screenshot)
        if appearance == "dark" {
            XCTAssertLessThan(background.max() ?? 255, 64, "Dark background must use the dark token")
        } else {
            XCTAssertGreaterThan(background.min() ?? 0, 200, "Light background must use the light token")
        }
    }

    func testAllTabsOpenSettingsAtTheSamePositionAndCapture() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance)
            var firstFrame: CGRect?
            for tab in ["Chats", "Work", "Brain", "Assets", "Usage"] {
                let tabButton = app.buttons[tab]
                XCTAssertTrue(tabButton.waitForExistence(timeout: 30), tab)
                tabButton.tap()
                // Only the visible tab's bar carries the button; the tab
                // views the picker keeps off screen must not answer here.
                let bar = app.navigationBars.buttons.matching(identifier: "laa.settings.open")
                XCTAssertEqual(bar.count, 1, "\(tab): one settings button in the visible bar")
                let settings = bar.firstMatch
                XCTAssertTrue(settings.waitForExistence(timeout: 15), tab)
                XCTAssertTrue(settings.isHittable, tab)
                if let firstFrame {
                    XCTAssertEqual(settings.frame.minX, firstFrame.minX, accuracy: 1, tab)
                    XCTAssertEqual(settings.frame.minY, firstFrame.minY, accuracy: 1, tab)
                    XCTAssertEqual(settings.frame.width, firstFrame.width, accuracy: 1, tab)
                    XCTAssertEqual(settings.frame.height, firstFrame.height, accuracy: 1, tab)
                } else {
                    firstFrame = settings.frame
                }
                if tab == "Chats" {
                    // The screen's own "Chats" heading is the only one: the
                    // bar above it stays empty (BUS-331).
                    XCTAssertFalse(app.navigationBars["Chats"].exists, "no navigation title over Chats")
                    XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "Chats")).count, 1)
                }
                capture("chrome-\(tab.lowercased())-\(appearance)")
                settings.tap()
                XCTAssertTrue(app.buttons["settings.chat"].waitForExistence(timeout: 10), tab)
                app.buttons["Close Settings"].tap()
            }
            let pairing = app.buttons["laa.bridge.openPairing"]
            XCTAssertTrue(pairing.waitForExistence(timeout: 10))
            pairing.tap()
            XCTAssertTrue(app.navigationBars["Connect to Mac"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.textFields["laa.bridge.address"].exists)
            let code = app.secureTextFields["laa.bridge.code"]
            XCTAssertTrue(code.exists)
            XCTAssertTrue(app.staticTexts["Address"].exists)
            XCTAssertTrue(app.staticTexts["Pairing code"].exists)
            // The bar title may be read once; the body must not repeat it.
            XCTAssertLessThanOrEqual(
                app.staticTexts.matching(NSPredicate(format: "label == %@", "Connect to Mac")).count, 1)
            let connect = app.buttons["laa.bridge.pair"]
            XCTAssertFalse(connect.isEnabled)
            try assertBackground(capture("chrome-pairing-\(appearance)"), appearance: appearance)
            if appearance == "light" {
                code.tap()
                code.typeText("123456")
                XCTAssertTrue(connect.isEnabled)
            }
            app.buttons["Close"].tap()
            app.terminate()
        }
    }

    func testDisconnectedChatsOpenSettingsAndCapture() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance, extra: ["-LAA_UI_TEST_FORCE_LOGIN", "-LAA_UI_TEST_FIRST_LOGIN"])
            let settings = app.buttons["laa.settings.open"]
            XCTAssertTrue(settings.waitForExistence(timeout: 30))
            capture("chrome-login-\(appearance)")
            settings.tap()
            XCTAssertTrue(app.buttons["settings.chat"].waitForExistence(timeout: 10))
            app.terminate()
        }
    }

    func testCallControlsAndCapture() throws {
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-laa-staff-call-fixture"] + (appearance == "dark" ? ["-laa-dark"] : [])
            app.launch()
            XCTAssertTrue(app.buttons["laa.employee.call"].waitForExistence(timeout: 30))
            app.buttons["laa.employee.call"].tap()
            XCTAssertTrue(app.buttons["laa.call.end"].waitForExistence(timeout: 10))
            XCTAssertEqual(app.buttons["laa.call.end"].label, "End")
            try assertBackground(capture("chrome-call-\(appearance)"), appearance: appearance)
            app.terminate()
        }
    }
}
#endif

#if LAA_BUILD
import XCTest

final class LAAChromeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ appearance: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CONDUIT_UITEST"] = "1"
        app.launchEnvironment["LAA_BRIDGE_DEFAULT_ADDRESS"] = "http://127.0.0.1:1"
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
            for tab in ["Chat", "Today", "Doc", "Studio", "Work"] {
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
                if tab == "Chat" {
                    // The section is "Chat" everywhere: the screen's own
                    // heading says so and the bar above it stays empty
                    // (BUS-331).
                    XCTAssertFalse(app.navigationBars["Chat"].exists, "no navigation title over Chat")
                    XCTAssertEqual(app.staticTexts["laa.chats.heading"].label, "Chat")
                }
                capture("chrome-\(tab.lowercased())-\(appearance)")
                settings.tap()
                XCTAssertTrue(app.buttons["settings.chat"].waitForExistence(timeout: 10), tab)
                if tab == "Chat" { capture("chrome-settings-\(appearance)") }
                app.buttons["laa.settings.done"].tap()
            }
            let settingsButton = app.buttons["laa.settings.open"]
            XCTAssertTrue(settingsButton.waitForExistence(timeout: 10)); settingsButton.tap()
            XCTAssertFalse(app.buttons["settings.ai-usage"].exists)
            let pairing = app.buttons["laa.settings.mac.repair"]
            XCTAssertTrue(pairing.waitForExistence(timeout: 10))
            pairing.tap()
            XCTAssertTrue(app.navigationBars["Macに接続"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.textFields["laa.bridge.address"].exists)
            let code = app.secureTextFields["laa.bridge.code"]
            XCTAssertTrue(code.exists)
            XCTAssertTrue(app.staticTexts["アドレス"].exists)
            XCTAssertTrue(app.staticTexts["接続コード"].exists)
            // The bar title may be read once; the body must not repeat it.
            XCTAssertLessThanOrEqual(
                app.staticTexts.matching(NSPredicate(format: "label == %@", "Macに接続")).count, 1)
            let connect = app.buttons["laa.bridge.pair"]
            XCTAssertFalse(connect.isEnabled)
            try assertBackground(capture("chrome-pairing-\(appearance)"), appearance: appearance)
            if appearance == "light" {
                code.tap()
                code.typeText("123456")
                XCTAssertTrue(connect.isEnabled)
            }
            app.buttons["閉じる"].tap()
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

    func testSettingsAndDataUseLAAContentAndCapture() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance)
            let settings = app.buttons["laa.settings.open"]
            XCTAssertTrue(settings.waitForExistence(timeout: 30))
            settings.tap()
            XCTAssertTrue(app.buttons["settings.chat"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["AI社員"].exists)
            XCTAssertFalse(app.staticTexts["Hermes"].exists)
            capture("remnants-settings-\(appearance)")

            let scroll = app.scrollViews.firstMatch
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "About & privacy")).firstMatch.exists)
            let data = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "データとライセンス")).firstMatch
            for _ in 0..<6 where !data.isHittable { scroll.swipeUp() }
            XCTAssertTrue(data.isHittable)
            data.tap()
            XCTAssertTrue(app.navigationBars["データとライセンス"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["LAAは設定したMacに接続します。会話と添付ファイルはその接続先で処理されます。"].exists)
            XCTAssertFalse(app.staticTexts["Active profile"].exists)
            XCTAssertFalse(app.staticTexts["Hermes"].exists)
            XCTAssertFalse(app.links["Privacy policy"].exists)
            XCTAssertFalse(app.links["Support"].exists)
            XCTAssertFalse(app.links["GitHub"].exists)
            capture("remnants-data-licenses-\(appearance)")

            let licenses = app.buttons["オープンソースライセンス"]
            for _ in 0..<6 where !licenses.isHittable { app.scrollViews.firstMatch.swipeUp() }
            XCTAssertTrue(licenses.isHittable)
            licenses.tap()
            let notice = app.staticTexts["laa.licenses.text"]
            XCTAssertTrue(notice.waitForExistence(timeout: 10))
            XCTAssertTrue(notice.label.contains("Copyright (c) 2026 kaishi00"))
            XCTAssertTrue(notice.label.contains("Copyright (c) 2026 LerSent001"))
            capture("remnants-licenses-\(appearance)")
            app.terminate()
        }
    }

    func testMacSettingsRemainReachableWhenUnpairedOrKeychainFails() {
        for (arguments, status) in [([String](), "未接続"),
                                    (["-LAA_UI_TEST_KEYCHAIN_ERROR"], "認証情報を読み取れません"),
                                    (["-LAA_UI_TEST_BRIDGE_OFFLINE"], "未接続")] {
            let app = launch("light", extra: arguments)
            let settings = app.buttons["laa.settings.open"]
            XCTAssertTrue(settings.waitForExistence(timeout: 30))
            settings.tap()
            let value = app.staticTexts["laa.settings.mac.status"]
            XCTAssertTrue(value.waitForExistence(timeout: 10))
            let predicate = NSPredicate(format: "label == %@", status)
            expectation(for: predicate, evaluatedWith: value)
            waitForExpectations(timeout: 10)
            XCTAssertFalse(app.buttons["settings.saved-dashboards"].exists)
            XCTAssertFalse(app.buttons["settings.connection-setup"].exists)
            XCTAssertFalse(app.buttons["settings.conduit-plugin"].exists)
            let repair = app.buttons["laa.settings.mac.repair"]
            XCTAssertTrue(repair.isHittable)
            repair.tap()
            if arguments.contains("-LAA_UI_TEST_BRIDGE_OFFLINE") {
                // The saved pairing survives an unreachable Mac. Retry keeps the settings card open.
                expectation(for: predicate, evaluatedWith: value)
                waitForExpectations(timeout: 10)
                XCTAssertFalse(app.secureTextFields["laa.bridge.code"].exists)
            } else {
                XCTAssertTrue(app.navigationBars["Macに接続"].waitForExistence(timeout: 10))
            }
            app.terminate()
        }
    }

    func testMacSettingsAndPairingCapture() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance)
            let settings = app.buttons["laa.settings.open"]
            XCTAssertTrue(settings.waitForExistence(timeout: 30))
            settings.tap()
            let repair = app.buttons["laa.settings.mac.repair"]
            XCTAssertTrue(repair.waitForExistence(timeout: 10))
            capture("remnants-mac-\(appearance)")
            repair.tap()
            XCTAssertTrue(app.navigationBars["Macに接続"].waitForExistence(timeout: 10))
            capture("remnants-mac-pairing-\(appearance)")
            app.terminate()
        }
    }

    func testExistingVoiceEntryShowsLAACallAndCanReturnFromTabs() {
        let app = launch("light", extra: ["-LAA_UI_TEST_EXISTING_VOICE"])
        XCTAssertTrue(app.buttons["laa.call.end"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.staticTexts["laa.call.name"].label, "Monet")
        app.buttons["laa.call.back"].tap()
        let returnToCall = app.buttons["laa.call.return"]
        XCTAssertTrue(returnToCall.waitForExistence(timeout: 10))
        returnToCall.tap()
        XCTAssertTrue(app.buttons["laa.call.end"].waitForExistence(timeout: 10))
        app.buttons["laa.call.end"].tap()
        XCTAssertFalse(app.buttons["laa.call.end"].exists)
    }

    func testAppearanceAndNotificationsOmitLegacyControls() {
        for appearance in ["light", "dark"] {
            for (setting, title) in [("settings.appearance", "Appearance"), ("settings.notifications", "Notifications")] {
                let app = launch(appearance)
                let settings = app.buttons["laa.settings.open"]
                XCTAssertTrue(settings.waitForExistence(timeout: 30))
                settings.tap()
                let entry = app.buttons[setting]
                XCTAssertTrue(entry.waitForExistence(timeout: 10))
                if !entry.isHittable { app.scrollViews.firstMatch.swipeUp() }
                entry.tap()
                XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
                if title == "Appearance" {
                    XCTAssertFalse(app.staticTexts["Main button"].exists)
                    XCTAssertFalse(app.staticTexts["Project chats"].exists)
                } else {
                    XCTAssertFalse(app.textFields["Push relay URL"].exists)
                    XCTAssertFalse(app.staticTexts["Verify pairing"].exists)
                    XCTAssertFalse(app.buttons["notifications.plugin-link"].exists)
                }
                capture("remnants-\(title.lowercased())-\(appearance)")
                app.terminate()
            }
        }
    }

    func testVoiceSettingsOmitLegacyCallOrbControl() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance, extra: ["-LAA_UI_TEST_VOICE_SETTINGS"])
            let settings = app.buttons["laa.settings.open"]
            XCTAssertTrue(settings.waitForExistence(timeout: 30))
            settings.tap()
            let voice = app.buttons["settings.voice"]
            XCTAssertTrue(voice.waitForExistence(timeout: 10))
            if !voice.isHittable { app.scrollViews.firstMatch.swipeUp() }
            voice.tap()
            XCTAssertTrue(app.navigationBars["Voice"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["Macの音声設定を取得できません。テキストの会話は引き続き使えます。"].waitForExistence(timeout: 15))
            capture("remnants-voice-\(appearance)")
            let advanced = app.buttons["voice.advancedToggle"]
            for _ in 0..<10 where !advanced.isHittable { app.scrollViews.firstMatch.swipeUp() }
            XCTAssertTrue(advanced.isHittable)
            if advanced.value as? String != "Expanded" { advanced.tap() }
            capture("remnants-voice-advanced-\(appearance)")
            XCTAssertFalse(app.staticTexts["Hermes"].exists, app.staticTexts["Hermes"].debugDescription)
            XCTAssertFalse(app.switches["voice.animateCallOrb"].exists)
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

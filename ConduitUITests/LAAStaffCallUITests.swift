#if LAA_BUILD
import XCTest

final class LAAStaffCallUITests: XCTestCase {
    func testCallChatReturnAndEnd() {
        let app = launch()
        XCTAssertTrue(app.buttons["laa.employee.call"].waitForExistence(timeout: 10))
        app.buttons["laa.employee.header"].tap()
        XCTAssertTrue(app.staticTexts["社長秘書・総合アドバイザー"].waitForExistence(timeout: 5))
        app.buttons["閉じる"].tap()
        app.buttons["laa.employee.call"].tap()
        XCTAssertTrue(app.buttons["laa.call.chat"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["laa.call.name"].exists)
        XCTAssertEqual(app.staticTexts["laa.call.engine"].label, "GPT-Live")
        app.buttons["laa.call.chat"].tap()
        XCTAssertTrue(app.staticTexts["laa.fixture.conversation"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["laa.call.return"].waitForExistence(timeout: 5))
        attachScreenshot(name: "staff-chat-in-call")
        app.buttons["laa.call.return"].tap()
        XCTAssertTrue(app.buttons["laa.call.end"].waitForExistence(timeout: 5))
        app.buttons["laa.call.end"].tap()
        XCTAssertTrue(app.staticTexts["laa.fixture.conversation"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["laa.call.return"].exists)
    }

    func testEmployeeVoiceSettingAndCall() {
        let app = launch()
        XCTAssertTrue(app.buttons["laa.employee.header"].waitForExistence(timeout: 10))
        app.buttons["laa.employee.header"].tap()
        let picker = app.descendants(matching: .any)["laa.employee.voice-setting"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        attachScreenshot(name: "employee-voice-settings")
        picker.tap()
        let choice = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Juniper")).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
        app.buttons["閉じる"].tap()
        app.buttons["laa.employee.call"].tap()
        XCTAssertTrue(app.staticTexts["laa.call.engine"].waitForExistence(timeout: 10))
        attachScreenshot(name: "employee-gpt-live-call")
    }

    func testGeneralGPTLiveSettingsHideAPIBillingEvenWithAnOldPreference() {
        let app = launch("-laa-gpt-live-settings")
        let voice = app.descendants(matching: .any)["laa.gptlive.subscription-voice"]
        XCTAssertTrue(voice.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["laa.gptlive.billing"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["laa.gptlive.api-hermes-calls"].exists)
        voice.tap()
        let subscriptionVoice = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Arbor")).firstMatch
        XCTAssertTrue(subscriptionVoice.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Cedar")).firstMatch.exists)
    }

    func testUnavailableBridgeExplainsDisabledCallAndClassicVoiceIsNotRequired() {
        for (argument, reason) in [("-laa-unpaired", "端末を接続すると通話できます"),
                                   ("-laa-revoked", "端末を再接続してください"),
                                   ("-laa-offline", "Hermesに接続してください")] {
            let app = launch(argument)
            let button = app.buttons["laa.employee.call"]
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            XCTAssertFalse(button.isEnabled)
            let header = app.descendants(matching: .any)["laa.employee.header"]
            XCTAssertTrue(header.waitForExistence(timeout: 5))
            XCTAssertTrue(header.label.contains(reason))
            app.terminate()
        }
        let app = launch("-laa-no-voice")
        let button = app.buttons["laa.employee.call"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertTrue(button.isEnabled)
    }

    func testLightDarkAndReduceMotionScreenshots() {
        for (name, args) in [("light", [String]()), ("dark", ["-laa-dark"]),
                             ("reduce-motion", ["-laa-reduce-motion"])] {
            let app = launch(args)
            let call = app.buttons["laa.employee.call"]
            XCTAssertTrue(call.waitForExistence(timeout: 10))
            attachScreenshot(name: "staff-chat-\(name)")
            call.tap()
            XCTAssertTrue(app.buttons["laa.call.end"].waitForExistence(timeout: 10))
            attachScreenshot(name: "staff-call-\(name)")
            app.terminate()
        }
    }

    func testNativeCallShowsSystemRoutePicker() {
        let app = launch("-laa-native-call")
        let call = app.buttons["laa.employee.call"]
        XCTAssertTrue(call.waitForExistence(timeout: 10))
        call.tap()
        let picker = app.descendants(matching: .any)["laa.call.audio-route"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertEqual(picker.label, "音声の出力先")
        attachScreenshot(name: "staff-call-system-route")
    }

    private func attachScreenshot(name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launch(_ arguments: String...) -> XCUIApplication { launch(arguments) }
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-laa-staff-call-fixture"] + arguments
        app.launch()
        return app
    }
}
#endif

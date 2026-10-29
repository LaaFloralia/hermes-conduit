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

    func testUnpairedAndMissingVoiceExplainDisabledCall() {
        for (argument, reason) in [("-laa-unpaired", "端末を接続すると通話できます"),
                                   ("-laa-revoked", "端末を再接続してください"),
                                   ("-laa-offline", "Hermesに接続してください"),
                                   ("-laa-no-voice", "音声出力を設定してください")] {
            let app = launch(argument)
            let button = app.buttons["laa.employee.call"]
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            XCTAssertFalse(button.isEnabled)
            let header = app.descendants(matching: .any)["laa.employee.header"]
            XCTAssertTrue(header.waitForExistence(timeout: 5))
            XCTAssertTrue(header.label.contains(reason))
            app.terminate()
        }
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

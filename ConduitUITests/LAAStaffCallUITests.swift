#if LAA_BUILD
import XCTest
import UIKit

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
        app.buttons["laa.call.back"].tap()
        XCTAssertTrue(app.buttons["laa.call.return"].waitForExistence(timeout: 5))
        app.buttons["laa.call.return"].tap()
        XCTAssertTrue(app.buttons["laa.call.chat"].waitForExistence(timeout: 5))
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

    func testExpandedComposerWaveformCallsTheEmployeeForNewAndSavedCalls() {
        for arguments in [["-laa-composer-fixture"], ["-laa-composer-fixture", "-laa-saved-call"]] {
            let app = launch(arguments)
            if arguments.contains("-laa-saved-call") {
                XCTAssertTrue(app.staticTexts["laa.fixture.saved-call"].waitForExistence(timeout: 10))
            }
            let field = app.textViews["composer.field"]
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            field.tap()
            let waveform = app.buttons["composer.voice"]
            XCTAssertTrue(waveform.waitForExistence(timeout: 5))
            XCTAssertTrue(waveform.isEnabled)
            waveform.tap()
            let name = app.staticTexts["laa.call.name"]
            XCTAssertTrue(name.waitForExistence(timeout: 10))
            XCTAssertEqual(name.label, "Morgan")
            XCTAssertEqual(app.staticTexts["laa.call.engine"].label, "GPT-Live")
            app.buttons["laa.call.chat"].tap()
            let context = app.staticTexts["laa.fixture.call-context"]
            XCTAssertTrue(context.waitForExistence(timeout: 5))
            XCTAssertEqual(context.label, "laa-cfo|fixture-conversation")
            app.terminate()
        }
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

    func testLightDarkAndReduceMotionScreenshots() throws {
        for (name, args) in [("light", [String]()), ("dark", ["-laa-dark"]),
                             ("reduce-motion", ["-laa-reduce-motion"])] {
            let app = launch(args)
            let call = app.buttons["laa.employee.call"]
            XCTAssertTrue(call.waitForExistence(timeout: 10))
            attachScreenshot(name: "staff-chat-\(name)")
            call.tap()
            XCTAssertTrue(app.buttons["laa.call.end"].waitForExistence(timeout: 10))
            attachScreenshot(name: "staff-call-\(name)")
            let background = try callBackgroundPixel()
            if name == "dark" {
                XCTAssertLessThan(background.max() ?? 255, 64, "Dark call background must use the dark token")
            } else {
                XCTAssertGreaterThan(background.min() ?? 0, 200, "Light call background must use the light token")
            }
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

    private func callBackgroundPixel() throws -> [UInt8] {
        let image = try XCTUnwrap(UIImage(data: XCUIScreen.main.screenshot().pngRepresentation)?.cgImage)
        // A point at the side avoids the centred avatar, text and controls.
        let pixel = try XCTUnwrap(image.cropping(to: CGRect(x: image.width / 100, y: image.height / 2,
                                                           width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                                          bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                            CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        XCTAssertTrue(rendered)
        return Array(rgba.prefix(3))
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

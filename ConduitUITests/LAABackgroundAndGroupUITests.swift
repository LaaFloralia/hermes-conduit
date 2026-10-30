import XCTest
import UIKit

final class LAABackgroundAndGroupUITests: XCTestCase {
    #if LAA_BUILD
    private func openBackground(_ app: XCUIApplication) {
        let menu = app.buttons["conversation.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        menu.tap()
        let choice = app.buttons["conversation.background"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
        XCTAssertTrue(app.buttons["background.choice.paper"].waitForExistence(timeout: 5))
    }

    func testAllBackgroundsAndPhotoControlsPersist() {
        let app = XCUIApplication()
        app.launchArguments = ["-LAA_UI_TEST_BACKGROUND"]
        app.launch()
        openBackground(app)
        for kind in ["paper", "tealNight", "ink"] {
            let choice = app.buttons["background.choice.\(kind)"]
            choice.tap()
            XCTAssertEqual(choice.value as? String, "Selected")
        }
        app.buttons["background.fixture.photo"].tap()
        let dim = app.sliders["background.photo.dim"]
        XCTAssertTrue(dim.waitForExistence(timeout: 5))
        dim.adjust(toNormalizedSliderPosition: 0.65)
        let blur = app.sliders["background.photo.blur"]
        blur.adjust(toNormalizedSliderPosition: 0.5)
        let dimValue = dim.value as? String
        let blurValue = blur.value as? String
        XCTAssertNotNil(dimValue)
        XCTAssertNotNil(blurValue)
        app.buttons["Done"].tap()
        app.terminate()
        app.launch()
        openBackground(app)
        XCTAssertTrue(app.sliders["background.photo.dim"].exists)
        XCTAssertTrue(app.sliders["background.photo.blur"].exists)
        XCTAssertEqual(app.sliders["background.photo.dim"].value as? String, dimValue)
        XCTAssertEqual(app.sliders["background.photo.blur"].value as? String, blurValue)
    }

    func testEmptyErrorAndOfflineGroupStates() {
        for (mode, expected) in [
            ("empty", "グループはまだありません。"),
            ("error", "グループを読み込めませんでした"),
            ("offline", "グループを開くには Hermes に接続してください。")
        ] {
            let app = XCUIApplication()
            app.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_GROUPS_STATE", mode]
            app.launch()
            let list = app.buttons["fixture.groups.list"]
            XCTAssertTrue(list.waitForExistence(timeout: 20))
            list.tap()
            let label = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", expected)).firstMatch
            XCTAssertTrue(label.waitForExistence(timeout: 15), mode)
            app.terminate()
        }
    }

    func testUnpairedBridgeExplainsPairingAndRejectsEmptyCode() {
        let app = XCUIApplication()
        app.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_UI_TEST_REAL_BRIDGE", "-LAA_UI_TEST_ISOLATED_BRIDGE"]
        app.launch()
        XCTAssertTrue(app.staticTexts["fixture.bridge.status"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.staticTexts["fixture.bridge.status"].label, "未接続")
        app.buttons["fixture.bridge"].tap()
        let pair = app.buttons["laa.bridge.pair"]
        XCTAssertTrue(pair.waitForExistence(timeout: 5))
        XCTAssertFalse(pair.isEnabled)
    }

    func testCreateAndUnsupportedParticipantChanges() {
        let app = XCUIApplication()
        app.launchArguments = ["-LAA_UI_TEST_BACKGROUND"]
        app.launch()
        // The expanded photo canvas must not intercept controls above it.
        openBackground(app)
        app.buttons["background.fixture.photo"].tap()
        app.buttons["Done"].tap()
        let create = app.buttons["fixture.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 20))
        create.tap()
        let name = app.textFields["groups.create.name"]
        guard name.waitForExistence(timeout: 5) else {
            XCTFail("The group creation screen did not open above the photo background")
            return
        }
        name.tap(); name.typeText("Planning")
        app.buttons["groups.employee.laa-ciel"].tap()
        app.buttons["groups.employee.laa-cto"].tap()
        let submit = app.buttons["groups.create.submit"]
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        XCTAssertTrue(app.staticTexts["fixture.created"].waitForExistence(timeout: 5))
        app.buttons["fixture.settings"].tap()
        let add = app.buttons["groups.member.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertFalse(add.isEnabled)
        XCTAssertFalse(app.buttons["groups.member.remove.laa-ciel"].isEnabled)
        XCTAssertTrue(app.staticTexts["この接続先には参加者を追加・削除する機能がありません。"].exists)
        let rename = app.textFields["groups.rename.name"]
        rename.tap()
        rename.typeText("2")
        app.buttons["groups.rename.submit"].tap()
        let created = app.staticTexts["fixture.created"]
        XCTAssertTrue(created.waitForExistence(timeout: 5))
        XCTAssertTrue(created.label.contains("2"))
        app.buttons["fixture.groups.list"].tap()
        let openCreate = app.buttons["groups.create.open"]
        XCTAssertTrue(openCreate.waitForExistence(timeout: 15))
        openCreate.tap()
        XCTAssertTrue(app.textFields["groups.create.name"].waitForExistence(timeout: 5))
    }

    func testWhitePhotoIsDrawnAndAutomaticallyDimmedInChat() throws {
        try assertWhitePhotoIsDrawn(surface: "chat")
    }

    func testWhitePhotoIsDrawnAndAutomaticallyDimmedInGroup() throws {
        try assertWhitePhotoIsDrawn(surface: "group")
    }

    private func assertWhitePhotoIsDrawn(surface: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_CAPTURE_SURFACE", surface,
                               "-LAA_CAPTURE_KIND", "photo", "-LAA_CAPTURE_WHITE"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["conversation.menu"].waitForExistence(timeout: 20), file: file, line: line)
        let deadline = Date().addingTimeInterval(15)
        var sample: Double = -1
        repeat {
            sample = try pixelBrightness(app.screenshot().image, x: 0.5, y: 0.67)
            if (0.35...0.47).contains(sample) { break }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        XCTAssertGreaterThan(sample, 0.35, "The white photo must reach the \(surface) surface", file: file, line: line)
        XCTAssertLessThanOrEqual(sample, 0.47, "A white photo with dim=0 must be automatically darkened", file: file, line: line)
        let luminance = sample <= 0.04045 ? sample / 12.92 : pow((sample + 0.055) / 1.055, 2.4)
        XCTAssertGreaterThanOrEqual(1.05 / (luminance + 0.05), 4.5, file: file, line: line)
        if surface == "chat" {
            let header = app.buttons["laa.employee.header"]
            XCTAssertTrue(header.waitForExistence(timeout: 5), file: file, line: line)
            XCTAssertTrue(app.buttons["laa.employee.call"].exists, file: file, line: line)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "staff-chat-photo-white"
            attachment.lifetime = .keepAlways
            add(attachment)
            header.tap()
            XCTAssertTrue(app.staticTexts["社長秘書・総合アドバイザー"].waitForExistence(timeout: 5), file: file, line: line)
        }
    }

    private func pixelBrightness(_ image: UIImage, x: Double, y: Double) throws -> Double {
        let cg = try XCTUnwrap(image.cgImage)
        let pixel = try XCTUnwrap(cg.cropping(to: CGRect(x: Int(Double(cg.width) * x), y: Int(Double(cg.height) * y), width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Double(max(bytes[0], bytes[1], bytes[2])) / 255
    }
    #else
    func testOnlyAvailableInLAABuild() throws { throw XCTSkip("LAA build only") }
    #endif
}

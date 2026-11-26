import XCTest

/// Photographs the Monet widget (HO-06): its views in the app's DEBUG
/// gallery, then the face's Smart Stack after the gallery handed the widget
/// a waiting decision as a relevant intent. A capture, run on its own; the
/// shots are its output.
final class LAAWatchMonetCaptureUITests: XCTestCase {
    func testMonetWidget() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-laa-watch-lab", "-laa-watch-monet-gallery", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        XCTAssertTrue(app.otherElements["laa.watch.monetGallery"].waitForExistence(timeout: 20)
                      || app.scrollViews["laa.watch.monetGallery"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2)
        shot(XCUIScreen.main.screenshot(), "gallery")
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1)
        shot(XCUIScreen.main.screenshot(), "gallery-2")
        // The face, then the Smart Stack under it (the crown turned up).
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        shot(XCUIScreen.main.screenshot(), "face")
        XCUIDevice.shared.rotateDigitalCrown(delta: 1.0)
        Thread.sleep(forTimeInterval: 3)
        shot(XCUIScreen.main.screenshot(), "smart-stack")
        XCUIDevice.shared.rotateDigitalCrown(delta: 1.0)
        Thread.sleep(forTimeInterval: 2)
        shot(XCUIScreen.main.screenshot(), "smart-stack-2")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.Carousel")
        let tree = XCTAttachment(string: springboard.debugDescription)
        tree.name = "carousel-tree"
        tree.lifetime = .keepAlways
        add(tree)
        XCUIDevice.shared.press(.home)
    }

    private func shot(_ screenshot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "watch-monet-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

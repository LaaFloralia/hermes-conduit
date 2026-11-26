#if LAA_BUILD
import XCTest

/// Photographs the staff Live Activities (HO-15) from the app's DEBUG
/// fixture (`-LAA_AMBIENT_ACTIVITY_FIXTURE call|turn`): the compact and the
/// expanded Dynamic Island, then the Lock Screen. Nothing is pushed and no
/// Bridge or Hermes is reached; the activities are the app's own requests.
/// A capture tool, not a behavior test (suites.json excludes it): the
/// shots are its output, read from the result bundle.
final class LAAAmbientCaptureUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() {
        continueAfterFailure = true
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func label(_ text: String) -> XCUIElement {
        springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// The fixture asks for notifications (the push capture needs them):
    /// allowed here, in either system language.
    private func allowNotifications() {
        for title in ["Allow", "許可"] {
            let button = springboard.alerts.buttons[title]
            if button.waitForExistence(timeout: 6) { button.tap(); return }
        }
    }

    private func capture(_ mode: String, name: String) {
        let app = XCUIApplication()
        app.launchArguments = ["-LAA_AMBIENT_ACTIVITY_FIXTURE", mode, "-LAA_UI_TEST_ISOLATED_BRIDGE",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchInLab()
        allowNotifications()
        Thread.sleep(forTimeInterval: 4)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        shot("\(mode)-island-compact")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.025)).press(forDuration: 1.2)
        Thread.sleep(forTimeInterval: 1.5)
        shot("\(mode)-island-expanded")
        add(XCTAttachment(string: springboard.debugDescription))
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        Thread.sleep(forTimeInterval: 2)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertTrue(label(name).waitForExistence(timeout: 10), "no card for \(name) on the Lock Screen")
        // The system asks once under the first card; allowed, then shot clean.
        let allow = springboard.buttons["Allow"]
        if allow.exists { allow.tap(); Thread.sleep(forTimeInterval: 1.5) }
        shot("\(mode)-lock")
        // Back to the Home Screen for the next capture.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1.5)
        app.terminate()
    }

    func testCall() { capture("call", name: "Morgan") }

    /// Monet's report and Morgan's decision as the extension decorates
    /// them (the app's local-notification fixture), on the Home Screen and
    /// in Notification Center.
    func testNotifications() {
        let app = XCUIApplication()
        app.launchArguments = ["-LAA_AMBIENT_NOTIFICATION_FIXTURE", "-LAA_UI_TEST_ISOLATED_BRIDGE",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchInLab()
        allowNotifications()
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(label("朝の報告").waitForExistence(timeout: 15), "no report banner")
        shot("notification-monet-report")
        XCTAssertTrue(label("経費").waitForExistence(timeout: 15), "no decision banner")
        shot("notification-decision-cfo")
        Thread.sleep(forTimeInterval: 6)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.005))
            .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.7)))
        Thread.sleep(forTimeInterval: 2)
        shot("notification-center")
        XCUIDevice.shared.press(.home)
        app.terminate()
    }

    func testTurn() { capture("turn", name: "Monet") }
}
#endif

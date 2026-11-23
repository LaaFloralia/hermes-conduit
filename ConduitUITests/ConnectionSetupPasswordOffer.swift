import XCTest

/// The OS may offer to save a synthetic password when Setup leaves the
/// credentials step, before the wizard has tested or applied the settings.
/// Decline only that offer so the fixture does not modify simulator Passwords.
struct ConnectionSetupPasswordOffer {
    private static let titles = ["Save Password?", "パスワードを保存しますか？", "パスワードを保存しますか?"]
    private static let declines = ["Not Now", "今はしない", "あとで"]

    private static func decline(in surface: XCUIElement) -> Bool {
        guard titles.contains(where: { surface.staticTexts[$0].exists }) else { return false }
        for label in declines {
            let button = surface.buttons[label].firstMatch
            if button.exists && button.isHittable {
                button.tap()
                return true
            }
        }
        return false
    }

    static func reveal(_ element: XCUIElement, in app: XCUIApplication, test: XCTestCase) {
        let isTestAction = element.identifier == "setup.test.run"
        let monitor = isTestAction ? test.addUIInterruptionMonitor(withDescription: "Save synthetic Setup password") {
            decline(in: $0)
        } : nil
        defer { if let monitor { test.removeUIInterruptionMonitor(monitor) } }
        for _ in 0..<6 {
            if element.isHittable { return }
            if isTestAction, decline(in: app) || decline(in: XCUIApplication(bundleIdentifier: "com.apple.springboard")) {
                continue
            }
            // The gesture also gives XCTest a chance to deliver a modal
            // system interruption that is not in either app's reportable tree.
            app.swipeUp()
        }
    }
}

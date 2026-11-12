#if LAA_BUILD
import XCTest

/// Asking before an agent operates the iPhone in use, end to end on the
/// simulator: a real push-to-start through the APNs sandbox starts the Live
/// Activity, and the owner's answer in the Dynamic Island reaches the Bridge.
/// Needs `scripts/laa/phone-use-ui-fixture.mjs` running under 1Password
/// (skipped otherwise) and a Debug build signed with the push entitlement.
final class LAAPhoneUseUITests: XCTestCase {
    private let port = Int(ProcessInfo.processInfo.environment["LAA_PHONE_USE_FIXTURE_PORT"] ?? "") ?? 19593
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    private func control(_ path: String) -> [String: Any]? {
        let done = expectation(description: path)
        var payload: [String: Any]?
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(port + 1)\(path)")!) { data, _, _ in
            if let data { payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 30)
        return payload
    }

    private func poll(_ seconds: TimeInterval, _ check: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if check() { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Pair once with the fixture, then let the app hand over its
    /// push-to-start token and its own push token for the wake (it retries
    /// when it becomes active).
    private func pairedAndRegistered() throws {
        guard control("/registered") != nil else { throw XCTSkip("Start scripts/laa/phone-use-ui-fixture.mjs") }
        let ready = { (r: [String: Any]?) in r?["registered"] as? Bool == true }
        if ready(control("/registered")) { return }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "work", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchEnvironment["LAA_BRIDGE_DEFAULT_ADDRESS"] = "http://127.0.0.1:\(port)"
        app.launch()
        if app.buttons["work.connect"].waitForExistence(timeout: 20) {
            let code = try XCTUnwrap(control("/code")?["code"] as? String)
            app.buttons["work.connect"].tap()
            let field = app.secureTextFields["laa.bridge.code"]
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            field.tap(); field.typeText(code)
            let pair = app.buttons["laa.bridge.pair"]
            if !pair.isHittable { app.swipeUp() }
            pair.tap()
            XCTAssertTrue(app.buttons["work.connect"].waitForNonExistence(timeout: 20))
        }
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(poll(150) { ready(control("/registered")) }, "push-to-start token never reached the Bridge")
        // The app's own push token (for the wake) usually comes with it; note whether it did.
        _ = poll(20) { control("/registered")?["wake"] as? Bool == true }
        add(XCTAttachment(string: "registration: \(control("/registered") ?? [:])"))
    }

    /// Ask with the app in the background (the owner is elsewhere on the phone).
    private func ask(timeout: Int = 60) throws -> String {
        try pairedAndRegistered()
        XCUIDevice.shared.press(.home)
        let asked = try XCTUnwrap(control("/ask?timeout=\(timeout)"))
        return try XCTUnwrap((asked["request"] as? [String: Any])?["id"] as? String, "ask failed: \(asked)")
    }

    /// The island's text in any form (expanded text, compact icon label).
    private func anyLabel(_ label: String) -> XCUIElement {
        springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
    }

    private func status(_ id: String) -> String? { control("/status?id=\(id)")?["status"] as? String }

    /// Whether the activity's update token reached the Bridge (the system
    /// wakes the app for it), so the Mac can end the activity by push.
    private func noteActivityToken(_ id: String) {
        let arrived = poll(20) { control("/status?id=\(id)")?["hasActivityToken"] as? Bool == true }
        add(XCTAttachment(string: "activity token reached the Bridge within 20 s: \(arrived)"))
    }

    /// The island's button: shown expanded when the activity starts; if it
    /// has folded into the compact island, a long press opens it again.
    private func islandButton(_ label: String) -> XCUIElement? {
        let button = springboard.buttons[label]
        if button.waitForExistence(timeout: 15) { return button }
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.025)).press(forDuration: 1.2)
        if button.waitForExistence(timeout: 5) { return button }
        add(XCTAttachment(string: springboard.debugDescription))
        return nil
    }

    func testAllowThenOperatingThenEnd() throws {
        let id = try ask()
        XCTAssertTrue(springboard.staticTexts["iPhoneを操作してよいですか"].waitForExistence(timeout: 20))
        shot("1-ask")
        noteActivityToken(id)
        let allow = try XCTUnwrap(islandButton("許可"))
        allow.tap()
        XCTAssertTrue(poll(20) { status(id) == "allowed" })
        Thread.sleep(forTimeInterval: 2)
        _ = islandButton("停止")
        shot("2-operating")
        XCTAssertTrue(springboard.staticTexts["iPhoneを操作中"].exists)
        let ended = try XCTUnwrap(control("/end?id=\(id)"))
        add(XCTAttachment(string: "end push: \(ended["endPush"] ?? "none"), wake: \(ended["wake"] ?? "none")"))
        // Without the activity's update token (iOS may give none) the Mac
        // wakes the app instead, which reads the request and ends it.
        // Neither reached it (the simulator may give neither token): the app
        // still takes it down the next time it runs.
        if !anyLabel("iPhoneを操作中").waitForNonExistence(timeout: 30) {
            add(XCTAttachment(string: "no end push or wake reached the activity; opening the app"))
            XCUIApplication().activate(); Thread.sleep(forTimeInterval: 3); XCUIDevice.shared.press(.home)
        }
        XCTAssertTrue(anyLabel("iPhoneを操作中").waitForNonExistence(timeout: 30))
        shot("3-ended")
    }

    func testDontAllow() throws {
        let id = try ask()
        let deny = try XCTUnwrap(islandButton("許可しない"))
        deny.tap()
        XCTAssertTrue(poll(20) { status(id) == "denied" })
        XCTAssertTrue(springboard.staticTexts["iPhoneを操作してよいですか"].waitForNonExistence(timeout: 20))
        shot("4-denied")
    }

    func testNoAnswerExpires() throws {
        let id = try ask(timeout: 30)
        XCTAssertTrue(springboard.staticTexts["iPhoneを操作してよいですか"].waitForExistence(timeout: 20))
        noteActivityToken(id)
        XCTAssertTrue(poll(40) { status(id) == "expired" })
        Thread.sleep(forTimeInterval: 2)
        shot("5-expired")
        // Gone, not left as a stale question: the end push or the wake took
        // it down, or else the app does when it next runs.
        if !anyLabel("iPhoneを操作してよいですか").waitForNonExistence(timeout: 30) {
            add(XCTAttachment(string: "no end push or wake reached the expired activity; opening the app"))
            XCUIApplication().activate(); Thread.sleep(forTimeInterval: 3); XCUIDevice.shared.press(.home)
        }
        XCTAssertTrue(anyLabel("iPhoneを操作してよいですか").waitForNonExistence(timeout: 30))
        XCTAssertTrue(anyLabel("時間切れ").waitForNonExistence(timeout: 30))
        shot("5b-expired-gone")
    }

    func testStopWhileOperating() throws {
        let id = try ask()
        try XCTUnwrap(islandButton("許可")).tap()
        XCTAssertTrue(poll(20) { status(id) == "allowed" })
        Thread.sleep(forTimeInterval: 2)
        try XCTUnwrap(islandButton("停止")).tap()
        XCTAssertTrue(poll(20) { status(id) == "stopped" })
        shot("6-stopped")
    }
}
#endif

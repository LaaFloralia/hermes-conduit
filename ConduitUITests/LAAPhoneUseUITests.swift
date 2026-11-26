#if LAA_BUILD
import XCTest

/// A local simctl notification transports the Bridge's start APS; its
/// ActivityKit UI and answers still go through the real intent and Bridge.
final class LAAPhoneUseUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    private func control(_ path: String) -> [String: Any]? {
        guard let data = try? LabUI.data(LabUI.fixture("phone-use-control"), path, acceptHTTPError: true) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
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

    private func pairedAndRegistered() throws -> XCUIApplication {
        try XCTSkipUnless(LabUI.active, "Run suite.py run integration for the local simctl connector.")
        continueAfterFailure = false
        _ = try XCTUnwrap(control("/reset-start"))
        let app = XCUIApplication()
        app.launchArguments = ["-laa-tab", "work", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchEnvironment["LAA_BRIDGE_DEFAULT_ADDRESS"] = try XCTUnwrap(LabUI.fixture("phone-use"))
        app.launchEnvironment["LAA_LAB_PHONE_USE_PUSH"] = "1"
        app.launchInLab()
        let connect = app.buttons["work.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 20))
        let code = try XCTUnwrap(control("/code")?["code"] as? String)
        connect.tap()
        let field = app.secureTextFields["laa.bridge.code"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText(code)
        let pair = app.buttons["laa.bridge.pair"]
        if !pair.isHittable { app.swipeUp() }
        pair.tap()
        XCTAssertTrue(connect.waitForNonExistence(timeout: 20))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(poll(20) { control("/registered")?["registered"] as? Bool == true })
        return app
    }

    private func ask(timeout: Int = 60) throws -> String {
        let app = try pairedAndRegistered()
        let simulator = try XCTUnwrap(LabUI.environment["LAA_LAB_SIMULATOR"])
        // App-originated Activity.request must run in the foreground. The
        // activity's buttons are then exercised outside the app as before.
        // activate() returns before the state settles after the Home press.
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let asked = try XCTUnwrap(control("/ask?timeout=\(timeout)&simulator=\(simulator)"))
        XCTAssertEqual(asked["ok"] as? Bool, true, "local push failed: \(asked)")
        let id = try XCTUnwrap((asked["request"] as? [String: Any])?["id"] as? String)
        XCTAssertTrue(poll(15) { control("/status?id=\(id)")?["hasActivityToken"] as? Bool == true },
                      "local push did not create a Live Activity")
        XCUIDevice.shared.press(.home)
        return id
    }

    /// The island's text in any form (expanded text, compact icon label).
    private func anyLabel(_ label: String) -> XCUIElement {
        springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
    }

    private func status(_ id: String) -> String? { control("/status?id=\(id)")?["status"] as? String }

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
        let allow = try XCTUnwrap(islandButton("許可"))
        XCTAssertTrue(springboard.staticTexts["iPhoneを操作してよいですか"].exists)
        shot("1-ask")
        let allowFrame = allow.frame
        allow.tap()
        XCTAssertTrue(poll(20) { status(id) == "allowed" })
        Thread.sleep(forTimeInterval: 2)
        let stop = try XCTUnwrap(islandButton("Stop"))
        shot("2-operating")
        XCTAssertTrue(springboard.staticTexts["iPhoneを操作中"].exists)
        XCTAssertLessThan(stop.frame.maxY, allowFrame.minY, "Stop must stay above the former permission row")
        springboard.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: allowFrame.midX, dy: allowFrame.midY)).tap()
        XCTAssertFalse(poll(3) { status(id) == "stopped" }, "A repeated tap at Allow must not trigger Stop")
        XCTAssertEqual(status(id), "allowed", "A repeated tap at Allow must not stop the operation")
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
        let id = try ask(timeout: 40)
        _ = try XCTUnwrap(islandButton("許可"))
        XCTAssertTrue(springboard.staticTexts["iPhoneを操作してよいですか"].exists)
        XCTAssertTrue(poll(45) { status(id) == "expired" })
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
        try XCTUnwrap(islandButton("Stop")).tap()
        XCTAssertTrue(poll(20) { status(id) == "stopped" })
        shot("6-stopped")
    }
}
#endif

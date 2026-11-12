#if LAA_BUILD
import XCTest

/// The composer's model · effort chip shows what Hermes reports for each
/// employee's running agent, and 「不明」 for what it does not report
/// (owner, 2026-11-12).
final class LAAChatRuntimeChipUITests: XCTestCase {
    private func launch(profile: String, runtime: String?, dark: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-LAA_UI_TEST_BACKGROUND", "-LAA_V2_CHAT_FIXTURE", "simple",
                               "-LAA_CAPTURE_SURFACE", "chat", "-LAA_CAPTURE_KIND", "paper",
                               "-LAA_FIXTURE_PUSH_CHAT", "-LAA_FIXTURE_PROFILE", profile]
            + (runtime.map { ["-LAA_FIXTURE_RUNTIME", $0] } ?? []) + (dark ? ["-LAA_V2_DARK"] : [])
        app.launch()
        XCTAssertTrue(app.staticTexts["fixture.capture.ready"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.textViews["composer.field"].waitForExistence(timeout: 15))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    private func chipValue(_ app: XCUIApplication) -> String {
        let chip = app.descendants(matching: .any)["composer.runtime"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        let field = app.textViews["composer.field"]
        XCTAssertGreaterThanOrEqual(chip.frame.minY, field.frame.maxY - 1, "the chip sits in the row under the field")
        return chip.value as? String ?? ""
    }

    func testEachEmployeeShowsItsOwnRunningModelAndEffort() {
        let cases: [(profile: String, runtime: String?, expected: String)] = [
            ("laa-monet", "claude-opus-5-5,claude,high", "Opus 5.5 · High"),
            ("laa-cto", "deepseek-v4.1-flash,laa-dsh,xhigh", "DeepSeek V4.1 Flash · XHigh"),
            ("laa-cfo", "deepseek-v4.1-flash,laa-dsh,", "DeepSeek V4.1 Flash · 不明"),
            ("laa-cso", nil, "不明 · 不明"),
        ]
        for (profile, runtime, expected) in cases {
            for dark in [false, true] {
                let app = launch(profile: profile, runtime: runtime, dark: dark)
                XCTAssertEqual(chipValue(app), expected, profile)
                capture(app, "chip-\(profile)-\(dark ? "dark" : "light")")
                app.terminate()
            }
        }
    }
}
#endif

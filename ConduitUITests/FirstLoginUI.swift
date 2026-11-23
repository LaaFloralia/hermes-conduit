import XCTest

extension XCUIApplication {
    /// Enter the actual first-run login flow without a simulator-wide erase
    /// or modifying the dashboard registry another test may have populated.
    static func firstLoginFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CONDUIT_UITEST"] = "1"
        app.launchArguments.append("-CONDUIT_UI_TEST_FRESH_LOGIN")
        return app
    }
}

#if LAA_BUILD
import XCTest
import UIKit

final class LAAShellNavigationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testTabLabelsNavigationAndSettings() {
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "source"]
        app.launch()
        XCTAssertTrue(app.buttons["Chats"].waitForExistence(timeout: 30))
        for name in ["Chats", "Work", "Brain", "Assets", "Usage"] {
            XCTAssertTrue(app.buttons[name].exists, "Missing tab \(name)")
        }
        app.buttons["Work"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Work"].waitForExistence(timeout: 10))
        app.buttons["Brain"].tap()
        XCTAssertTrue(app.navigationBars["Brain"].waitForExistence(timeout: 10))
        app.buttons["Usage"].tap()
        XCTAssertTrue(app.navigationBars["Usage"].waitForExistence(timeout: 10))
        app.buttons["Assets"].tap()
        XCTAssertTrue(app.navigationBars["Assets"].waitForExistence(timeout: 10))
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        // The existing Settings sheet uses a custom header, not a navigation bar.
        XCTAssertTrue(app.buttons["settings.chat"].waitForExistence(timeout: 10))
    }

    func testDocumentHidesTabBarAndBackRestoresIt() {
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "brain", "-laa-brain-fixture", "normal"]
        app.launch()
        let note = app.staticTexts["Start"]
        XCTAssertTrue(note.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Usage"].exists)
        note.tap()
        let back = app.buttons["laa.brain.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Usage"].exists)
        back.tap()
        XCTAssertTrue(app.buttons["Usage"].waitForExistence(timeout: 10))
    }

    func testExistingChatRouteHidesTabBar() {
        let app = XCUIApplication()
        app.launchEnvironment["CONDUIT_UITEST"] = "1"
        let link = "conduit://widget/v1/resume?dashboard=8d516b21-6b3c-4f5a-a0d6-6f6e8b73a901&profile=work&kind=dashboard&scope=work&session=widget-ui-test-session&unverified=false"
        app.launchArguments += ["-CONDUIT_UI_TEST_CONNECTED_DASHBOARD", "https://conduit-ui-test.invalid",
                                "-CONDUIT_UI_TEST_PROFILES", "work,staging",
                                "-CONDUIT_UI_TEST_WIDGET_URL", link]
        app.launch()
        XCTAssertTrue(app.textViews["composer.field"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["Usage"].exists)
    }

    func testCallPresentationHidesTabBar() {
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "source", "-LAA_UI_TEST_CALL_COVERS_TABS"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Assets"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["Usage"].exists)
    }
    /// Opt-in only: the operator places a one-time code on this dedicated
    /// simulator's pasteboard. The code is pasted into SecureField, never
    /// passed as a test argument or printed by the test.
    func testRealBridgePairingWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["LAA_REAL_BRIDGE_TEST"] == "1" else {
            throw XCTSkip("Live Bridge pairing requires the dedicated simulator and an operator-issued code.")
        }
        defer { UIPasteboard.general.items = [] }
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "source"]
        app.launch()
        let connect = app.buttons["Macに接続する"]
        XCTAssertTrue(connect.waitForExistence(timeout: 30))
        connect.tap()
        let code = app.secureTextFields["laa.bridge.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        code.tap()
        code.press(forDuration: 1.2)
        let paste = app.menuItems.matching(NSPredicate(format: "label IN %@", ["Paste", "ペースト"])).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 10))
        paste.tap()
        let pair = app.buttons["laa.bridge.pair"]
        XCTAssertTrue(pair.waitForExistence(timeout: 10))
        XCTAssertTrue(pair.isEnabled)
        pair.tap()
        XCTAssertTrue(app.staticTexts["この画面は準備中です。"].waitForExistence(timeout: 30))
    }
    func testRealBridgeRevocationWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["LAA_REAL_BRIDGE_TEST"] == "1" else {
            throw XCTSkip("Live Bridge revocation requires the dedicated simulator.")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "source"]
        app.launch()
        XCTAssertTrue(app.staticTexts["この端末の接続が無効になりました。新しいコードで接続してください。"].waitForExistence(timeout: 30))
    }
}
#endif

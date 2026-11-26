#if LAA_BUILD
import XCTest
import UIKit

final class LAAShellNavigationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testTabLabelsNavigationAndSettings() {
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "work", "-LAA_UI_TEST_ISOLATED_BRIDGE"]
        app.launchInLab()
        for name in ["Chat", "Today", "Doc", "Studio", "Work"] {
            XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 30), "Missing tab \(name)")
        }
        XCTAssertTrue(app.buttons["work.section.tasks"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["work.section.projects"].isSelected, "Work opens on Projects (owner, 2026-11-23)")
        app.buttons["Doc"].tap()
        XCTAssertTrue(app.staticTexts["laa.brain.title"].waitForExistence(timeout: 10))
        app.buttons["Work"].tap()
        for name in ["sessions", "tasks"] {
            let segment = app.buttons["work.section.\(name)"]
            XCTAssertTrue(segment.waitForExistence(timeout: 10))
            segment.tap()
            XCTAssertTrue(segment.isSelected)
        }
        LAAWorkSectionUI.open("routines", in: app)
        let more = app.buttons["work.section.more"]
        XCTAssertTrue(more.isSelected)
        XCTAssertEqual(more.value as? String, "Routines")
        XCTAssertTrue(app.buttons["work.section.projects"].exists)
        XCTAssertFalse(app.buttons["work.section.skills"].exists)
        XCTAssertTrue(app.buttons["work.usage"].exists)
        // Unpaired, AI usage waits for the Mac like the other Work sections.
        XCTAssertTrue(app.buttons["work.connect"].waitForExistence(timeout: 10))
        app.buttons["Studio"].tap()
        // Studio opens on its Studio page; Drive is the page beside it, not a pushed screen.
        XCTAssertTrue(app.staticTexts["laa.assets.title"].waitForExistence(timeout: 10))
        let studio = app.buttons["studio.section.studio"]
        XCTAssertTrue(studio.waitForExistence(timeout: 10))
        XCTAssertTrue(studio.isSelected)
        let drive = app.buttons["studio.drive"]
        XCTAssertTrue(drive.waitForExistence(timeout: 10)); drive.tap()
        XCTAssertTrue(drive.isSelected)
        XCTAssertFalse(studio.isSelected)
        let settings = app.buttons["laa.settings.open"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        XCTAssertTrue(app.buttons["settings.chat"].waitForExistence(timeout: 10))
    }

    func testDocumentHidesTabBarAndBackRestoresIt() {
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "brain", "-laa-brain-local-fixture", "-LAA_UI_TEST_ISOLATED_BRIDGE"]
        app.launchInLab()
        let company = app.buttons["laa.brain.folder.Company"]
        XCTAssertTrue(company.waitForExistence(timeout: 30))
        if !company.isHittable { app.swipeUp() }
        company.tap()
        let note = app.buttons.matching(identifier: "laa.brain.note")
            .matching(NSPredicate(format: "label == %@", "Start")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Work"].exists)
        note.tap()
        let back = app.buttons["laa.brain.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Work"].exists)
        back.tap()
        XCTAssertTrue(app.buttons["Work"].waitForExistence(timeout: 10))
    }

    func testExistingChatRouteHidesTabBar() {
        let app = XCUIApplication()
        app.launchEnvironment["CONDUIT_UITEST"] = "1"
        let link = "conduit://widget/v1/resume?dashboard=8d516b21-6b3c-4f5a-a0d6-6f6e8b73a901&profile=work&kind=dashboard&scope=work&session=widget-ui-test-session&unverified=false"
        app.launchArguments += ["-CONDUIT_UI_TEST_CONNECTED_DASHBOARD", "https://conduit-ui-test.invalid",
                                "-CONDUIT_UI_TEST_PROFILES", "work,staging",
                                "-CONDUIT_UI_TEST_WIDGET_URL", link]
        app.launchInLab()
        XCTAssertTrue(app.textViews["composer.field"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["Work"].exists)
    }

    func testCallPresentationHidesTabBar() {
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "brain", "-LAA_UI_TEST_CALL_COVERS_TABS"]
        app.launchInLab()
        XCTAssertTrue(app.staticTexts["laa.brain.title"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["Work"].exists)
    }
    /// Opt-in only: the operator places a one-time code on this dedicated
    /// simulator's pasteboard. The code is pasted into SecureField, never
    /// passed as a test argument or printed by the test.
    func testRealBridgePairingWhenExplicitlyEnabled() throws {
        if LabUI.active {
            let app = WorkLaneUI.launch()
            try WorkLaneUI.pair(app)
            WorkLaneUI.sessions(app)
            return
        }
        guard ProcessInfo.processInfo.environment["LAA_REAL_BRIDGE_TEST"] == "1" else {
            throw XCTSkip("Live Bridge pairing requires the dedicated simulator and an operator-issued code.")
        }
        defer { UIPasteboard.general.items = [] }
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "work"]
        app.launchInLab()
        XCTAssertTrue(app.buttons["Drive"].waitForExistence(timeout: 30)); app.buttons["Drive"].tap()
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
        if LabUI.active {
            let app = WorkLaneUI.launch()
            let tag = try WorkLaneUI.pair(app)
            WorkLaneUI.sessions(app)
            XCTAssertEqual(try WorkLaneUI.setup("revoke", ["tag": tag])["revoked"] as? Bool, true)
            app.terminate(); app.launchInLab()
            XCTAssertTrue(app.staticTexts["この端末の接続は失効しています。新しいコードで接続してください。"].waitForExistence(timeout: 30))
            return
        }
        guard ProcessInfo.processInfo.environment["LAA_REAL_BRIDGE_TEST"] == "1" else {
            throw XCTSkip("Live Bridge revocation requires the dedicated simulator.")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-laa-tab", "work"]
        app.launchInLab()
        XCTAssertTrue(app.buttons["Drive"].waitForExistence(timeout: 30)); app.buttons["Drive"].tap()
        XCTAssertTrue(app.staticTexts["この端末の接続が無効になりました。新しいコードで接続してください。"].waitForExistence(timeout: 30))
    }
}
#endif

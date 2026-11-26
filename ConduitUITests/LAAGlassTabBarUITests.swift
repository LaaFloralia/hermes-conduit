#if LAA_BUILD && !targetEnvironment(macCatalyst)
import XCTest

final class LAAGlassTabBarUITests: XCTestCase {
    private let destinations = [("Chat", "laa.chats.heading"), ("Work", "work.section.projects"),
                                ("Today", "laa.today.title"), ("Doc", "laa.brain.title"),
                                ("Studio", "laa.assets.title")]

    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ extra: [String] = [], tab: String = "chats") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CONDUIT_UITEST"] = "1"
        app.launchArguments = ["-laa-tab", tab, "-LAA_UI_TEST_ISOLATED_BRIDGE",
                               "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD", "https://glass-tabbar-test.invalid"] + extra
        app.launchInLab()
        return app
    }

    private func assertCollapsed(_ app: XCUIApplication, selected: String, file: StaticString = #filePath, line: UInt = #line) {
        let icon = app.laaSettingsEntry
        XCTAssertTrue(icon.waitForExistence(timeout: 10), selected, file: file, line: line)
        XCTAssertTrue(icon.isHittable, selected, file: file, line: line)
        XCTAssertEqual(icon.label, "Hortensia, Settings", file: file, line: line)
        XCTAssertFalse(app.buttons["laa.settings.open"].exists, selected, file: file, line: line)
        // XCUI snapshots SwiftUI's .isTabBar group as Other. The bottom row's
        // named buttons, not the decorative unnamed children, are its controls.
        let tabs = app.buttons.matching(NSPredicate(format: "label != ''")).allElementsBoundByIndex.filter {
            $0.identifier != "laa.tabbar.app" && abs($0.frame.midY - icon.frame.midY) <= 1 && $0.frame.maxX <= icon.frame.minX
        }
        XCTAssertEqual(tabs.map(\.label).sorted(), destinations.map { $0.0 }.sorted(),
                       "Five named tabs on \(selected):\n\(app.debugDescription)", file: file, line: line)
        XCTAssertEqual(tabs.filter(\.isSelected).map(\.label), [selected], file: file, line: line)
        XCTAssertTrue(tabs.allSatisfy(\.isHittable), selected, file: file, line: line)
    }

    private func assertDestinationButtonsHidden(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        for (title, _) in destinations {
            XCTAssertFalse(app.laaTab(title).exists, "Unexpected tab: \(title)", file: file, line: line)
        }
    }

    func testFiveNamedTabsAndSelectionOnEveryRoot() {
        let app = launch(["-LAA_UI_TEST_CHATS"])
        for (title, marker) in destinations {
            let tab = app.laaTab(title)
            XCTAssertTrue(tab.waitForExistence(timeout: 10), title)
            if title != "Chat" { tab.tap() }
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: marker).firstMatch
                .waitForExistence(timeout: 10), "Missing \(title) root")
            assertCollapsed(app, selected: title)
        }
    }

    func testCardShowsFiveRowsAndOutsideTapCollapses() {
        let app = launch(["-LAA_UI_TEST_CHATS"])
        assertCollapsed(app, selected: "Chat")
        app.laaSettingsEntry.tap()
        let card = app.descendants(matching: .any)["laa.tabbar.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        for row in ["mac", "mode", "theme", "notifications", "settings"] {
            XCTAssertTrue(card.descendants(matching: .any).matching(identifier: "laa.tabbar.\(row)").firstMatch.exists,
                          "Missing settings card row: \(row)\n\(card.debugDescription)")
        }
        XCTAssertTrue(app.buttons["laa.tabbar.close"].isHittable)
        XCTAssertFalse(app.laaSettingsEntry.exists)
        assertDestinationButtonsHidden(app)
        let outside = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        XCTAssertFalse(card.frame.contains(outside.screenPoint))
        outside.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 10))
        assertCollapsed(app, selected: "Chat")
    }

    private func attachScreen(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testExpandedCardHidesRootToolbarFromAccessibility() {
        let app = launch(tab: "studio")
        let drive = app.buttons["studio.drive"]
        XCTAssertTrue(drive.waitForExistence(timeout: 10))
        drive.tap()
        let layout = app.buttons["laa.drive.layout"]
        XCTAssertTrue(layout.waitForExistence(timeout: 10))
        XCTAssertTrue(layout.isHittable, "Drive layout is a visible root toolbar action before opening the card")

        let icon = app.laaSettingsEntry
        XCTAssertTrue(icon.isHittable)
        icon.tap()
        let card = app.descendants(matching: .any)["laa.tabbar.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        attachScreen(app, named: "drive-card-expanded")
        let inTree = layout.exists
        let hittable = inTree && layout.isHittable
        // XCTest cannot traverse VoiceOver focus. Require the background action
        // to be absent from its accessibility snapshot, not merely covered.
        XCTAssertFalse(inTree, "Drive layout leaked behind the card (hittable: \(hittable))\n\(app.debugDescription)")

        app.buttons["laa.tabbar.close"].tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 10))
        XCTAssertTrue(layout.waitForExistence(timeout: 10))
        XCTAssertTrue(layout.isHittable)
    }

    func testFirstLoginFootActionsClearCollapsedBar() {
        let app = launch(["-LAA_UI_TEST_FORCE_LOGIN", "-LAA_UI_TEST_FIRST_LOGIN"])
        let icon = app.laaSettingsEntry
        XCTAssertTrue(icon.waitForExistence(timeout: 10))
        XCTAssertTrue(icon.isHittable)
        let tab = app.laaTab("Chat")
        XCTAssertTrue(tab.isHittable)
        let barTop = min(icon.frame.minY, tab.frame.minY)
        let setup = app.buttons["login.connection-setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 10))
        attachScreen(app, named: "first-login-tab-clearance")
        for action in [app.buttons["login.connect"], setup] {
            XCTAssertTrue(action.exists)
            // On a small screen (iPhone SE) the login page scrolls: bring the whole action above the bar (a
            // partly clipped button is already hittable), then require it to rest there, never under the glass.
            for _ in 0..<3 where !action.isHittable || action.frame.maxY > barTop { app.scrollViews.firstMatch.swipeUp() }
            XCTAssertTrue(action.isHittable, "\(action.identifier) cannot be reached above the tab bar")
            XCTAssertLessThanOrEqual(action.frame.maxY, barTop,
                                     "\(action.identifier) overlaps the glass tab bar\n\(app.debugDescription)")
        }
        XCTAssertTrue(setup.isHittable)
    }

    func testCloseButtonCollapsesWithoutChangingSelection() {
        let app = launch(tab: "work")
        assertCollapsed(app, selected: "Work")
        app.laaSettingsEntry.tap()
        let close = app.buttons["laa.tabbar.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        XCTAssertTrue(close.isHittable)
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["laa.tabbar.card"].exists)
        assertCollapsed(app, selected: "Work")
    }

    func testSettingsRowOpensSheet() {
        let app = launch(["-LAA_UI_TEST_CHATS"])
        app.openLAASettings()
        XCTAssertTrue(app.buttons["settings.chat"].waitForExistence(timeout: 10))
        let done = app.buttons["laa.settings.done"]
        XCTAssertTrue(done.isHittable)
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["laa.tabbar.card"].exists)
        assertCollapsed(app, selected: "Chat")
    }

    func testConversationHidesBarAndBackRestoresIt() {
        // Deliver the seeded resume URL from the debug widget fixture; no Hermes or Bridge request is needed.
        let link = "conduit://widget/v1/resume?dashboard=8d516b21-6b3c-4f5a-a0d6-6f6e8b73a901&profile=work&kind=dashboard&scope=work&session=widget-ui-test-session&unverified=false"
        let app = launch(["-CONDUIT_UI_TEST_PROFILES", "work,staging",
                          "-CONDUIT_UI_TEST_WIDGET_URL", link, "-CONDUIT_UI_TEST_WIDGET_DELIVERY", "warm"])
        assertCollapsed(app, selected: "Chat")
        let deliver = app.buttons["widgetUITestDeliverURL"]
        XCTAssertTrue(deliver.waitForExistence(timeout: 10))
        deliver.tap()
        let composer = app.textViews["composer.field"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        XCTAssertTrue(app.laaSettingsEntry.waitForNonExistence(timeout: 10))
        assertDestinationButtonsHidden(app)
        let back = app.navigationBars.buttons["BackButton"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        XCTAssertTrue(back.isHittable)
        back.tap()
        XCTAssertTrue(composer.waitForNonExistence(timeout: 10))
        assertCollapsed(app, selected: "Chat")
    }
}
#endif

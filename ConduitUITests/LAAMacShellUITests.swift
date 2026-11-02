#if LAA_BUILD && targetEnvironment(macCatalyst)
import XCTest

/// The Mac window on the Catalyst destination: the sidebar lists and switches
/// every section, ⌘1–⌘7 reach them from the keyboard, and the Chat section
/// keeps its list with the detail column explaining itself until a
/// conversation opens.
///
/// Selecting a chat row and seeing the conversation beside it needs a Hermes
/// dashboard with the staff profiles, which this fixture-free target does not
/// have; the rule itself is covered by
/// `LAAMacCatalystTests.testChatDetailResolvesFromShownAndOpen`, and the live
/// path by the parent's Bridge check.
final class LAAMacShellUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private static let sections = ["chats", "work", "today", "brain", "studio", "drive", "usage"]

    private func launch(_ section: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-laa-mac-section", section]
        app.launch()
        return app
    }

    private func row(_ app: XCUIApplication, _ section: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "laa.mac.section.\(section)").firstMatch
    }

    func testSidebarListsEverySection() {
        let app = launch("chats")
        for section in Self.sections {
            XCTAssertTrue(row(app, section).waitForExistence(timeout: 30), "missing sidebar row \(section)")
        }
        // The Mac's own connection state sits under the sections.
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "laa.mac.connection").firstMatch.exists)
    }

    func testSidebarSwitchesSections() {
        let app = launch("work")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "work.segment").firstMatch
            .waitForExistence(timeout: 30))

        row(app, "usage").tap()
        XCTAssertTrue(app.buttons["laa.usage.refresh"].waitForExistence(timeout: 20),
                      "Usage did not open beside the sidebar")

        row(app, "brain").tap()
        XCTAssertTrue(app.staticTexts["laa.brain.title"].waitForExistence(timeout: 20),
                      "Brain did not open beside the sidebar")
    }

    func testCommandNumbersSwitchSections() {
        let app = launch("chats")
        XCTAssertTrue(row(app, "chats").waitForExistence(timeout: 30))

        app.typeKey("6", modifierFlags: .command) // Drive
        XCTAssertTrue(app.staticTexts["laa.assets.title"].waitForExistence(timeout: 20),
                      "⌘6 did not open Drive")

        app.typeKey("3", modifierFlags: .command) // Today
        XCTAssertTrue(app.staticTexts["laa.today.title"].waitForExistence(timeout: 20),
                      "⌘3 did not open Today")
    }

    /// Chat keeps its list; the detail column says what to do rather than
    /// showing an empty conversation.
    func testChatStartsWithListAndEmptyDetail() {
        let app = launch("chats")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "laa.chats.list").firstMatch
            .waitForExistence(timeout: 30), "the chat list is missing")
        let empty = app.descendants(matching: .any).matching(identifier: "laa.mac.chats.empty").firstMatch
        let signIn = app.buttons["laa.bridge.pair"]
        XCTAssertTrue(empty.waitForExistence(timeout: 10) || signIn.exists,
                      "the detail column showed neither the empty state nor sign-in")
    }
}
#endif

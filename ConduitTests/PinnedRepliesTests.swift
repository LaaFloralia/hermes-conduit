import XCTest
import UIKit
@testable import Conduit

/// Replies pinned to the top of their chat (#918).
final class PinnedRepliesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func reply(_ id: String, _ content: String, rowId: Int? = nil) -> ChatMessage {
        var message = ChatMessage(id: id, role: .assistant, content: content, timestamp: "")
        message.rowId = rowId
        return message
    }

    private func user(_ id: String, _ content: String) -> ChatMessage {
        ChatMessage(id: id, role: .user, content: content, timestamp: "")
    }

    private func pin(_ message: ChatMessage, session: String = "s1", at offset: TimeInterval = 0) -> PinnedReply {
        PinnedReply(sessionID: session, message: message, chatTitle: "Plan", pinnedAt: t0.addingTimeInterval(offset))
    }

    // MARK: - Finding a pin's reply

    func testExcerptFoldsWhitespaceAndCaps() {
        XCTAssertEqual(PinnedReply.excerpt(of: "  1. First\n\n2.  Second\t"), "1. First 2. Second")
        let long = String(repeating: "a", count: PinnedReply.excerptLength + 50)
        XCTAssertEqual(PinnedReply.excerpt(of: long).count, PinnedReply.excerptLength)
    }

    func testDurableIdFindsTheReplyAfterAReloadRenamedItsRow() {
        let pinned = pin(reply("live-7", "Twenty points", rowId: 42))
        let reloaded = [user("u1", "Go"), reply("r-42", "Twenty points", rowId: 42)]
        XCTAssertEqual(PinnedReplies.messageID(for: pinned, in: reloaded), "r-42")
    }

    func testDurableIdWinsOverTheSameOpeningWords() {
        // Two replies open the same way; the pinned one is the second.
        let pinned = pin(reply("b", "Sure, here is the plan", rowId: 9))
        let messages = [reply("a", "Sure, here is the plan", rowId: 5), reply("b", "Sure, here is the plan", rowId: 9)]
        XCTAssertEqual(PinnedReplies.messageID(for: pinned, in: messages), "b")
    }

    func testAReplyPinnedAsItArrivedIsFoundByItsTextOnceReloaded() {
        // Pinned before Hermes gave the row an id; the reload renames it.
        let pinned = pin(reply("live-3", "Step one.\nStep two."))
        let reloaded = [user("u1", "Go"), reply("r-12", "Step one. Step two.", rowId: 12)]
        XCTAssertEqual(PinnedReplies.messageID(for: pinned, in: reloaded), "r-12")
        // And it takes the durable id from there on.
        let refreshed = PinnedReplies.refreshed([pinned], in: reloaded)
        XCTAssertEqual(refreshed?.first?.rowId, 12)
        XCTAssertEqual(refreshed?.first?.messageID, "r-12")
        XCTAssertNil(PinnedReplies.refreshed(refreshed ?? [], in: reloaded), "nothing left to change")
    }

    func testOfTwoRepliesReadingTheSameTheTappedOneIsPinned() {
        // Live rows: no durable ids yet, and both replies say the same.
        let first = reply("live-1", "Done.")
        let second = reply("live-2", "Done.")
        let pinned = pin(second)
        XCTAssertEqual(PinnedReplies.messageID(for: pinned, in: [first, second]), "live-2")
        XCTAssertNil(PinnedReplies.pin(for: first, in: [pinned], messages: [first, second]),
                     "pinning the other one adds a pin instead of unpinning this one")
        XCTAssertNil(PinnedReplies.refreshed([pinned], in: [first, second]), "the right row is kept")
    }

    func testTwoPinsOnRepliesReadingTheSameKeepTheirOwnReplies() {
        // Both pinned as they arrived (no durable ids), then a reload gave
        // the rows new ids: the text is all that is left to go on.
        let first = pin(reply("live-1", "Done."), at: 0)
        let second = pin(reply("live-2", "Done."), at: 10)
        let reloaded = [reply("r-1", "Done.", rowId: 1), user("u", "And?"), reply("r-2", "Done.", rowId: 2)]
        let pins = [first, second]

        XCTAssertEqual(PinnedReplies.messageID(for: second, in: reloaded, among: pins), "r-2", "the newest pin keeps the latest reply")
        XCTAssertEqual(PinnedReplies.messageID(for: first, in: reloaded, among: pins), "r-1")
        XCTAssertEqual(PinnedReplies.pinnedMessageIDs(pins, in: reloaded), ["r-1", "r-2"])
        XCTAssertEqual(PinnedReplies.barOrder(pins, in: reloaded).map(\.id), [first.id, second.id])
        XCTAssertEqual(PinnedReplies.pin(for: reloaded[0], in: pins, messages: reloaded)?.id, first.id)
        let refreshed = PinnedReplies.refreshed(pins, in: reloaded)
        XCTAssertEqual(refreshed?.map(\.rowId), [1, 2], "each pin saves its own reply's durable id")
    }

    func testATextMatchNeverTakesAReplyAnotherPinHasById() {
        let byID = pin(reply("r-2", "Done.", rowId: 2), at: 0)
        let byText = pin(reply("live-9", "Done."), at: 10)
        let messages = [reply("r-1", "Done.", rowId: 1), reply("r-2", "Done.", rowId: 2)]
        let resolved = PinnedReplies.resolved([byText, byID], in: messages)
        XCTAssertEqual(resolved[byID.id], "r-2")
        XCTAssertEqual(resolved[byText.id], "r-1")
    }

    func testAUserMessageWithTheSameTextIsNeverThePin() {
        let pinned = pin(reply("live-1", "Yes"))
        XCTAssertNil(PinnedReplies.messageID(for: pinned, in: [user("live-1", "Yes")]))
    }

    func testAReplyNotLoadedIsNotFound() {
        let pinned = pin(reply("old", "From last week", rowId: 3))
        XCTAssertNil(PinnedReplies.messageID(for: pinned, in: [reply("new", "Today", rowId: 80)]))
    }

    // MARK: - The bar

    func testBarFollowsTheChatsOrderWithUnloadedPinsFirst() {
        let a = reply("a", "First answer", rowId: 10)
        let b = reply("b", "Second answer", rowId: 20)
        let messages = [a, user("u", "more"), b]
        // Pinned newest-reply first; the bar still reads as the chat does.
        let pins = [pin(b, at: 0), pin(a, at: 10), pin(reply("old", "Older", rowId: 1), at: 20)]
        XCTAssertEqual(PinnedReplies.barOrder(pins, in: messages).map(\.excerpt), ["Older", "First answer", "Second answer"])
    }

    func testBarCyclesFromTheLatestBackAndRoundAgain() {
        // Three pins: the bar starts on the latest (2) and steps back.
        XCTAssertEqual(PinnedReplies.nextBarIndex(after: 2, count: 3), 1)
        XCTAssertEqual(PinnedReplies.nextBarIndex(after: 1, count: 3), 0)
        XCTAssertEqual(PinnedReplies.nextBarIndex(after: 0, count: 3), 2)
        XCTAssertEqual(PinnedReplies.nextBarIndex(after: 0, count: 1), 0)
        XCTAssertEqual(PinnedReplies.nextBarIndex(after: 7, count: 3), 1, "a stale index clamps")
    }

    // MARK: - The overview

    func testOverviewGroupsByChatLatestPinFirst() {
        let pins = [
            pin(reply("a", "A1", rowId: 1), session: "s1", at: 0),
            pin(reply("b", "B1", rowId: 2), session: "s2", at: 5),
            pin(reply("c", "A2", rowId: 3), session: "s1", at: 10),
        ]
        let sections = PinnedReplies.overview(pins)
        XCTAssertEqual(sections.map(\.sessionID), ["s1", "s2"])
        XCTAssertEqual(sections.first?.pins.map(\.excerpt), ["A2", "A1"])
    }

    // MARK: - AppState

    @MainActor
    private func makeAppState(_ defaults: UserDefaults) -> AppState {
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.setActiveProfileForTesting("default")
        return appState
    }

    private func freshDefaults() -> UserDefaults {
        let name = "PinnedRepliesTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            XCTFail("Couldn't create the test settings store")
            return .standard
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    @MainActor
    func testPinningAReplyShowsInTheOpenChatAndSurvivesARelaunch() {
        let defaults = freshDefaults()
        let appState = makeAppState(defaults)
        appState.activeSessionId = "chat-1"
        let answer = reply("a", "1. Do this\n2. Then that", rowId: 7)
        appState.messages = [user("u", "Plan?"), answer, reply("b", "Anything else?", rowId: 8)]

        XCTAssertTrue(appState.canPinReplies)
        appState.togglePinnedReply(answer)
        XCTAssertEqual(appState.openChatPinnedMessageIDs, ["a"])
        XCTAssertEqual(appState.openChatPinnedReplies.map(\.excerpt), ["1. Do this 2. Then that"])

        let relaunched = makeAppState(defaults)
        relaunched.activeSessionId = "chat-1"
        relaunched.messages = [reply("a-reloaded", "1. Do this\n2. Then that", rowId: 7)]
        XCTAssertEqual(relaunched.openChatPinnedMessageIDs, ["a-reloaded"])
        XCTAssertEqual(relaunched.activePinnedReplies.count, 1)
    }

    @MainActor
    func testTogglingAPinnedReplyUnpinsIt() {
        let appState = makeAppState(freshDefaults())
        appState.activeSessionId = "chat-1"
        let answer = reply("a", "Twenty points", rowId: 7)
        appState.messages = [answer]
        appState.togglePinnedReply(answer)
        appState.togglePinnedReply(answer)
        XCTAssertTrue(appState.activePinnedReplies.isEmpty)
        XCTAssertTrue(appState.openChatPinnedMessageIDs.isEmpty)
    }

    // MARK: - Long-press menu

    @MainActor
    private func editMenu(_ bridge: SelectableTextView.Coordinator) -> UIMenu? {
        let textView = SelectableTextView.makeTextView()
        textView.attributedText = NSAttributedString(string: "Twenty points")
        let copy = UIAction(title: "Copy") { _ in }
        let suggested: [UIMenuElement] = [
            UIMenu(title: "", identifier: .standardEdit, options: .displayInline, children: [copy])
        ]
        let delegate: UITextViewDelegate = bridge
        return delegate.textView?(textView, editMenuForTextIn: NSRange(location: 0, length: 6), suggestedActions: suggested) ?? nil
    }

    @MainActor
    func testTheLongPressMenuPinsAndUnpinsTheReplyAfterQuote() throws {
        let appState = makeAppState(freshDefaults())
        appState.activeSessionId = "chat-1"
        let answer = reply("a", "Twenty points", rowId: 7)
        appState.messages = [answer]
        let bridge = SelectableTextView(text: "Twenty points").makeCoordinator()
        bridge.quoteAction = ChatQuoteAction(owner: appState) { _ in }
        bridge.pinReplyAction = try XCTUnwrap(ChatPinReplyAction(message: answer, appState: appState))

        let menu = try XCTUnwrap(editMenu(bridge))
        XCTAssertEqual(menu.children.count, 3)
        XCTAssertEqual((menu.children[0] as? UIMenu)?.identifier, .standardEdit)
        XCTAssertEqual((menu.children[1] as? UIAction)?.title, AppLocalization.string("Quote"))
        let pin = try XCTUnwrap(menu.children[2] as? UIAction)
        XCTAssertEqual(pin.title, AppLocalization.string("Pin"))

        bridge.pinReplyAction?()
        XCTAssertEqual(appState.openChatPinnedMessageIDs, ["a"])
        // The menu asks again when it next opens.
        let unpin = try XCTUnwrap(editMenu(bridge)?.children.last as? UIAction)
        XCTAssertEqual(unpin.title, AppLocalization.string("Unpin"))

        bridge.pinReplyAction?()
        XCTAssertTrue(appState.activePinnedReplies.isEmpty)
    }

    @MainActor
    func testPinStaysInTheMenuWhileQuoteIsOff() throws {
        let appState = makeAppState(freshDefaults())
        appState.activeSessionId = "chat-1"
        let answer = reply("a", "Twenty points", rowId: 7)
        let bridge = SelectableTextView(text: "Twenty points").makeCoordinator()
        bridge.quoteAction = ChatQuoteAction(owner: appState, isAvailable: { false }) { _ in }
        bridge.pinReplyAction = try XCTUnwrap(ChatPinReplyAction(message: answer, appState: appState))

        let menu = try XCTUnwrap(editMenu(bridge))
        XCTAssertEqual(menu.children.map { ($0 as? UIAction)?.title }, [nil, AppLocalization.string("Pin")])
    }

    @MainActor
    func testOnlyAReplyInAChatThatCanPinGetsTheMenuAction() {
        let appState = makeAppState(freshDefaults())
        appState.activeSessionId = "chat-1"
        XCTAssertNil(ChatPinReplyAction(message: user("u", "Hello"), appState: appState))
        XCTAssertNotNil(ChatPinReplyAction(message: reply("a", "Answer"), appState: appState))
        appState.activeSessionId = nil
        XCTAssertNil(ChatPinReplyAction(message: reply("a", "Answer"), appState: appState))
    }

    @MainActor
    func testUserMessagesAndEmptyRepliesCannotBePinned() {
        let appState = makeAppState(freshDefaults())
        appState.activeSessionId = "chat-1"
        appState.togglePinnedReply(user("u", "Hello"))
        appState.togglePinnedReply(reply("blank", "  \n"))
        XCTAssertTrue(appState.activePinnedReplies.isEmpty)
    }

    @MainActor
    func testANewChatWithoutAnIdCannotPin() {
        let appState = makeAppState(freshDefaults())
        appState.activeSessionId = nil
        XCTAssertFalse(appState.canPinReplies)
        appState.togglePinnedReply(reply("a", "Answer", rowId: 1))
        XCTAssertTrue(appState.activePinnedReplies.isEmpty)
    }

    @MainActor
    func testTheBarShowsOnlyTheOpenChatsPins() {
        let appState = makeAppState(freshDefaults())
        appState.activeSessionId = "chat-1"
        let first = reply("a", "Chat one answer", rowId: 1)
        appState.messages = [first]
        appState.togglePinnedReply(first)

        appState.activeSessionId = "chat-2"
        let second = reply("b", "Chat two answer", rowId: 2)
        appState.messages = [second]
        appState.togglePinnedReply(second)

        XCTAssertEqual(appState.openChatPinnedReplies.map(\.excerpt), ["Chat two answer"])
        XCTAssertEqual(appState.activePinnedReplies.count, 2, "the overview lists both")
    }

    @MainActor
    func testPinsBelongToTheirProfile() {
        let appState = makeAppState(freshDefaults())
        appState.activeSessionId = "chat-1"
        let answer = reply("a", "Answer", rowId: 1)
        appState.messages = [answer]
        appState.togglePinnedReply(answer)

        appState.setActiveProfileForTesting("work")
        XCTAssertTrue(appState.activePinnedReplies.isEmpty)
        XCTAssertTrue(appState.openChatPinnedMessageIDs.isEmpty)

        appState.setActiveProfileForTesting("default")
        XCTAssertEqual(appState.activePinnedReplies.count, 1)
    }

    @MainActor
    func testShowingAPinFromAnotherChatOpensThatChatFirst() throws {
        let appState = makeAppState(freshDefaults())
        appState.activeSessionId = "chat-1"
        let answer = reply("a", "Answer", rowId: 1)
        appState.messages = [answer]
        appState.togglePinnedReply(answer)
        let pinned = try XCTUnwrap(appState.activePinnedReplies.first)

        // In its own chat: just the scroll.
        appState.showPinnedReply(pinned)
        XCTAssertNil(appState.pendingPinnedReplyReveal?.opening)
        XCTAssertTrue(appState.isShowingChat(for: try XCTUnwrap(appState.pendingPinnedReplyReveal)))

        // From another chat: it waits for chat-1 to be the open one.
        appState.activeSessionId = "chat-2"
        let reveal = PinnedReplyReveal(pin: pinned, opening: "chat-1")
        XCTAssertFalse(appState.isShowingChat(for: reveal))
        appState.activeSessionId = "chat-1"
        XCTAssertTrue(appState.isShowingChat(for: reveal))
    }

    private func row(_ id: String, alternates: [String] = []) -> SessionSummary {
        SessionSummary(
            id: id, alternateIds: alternates, title: "Plan", model: "Hermes", updatedLabel: "",
            lastActivityAt: nil, profile: "default", source: .chat, isActive: false, isArchived: false,
            messageCount: nil, isUnread: nil, readWatermark: nil, lineageRootId: nil
        )
    }

    @MainActor
    func testAPinMadeBeforeTheChatWasListedFollowsItToItsRow() {
        let appState = makeAppState(freshDefaults())
        appState.activeSessionId = "runtime-1"
        let answer = reply("a", "The plan", rowId: 7)
        appState.messages = [answer]
        appState.togglePinnedReply(answer)
        XCTAssertEqual(appState.activePinnedReplies.first?.sessionID, "runtime-1")

        // The list now has the chat's row, known by that runtime id too.
        appState.sessions = [row("row-1", alternates: ["runtime-1"])]
        appState.refreshOpenChatPinnedReplies()
        XCTAssertEqual(appState.activePinnedReplies.first?.sessionID, "row-1")

        // Reopened later under another runtime id: still its chat's pin.
        appState.sessions = [row("row-1", alternates: ["runtime-2"])]
        appState.activeSessionId = "runtime-2"
        XCTAssertEqual(appState.openChatPinnedMessageIDs, ["a"])
    }

    @MainActor
    func testAnotherChatSharingAnAlternateIdNeverShowsThisChatsPin() {
        let appState = makeAppState(freshDefaults())
        appState.sessions = [row("row-a"), row("row-b", alternates: ["row-a"])]
        appState.activeSessionId = "row-a"
        let answer = reply("a", "Chat A's plan", rowId: 7)
        appState.messages = [answer]
        appState.togglePinnedReply(answer)

        appState.activeSessionId = "row-b"
        appState.messages = [reply("b", "Chat B", rowId: 8)]
        XCTAssertTrue(appState.openChatPinnedReplies.isEmpty)
        appState.dropPinnedReplies(forDeleted: row("row-b", alternates: ["row-a"]))
        XCTAssertEqual(appState.activePinnedReplies.count, 1, "deleting B keeps A's pin")
    }

    @MainActor
    func testDeletingAChatDropsAPinStillKeptUnderItsRuntimeId() {
        let appState = makeAppState(freshDefaults())
        appState.activeSessionId = "runtime-1"
        let answer = reply("a", "The plan", rowId: 7)
        appState.messages = [answer]
        appState.togglePinnedReply(answer)
        // Listed, but the pin has not moved to the row yet.
        let listed = row("row-1", alternates: ["runtime-1"])
        appState.sessions = [listed]
        appState.dropPinnedReplies(forDeleted: listed)
        XCTAssertTrue(appState.activePinnedReplies.isEmpty)
    }

    @MainActor
    func testDeletingAChatDropsItsPinnedReplies() {
        let appState = makeAppState(freshDefaults())
        appState.activeSessionId = "row-1"
        let answer = reply("a", "The plan", rowId: 7)
        appState.messages = [answer]
        appState.togglePinnedReply(answer)
        appState.activeSessionId = "row-2"
        let other = reply("b", "Other plan", rowId: 8)
        appState.messages = [other]
        appState.togglePinnedReply(other)

        appState.dropPinnedReplies(forDeleted: row("row-1"))
        XCTAssertEqual(appState.activePinnedReplies.map(\.sessionID), ["row-2"])
    }

    @MainActor
    private func pinnedAppState(dashboards: [SavedDashboard]) -> AppState {
        let appState = AppState(
            defaults: freshDefaults(),
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: dashboards[0].id, dashboards: dashboards)
        )
        appState.setActiveProfileForTesting("default")
        appState.phoneScreenIsAway = { false }
        appState.activeSessionId = "chat-1"
        let answer = reply("a", "Account A's plan", rowId: 7)
        appState.messages = [answer]
        appState.togglePinnedReply(answer)
        XCTAssertEqual(appState.activePinnedReplies.count, 1)
        return appState
    }

    @MainActor
    func testSignInRequiredOnScreenClearsPinnedReplies() {
        let one = SavedDashboard(id: UUID(), label: "One", normalizedURL: "https://one.example")
        let appState = pinnedAppState(dashboards: [one])
        appState.requireSignIn(failure: .signInExpired)
        XCTAssertTrue(appState.pinnedRepliesByProfile.isEmpty, "another account may sign in next")
    }

    @MainActor
    func testSignInRequiredOffScreenKeepsPinnedRepliesForTheRetry() {
        let one = SavedDashboard(id: UUID(), label: "One", normalizedURL: "https://one.example")
        let appState = pinnedAppState(dashboards: [one])
        appState.phoneScreenIsAway = { true }
        appState.requireSignIn(failure: .signInExpired)
        XCTAssertEqual(appState.activePinnedReplies.count, 1)
    }

    @MainActor
    func testAnInteractiveSignInClearsOnlyTheOpenDashboardsPins() {
        let one = SavedDashboard(id: UUID(), label: "One", normalizedURL: "https://one.example")
        let two = SavedDashboard(id: UUID(), label: "Two", normalizedURL: "https://two.example")
        let appState = pinnedAppState(dashboards: [one, two])
        appState.prepareInteractiveSignIn(baseURL: "https://two.example")
        XCTAssertEqual(appState.activePinnedReplies.count, 1, "another dashboard's sign-in leaves them")
        appState.prepareInteractiveSignIn(baseURL: "https://one.example")
        XCTAssertTrue(appState.pinnedRepliesByProfile.isEmpty)
    }

    @MainActor
    func testADeletedProfileTakesItsPinnedRepliesWithIt() {
        let defaults = freshDefaults()
        let appState = makeAppState(defaults)
        appState.activeSessionId = "chat-1"
        let answer = reply("a", "The plan", rowId: 7)
        appState.messages = [answer]
        appState.togglePinnedReply(answer)

        appState.adoptAuthoritativeFallbackProfile("fallback")
        XCTAssertNil(appState.pinnedRepliesByProfile["default"])
        XCTAssertNil(makeAppState(defaults).pinnedRepliesByProfile["default"],
                     "a profile made later with the same name starts with no pins")
    }

    @MainActor
    func testAChatDeletedAfterAProfileSwitchDropsItsPinsInItsOwnProfile() {
        let appState = makeAppState(freshDefaults())
        appState.activeSessionId = "row-1"
        let answer = reply("a", "The plan", rowId: 7)
        appState.messages = [answer]
        appState.togglePinnedReply(answer)
        appState.setActiveProfileForTesting("work")

        appState.dropPinnedReplies(forDeleted: row("row-1"), profile: "default")
        XCTAssertNil(appState.pinnedRepliesByProfile["default"])
    }

    @MainActor
    func testForgettingAnInactiveProfileDropsOnlyItsPins() {
        let defaults = freshDefaults()
        let appState = makeAppState(defaults)
        appState.activeSessionId = "chat-1"
        let answer = reply("a", "The plan", rowId: 7)
        appState.messages = [answer]
        appState.togglePinnedReply(answer)
        appState.setActiveProfileForTesting("work")
        appState.togglePinnedReply(answer)

        appState.forgetPinnedReplies(profile: "default")
        XCTAssertNil(appState.pinnedRepliesByProfile["default"])
        XCTAssertEqual(appState.activePinnedReplies.count, 1)
        XCTAssertNil(makeAppState(defaults).pinnedRepliesByProfile["default"], "and it stays gone")
    }

    @MainActor
    func testUnpinningClearsAWaitingReveal() throws {
        let appState = makeAppState(freshDefaults())
        appState.activeSessionId = "chat-1"
        let answer = reply("a", "Answer", rowId: 1)
        appState.messages = [answer]
        appState.togglePinnedReply(answer)
        let pinned = try XCTUnwrap(appState.activePinnedReplies.first)
        appState.showPinnedReply(pinned)
        appState.unpinReply(pinned)
        XCTAssertNil(appState.pendingPinnedReplyReveal)
    }
}

#if LAA_BUILD && targetEnvironment(macCatalyst)
import XCTest
import UIKit
@testable import Conduit

@MainActor
final class LAAMacCatalystTests: XCTestCase {
    // Window geometry, safe area and title bar are measured manually on Mac.
    func testWindowSizeConstants() {
        // The design sizes are Mac points; Catalyst draws one UIKit point at
        // about 0.77 of them.
        XCTAssertEqual(LAAMacWindow.initialWidth * LAAMacWindow.scale, 1280, accuracy: 2)
        XCTAssertEqual(LAAMacWindow.initialHeight * LAAMacWindow.scale, 820, accuracy: 2)
        XCTAssertEqual(LAAMacWindow.minimumWidth * LAAMacWindow.scale, 900, accuracy: 2)
        XCTAssertEqual(LAAMacWindow.minimumHeight * LAAMacWindow.scale, 600, accuracy: 2)
        XCTAssertGreaterThan(LAAMacWindow.initialWidth, LAAMacWindow.minimumWidth)
        XCTAssertGreaterThan(LAAMacWindow.initialHeight, LAAMacWindow.minimumHeight)
    }

    /// The sidebar's order, its ⌘1–⌘7 keys and its mapping onto the phone's
    /// tabs: Drive is the Assets tab, and nothing is listed twice.
    func testSidebarSectionsMapToTabs() {
        XCTAssertEqual(LAAMacSection.allCases,
                       [.chats, .work, .today, .brain, .studio, .drive, .usage])
        XCTAssertEqual(LAAMacSection.allCases.map(\.shortcutNumber), [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(LAAMacSection.drive.tab, .source)
        XCTAssertEqual(Set(LAAMacSection.allCases.map(\.tab)), Set(LAATab.allCases))
        XCTAssertEqual(LAAMacSection.allCases.map(\.title),
                       ["Chat", "Work", "Today", "Doc", "Studio", "Drive", "Usage"])
        // The phone's five destinations are all reachable from the sidebar.
        XCTAssertTrue(Set(LAATab.destinations).isSubset(of: Set(LAAMacSection.allCases.map(\.tab))))
    }

    /// A widget or notification link opens the section it names; an unknown
    /// host opens nothing rather than guessing.
    func testWidgetLinkHostsResolveToSections() {
        XCTAssertEqual(LAAMacSection(linkHost: "work"), .work)
        XCTAssertEqual(LAAMacSection(linkHost: "today"), .today)
        XCTAssertEqual(LAAMacSection(linkHost: "brain"), .brain)
        XCTAssertEqual(LAAMacSection(linkHost: "assets"), .drive)
        XCTAssertNil(LAAMacSection(linkHost: "settings"))
    }

    /// The split keeps the list readable and leaves the detail the rest.
    func testDesktopMetricsLeaveRoomForBothColumns() {
        XCTAssertGreaterThanOrEqual(LAADesktopMetrics.listMinWidth, 300)
        XCTAssertGreaterThan(LAADesktopMetrics.listIdealWidth, LAADesktopMetrics.listMinWidth)
        XCTAssertGreaterThanOrEqual(LAADesktopMetrics.listMaxWidth, LAADesktopMetrics.listIdealWidth)
        XCTAssertGreaterThan(LAADesktopMetrics.readingWidth, LAADesktopMetrics.documentWidth)
        // The smallest window still fits the narrowest list and a column of
        // readable text beside it.
        XCTAssertGreaterThan(LAAMacWindow.minimumWidth,
                             LAADesktopMetrics.listMinWidth + 1 + LAADesktopMetrics.gridItemMinWidth)
    }

    /// The detail column holds a conversation only while one is open and the
    /// list hasn't been returned to; otherwise it explains what to do.
    func testChatDetailResolvesFromShownAndOpen() {
        XCTAssertEqual(LAAMacChatDetail.resolve(shown: true, hasConversation: true), .conversation)
        XCTAssertEqual(LAAMacChatDetail.resolve(shown: true, hasConversation: false), .empty)
        XCTAssertEqual(LAAMacChatDetail.resolve(shown: false, hasConversation: true), .empty)
        XCTAssertEqual(LAAMacChatDetail.resolve(shown: false, hasConversation: false), .empty)
    }

    /// The list marks the row whose conversation is open, and marks no person
    /// row while a group room is open.
    func testChatListSelectionMarksOneRow() {
        let person = LAAChatsListSelection(profile: "laa-monet", roomID: nil)
        XCTAssertFalse(person.isEmpty)
        XCTAssertEqual(person.profile, "laa-monet")
        XCTAssertNil(person.roomID)
        let room = LAAChatsListSelection(profile: nil, roomID: "room-1")
        XCTAssertEqual(room.roomID, "room-1")
        XCTAssertNil(room.profile)
        XCTAssertTrue(LAAChatsListSelection().isEmpty)
    }

    func testInAppVoiceCanStartWithoutSystemCall() async {
        XCTAssertFalse(HermesNativeCalls.ringingBuilt)
        let host = VoicePlacedCallHost(
            isSettingOn: { true }, isVoiceRunning: { false }, displayName: { "Test" },
            endVoice: {}, voiceMuted: { nil }, setVoiceMuted: { _ in },
            setCallActive: { _ in }, runsElsewhere: { false }
        )
        let calls = VoicePlacedCalls(callKit: HermesNativeCalls.shared, host: host)
        let start = await calls.prepareForVoiceStart()
        XCTAssertEqual(start, .withoutCall)
        XCTAssertTrue(calls.canStartVoice(start))
    }

    func testLiveActivityRequestsAreInert() {
        let activities = LiveTurnActivities.shared
        activities.turnStarted(sessionIDs: ["s1"], primaryID: "s1", title: "Test", profile: "p1")
        XCTAssertFalse(activities.reconcile(liveSessionIDs: ["s1"], profile: "p1", dashboardID: nil))
        XCTAssertEqual(LiveTurnActivities.sessionIDs(linkedTo: "s1", profile: "p1", dashboardID: nil), [])
    }
}
#endif

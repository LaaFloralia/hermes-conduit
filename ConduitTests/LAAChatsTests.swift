#if LAA_BUILD
import XCTest
@testable import Conduit

final class LAAChatsTests: XCTestCase {
    private let person = LAAChatsPerson(profile: "laa-cfo", name: "Morgan", role: "CFO", available: true)
    private var room: GroupRoom {
        GroupRoom(roomID: "r", name: "Design team", members: [
            GroupMember(memberID: "laa-cto", profile: "laa-cto", handle: "ada", displayName: "Ada", target: nil, extra: [:])
        ], authorityGatewayID: "gateway", authorityEpoch: 1, revision: 1, createdAt: 1, updatedAt: 2,
                  disbandedAt: nil, latestSeq: nil)
    }
    private var session: SessionSummary {
        SessionSummary(id: "s", alternateIds: [], title: "Weekly plan", model: "", updatedLabel: "today",
                       profile: "laa-cfo", source: .chat, isActive: false, isArchived: false, preview: "予算を確認")
    }

    func testSearchMatchesNamesRolesGroupsMembersAndLoadedConversations() {
        XCTAssertTrue(LAAChatsSearch.person(person, matches: " mOrGaN "))
        XCTAssertTrue(LAAChatsSearch.person(person, matches: "cfo"))
        XCTAssertTrue(LAAChatsSearch.room(room, matches: "DESIGN"))
        XCTAssertTrue(LAAChatsSearch.room(room, matches: "ada"))
        XCTAssertTrue(LAAChatsSearch.session(session, ownerName: "Morgan", matches: "予算"))
        XCTAssertTrue(LAAChatsSearch.session(session, ownerName: "Morgan", matches: "morgan"))
        XCTAssertFalse(LAAChatsSearch.session(session, ownerName: "Morgan", matches: "nothing"))
        XCTAssertTrue(LAAChatsSearch.person(person, matches: "  "))
    }

    func testSearchDoesNotClaimNoResultsBeforeAllSourcesAreReady() {
        XCTAssertEqual(LAAChatsSearch.emptySearchState(groups: .ready, sessions: .ready), .ready)
        XCTAssertEqual(LAAChatsSearch.emptySearchState(groups: .ready, sessions: .loading), .loading)
        XCTAssertEqual(LAAChatsSearch.emptySearchState(groups: .failed("failure"), sessions: .ready), .failed(""))
        XCTAssertEqual(LAAChatsSearch.emptySearchState(groups: .unsupported, sessions: .ready), .failed(""))
        XCTAssertEqual(LAAChatsSearch.emptySearchState(groups: .offline, sessions: .ready), .offline)
    }
}
#endif

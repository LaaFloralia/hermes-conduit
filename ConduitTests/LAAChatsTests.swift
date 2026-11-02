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
    func testSearchMatchesNamesRolesGroupsAndMembers() {
        XCTAssertTrue(LAAChatsSearch.person(person, matches: " mOrGaN "))
        XCTAssertTrue(LAAChatsSearch.person(person, matches: "cfo"))
        XCTAssertTrue(LAAChatsSearch.room(room, matches: "DESIGN"))
        XCTAssertTrue(LAAChatsSearch.room(room, matches: "ada"))
        XCTAssertFalse(LAAChatsSearch.room(room, matches: "nothing"))
        XCTAssertTrue(LAAChatsSearch.person(person, matches: "  "))
    }

    func testSearchDoesNotClaimNoResultsBeforeGroupsAreReady() {
        XCTAssertEqual(LAAChatsSearch.emptySearchState(groups: .ready), .ready)
        XCTAssertEqual(LAAChatsSearch.emptySearchState(groups: .loading), .loading)
        XCTAssertEqual(LAAChatsSearch.emptySearchState(groups: .failed("failure")), .failed(""))
        XCTAssertEqual(LAAChatsSearch.emptySearchState(groups: .unsupported), .failed(""))
        XCTAssertEqual(LAAChatsSearch.emptySearchState(groups: .offline), .offline)
    }
}
#endif

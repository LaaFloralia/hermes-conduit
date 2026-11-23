#if LAA_BUILD
import XCTest
@testable import Conduit

/// Chat's placement (owner, 2026-11-23): Monet at the top, the employees,
/// then the contractors (派遣社員: Muse and Monet（Dots）), then the groups;
/// and a new Session always goes into a project.
final class LAAStaffPlacementTests: XCTestCase {
    private func person(_ staff: LAAStaff, available: Bool = true) -> LAAChatsPerson {
        LAAChatsPerson(profile: "laa-\(staff.rawValue)", name: staff.name, role: staff.role, available: available)
    }

    func testEveryPersonHasOnePlaceInTheListsOrder() {
        XCTAssertEqual(LAAStaff.members(of: .monet), [.monet, .monetUncensored])
        XCTAssertEqual(LAAStaff.members(of: .employee), [.argus, .cfo, .cio, .cos, .cso, .cto])
        XCTAssertEqual(LAAStaff.members(of: .contractor), [.monetDots, .soap])
        XCTAssertEqual(LAAStaff.Placement.allCases.flatMap(LAAStaff.members(of:)).count, LAAStaff.allCases.count)

        let people = LAAStaff.allCases.map { person($0) }
        XCTAssertEqual(LAAChatsPlacement.monet(people)?.staff, .monet)
        XCTAssertEqual(LAAChatsPlacement.monetVariants(people).map(\.staff), [.monetUncensored],
                       "Dots left Monet's variants; the uncensored Monet stays")
        XCTAssertEqual(LAAChatsPlacement.people(people, in: .employee).map(\.staff), [.argus, .cfo, .cio, .cos, .cso, .cto])
        XCTAssertEqual(LAAChatsPlacement.people(people, in: .contractor).map(\.staff), [.monetDots, .soap])
    }

    /// The profile IDs decide the place (Hermes names no group), so Muse
    /// reads as a contractor even when Hermes lists laa-soap without a name.
    func testTheProfileIDDecidesThePlace() {
        XCTAssertEqual(LAAStaff(profile: "laa-monet")?.placement, .monet)
        XCTAssertEqual(LAAStaff(profile: "laa-soap")?.placement, .contractor)
        XCTAssertEqual(LAAStaff(profile: "laa-monet-dots")?.placement, .contractor)
        let unnamed = LAAChatsPerson(profile: "laa-soap", name: "", role: "", available: true)
        XCTAssertEqual(unnamed.placement, .contractor)
    }

    /// The new group's member choice shows the same sections, Monet's
    /// uncensored variant left out as before.
    @MainActor func testTheGroupPickerUsesTheSamePlacement() {
        XCTAssertEqual(LAAGroupCandidates.sections.map(\.title),
                       [LAACopy.groupSelectEmployees, LAACopy.chatsEmployees, LAACopy.chatsContractors])
        XCTAssertEqual(LAAGroupCandidates.all, [.monet, .argus, .cfo, .cio, .cos, .cso, .cto, .monetDots, .soap])
        XCTAssertFalse(LAAGroupCandidates.all.contains(.monetUncensored))
        XCTAssertEqual(LAAChatPerson.name(LAAStaff.monetDots.name), "Monet · Dots")
    }

    // MARK: Sessions inside projects

    private func projects() throws -> [LAAWorkProject] {
        try JSONDecoder().decode([LAAWorkProject].self, from: Data(#"""
        [{"id":"prj_000000000000","name":"未分類"},
         {"id":"prj_aaaaaaaaaaaa","name":"LAAアプリ"},
         {"id":"prj_bbbbbbbbbbbb","name":"旧案件","archivedAt":"2026-11-01T00:00:00Z"},
         {"id":"prj_cccccccccccc","name":"Studio"}]
        """#.utf8))
    }

    func testANewSessionStartsInTheProjectItWasOpenedFromElseTheLastElseAsks() throws {
        let all = try projects()
        typealias P = LAAWorkSessionProjects
        XCTAssertEqual(P.choices(all).map(\.id), ["prj_aaaaaaaaaaaa", "prj_cccccccccccc", "prj_000000000000"],
                       "archived ones are not offered, 未分類 comes last")
        XCTAssertEqual(P.initialID(given: "prj_cccccccccccc", last: "prj_aaaaaaaaaaaa", in: all), "prj_cccccccccccc")
        XCTAssertEqual(P.initialID(given: "", last: "prj_aaaaaaaaaaaa", in: all), "prj_aaaaaaaaaaaa")
        XCTAssertEqual(P.initialID(given: "", last: "prj_bbbbbbbbbbbb", in: all), "", "an archived last project is not chosen")
        XCTAssertEqual(P.initialID(given: "", last: "", in: all), "", "with nothing to go on, the owner chooses")
        let made = try JSONDecoder().decode(LAAWorkProject.self, from: Data(#"{"id":"prj_dddddddddddd","name":"新規"}"#.utf8))
        XCTAssertEqual(P.created(before: all, after: all + [made])?.id, "prj_dddddddddddd")
        XCTAssertNil(P.created(before: all, after: all))
    }

    func testTheLastOpenedProjectIsRemembered() throws {
        let suite = "laa.test.project.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        LAAWorkSessionProjects.noteOpened("prj_aaaaaaaaaaaa", defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: LAAWorkSessionProjects.lastKey), "prj_aaaaaaaaaaaa")
        LAAWorkSessionProjects.noteOpened("", defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: LAAWorkSessionProjects.lastKey), "prj_aaaaaaaaaaaa", "an empty id is ignored")
    }

    /// The move sends `projectId` alone (C3's contract), and an older Bridge's
    /// refusal reads as an update to make, not a failure of the project.
    func testAMoveSendsOnlyTheProjectAndReadsAnOlderBridge() throws {
        let body = try JSONEncoder().encode(LAAWorkSessionProjects.Move(projectId: "prj_aaaaaaaaaaaa"))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"projectId":"prj_aaaaaaaaaaaa"}"#)
        func error(_ status: Int, _ message: String?) -> LAABridgeHTTPError {
            LAABridgeHTTPError(status: status, code: "payload_invalid", message: message, retryable: false,
                               details: nil, requestId: nil, currentETag: nil)
        }
        XCTAssertTrue(LAAWorkSessionProjects.isOlderBridge(error(400, "favorite, archived, name, model, effort or fast is required")))
        XCTAssertFalse(LAAWorkSessionProjects.isOlderBridge(error(400, "supply projectId alone as a valid project ID")))
        XCTAssertFalse(LAAWorkSessionProjects.isOlderBridge(error(409, "a child cannot be moved away from its parent")))
        XCTAssertEqual(LAAWorkSessionProjects.failure(error(400, "favorite, archived, name, model, effort or fast is required")),
                       "MacのLAAアプリを最新にすると使えます。")
    }
}
#endif

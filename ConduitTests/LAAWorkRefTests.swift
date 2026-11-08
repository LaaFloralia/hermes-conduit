#if LAA_BUILD
import XCTest
@testable import Conduit

/// Short numbers (`T12`, `S4`, …): decoding them from a newer Bridge, staying
/// quiet when an older one sends none, and the one search rule Work uses.
final class LAAWorkRefTests: XCTestCase {
    private func decode<T: Decodable>(_ json: [String: Any], _ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: json))
    }

    func testShortNumbersAreCanonicalWhateverTheOwnerTypes() {
        XCTAssertEqual(LAAWorkRef.parse("t12"), "T12")
        XCTAssertEqual(LAAWorkRef.parse("Ｔ１２"), "T12")
        XCTAssertEqual(LAAWorkRef.parse("T-12"), "T12")
        XCTAssertEqual(LAAWorkRef.parse(" T 12 "), "T12")
        XCTAssertEqual(LAAWorkRef.parse("T012"), "T12")
        XCTAssertEqual(LAAWorkRef.parse("S4"), "S4")
        XCTAssertEqual(LAAWorkRef.parse("p2"), "P2")
        XCTAssertEqual(LAAWorkRef.parse("R7"), "R7")
        XCTAssertEqual(LAAWorkRef.parse("K3"), "K3")
        XCTAssertNil(LAAWorkRef.parse("12"))
        XCTAssertNil(LAAWorkRef.parse("TX12"))
        XCTAssertNil(LAAWorkRef.parse("T0"))
        XCTAssertNil(LAAWorkRef.parse("T123456"))
        XCTAssertNil(LAAWorkRef.parse("BUS-123"))
        XCTAssertNil(LAAWorkRef.parse(""))
    }

    func testBlankRefsShowNothing() {
        XCTAssertNil(LAAWorkRef.display(nil))
        XCTAssertNil(LAAWorkRef.display(""))
        XCTAssertNil(LAAWorkRef.display("   "))
        XCTAssertEqual(LAAWorkRef.display(" T12 "), "T12")
    }

    func testSearchFindsTheNumberExactlyOrTheRowsText() {
        XCTAssertTrue(LAAWorkRef.matches("", ref: nil, text: ["anything"]))
        XCTAssertTrue(LAAWorkRef.matches("   ", ref: nil, text: []))
        XCTAssertTrue(LAAWorkRef.matches("t12", ref: "T12", text: []))
        XCTAssertTrue(LAAWorkRef.matches("Ｔ１２", ref: "T12", text: []))
        XCTAssertFalse(LAAWorkRef.matches("t12", ref: "T13", text: []))
        XCTAssertFalse(LAAWorkRef.matches("t12", ref: "T123", text: []))
        XCTAssertFalse(LAAWorkRef.matches("t12", ref: nil, text: ["次の打ち合わせ"]))
        XCTAssertTrue(LAAWorkRef.matches("打ち合わせ", ref: nil, text: ["次の打ち合わせを確認する"]))
        XCTAssertTrue(LAAWorkRef.matches("BUS-TEST1", ref: nil, text: ["BUS-TEST1"]))
        // A number is not a substring: the row must hold that exact number.
        XCTAssertFalse(LAAWorkRef.matches("t1", ref: "T12", text: []))
    }

    func testLinearTaskDecodesTheRefAndToleratesItsAbsence() throws {
        let base: [String: Any] = [
            "id": "b9d2f664-cda3-4c56-8d39-c4d6df597254", "identifier": "BUS-1", "title": "Task",
            "priority": 0, "status": "todo", "stateName": "Todo", "updatedAt": "2026-11-02T00:00:00Z",
        ]
        XCTAssertEqual(try decode(base.merging(["ref": "T12"]) { $1 }, LAALinearTask.self).ref, "T12")
        XCTAssertNil(try decode(base, LAALinearTask.self).ref)
        XCTAssertNil(try decode(base.merging(["ref": NSNull()]) { $1 }, LAALinearTask.self).ref)
    }

    func testWorkSessionDecodesTheRefAndToleratesItsAbsence() throws {
        let base: [String: Any] = [
            "id": "ses_1", "name": "Session", "requestId": "req", "workspaceId": "ws",
            "profile": "test", "phase": "running", "createdAt": "2026-11-06T00:00:00Z",
            "updatedAt": "2026-11-06T00:00:00Z",
            "events": ["lastSeq": 1, "oldestSeq": 1, "cursor": "cursor"],
        ]
        XCTAssertEqual(try decode(base.merging(["ref": "S4"]) { $1 }, LAAWorkSession.self).ref, "S4")
        XCTAssertNil(try decode(base, LAAWorkSession.self).ref)
    }

    func testProjectDecodesTheRefAndToleratesItsAbsence() throws {
        XCTAssertEqual(try decode(["id": "p1", "name": "LAA", "ref": "P1"], LAAWorkProject.self).ref, "P1")
        XCTAssertNil(try decode(["id": "p1", "name": "LAA"], LAAWorkProject.self).ref)
    }

    func testRoutineDecodesTheRefAndToleratesItsAbsence() throws {
        let base: [String: Any] = ["id": "job:a", "name": "Daily"]
        XCTAssertEqual(try decode(base.merging(["ref": "R1"]) { $1 }, LAAWorkRoutine.self).ref, "R1")
        XCTAssertNil(try decode(base, LAAWorkRoutine.self).ref)
    }

    func testSkillDecodesTheRefAndToleratesItsAbsence() throws {
        let base: [String: Any] = ["id": "k", "name": "weekly-report", "description": "", "source": "Claude"]
        XCTAssertEqual(try decode(base.merging(["ref": "K1"]) { $1 }, LAAWorkSkill.self).ref, "K1")
        XCTAssertNil(try decode(base, LAAWorkSkill.self).ref)
    }

    /// The phone and the Mac must not disagree about what a search finds.
    func testDesktopAndPhoneShareOneMatcher() {
        XCTAssertTrue(LAAWorkRef.matches("s2", ref: "S2", text: ["判断待ち"]))
        XCTAssertTrue(LAAWorkRef.matches("判断", ref: "S2", text: ["判断待ち"]))
        XCTAssertFalse(LAAWorkRef.matches("s3", ref: "S2", text: ["判断待ち"]))
    }
}
#endif

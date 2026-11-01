#if LAA_BUILD
import Foundation
import XCTest
@testable import Conduit

final class LAAOwnerTaskPresentationTests: XCTestCase {
    private func task(_ id: Int, _ status: LAAOwnerTaskStatus, due: String? = nil, updated: Double) -> LAAOwnerTask {
        LAAOwnerTask(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
            title: "Task \(id)", memo: "", status: status,
            dueDate: due.flatMap(LAAOwnerTaskDay.init), source: .owner, links: [],
            updatedAt: Date(timeIntervalSince1970: updated), revision: 1
        )
    }

    func testOpenTasksAreSortedByDueDayThenUndatedByMostRecentUpdate() {
        let groups = LAAOwnerTaskGroups(tasks: [
            task(1, .todo, updated: 30),
            task(2, .doing, due: "2026-12-01", updated: 40),
            task(3, .todo, due: "2026-11-01", updated: 10),
            task(4, .doing, updated: 60),
            task(5, .done, updated: 100),
            task(6, .canceled, updated: 100),
            task(7, .todo, due: "2026-11-01", updated: 50),
            task(8, .done, updated: 200),
            task(9, .canceled, updated: 300)
        ])
        XCTAssertEqual(groups.open.map(\.title), ["Task 7", "Task 3", "Task 2", "Task 4", "Task 1"])
        XCTAssertEqual(groups.done.map(\.title), ["Task 8", "Task 5"])
        XCTAssertEqual(groups.canceled.map(\.title), ["Task 9", "Task 6"])
    }

    func testTiesUseStableIdentifierOrdering() {
        let groups = LAAOwnerTaskGroups(tasks: [
            task(2, .todo, due: "2026-11-01", updated: 1),
            task(1, .doing, due: "2026-11-01", updated: 1),
            task(4, .canceled, updated: 1), task(3, .canceled, updated: 1)
        ])
        XCTAssertEqual(groups.open.map(\.title), ["Task 1", "Task 2"])
        XCTAssertEqual(groups.canceled.map(\.title), ["Task 3", "Task 4"])
    }

    func testDueDayValidationDoesNotNormalizeInvalidDates() {
        for valid in ["2024-02-29", "2000-02-29", "2026-12-31", "0001-01-01"] {
            XCTAssertNotNil(LAAOwnerTaskDay(valid), valid)
        }
        for invalid in ["2026-02-29", "1900-02-29", "2026-04-31", "0000-01-01", "2026-1-01", "2026-01-00", "２０２６-01-01", "2026-01-01T00:00:00Z"] {
            XCTAssertNil(LAAOwnerTaskDay(invalid), invalid)
        }
        XCTAssertLessThan(LAAOwnerTaskDay("2026-01-01")!, LAAOwnerTaskDay("2026-12-01")!)
    }

    func testOnlyHttpsLinksWithHostAndNoCredentialsAreOpenable() {
        XCTAssertNotNil(LAAOwnerTaskLink.openableURL("https://example.com/reference"))
        for text in ["http://example.com", "custom://example.com", "javascript:alert(1)", "https:///path", "https://user:password@example.com"] {
            XCTAssertNil(LAAOwnerTaskLink.openableURL(text), text)
        }
    }

    func testDraftRetainsOriginalContentAndCanRestoreCanceledTask() throws {
        let original = LAAOwnerTask(
            id: UUID(), title: "  題名  ", memo: "# 見出し\n本文\n", status: .canceled,
            dueDate: LAAOwnerTaskDay("2026-11-01"), source: .linearImport,
            links: ["https://example.com/", "custom://kept-as-text"],
            updatedAt: Date(timeIntervalSince1970: 20), revision: 9
        )
        var draft = LAAOwnerTaskDraft(task: original)
        XCTAssertEqual(draft.id, original.id)
        XCTAssertEqual(draft.base, original)
        XCTAssertEqual(draft.title, original.title)
        XCTAssertEqual(draft.memo, original.memo)
        XCTAssertEqual(draft.links, original.links)
        XCTAssertEqual(draft.dueDateText, "2026-11-01")
        XCTAssertEqual(draft.status, .canceled)
        draft.status = .todo
        draft.dueDateText = ""
        XCTAssertNoThrow(try draft.validate())
        XCTAssertEqual(draft.status, .todo)
        XCTAssertEqual(draft.base?.revision, 9)
    }

    func testDraftValidationRejectsEmptyTitleInvalidDateAndBlankLink() {
        var draft = LAAOwnerTaskDraft()
        XCTAssertThrowsError(try draft.validate()) { XCTAssertEqual($0 as? LAAOwnerTaskDraft.ValidationError, .missingTitle) }
        draft.title = "題名"
        draft.dueDateText = "2026-02-29"
        XCTAssertThrowsError(try draft.validate()) { XCTAssertEqual($0 as? LAAOwnerTaskDraft.ValidationError, .invalidDueDate) }
        draft.dueDateText = ""
        draft.links = ["https://example.com", " \n"]
        XCTAssertThrowsError(try draft.validate()) { XCTAssertEqual($0 as? LAAOwnerTaskDraft.ValidationError, .emptyLink) }
        draft.links.removeLast()
        XCTAssertNoThrow(try draft.validate())
    }
}
#endif

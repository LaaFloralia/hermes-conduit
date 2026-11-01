#if LAA_BUILD
import XCTest
@testable import Conduit

final class LAABrainDailyTests: XCTestCase {
    private var root: URL!
    private var history: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("daily-" + UUID().uuidString, isDirectory: true)
        history = FileManager.default.temporaryDirectory.appendingPathComponent("daily-history-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: history)
    }

    func testDateUsesLocalCalendarYearAtNewYear() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2021-12-31T15:00:00Z"))
        XCTAssertEqual(LAABrainDailyNote.path(date: date, timeZone: TimeZone(secondsFromGMT: 9 * 3600)!), "daily journal/2022-01-01.md")
        XCTAssertEqual(LAABrainDailyNote.path(date: date, timeZone: TimeZone(secondsFromGMT: 0)!), "daily journal/2021-12-31.md")
    }

    func testCreatesEmptyAndReopeningPreservesExistingText() throws {
        let journal = LAABrainSaveJournal(directory: history)
        let path = try LAABrainDailyNote.open(root: root, journal: journal)
        let url = root.appendingPathComponent(path)
        XCTAssertEqual(try Data(contentsOf: url), Data())
        try Data("existing".utf8).write(to: url)
        XCTAssertEqual(try LAABrainDailyNote.open(root: root, journal: journal), path)
        XCTAssertEqual(try Data(contentsOf: url), Data("existing".utf8))
    }

    func testExistingSymlinkIsNeverFollowedOrReplaced() throws {
        let outside = history.appendingPathComponent("other.md")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(LAABrainDailyNote.folder), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(LAABrainDailyNote.path()), withDestinationURL: outside)
        XCTAssertThrowsError(try LAABrainDailyNote.open(root: root, journal: LAABrainSaveJournal(directory: history)))
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
    }

    @MainActor func testRequestSurvivesRecreationAndOldCompletionDoesNotClearNewRequest() throws {
        let suite = "brain-daily-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = LAABrainDailyRequest(defaults: defaults)
        first.enqueue()
        let old = try XCTUnwrap(first.id)
        let restored = LAABrainDailyRequest(defaults: defaults)
        XCTAssertEqual(restored.id, old)
        restored.enqueue()
        let current = try XCTUnwrap(restored.id)
        restored.consume(old)
        XCTAssertEqual(restored.id, current)
        restored.consume(current)
        XCTAssertNil(LAABrainDailyRequest(defaults: defaults).id)
    }

    @MainActor func testIntentEnqueuesLaunch() async throws {
        _ = try await OpenTodayDailyNoteIntent().perform()
        let id = try XCTUnwrap(LAABrainDailyRequest.shared.id)
        LAABrainDailyRequest.shared.consume(id)
    }
}
#endif

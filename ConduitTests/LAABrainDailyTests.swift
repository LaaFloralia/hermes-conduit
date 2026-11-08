#if LAA_BUILD
import XCTest
@testable import Conduit

final class LAABrainDailyTests: XCTestCase {
    private var root: URL!
    private var history: URL!
    private let tokyo = TimeZone(secondsFromGMT: 9 * 3600)!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("daily-" + UUID().uuidString, isDirectory: true)
        history = FileManager.default.temporaryDirectory.appendingPathComponent("daily-history-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: history)
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }

    /// The owner's iPhone selects "このiPhone内/LAA", which holds Brain/ and HQ/.
    func testPathUsesBrainVaultWhenBrainIsADirectoryAtRoot() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Brain"), withIntermediateDirectories: true)
        XCTAssertEqual(try LAABrainDailyNote.path(root: root, date: date("2026-11-08T03:00:00Z"), timeZone: tokyo),
                       "Brain/daily journal/2026-11/2026-11-08.md")
    }

    /// A device that selected the Brain folder itself keeps working.
    func testPathUsesRootWhenThereIsNoBrainFolder() throws {
        XCTAssertEqual(try LAABrainDailyNote.path(root: root, date: date("2026-11-08T03:00:00Z"), timeZone: tokyo),
                       "daily journal/2026-11/2026-11-08.md")
    }

    func testDateUsesLocalCalendarYearAtNewYear() throws {
        let value = try date("2021-12-31T15:00:00Z")
        XCTAssertEqual(try LAABrainDailyNote.path(root: root, date: value, timeZone: tokyo),
                       "daily journal/2022-01/2022-01-01.md")
        XCTAssertEqual(try LAABrainDailyNote.path(root: root, date: value, timeZone: TimeZone(secondsFromGMT: 0)!),
                       "daily journal/2021-12/2021-12-31.md")
    }

    func testCreatesEmptyNoteInMonthFolderAndReopeningPreservesExistingText() throws {
        let journal = LAABrainSaveJournal(directory: history)
        let value = try date("2026-11-08T03:00:00Z")
        let path = try LAABrainDailyNote.open(root: root, date: value, timeZone: tokyo, journal: journal)
        XCTAssertEqual(path, "daily journal/2026-11/2026-11-08.md")
        let url = root.appendingPathComponent(path)
        XCTAssertEqual(try Data(contentsOf: url), Data())
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("daily journal/2026-11").path))
        try Data("existing".utf8).write(to: url)
        XCTAssertEqual(try LAABrainDailyNote.open(root: root, date: value, timeZone: tokyo, journal: journal), path)
        XCTAssertEqual(try Data(contentsOf: url), Data("existing".utf8))
    }

    func testOpenWritesInsideBrainAndNeverCreatesRootDailyFolder() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Brain"), withIntermediateDirectories: true)
        let value = try date("2026-11-08T03:00:00Z")
        let path = try LAABrainDailyNote.open(root: root, date: value, timeZone: tokyo,
                                              journal: LAABrainSaveJournal(directory: history))
        XCTAssertEqual(path, "Brain/daily journal/2026-11/2026-11-08.md")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("daily journal").path))
    }

    func testExistingSymlinkIsNeverFollowedOrReplaced() throws {
        let outside = history.appendingPathComponent("other.md")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside)
        let value = try date("2026-11-08T03:00:00Z")
        let path = try LAABrainDailyNote.path(root: root, date: value, timeZone: tokyo)
        let month = root.appendingPathComponent(path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: month, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(path), withDestinationURL: outside)
        XCTAssertThrowsError(try LAABrainDailyNote.open(root: root, date: value, timeZone: tokyo,
                                                        journal: LAABrainSaveJournal(directory: history)))
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
    }

    func testLinkedBrainIsRefusedInsteadOfWritingTheWrongRootFolder() throws {
        let outside = history.appendingPathComponent("Brain", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Brain"), withDestinationURL: outside)
        XCTAssertThrowsError(try LAABrainDailyNote.open(root: root, date: date("2026-11-08T03:00:00Z"), timeZone: tokyo,
                                                        journal: LAABrainSaveJournal(directory: history)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("daily journal").path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
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

#if LAA_BUILD
import Foundation
import XCTest
@testable import Conduit

@MainActor
final class LAAOwnerTaskLocalDraftsTests: XCTestCase {
    private func fixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testDraftSurvivesStoreReloadAndKeepsIncompleteInput() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("drafts.json")
        let store = ComposerDraftStore(capacity: .max, fileURL: file)
        var draft = LAAOwnerTaskDraft()
        draft.title = "未完成の入力"
        draft.memo = "本文\n"
        draft.dueDateText = "2026-11-"
        draft.links = ["custom://kept", ""]
        XCTAssertTrue(LAAOwnerTaskLocalDrafts.save(draft, in: store, deviceID: "device-a"))
        let reloaded = ComposerDraftStore(capacity: .max, fileURL: file)
        XCTAssertEqual(LAAOwnerTaskLocalDrafts.read(reloaded, deviceID: "device-a", taskID: draft.id), .saved(draft))
        XCTAssertEqual(LAAOwnerTaskLocalDrafts.read(reloaded, deviceID: "device-b", taskID: draft.id), .absent)
        XCTAssertEqual(LAAOwnerTaskLocalDrafts.entries(in: reloaded).first?.deviceID, "device-a")
        XCTAssertEqual(LAAOwnerTaskLocalDrafts.entries(in: reloaded).first?.taskID, draft.id)
    }

    func testUnreadableRecordIsNotOverwritten() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("drafts.json")
        let store = ComposerDraftStore(capacity: .max, fileURL: file)
        let draft = LAAOwnerTaskDraft()
        let key = try XCTUnwrap(LAAOwnerTaskLocalDrafts.key(deviceID: "device-a", taskID: draft.id))
        XCTAssertTrue(store.save(ComposerDraft(text: "{broken", attachments: []), for: key))
        XCTAssertFalse(LAAOwnerTaskLocalDrafts.save(draft, in: store, deviceID: "device-a"))
        XCTAssertEqual(LAAOwnerTaskLocalDrafts.read(store, deviceID: "device-a", taskID: draft.id), .unreadable)
        XCTAssertEqual(store.draft(for: key).text, "{broken")
    }

    func testUnreadableSnapshotIsNotReplacedWithEmptyData() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("drafts.json")
        let bytes = Data("unreadable snapshot".utf8)
        try bytes.write(to: file)
        let store = ComposerDraftStore(capacity: .max, fileURL: file)
        let draft = LAAOwnerTaskDraft()
        XCTAssertTrue(store.persistenceFailed)
        XCTAssertFalse(LAAOwnerTaskLocalDrafts.save(draft, in: store, deviceID: "device-a"))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testOlderSavedResponseCannotRemoveNewerEdit() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ComposerDraftStore(capacity: .max, fileURL: directory.appendingPathComponent("drafts.json"))
        var first = LAAOwnerTaskDraft()
        first.title = "元の入力"
        var later = first
        later.title = "後から入力"
        XCTAssertTrue(LAAOwnerTaskLocalDrafts.save(first, in: store, deviceID: "device-a"))
        XCTAssertTrue(LAAOwnerTaskLocalDrafts.save(later, in: store, deviceID: "device-a"))
        XCTAssertFalse(LAAOwnerTaskLocalDrafts.remove(first, from: store, deviceID: "device-a"))
        XCTAssertEqual(LAAOwnerTaskLocalDrafts.read(store, deviceID: "device-a", taskID: later.id), .saved(later))
        XCTAssertTrue(LAAOwnerTaskLocalDrafts.remove(later, from: store, deviceID: "device-a"))
        XCTAssertEqual(LAAOwnerTaskLocalDrafts.read(store, deviceID: "device-a", taskID: later.id), .absent)
    }

    func testMalformedKeyRemainsEnumeratedWithoutAnAssumedOwner() throws {
        let store = ComposerDraftStore(capacity: .max)
        let malformed = ComposerDraftKey(profile: "laa-owner-task-draft-v1", sessionID: "bad",
                                         dashboardID: LAAWorkDrafts.dashboardID)
        XCTAssertTrue(store.save(ComposerDraft(text: "unreadable", attachments: []), for: malformed))
        let entry = try XCTUnwrap(LAAOwnerTaskLocalDrafts.entries(in: store).first)
        XCTAssertEqual(entry.key, malformed)
        XCTAssertNil(entry.deviceID)
        XCTAssertNil(entry.taskID)
    }

    func testFailedSaveKeepsInMemoryCopyAndCanRetry() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)
        let store = ComposerDraftStore(capacity: .max, fileURL: blocker.appendingPathComponent("drafts.json"))
        var draft = LAAOwnerTaskDraft()
        draft.title = "保存をやり直す"
        XCTAssertFalse(LAAOwnerTaskLocalDrafts.save(draft, in: store, deviceID: "device-a"))
        XCTAssertTrue(store.persistenceFailed)
        XCTAssertEqual(LAAOwnerTaskLocalDrafts.read(store, deviceID: "device-a", taskID: draft.id), .saved(draft))
        try FileManager.default.removeItem(at: blocker)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        XCTAssertTrue(LAAOwnerTaskLocalDrafts.save(draft, in: store, deviceID: "device-a"))
        let reloaded = ComposerDraftStore(capacity: .max, fileURL: blocker.appendingPathComponent("drafts.json"))
        XCTAssertEqual(LAAOwnerTaskLocalDrafts.read(reloaded, deviceID: "device-a", taskID: draft.id), .saved(draft))
    }

    func testFailedRemovalRestoresInMemoryCopy() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("drafts.json")
        let store = ComposerDraftStore(capacity: .max, fileURL: file)
        var draft = LAAOwnerTaskDraft()
        draft.title = "保持する入力"
        XCTAssertTrue(LAAOwnerTaskLocalDrafts.save(draft, in: store, deviceID: "device-a"))
        let backup = directory.appendingPathComponent("backup.json")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertFalse(LAAOwnerTaskLocalDrafts.remove(draft, from: store, deviceID: "device-a"))
        XCTAssertEqual(LAAOwnerTaskLocalDrafts.read(store, deviceID: "device-a", taskID: draft.id), .saved(draft))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }
}
#endif

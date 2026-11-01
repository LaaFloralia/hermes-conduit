#if LAA_BUILD
import Foundation
import XCTest
@testable import Conduit

@MainActor
final class LAAOwnerTaskAPITests: XCTestCase {
    private let id = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!

    private func task(_ status: LAAOwnerTaskStatus = .todo) -> LAAOwnerTask {
        LAAOwnerTask(id: id, title: "作業", memo: "残すメモ", status: status,
                     dueDate: LAAOwnerTaskDay("2026-11-10"), source: .agent,
                     links: ["https://example.com"], updatedAt: Date(timeIntervalSince1970: 1), revision: 7)
    }

    private func json(_ request: LAAOwnerTaskRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }

    private func page(ids: [UUID], total: Int, next: String?) throws -> LAAOwnerTaskPage {
        let items: [[String: Any]] = ids.map { id in
            ["id": id.uuidString, "title": "題名", "status": "todo", "dueDate": NSNull(),
             "source": "owner", "updatedAt": "2026-11-01T00:00:00.000Z", "revision": 1]
        }
        let object: [String: Any] = ["items": items, "total": total, "nextCursor": next as Any? ?? NSNull()]
        return try JSONDecoder().decode(LAAOwnerTaskPage.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testSummaryCannotBecomeEditingDetail() throws {
        let bytes = Data("""
        {"id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","title":"作業","status":"todo",
         "dueDate":null,"source":"owner","updatedAt":"2026-11-01T00:00:00.000Z","revision":1}
        """.utf8)
        let item = try JSONDecoder().decode(LAAOwnerTaskWire.self, from: bytes)
        XCTAssertEqual(try item.task(requiringDetail: false).title, "作業")
        XCTAssertThrowsError(try item.task(requiringDetail: true))
    }

    func testDetailRequiresValidRevisionAndTimestamp() throws {
        let bytes = Data("""
        {"id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","title":"作業","memo":"本文","links":[],
         "status":"doing","dueDate":"2026-11-03","source":"agent","updatedAt":"2026-11-01T00:00:00Z","revision":3}
        """.utf8)
        let item = try JSONDecoder().decode(LAAOwnerTaskWire.self, from: bytes)
        XCTAssertEqual(try item.task(requiringDetail: true).memo, "本文")
        let bad = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\"revision\":3", with: "\"revision\":0").utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(LAAOwnerTaskWire.self, from: bad).task(requiringDetail: true))
    }

    func testPagesCompleteOnlyWhenEverySummaryIsPresent() throws {
        var pages = LAAOwnerTaskPageAccumulator()
        let second = UUID()
        try pages.append(page(ids: [id], total: 2, next: "cursor"))
        XCTAssertThrowsError(try pages.complete())
        try pages.append(page(ids: [second], total: 2, next: nil))
        XCTAssertEqual(try pages.complete().map(\.id), [id, second])
    }

    func testPagesRejectRepeatedCursorDuplicateRowAndChangedTotal() throws {
        var repeated = LAAOwnerTaskPageAccumulator()
        try repeated.append(page(ids: [id], total: 3, next: "cursor"))
        XCTAssertThrowsError(try repeated.append(page(ids: [UUID()], total: 3, next: "cursor")))
        var duplicate = LAAOwnerTaskPageAccumulator()
        try duplicate.append(page(ids: [id], total: 2, next: "first"))
        XCTAssertThrowsError(try duplicate.append(page(ids: [id], total: 2, next: nil)))
        var changed = LAAOwnerTaskPageAccumulator()
        try changed.append(page(ids: [id], total: 2, next: "first"))
        XCTAssertThrowsError(try changed.append(page(ids: [UUID()], total: 1, next: nil)))
    }

    func testEmptyPageIsNotACompleteListWhenServerReportsRows() throws {
        var pages = LAAOwnerTaskPageAccumulator()
        try pages.append(page(ids: [], total: 1, next: nil))
        XCTAssertThrowsError(try pages.complete())
        var empty = LAAOwnerTaskPageAccumulator()
        try empty.append(page(ids: [], total: 0, next: nil))
        XCTAssertTrue(try empty.complete().isEmpty)
    }

    func testCreateReservesTaskIdentityAndNullDueDate() throws {
        var draft = LAAOwnerTaskDraft(id: id)
        draft.title = "新しい作業"
        let request = try LAAOwnerTaskRequest.create(draft, deviceID: "device-a", key: "key-a")
        let body = try json(request)
        XCTAssertEqual(request.path, "/v1/owner-tasks")
        XCTAssertEqual(body["id"] as? String, id.uuidString.lowercased())
        XCTAssertTrue(body["dueDate"] is NSNull)
        XCTAssertEqual(body["source"] as? String, "owner")
    }

    func testPatchSendsOnlyChangedFieldsAndCanClearDate() throws {
        var draft = LAAOwnerTaskDraft(task: task())
        draft.title = "変更"
        draft.dueDateText = ""
        let request = try LAAOwnerTaskRequest.update(draft, deviceID: "device-a", key: "key-b")
        let body = try json(request)
        XCTAssertEqual(Set(body.keys), Set(["title", "dueDate"]))
        XCTAssertTrue(body["dueDate"] is NSNull)
        XCTAssertEqual(request.ifMatch, "\"7\"")
    }

    func testCheckAndUncheckAreAbsoluteStatusUpdates() throws {
        let check = try LAAOwnerTaskRequest.check(task(.doing), deviceID: "device-a", key: "key-c")
        let uncheck = try LAAOwnerTaskRequest.check(task(.done), deviceID: "device-a", key: "key-d")
        XCTAssertEqual(try json(check)["status"] as? String, "done")
        XCTAssertEqual(try json(uncheck)["status"] as? String, "todo")
        XCTAssertEqual(try Set(json(check).keys), Set(["status"]))
    }

    func testUnchangedPatchDoesNotMakeARequest() {
        XCTAssertThrowsError(try LAAOwnerTaskRequest.update(LAAOwnerTaskDraft(task: task()), deviceID: "device-a", key: "key-e"))
    }

    func testReservedRequestSurvivesRestartWithExactBytesAndDevice() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("drafts.json")
        let store = ComposerDraftStore(capacity: .max, fileURL: file)
        var draft = LAAOwnerTaskDraft(id: id); draft.title = "保存前に接続断"
        XCTAssertTrue(LAAOwnerTaskLocalDrafts.save(draft, in: store, deviceID: "device-a"))
        let request = try LAAOwnerTaskRequest.create(draft, deviceID: "device-a", key: "key-f")
        XCTAssertNotNil(LAAOwnerTaskOutbox.reserve(request, in: store))
        let reloaded = ComposerDraftStore(capacity: .max, fileURL: file)
        let item = try XCTUnwrap(LAAOwnerTaskOutbox.entries(in: reloaded).first)
        XCTAssertEqual(LAAOwnerTaskOutbox.request(item), request)
        XCTAssertEqual(reloaded.unknownSubmissions.count, 1)
        XCTAssertEqual(LAAOwnerTaskLocalDrafts.read(reloaded, deviceID: "device-b", taskID: id), .absent)
    }

    func testRejectedRequestRestoresDraftWithoutOverwritingNewerInput() throws {
        let store = ComposerDraftStore(capacity: .max)
        var draft = LAAOwnerTaskDraft(id: id); draft.title = "初めの入力"
        XCTAssertTrue(LAAOwnerTaskLocalDrafts.save(draft, in: store, deviceID: "device-a"))
        let request = try LAAOwnerTaskRequest.create(draft, deviceID: "device-a", key: "key-g")
        let item = try XCTUnwrap(LAAOwnerTaskOutbox.reserve(request, in: store))
        var newer = draft; newer.title = "後の入力"
        XCTAssertTrue(LAAOwnerTaskLocalDrafts.save(newer, in: store, deviceID: "device-a"))
        XCTAssertFalse(LAAOwnerTaskOutbox.restoreRejected(item, in: store))
        XCTAssertEqual(LAAOwnerTaskLocalDrafts.read(store, deviceID: "device-a", taskID: id), .saved(newer))
        XCTAssertTrue(LAAOwnerTaskLocalDrafts.remove(newer, from: store, deviceID: "device-a"))
        XCTAssertTrue(LAAOwnerTaskOutbox.restoreRejected(item, in: store))
        XCTAssertEqual(LAAOwnerTaskLocalDrafts.read(store, deviceID: "device-a", taskID: id), .saved(draft))
    }

    func testExplicitMoveKeepsUnknownRequestUUIDKeyAndBytesAcrossRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("drafts.json")
        let store = ComposerDraftStore(capacity: .max, fileURL: file)
        var draft = LAAOwnerTaskDraft(id: id); draft.title = "移した作成"
        XCTAssertTrue(LAAOwnerTaskLocalDrafts.save(draft, in: store, deviceID: "device-a"))
        let original = try LAAOwnerTaskRequest.create(draft, deviceID: "device-a", key: "same-key")
        let item = try XCTUnwrap(LAAOwnerTaskOutbox.reserve(original, in: store))
        XCTAssertTrue(LAAOwnerTaskOutbox.move(item, to: "device-b", in: store))
        let reloaded = ComposerDraftStore(capacity: .max, fileURL: file)
        let movedItem = try XCTUnwrap(LAAOwnerTaskOutbox.entries(in: reloaded).first)
        let moved = try XCTUnwrap(LAAOwnerTaskOutbox.request(movedItem))
        XCTAssertEqual(moved.deviceID, "device-b")
        XCTAssertEqual(moved.originalDeviceID, "device-a")
        XCTAssertEqual(moved.taskID, original.taskID)
        XCTAssertEqual(moved.key, original.key)
        XCTAssertEqual(moved.body, original.body)
        XCTAssertEqual(reloaded.unknownSubmissions.count, 1)
    }

    func testMoveRefusesToReplaceDestinationDraft() throws {
        let store = ComposerDraftStore(capacity: .max)
        var draft = LAAOwnerTaskDraft(id: id); draft.title = "古い端末"
        XCTAssertTrue(LAAOwnerTaskLocalDrafts.save(draft, in: store, deviceID: "device-a"))
        let old = try XCTUnwrap(LAAOwnerTaskLocalDrafts.entries(in: store).first)
        var other = draft; other.title = "新しい端末"
        XCTAssertTrue(LAAOwnerTaskLocalDrafts.save(other, in: store, deviceID: "device-b"))
        XCTAssertFalse(LAAOwnerTaskLocalDrafts.move(old, to: "device-b", in: store))
        XCTAssertEqual(LAAOwnerTaskLocalDrafts.read(store, deviceID: "device-a", taskID: id), .saved(draft))
        XCTAssertEqual(LAAOwnerTaskLocalDrafts.read(store, deviceID: "device-b", taskID: id), .saved(other))
    }

    func testMoveOfUnsentDraftIsExplicitAndKeepsIdentity() throws {
        let store = ComposerDraftStore(capacity: .max)
        var draft = LAAOwnerTaskDraft(id: id); draft.title = "端末内の入力"
        draft.memo = "続き"
        XCTAssertTrue(LAAOwnerTaskLocalDrafts.save(draft, in: store, deviceID: "device-a"))
        let old = try XCTUnwrap(LAAOwnerTaskLocalDrafts.entries(in: store).first)
        XCTAssertTrue(LAAOwnerTaskLocalDrafts.move(old, to: "device-b", in: store))
        XCTAssertEqual(LAAOwnerTaskLocalDrafts.read(store, deviceID: "device-a", taskID: id), .absent)
        XCTAssertEqual(LAAOwnerTaskLocalDrafts.read(store, deviceID: "device-b", taskID: id), .saved(draft))
        XCTAssertTrue(LAAOwnerTaskOutbox.entries(in: store).isEmpty)
    }

    func testRestoredInlineTitleDoesNotEraseMemoDateOrLinks() throws {
        let store = ComposerDraftStore(capacity: .max)
        var draft = LAAOwnerTaskDraft(id: id)
        draft.title = "前の題名"; draft.memo = "残すメモ"; draft.dueDateText = "2026-11-08"
        draft.links = ["https://example.com"]
        XCTAssertTrue(LAAOwnerTaskLocalDrafts.save(draft, in: store, deviceID: "device-a"))
        let changed = try XCTUnwrap(LAAOwnerTaskLocalDrafts.updatingInlineTitle("新しい題名", store: store, deviceID: "device-a", taskID: id))
        XCTAssertEqual(changed.title, "新しい題名")
        XCTAssertEqual(changed.memo, draft.memo)
        XCTAssertEqual(changed.dueDateText, draft.dueDateText)
        XCTAssertEqual(changed.links, draft.links)
        XCTAssertEqual(changed.id, id)
    }

    func testFailedMoveKeepsOriginalPendingRequest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("drafts.json")
        let store = ComposerDraftStore(capacity: .max, fileURL: file)
        var draft = LAAOwnerTaskDraft(id: id); draft.title = "保留"
        XCTAssertTrue(LAAOwnerTaskLocalDrafts.save(draft, in: store, deviceID: "device-a"))
        let request = try LAAOwnerTaskRequest.create(draft, deviceID: "device-a", key: "key-i")
        let item = try XCTUnwrap(LAAOwnerTaskOutbox.reserve(request, in: store))
        let backup = directory.appendingPathComponent("backup.json")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertFalse(LAAOwnerTaskOutbox.move(item, to: "device-b", in: store))
        XCTAssertEqual(LAAOwnerTaskOutbox.request(try XCTUnwrap(LAAOwnerTaskOutbox.entries(in: store).first)), request)
        let recovered = ComposerDraftStore(capacity: .max, fileURL: backup)
        XCTAssertEqual(LAAOwnerTaskOutbox.request(try XCTUnwrap(LAAOwnerTaskOutbox.entries(in: recovered).first)), request)
    }

    func testUnreadableOutboxEntryIsStillCounted() throws {
        let store = ComposerDraftStore(capacity: .max)
        let key = try XCTUnwrap(LAAOwnerTaskLocalDrafts.key(deviceID: "device-a", taskID: id))
        let item = ComposerDraftStore.Submission(id: UUID(), key: key, dashboardID: LAAWorkDrafts.dashboardID,
            draft: ComposerDraft(text: "unreadable", attachments: []), pendingSendID: nil,
            groupEventID: "key", groupOutboundText: "corrupt")
        XCTAssertTrue(store.beginSubmission(item, clearingDraft: false))
        XCTAssertEqual(LAAOwnerTaskOutbox.entries(in: store).count, 1)
        XCTAssertNil(LAAOwnerTaskOutbox.request(item))
    }

    func testCacheIsIsolatedByDeviceAndRetainsFullOfflineDetail() throws {
        let store = ComposerDraftStore(capacity: .max)
        let cached = LAAOwnerTaskCache(items: [task()], details: [task()], observedAt: Date(timeIntervalSince1970: 1))
        XCTAssertTrue(LAAOwnerTaskCacheStore.save(cached, in: store, deviceID: "device-a"))
        XCTAssertEqual(LAAOwnerTaskCacheStore.read(store, deviceID: "device-a"), cached)
        XCTAssertNil(LAAOwnerTaskCacheStore.read(store, deviceID: "device-b"))
    }

    func testInvalidInputIsRejectedBeforeNetworkReservation() throws {
        var draft = LAAOwnerTaskDraft(id: id)
        draft.title = "一行\n二行"
        XCTAssertThrowsError(try LAAOwnerTaskRequest.create(draft, deviceID: "device-a", key: "key-h"))
        draft.title = String(repeating: "題", count: 501)
        XCTAssertThrowsError(try LAAOwnerTaskRequest.create(draft, deviceID: "device-a", key: "key-h"))
        draft.title = "題名"
        draft.memo = String(repeating: "文", count: 20_001)
        XCTAssertThrowsError(try LAAOwnerTaskRequest.create(draft, deviceID: "device-a", key: "key-h"))
    }
}
#endif

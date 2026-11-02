#if LAA_BUILD
import XCTest
@testable import Conduit

@MainActor
final class LAAWorkTests: XCTestCase {
    private func session(_ id: String, name: String, parent: String? = nil,
                         updated: String, requested: [String: String] = [:],
                         observed: [String: String]? = nil) throws -> LAAWorkSession {
        let json: [String: Any] = [
            "id": id, "name": name, "nameSource": "owner", "requestId": id,
            "parentId": parent as Any? ?? NSNull(), "workspaceId": "ws_test",
            "profile": "test", "requested": requested, "observed": observed as Any? ?? NSNull(),
            "phase": "running", "createdAt": updated, "updatedAt": updated,
            "events": ["lastSeq": 1, "oldestSeq": 1, "cursor": "cursor"]
        ]
        return try JSONDecoder().decode(LAAWorkSession.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testRoutineReadsMissingObservationsAsUnknown() throws {
        let data = Data(#"{"items":[{"id":"job:a","name":"Daily","schedule":"daily","nextRunAt":null,"lastRunAt":null,"result":null}],"nextCursor":null}"#.utf8)
        let page = try JSONDecoder().decode(LAAWorkPage<LAAWorkRoutine>.self, from: data)
        XCTAssertEqual(page.items.first?.name, "Daily")
        XCTAssertNil(page.items.first?.nextRunAt)
        XCTAssertNil(page.items.first?.lastRunAt)
        XCTAssertNil(page.items.first?.result)
    }

    func testRoutinePageKeepsTheBridgeFetchTime() throws {
        let data = Data(#"{"items":[],"nextCursor":null,"fetchedAt":"2026-11-02T12:00:00.000Z"}"#.utf8)
        let page = try JSONDecoder().decode(LAAWorkPage<LAAWorkRoutine>.self, from: data)
        let fetched = try XCTUnwrap(LAAWorkFreshness.date(page.fetchedAt))
        XCTAssertEqual(fetched.timeIntervalSince1970, 1_793_620_800, accuracy: 0.001)
    }

    func testRoutineFreshnessUsesTheBridgeWindow() {
        let fetched = Date(timeIntervalSince1970: 1_793_620_800)
        XCTAssertFalse(LAAWorkFreshness.isStale(fetched, now: fetched.addingTimeInterval(59)))
        XCTAssertFalse(LAAWorkFreshness.isStale(fetched, now: fetched.addingTimeInterval(60)))
        XCTAssertTrue(LAAWorkFreshness.isStale(fetched, now: fetched.addingTimeInterval(61)))
        XCTAssertFalse(LAAWorkFreshness.isStale(nil))
        XCTAssertEqual(LAAWorkFreshness.date("2026-11-02T12:00:00Z"), fetched)
        XCTAssertNil(LAAWorkFreshness.date(nil))
        XCTAssertNil(LAAWorkFreshness.date(""))
    }

    func testFavouritesComeFirstAndArchivedOrWorktreeFieldsDecode() throws {
        let older = try session("o", name: "古い", updated: "2026-10-01T00:00:00Z")
        let newer = try session("n", name: "新しい", updated: "2026-10-03T00:00:00Z")
        let pinnedData = Data(#"{"id":"f","name":"ピン","requestId":"f","workspaceId":"home","profile":"opus-high","phase":"running","createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-01T00:00:00Z","events":{"lastSeq":1,"oldestSeq":1,"cursor":"c"},"favorite":true,"archivedAt":null,"mode":"bypass","fast":true,"worktree":false}"#.utf8)
        let pinned = try JSONDecoder().decode(LAAWorkSession.self, from: pinnedData)
        let rows = LAAWorkSessionOrder.rows([older, pinned, newer])
        XCTAssertEqual(rows.pinned.map(\.id), ["f"])
        XCTAssertEqual(rows.recent.map(\.id), ["n", "o"])
        XCTAssertTrue(pinned.isFavorite)
        XCTAssertFalse(pinned.isArchived)
        XCTAssertEqual(pinned.fast, true)
        XCTAssertFalse(older.isFavorite, "an older Bridge omits the field")
    }

    func testModelLabelsAndSavedFavouritesRoundTrip() throws {
        let data = Data(#"{"profiles":[{"id":"opus-high","label":"Claude Opus 5.5","provider":"claude","model":"claude-opus-5-5","effort":"high","fast":true},{"id":"sol-xhigh","label":"GPT-6.1 Terra","provider":"codex","model":"gpt-6.1-terra","effort":"xhigh","fast":true}],"defaultProfile":"opus-high","defaultMode":"bypass"}"#.utf8)
        let options = try JSONDecoder().decode(LAAWorkSessionOptions.self, from: data)
        XCTAssertEqual(LAAWorkSessionStyle.profileLabel(options.profiles[0]), "Opus 5.5 High")
        XCTAssertEqual(LAAWorkSessionStyle.profileLabel(options.profiles[0], fast: true), "Opus 5.5 High ⚡︎")
        XCTAssertEqual(LAAWorkSessionStyle.profileLabel(options.profiles[1]), "GPT-6.1 Terra XHigh")
        XCTAssertEqual(LAAWorkSessionStyle.shortLabel("DeepSeek V4.1-Flash-1017"), "DeepSeek V4.1-Flash")
        let saved = [LAAWorkModelFavorite(profile: "opus-high", fast: true), LAAWorkModelFavorite(profile: "sol-xhigh", fast: false)]
        XCTAssertEqual(LAAWorkModelPreferences.decode(LAAWorkModelPreferences.encode(saved)), saved)
        XCTAssertEqual(LAAWorkModelPreferences.decode("not json"), [])
    }

    func testMissingObservationIsNotTreatedAsMatchOrMismatch() throws {
        let requested = ["provider": "dsh", "model": "expected", "effort": "high"]
        let missing = try session("a", name: "a", updated: "1", requested: requested)
        let mismatched = try session("b", name: "b", updated: "2", requested: requested,
                                     observed: ["provider": "dsh", "model": "different"])
        XCTAssertFalse(missing.modelMismatch)
        XCTAssertFalse(missing.runtimeVerified ?? false)
        XCTAssertTrue(mismatched.modelMismatch)
    }

    func testDecisionShortcutRequiresReportedPendingWorkOrDecisionPhase() throws {
        func decode(_ phase: String, pending: Int?) throws -> LAAWorkSession {
            var json: [String: Any] = ["id": "s", "name": "Session", "requestId": "s", "workspaceId": "ws",
                                       "profile": "test", "phase": phase, "createdAt": "1", "updatedAt": "1",
                                       "events": ["lastSeq": 1, "oldestSeq": 1, "cursor": "c"]]
            if let pending { json["pending"] = ["count": pending] }
            return try JSONDecoder().decode(LAAWorkSession.self, from: JSONSerialization.data(withJSONObject: json))
        }
        XCTAssertTrue(try decode("awaiting_decision", pending: nil).needsDecision)
        XCTAssertTrue(try decode("running", pending: 1).needsDecision)
        XCTAssertFalse(try decode("running", pending: 0).needsDecision)
        XCTAssertFalse(try decode("awaiting_review", pending: nil).needsDecision)
    }

    func testInstructionEditingRequiresBodyFromServer() throws {
        let old = try JSONDecoder().decode(LAAWorkProject.self, from: Data(#"{"id":"p","name":"旧","etag":"\"1\""}"#.utf8))
        let new = try JSONDecoder().decode(LAAWorkProject.self, from: Data(#"{"id":"p","name":"新","etag":"\"2\"","instructions":"共有"}"#.utf8))
        XCTAssertFalse(old.hasInstructionBody)
        XCTAssertTrue(new.hasInstructionBody)
        XCTAssertEqual(new.instructions, "共有")
    }

    func testLinearTaskDetailDecodesTaskInsideResponse() throws {
        // Bridge data contains a task plus optional comments and links.
        let data = Data(#"{"task":{"id":"linear:BUS-123","source":"linear","sourceId":"BUS-123","title":"依頼","description":"詳細","status":{"name":"Todo","type":"unstarted","category":"open"}},"comments":[],"links":[]}"#.utf8)
        let task = try JSONDecoder().decode(LAAWorkTaskDetailResponse.self, from: data).task
        XCTAssertEqual(task.id, "linear:BUS-123")
        XCTAssertEqual(task.description, "詳細")
        XCTAssertEqual(task.status?.name, "Todo")
    }

    func testLegacyProjectReferenceCanOnlyBeClearedExplicitly() throws {
        let encoder = JSONEncoder()
        let rename = LAAWorkProjectChanges(name: "名前", instructions: nil)
        let untouched = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(rename)) as? [String: Any])
        XCTAssertNil(untouched["instructionRef"])
        XCTAssertNil(untouched["instructions"])

        let remove = LAAWorkProjectChanges(name: "名前", instructions: "本文", clearInstructionRef: true)
        let cleared = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(remove)) as? [String: Any])
        XCTAssertTrue(cleared["instructionRef"] is NSNull)
        XCTAssertEqual(cleared["instructions"] as? String, "本文")
        let restored = try JSONDecoder().decode(LAAWorkProjectChanges.self, from: encoder.encode(remove))
        XCTAssertTrue(restored.clearInstructionRef)
    }

    func testInterruptedIntentRestoresExactRequestAndKeyWithoutResending() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("work-drafts.json")
        let key = LAAWorkDrafts.key(deviceID: "device-a", target: "new-session")
        let other = LAAWorkDrafts.key(deviceID: "device-b", target: "new-session")
        let payload = Data(#"{"prompt":"日本語","requestId":"request-1","workspaceId":"ws-1"}"#.utf8)
        let idempotency = try XCTUnwrap(LAABridgeIdempotencyKey(restoring: "intent-1"))
        let first = ComposerDraftStore(capacity: .max, fileURL: url)
        XCTAssertTrue(first.save(.init(text: "日本語", attachments: []), for: key))
        _ = try XCTUnwrap(LAAWorkDrafts.reserve(first, key: key, text: "日本語", body: payload, idempotency: idempotency))
        XCTAssertNil(LAAWorkDrafts.reserve(first, key: key, text: "重複", body: payload, idempotency: idempotency))

        let restored = ComposerDraftStore(capacity: .max, fileURL: url)
        let item = try XCTUnwrap(LAAWorkDrafts.pending(restored, key: key))
        let request = try XCTUnwrap(LAAWorkDrafts.request(item))
        XCTAssertEqual(restored.unknownSubmissions.count, 1)
        XCTAssertEqual(request.0, payload)
        XCTAssertEqual(request.1.value, "intent-1")
        XCTAssertNil(LAAWorkDrafts.pending(restored, key: other))
        XCTAssertEqual(item.draft.text, "日本語")
    }

    func testOldUnknownIntentCanBeReadButCannotBeRepeatedAfterRetentionWindow() throws {
        let store = ComposerDraftStore(capacity: .max)
        let key = LAAWorkDrafts.key(deviceID: "device-a", target: "message:session")
        let reserved = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = Data(#"{"message":"continued"}"#.utf8)
        let idempotency = try XCTUnwrap(LAABridgeIdempotencyKey(restoring: "intent-2"))
        let item = try XCTUnwrap(LAAWorkDrafts.reserve(store, key: key, text: "continued", body: payload,
                                                       idempotency: idempotency, now: reserved))
        XCTAssertTrue(LAAWorkDrafts.canRepeat(item, now: reserved.addingTimeInterval(5 * 24 * 60 * 60)))
        XCTAssertFalse(LAAWorkDrafts.canRepeat(item, now: reserved.addingTimeInterval(6 * 24 * 60 * 60)))
        XCTAssertFalse(LAAWorkDrafts.canRepeat(item, now: reserved.addingTimeInterval(-1)))
        XCTAssertEqual(LAAWorkDrafts.request(item)?.0, payload)

        var oldItem = item
        oldItem.groupOutboundText = String(decoding: payload, as: UTF8.self)
        XCTAssertFalse(LAAWorkDrafts.canRepeat(oldItem, now: reserved))
        XCTAssertEqual(LAAWorkDrafts.request(oldItem)?.0, payload)
    }

    func testServerRefusalsAndUnknownOutcomesAreDistinguished() {
        func error(_ status: Int, _ code: String) -> LAABridgeHTTPError {
            LAABridgeHTTPError(status: status, code: code, message: nil, retryable: nil,
                               details: nil, requestId: nil, currentETag: nil)
        }
        XCTAssertFalse(LAAWorkHTTP.outcomeUnknown(error(409, "pending_decision_requires_reply")))
        XCTAssertFalse(LAAWorkHTTP.outcomeUnknown(error(409, "session_busy")))
        XCTAssertTrue(LAAWorkHTTP.outcomeUnknown(error(409, "idempotency_outcome_unknown")))
        XCTAssertTrue(LAAWorkHTTP.outcomeUnknown(error(409, "send_outcome_unknown")))
        XCTAssertTrue(LAAWorkHTTP.outcomeUnknown(error(409, "message_id_conflict")))
        XCTAssertFalse(LAAWorkHTTP.outcomeUnknown(error(409, "message_limit_reached")))
        XCTAssertTrue(LAAWorkHTTP.outcomeUnknown(error(503, "delegation_timeout")))
        XCTAssertTrue(LAAWorkHTTP.isVersionConflict(error(412, "version_mismatch")))
    }

    func testProjectConflictRecordSurvivesUntilTheOwnerChooses() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rejected = UUID()
        let unknown = UUID()
        XCTAssertFalse(LAAWorkConflictJournal.contains(rejected, in: folder))
        XCTAssertTrue(LAAWorkConflictJournal.mark(rejected, in: folder))
        XCTAssertTrue(LAAWorkConflictJournal.contains(rejected, in: folder))
        XCTAssertFalse(LAAWorkConflictJournal.contains(unknown, in: folder))
        LAAWorkConflictJournal.clear(rejected, in: folder)
        XCTAssertFalse(LAAWorkConflictJournal.contains(rejected, in: folder))
    }
    func testSessionTreesKeepChildrenUnderParentsAndHandleCycles() throws {
        let parent = try session("p", name: "親", updated: "1")
        let child = try session("c", name: "子", parent: "p", updated: "3")
        let sibling = try session("s", name: "別", updated: "2")
        XCTAssertEqual(LAAWorkSessionOrder.rows([child, sibling, parent]).recent.map(\.id), ["s", "p", "c"])
        XCTAssertEqual(LAAWorkSessionOrder.depth(child, in: [child, parent]), 1)
        let cycle = try session("p", name: "親", parent: "c", updated: "1")
        XCTAssertEqual(Set(LAAWorkSessionOrder.rows([cycle, child]).recent.map(\.id)), ["p", "c"])
    }

    func testDeviceScopedSessionCacheRestoresBeforeAnyNetworkRead() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("cache.json")
        let row = try session("p", name: "保存済み", updated: "1")
        let store = ComposerDraftStore(capacity: .max, fileURL: url)
        LAAWorkSessionCache.save([row], store: store, device: "a", target: "list")
        let restored = ComposerDraftStore(capacity: .max, fileURL: url)
        let rows = LAAWorkSessionCache.read([LAAWorkSession].self, store: restored, device: "a", target: "list")
        XCTAssertEqual(rows?.first?.name, "保存済み")
        XCTAssertNil(LAAWorkSessionCache.read([LAAWorkSession].self, store: restored, device: "b", target: "list"))
    }

    func testNotificationLinksPreserveCalendarIdentityAndValidateSessionRoute() throws {
        let route = LAAWorkLinkRequest()
        XCTAssertTrue(route.open(try XCTUnwrap(URL(string: "laa://today/events/same-id?calendar=team%40example.com"))))
        XCTAssertEqual(route.calendarEvent?.id, "same-id")
        XCTAssertEqual(route.calendarEvent?.calendarID, "team@example.com")
        XCTAssertTrue(route.open(try XCTUnwrap(URL(string: "laa://today/events/same-id"))))
        XCTAssertNil(route.calendarEvent)
        XCTAssertTrue(route.open(try XCTUnwrap(URL(string: "laa://work/sessions/ses_0123456789abcdef"))))
        XCTAssertEqual(route.sessionID, "ses_0123456789abcdef")
        XCTAssertTrue(route.open(try XCTUnwrap(URL(string: "laa://work/sessions/agent-from-paseo"))))
        XCTAssertEqual(route.sessionTarget, "agent-from-paseo")
        XCTAssertNil(route.sessionID)
        XCTAssertFalse(route.open(try XCTUnwrap(URL(string: "https://example.com/work"))))
    }

    func testCalendarDeepLinkRoundTripPreservesGoogleIdentifierCharacters() throws {
        let route = LAAWorkLinkRequest()
        let values = [
            ("invite_123@google.com", "floralia@laa-inc.com"),
            ("holiday_123", "ja.japanese#holiday@group.v.calendar.google.com"),
            ("event+with_under_score@google.com", "team+calendar_123@group.calendar.google.com")
        ]
        let segmentCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_~."))
        for (event, calendar) in values {
            var link = URLComponents()
            link.scheme = "laa"; link.host = "today"
            link.percentEncodedPath = "/events/" + (try XCTUnwrap(event.addingPercentEncoding(withAllowedCharacters: segmentCharacters)))
            link.queryItems = [URLQueryItem(name: "calendar", value: calendar)]
            let url = try XCTUnwrap(link.url)
            XCTAssertTrue(route.open(url))
            XCTAssertEqual(route.calendarEvent?.id, event)
            XCTAssertEqual(route.calendarEvent?.calendarID, calendar)
        }
        XCTAssertTrue(route.open(try XCTUnwrap(URL(string: "laa://today/events/event%2B_uid%40google.com?calendar=team%2Bname%23holiday%40group.calendar.google.com"))))
        XCTAssertEqual(route.calendarEvent?.id, "event+_uid@google.com")
        XCTAssertEqual(route.calendarEvent?.calendarID, "team+name#holiday@group.calendar.google.com")
    }

    func testImageDraftAndExactRequestSurviveUncertainSubmission() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("draft.json")
        let key = LAAWorkDrafts.key(deviceID: "a", target: "message:p")
        let image = Attachment(id: "image-1", name: "画像", uri: "data:image/jpeg;base64,YWJj", mimeType: "image/jpeg", kind: .image)
        let store = ComposerDraftStore(capacity: .max, fileURL: url)
        let payload = Data(#"{"message":"確認","images":[{"data":"YWJj","mimeType":"image/jpeg"}]}"#.utf8)
        let item = try XCTUnwrap(LAAWorkDrafts.reserve(store, key: key, text: "確認", body: payload,
                                                      idempotency: LAABridgeIdempotencyKey(), attachments: [image]))
        store.markSubmissionUnknown(item.id)
        let restored = ComposerDraftStore(capacity: .max, fileURL: url)
        let pending = try XCTUnwrap(LAAWorkDrafts.pending(restored, key: key))
        XCTAssertEqual(LAAWorkDrafts.request(pending)?.0, payload)
        XCTAssertEqual(pending.draft.attachments.first?.uri, image.uri)
        XCTAssertTrue(restored.finishSubmission(pending.id, restoring: true))
        XCTAssertEqual(restored.draft(for: key).attachments.first?.id, "image-1")
    }

}
#endif

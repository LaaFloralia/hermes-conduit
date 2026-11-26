#if LAA_BUILD
import XCTest
@testable import Conduit

@MainActor
final class LAAWorkTests: XCTestCase {
    private func session(_ id: String, name: String, parent: String? = nil,
                         updated: String, phase: String = "running", requested: [String: String] = [:],
                         observed: [String: String]? = nil) throws -> LAAWorkSession {
        let json: [String: Any] = [
            "id": id, "name": name, "nameSource": "owner", "requestId": id,
            "parentId": parent as Any? ?? NSNull(), "workspaceId": "ws_test",
            "profile": "test", "requested": requested, "observed": observed as Any? ?? NSNull(),
            "phase": phase, "createdAt": updated, "updatedAt": updated,
            "events": ["lastSeq": 1, "oldestSeq": 1, "cursor": "cursor"]
        ]
        return try JSONDecoder().decode(LAAWorkSession.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testWorkListKeepsTheLAAProjectItsChildrenAndPinnedSessions() throws {
        func row(_ id: String, project: String?, cwd: String?, parent: String? = nil,
                 favorite: Bool? = nil) throws -> LAAWorkSession {
            var json: [String: Any] = [
                "id": id, "name": id, "nameSource": "owner", "requestId": id,
                "parentId": parent as Any? ?? NSNull(), "workspaceId": "ws_test",
                "profile": "test", "requested": [:], "observed": NSNull(),
                "phase": "running", "createdAt": "2026-11-03T00:00:00Z", "updatedAt": "2026-11-03T00:00:00Z",
                "events": ["lastSeq": 1, "oldestSeq": 1, "cursor": "cursor"]
            ]
            if let project { json["projectId"] = project }
            if let cwd { json["cwd"] = cwd }
            if let favorite { json["favorite"] = favorite }
            return try JSONDecoder().decode(LAAWorkSession.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let projects = try JSONDecoder().decode([LAAWorkProject].self, from: JSONSerialization.data(withJSONObject: [
            ["id": "proj_laa", "name": "LAA"], ["id": "proj_other", "name": "Hermes"],
        ]))
        let sessions = try [
            row("project", project: "proj_laa", cwd: "/Users/laa"),
            row("rootcwd", project: "proj_other", cwd: "/Users/laa"),
            row("child", project: "proj_other", cwd: "/Users/laa/.paseo/worktrees/x", parent: "project"),
            row("oldworktree", project: "proj_other", cwd: "/Users/laa/work/old-20261018"),
            row("pinned", project: "proj_other", cwd: "/Users/laa/dev/hp", favorite: true),
        ]
        XCTAssertEqual(LAAWorkSessionScope.default(sessions, projects: projects).map(\.id),
                       ["project", "rootcwd", "child", "pinned"])
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
        XCTAssertEqual(LAAWorkSessionStyle.profileLabel(options.profiles[0], fast: true), "Opus 5.5 High · Fast")
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

    func testUnresolvedLaunchesKeepTheirIdentityWithoutBlockingIndependentNewWork() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("work-drafts.json")
        let key = LAAWorkDrafts.key(deviceID: "device-a", target: "launch-session")
        var store = ComposerDraftStore(capacity: .max, fileURL: url)
        var saved: [(UUID, Data, String)] = []
        for n in 0..<3 {
            let body = Data("{\"requestId\":\"failed-\(n)\",\"prompt\":\"saved \(n)\"}".utf8)
            let token = try XCTUnwrap(LAABridgeIdempotencyKey(restoring: "launch-\(n)"))
            let item = try XCTUnwrap(LAAWorkDrafts.reserve(store, key: key, text: "saved \(n)", body: body,
                                                        idempotency: token, independentLaunch: true))
            store.markSubmissionUnknown(item.id)
            XCTAssertNil(LAAWorkDrafts.reserve(store, key: key, text: "duplicate", body: body,
                                              idempotency: token, independentLaunch: true))
            saved.append((item.id, body, token.value))
        }
        let successBody = Data(#"{"requestId":"new-work","prompt":"new independent request"}"#.utf8)
        let success = try XCTUnwrap(LAAWorkDrafts.reserve(store, key: key, text: "new independent request", body: successBody,
            idempotency: LAABridgeIdempotencyKey(), independentLaunch: true))
        XCTAssertTrue(store.finishSubmission(success.id, restoring: false))
        XCTAssertTrue(store.save(.init(text: "next draft", attachments: []), for: key))
        store = ComposerDraftStore(capacity: .max, fileURL: url)
        XCTAssertEqual(store.submissions.count, 3)
        XCTAssertEqual(store.draft(for: key).text, "next draft")
        for (id, body, token) in saved {
            let item = try XCTUnwrap(store.submissions.first { $0.id == id })
            XCTAssertEqual(LAAWorkDrafts.request(item)?.0, body)
            XCTAssertEqual(LAAWorkDrafts.request(item)?.1.value, token)
        }
        let next = try XCTUnwrap(LAAWorkDrafts.reserve(store, key: key, text: "after restart", body: Data(#"{"requestId":"after-restart"}"#.utf8),
            idempotency: LAABridgeIdempotencyKey(), independentLaunch: true))
        XCTAssertTrue(store.finishSubmission(next.id, restoring: false))
        XCTAssertEqual(store.submissions.map(\.id), saved.map { $0.0 })
        // This exception applies only to new sessions, never another chat's send.
        XCTAssertNil(LAAWorkDrafts.reserve(store, key: LAAWorkDrafts.key(deviceID: "device-a", target: "message:existing"),
            text: "guard", body: successBody, idempotency: LAABridgeIdempotencyKey(), independentLaunch: true))
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

    func testChildrenFoldUnderTheirParentUntilOpened() throws {
        let parent = try session("p", name: "親", updated: "1")
        let child = try session("c", name: "子", parent: "p", updated: "2")
        let grandchild = try session("g", name: "孫", parent: "c", updated: "3")
        let other = try session("o", name: "別", updated: "0")
        let rows = [parent, child, grandchild, other]
        XCTAssertEqual(LAAWorkSessionOrder.visible(rows, expanded: []).map(\.id), ["p", "o"])
        XCTAssertEqual(LAAWorkSessionOrder.visible(rows, expanded: ["p"]).map(\.id), ["p", "c", "o"])
        XCTAssertEqual(LAAWorkSessionOrder.visible(rows, expanded: ["p", "c"]).map(\.id), ["p", "c", "g", "o"])
        XCTAssertEqual(LAAWorkSessionOrder.visible(rows, expanded: ["c"]).map(\.id), ["p", "o"], "A closed grandparent hides everything below it")
        let tree = LAAWorkSessionOrder.descendants(rows)
        XCTAssertEqual(tree["p"]?.map(\.id), ["c", "g"])
        XCTAssertEqual(tree["c"]?.map(\.id), ["g"])
        XCTAssertNil(tree["o"])
        let orphan = try session("x", name: "親なし", parent: "archived", updated: "1")
        XCTAssertEqual(LAAWorkSessionOrder.visible([orphan], expanded: []).map(\.id), ["x"], "A child whose parent is not listed stays visible")
        let cycle = try session("p", name: "親", parent: "c", updated: "1")
        XCTAssertEqual(LAAWorkSessionOrder.descendants([cycle, child])["p"]?.map(\.id), ["c"])
    }

    func testProjectArchiveFieldDecodes() throws {
        let older = try JSONDecoder().decode(LAAWorkProject.self, from: Data(#"{"id":"prj_1","name":"旧"}"#.utf8))
        XCTAssertFalse(older.isArchived, "an older Bridge omits the field")
        let archived = try JSONDecoder().decode(LAAWorkProject.self, from: Data(#"{"id":"prj_2","name":"済","archivedAt":"2026-11-05T00:00:00Z"}"#.utf8))
        XCTAssertTrue(archived.isArchived)
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

    func testChatScheduledSectionNeverCallsAnUnreadListEmpty() {
        XCTAssertEqual(LAAChatsCron.loadState(.ready, connected: true), .ready)
        XCTAssertEqual(LAAChatsCron.loadState(.loading, connected: true), .loading)
        XCTAssertEqual(LAAChatsCron.loadState(.idle, connected: true), .loading)
        XCTAssertEqual(LAAChatsCron.loadState(.loading, connected: false), .offline)
        XCTAssertEqual(LAAChatsCron.loadState(.failed("x"), connected: true), .failed(LAACopy.chatsCronUnavailable))
        XCTAssertTrue(LAACopy.chatsCronUnavailable.contains("読み込めません"))
        XCTAssertNotEqual(LAACopy.chatsCronUnavailable, LAACopy.chatsCronNone)
    }

    /// Stands in for a bridge or client instance: only its identity matters,
    /// and a re-created connection is a new object.
    private func cronConnection(_ object: NSObject, dashboard: UUID?,
                                profile: String = "laa-monet",
                                kind: CronJobsConnection.Kind = .dashboard) -> CronJobsConnection {
        CronJobsConnection(kind: kind,
                           owner: CronJobsOwner(dashboardID: dashboard, profile: profile),
                           object: object)
    }

    func testCronReadPublishesOnlyForTheConnectionItReadThrough() {
        let macA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")
        let macB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")
        let bridgeA = NSObject()
        let bridgeAReplaced = NSObject()
        let connection = cronConnection(bridgeA, dashboard: macA)
        let reconnected = cronConnection(bridgeAReplaced, dashboard: macA)
        let otherDashboard = cronConnection(bridgeA, dashboard: macB)

        // A read for this connection is not started twice...
        XCTAssertFalse(CronJobsReadDecision.mayStart(loadingConnection: connection, connection: connection))
        // ...but a re-created bridge for the same dashboard and profile, or
        // another dashboard, is a different connection and may start.
        XCTAssertTrue(CronJobsReadDecision.mayStart(loadingConnection: connection, connection: reconnected))
        XCTAssertTrue(CronJobsReadDecision.mayStart(loadingConnection: connection, connection: otherDashboard))
        XCTAssertTrue(CronJobsReadDecision.mayStart(loadingConnection: nil, connection: connection))

        XCTAssertTrue(CronJobsReadDecision.mayPublish(connection: connection, activeConnection: connection,
                                                      generation: 1, currentGeneration: 1))
        // The same profile and dashboard through a replaced bridge: the old
        // answer belongs to a connection that no longer exists.
        XCTAssertFalse(CronJobsReadDecision.mayPublish(connection: connection, activeConnection: reconnected,
                                                       generation: 1, currentGeneration: 1))
        XCTAssertFalse(CronJobsReadDecision.mayPublish(connection: connection, activeConnection: otherDashboard,
                                                       generation: 1, currentGeneration: 1))
        // No connection at all, and a job deleted while the read was in flight.
        XCTAssertFalse(CronJobsReadDecision.mayPublish(connection: connection, activeConnection: nil,
                                                       generation: 1, currentGeneration: 1))
        XCTAssertFalse(CronJobsReadDecision.mayPublish(connection: connection, activeConnection: connection,
                                                       generation: 1, currentGeneration: 2))
    }

    func testCronDropReloadsForAReplacedBridgeButNotForAChangedOwner() {
        let macA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")
        let bridgeA = NSObject()
        let bridgeAReplaced = NSObject()
        let connection = cronConnection(bridgeA, dashboard: macA)
        let reconnected = cronConnection(bridgeAReplaced, dashboard: macA)
        // Same dashboard and profile after a reconnect: read again there.
        XCTAssertTrue(CronJobsReadDecision.shouldReloadAfterDrop(owner: connection.owner, activeOwner: reconnected.owner))
        // Switched away or offline: the owner now on screen has its own reader.
        XCTAssertFalse(CronJobsReadDecision.shouldReloadAfterDrop(owner: connection.owner,
                                                                 activeOwner: cronConnection(bridgeA, dashboard: UUID()).owner))
        XCTAssertFalse(CronJobsReadDecision.shouldReloadAfterDrop(owner: connection.owner, activeOwner: nil))
    }

    func testCronRowsShowOnlyForTheConnectionThatReadThem() {
        let macA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")
        let bridgeA = NSObject()
        let bridgeAReplaced = NSObject()
        let connection = cronConnection(bridgeA, dashboard: macA)
        let reconnected = cronConnection(bridgeAReplaced, dashboard: macA)

        XCTAssertTrue(CronJobsReadDecision.showsRows(rowsConnection: connection, activeConnection: connection))
        // Same dashboard and profile through a re-created bridge: the old rows
        // are not this connection's, and the screen waits for its read.
        XCTAssertFalse(CronJobsReadDecision.showsRows(rowsConnection: connection, activeConnection: reconnected))
        XCTAssertFalse(CronJobsReadDecision.showsRows(rowsConnection: connection, activeConnection: nil))
        XCTAssertFalse(CronJobsReadDecision.showsRows(rowsConnection: nil, activeConnection: connection))
        // Hiding them while that read runs is a loading screen, not "no jobs".
        XCTAssertEqual(CronJobsReadDecision.phase(loadingConnection: reconnected, phaseConnection: reconnected,
                                                  phase: .loading, activeConnection: reconnected), .loading)
    }

    func testCronPhaseNeverBorrowsAnotherConnectionsRead() {
        let macA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")
        let bridgeA = NSObject()
        let bridgeAReplaced = NSObject()
        let connection = cronConnection(bridgeA, dashboard: macA)
        let reconnected = cronConnection(bridgeAReplaced, dashboard: macA)

        XCTAssertEqual(CronJobsReadDecision.phase(loadingConnection: connection, phaseConnection: connection,
                                                  phase: .loading, activeConnection: connection), .loading)
        XCTAssertEqual(CronJobsReadDecision.phase(loadingConnection: nil, phaseConnection: connection,
                                                  phase: .failed("x"), activeConnection: connection), .failed("x"))
        XCTAssertEqual(CronJobsReadDecision.phase(loadingConnection: nil, phaseConnection: connection,
                                                  phase: .ready, activeConnection: connection), .ready)
        // A read still running for the replaced bridge must not spin the new one.
        XCTAssertEqual(CronJobsReadDecision.phase(loadingConnection: connection, phaseConnection: connection,
                                                  phase: .loading, activeConnection: reconnected), .idle)
        // An old connection's failure or readiness says nothing about the new one.
        XCTAssertEqual(CronJobsReadDecision.phase(loadingConnection: nil, phaseConnection: connection,
                                                  phase: .failed("x"), activeConnection: reconnected), .idle)
        XCTAssertEqual(CronJobsReadDecision.phase(loadingConnection: nil, phaseConnection: connection,
                                                  phase: .ready, activeConnection: reconnected), .idle)
        // A `loading` left behind by a read that no longer runs does not spin.
        XCTAssertEqual(CronJobsReadDecision.phase(loadingConnection: nil, phaseConnection: reconnected,
                                                  phase: .loading, activeConnection: reconnected), .idle)
        XCTAssertEqual(CronJobsReadDecision.phase(loadingConnection: nil, phaseConnection: connection,
                                                  phase: .failed("x"), activeConnection: nil), .idle)
    }

    func testChatCronPayloadOnlyCallsAnEmptyArrayEmpty() {
        func job(_ value: Any) -> CronJob? {
            guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
            return try? JSONDecoder().decode(CronJob.self, from: data)
        }
        var outcome = CronJobsPayload.decode(rows: [], decode: job)
        if case .jobs(let jobs, let skipped) = outcome {
            XCTAssertTrue(jobs.isEmpty)
            XCTAssertEqual(skipped, 0)
        } else { XCTFail("an empty array is the only empty schedule") }

        // No job array at all (a changed document) is a failed read.
        if case .jobs = CronJobsPayload.decode(rows: nil, decode: job) {
            XCTFail("a document without jobs is not an empty schedule")
        }
        // Every row undecodable is a changed shape, not an empty list.
        if case .jobs = CronJobsPayload.decode(rows: [["nope": 1], ["also": 2]], decode: job) {
            XCTFail("all rows failing must not read as no jobs")
        }
        // A mixed answer keeps the readable rows and says how many are missing.
        outcome = CronJobsPayload.decode(rows: [["id": "a", "enabled": true], ["id": 7]], decode: job)
        if case .jobs(let jobs, let skipped) = outcome {
            XCTAssertEqual(jobs.map(\.id), ["a"])
            XCTAssertEqual(skipped, 1)
        } else { XCTFail("a partial list stays a list") }
        XCTAssertTrue(LAACopy.chatsCronPartial(2).contains("2件"))
    }

    func testRoutinePageKeepsTheBridgesSkippedCount() throws {
        let partial = Data(#"{"items":[],"nextCursor":null,"skipped":3,"fetchedAt":"2026-11-02T12:00:00Z"}"#.utf8)
        let page = try JSONDecoder().decode(LAAWorkPage<LAAWorkRoutine>.self, from: partial)
        XCTAssertEqual(page.skipped, 3, "a partial list must not decode as a whole one")
        let whole = Data(#"{"items":[],"nextCursor":null}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(LAAWorkPage<LAAWorkRoutine>.self, from: whole).skipped)
    }

    func testAppliedModelAndFastComeFromTheDaemonNotTheRequest() throws {
        let data = Data(#"{"id":"s","name":"短い題名","nameSource":"agent","requestId":"s","workspaceId":"w","profile":"opus-xhigh","requested":{"provider":"claude","model":"claude-opus-5-5","effort":"xhigh"},"observed":{"provider":"claude","model":"claude-opus-5-5","effort":"xhigh"},"runtimeVerified":true,"observedFast":false,"capabilities":{"effort":true},"phase":"awaiting_review","createdAt":"2026-11-06T00:00:00Z","updatedAt":"2026-11-06T00:00:00Z","events":{"lastSeq":1,"oldestSeq":1,"cursor":"c"}}"#.utf8)
        let session = try JSONDecoder().decode(LAAWorkSession.self, from: data)
        let options = try JSONDecoder().decode(LAAWorkSessionOptions.self, from: Data(#"{"profiles":[{"id":"opus-xhigh","label":"Claude Opus 5.5","provider":"claude","model":"claude-opus-5-5","effort":"xhigh","fast":true},{"id":"opus-high","label":"Claude Opus 5.5","provider":"claude","model":"claude-opus-5-5","effort":"high","fast":true}],"defaultProfile":"opus-xhigh","defaultMode":"bypass"}"#.utf8))
        XCTAssertEqual(LAAWorkSessionStyle.appliedModel(session, options: options), "Opus 5.5 · XHigh")
        XCTAssertEqual(LAAWorkSessionStyle.effortChoices(session, options: options), ["high", "xhigh"])
        XCTAssertEqual(session.observedFast, false)
        XCTAssertEqual(session.capabilities?.effort, true)

        // No observation and no Fast value: the detail shows nothing rather
        // than presenting the request as the current setting.
        let unknown = try JSONDecoder().decode(LAAWorkSession.self, from: Data(#"{"id":"u","name":"u","requestId":"u","workspaceId":"w","profile":"opus-high","requested":{"provider":"claude","model":"claude-opus-5-5","effort":"high"},"observed":null,"observedFast":null,"capabilities":{"effort":false},"phase":"created","createdAt":"2026-11-06T00:00:00Z","updatedAt":"2026-11-06T00:00:00Z","events":{"lastSeq":1,"oldestSeq":1,"cursor":"c"}}"#.utf8))
        XCTAssertNil(LAAWorkSessionStyle.appliedModel(unknown, options: options))
        XCTAssertTrue(LAAWorkSessionStyle.effortChoices(unknown, options: options).isEmpty)
        XCTAssertNil(unknown.observedFast)
        XCTAssertEqual(unknown.capabilities?.effort, false)

        // Hide an incomplete applied model and keep the generic speaker name.
        let noEffort = try JSONDecoder().decode(LAAWorkSession.self, from: Data(#"{"id":"e","name":"e","requestId":"e","workspaceId":"w","profile":"opus-high","requested":{"provider":"claude","model":"claude-opus-5-5","effort":"high"},"observed":{"provider":"claude","model":"claude-opus-5-5"},"observedFast":true,"capabilities":{"effort":true},"phase":"running","createdAt":"2026-11-06T00:00:00Z","updatedAt":"2026-11-06T00:00:00Z","events":{"lastSeq":1,"oldestSeq":1,"cursor":"c"}}"#.utf8))
        XCTAssertNil(LAAWorkSessionStyle.appliedModel(noEffort, options: options))
        XCTAssertEqual(LAAWorkSpeaker.agentName(noEffort, options: options), "AI")
    }

    /// The Fast pill: hidden when the model has no Fast, pressable only when
    /// the Bridge advertises the toggle, read-only when the last read failed.
    func testFastPillVisibilityAndPressability() throws {
        // Observed, and the Bridge accepts a change.
        let on = try XCTUnwrap(LAAWorkFastControl.display(observing: true, observed: true, capable: true))
        XCTAssertEqual(on, LAAWorkFastControl.Display(value: true, current: true, canToggle: true))
        XCTAssertEqual(LAAWorkFastControl.valueText(on), "オン")
        XCTAssertEqual(LAAWorkFastControl.hint(on), "Fastの切り替え")

        // No Fast at all for this model: nothing to show.
        XCTAssertNil(LAAWorkFastControl.display(observing: true, observed: nil, capable: true))
        XCTAssertNil(LAAWorkFastControl.display(observing: false, observed: nil, capable: true))

        // Fast exists, but this Bridge/session cannot change it.
        let readOnly = try XCTUnwrap(LAAWorkFastControl.display(observing: true, observed: false, capable: false))
        XCTAssertEqual(readOnly, LAAWorkFastControl.Display(value: false, current: true, canToggle: false))
        XCTAssertEqual(LAAWorkFastControl.valueText(readOnly), "オフ")
        XCTAssertFalse(readOnly.canToggle)
        // An older Bridge that never sent `capabilities.fast` is the same.
        XCTAssertEqual(LAAWorkFastControl.display(observing: true, observed: false, capable: nil)?.canToggle, false)

        // The daemon is unreachable: the last value stays, unpressed, and its
        // freshness is in the value/hint rather than in the word on screen.
        let last = try XCTUnwrap(LAAWorkFastControl.display(observing: false, observed: true, capable: true))
        XCTAssertEqual(last, LAAWorkFastControl.Display(value: true, current: false, canToggle: false))
        XCTAssertEqual(LAAWorkFastControl.valueText(last), "最終確認: オン")
        XCTAssertEqual(LAAWorkFastControl.hint(last), "最後に確認した値です。現在値は未確認です。")
    }

    func testCapabilitiesFastIsOptional() throws {
        func session(_ capabilities: String) throws -> LAAWorkSession {
            try JSONDecoder().decode(LAAWorkSession.self, from: Data(#"{"id":"s","name":"s","requestId":"s","workspaceId":"w","profile":"p","observed":{"provider":"claude","model":"claude-opus-5-5","effort":"high"},"observedFast":true,\#(capabilities),"phase":"running","createdAt":"2026-11-06T00:00:00Z","updatedAt":"2026-11-06T00:00:00Z","events":{"lastSeq":1,"oldestSeq":1,"cursor":"c"}}"#.utf8))
        }
        XCTAssertEqual(try session(#""capabilities":{"effort":true,"fast":true}"#).capabilities?.fast, true)
        XCTAssertEqual(try session(#""capabilities":{"effort":true,"fast":false}"#).capabilities?.fast, false)
        // An older Bridge omits the field: read as unknown, not as false.
        XCTAssertNil(try session(#""capabilities":{"effort":true}"#).capabilities?.fast)
        // A session answer with no capabilities at all still decodes.
        XCTAssertNil(try session(#""capabilities":null"#).capabilities)
    }

    /// Projects comes first and Work opens on it (owner, 2026-11-23); the
    /// board stays a section beside Sessions, not a card above them.
    func testWorkSectionsInTheReadingOrder() {
        XCTAssertEqual(LAAWorkHub.Section.allCases.map(\.rawValue),
                       ["projects", "sessions", "decisions", "campaigns", "tasks"])
        XCTAssertEqual(LAAWorkHub.Section.allCases.first, .projects)
        XCTAssertFalse(LAAWorkHub.Section.decisions.searchable)
    }

    func testStatusMarksSeparateDoneFromError() {
        XCTAssertEqual(LAAWorkStatus.session("awaiting_review"), .waiting, "a finished turn waits (BUS-508)")
        XCTAssertEqual(LAAWorkStatus.session("idle"), .waiting)
        XCTAssertEqual(LAAWorkStatus.session("closed"), .done)
        XCTAssertEqual(LAAWorkStatus.session("error"), .error)
        XCTAssertEqual(LAAWorkStatus.session("stop_unconfirmed"), .error)
        XCTAssertEqual(LAAWorkStatus.session("awaiting_decision"), .decision)
        XCTAssertEqual(LAAWorkStatus.session("running"), .running)
        XCTAssertEqual(LAAWorkStatus.done.color, LAAColor.link)
        XCTAssertEqual(LAAWorkStatus.error.color, LAAColor.end)
    }

    /// Every task row carries a unique number: the short one when the Bridge
    /// sends it, Linear's identifier otherwise.
    func testTaskNumberFallsBackToTheLinearIdentifier() {
        let base = LAALinearTask(id: "1", identifier: "BUS-7", title: "t", priority: 0, status: "todo",
                                 stateName: "Todo", updatedAt: "2026-11-11T00:00:00Z")
        var numbered = base; numbered.ref = "T12"
        XCTAssertEqual(LAATaskNumberLabel.number(numbered), "T12")
        XCTAssertEqual(LAATaskNumberLabel.number(base), "BUS-7")
    }

    func testActiveChildPromotesItsWholeTreeAheadOfPinnedCompletedWork() throws {
        let parent = try session("parent", name: "parent", updated: "2026-11-01T00:00:00Z", phase: "awaiting_review")
        let child = try session("child", name: "child", parent: "parent", updated: "2026-11-02T00:00:00Z", phase: "awaiting_decision")
        let finished = try session("finished", name: "finished", updated: "2026-11-03T00:00:00Z", phase: "awaiting_review")
        let groups = LAAWorkSessionOrder.sections([finished, child, parent])
        XCTAssertEqual(groups.active.map(\.id), ["parent", "child"])
        XCTAssertEqual(groups.recent.map(\.id), ["finished"])
        XCTAssertTrue(groups.pinned.isEmpty)
    }

    func testRawModelArrayUsesADisplayName() {
        XCTAssertEqual(LAAWorkSessionStyle.displayModel(#"["opencode-go","deepseek-v4.1-flash"]"#), "DeepSeek V4.1 Flash")
        XCTAssertEqual(LAAWorkSessionStyle.displayModel("gpt-6.1-sol"), "GPT 6.1 Sol")
        XCTAssertEqual(LAAWorkSessionStyle.displayModel(#"["private-provider","unknown"]"#), "AI")
    }

    // MARK: - Model and effort display (owner, 2026-11-12)

    private var tableOptions: LAAWorkSessionOptions {
        get throws {
            try JSONDecoder().decode(LAAWorkSessionOptions.self, from: Data("""
            {"profiles":[{"id":"fable-high","label":"Claude Fable 5.2","provider":"claude","model":"claude-fable-5-2","effort":"high","fast":false},
             {"id":"mythos-high","label":"Claude Mythos 5.2","provider":"claude","model":"claude-mythos-5-2","effort":"high","fast":false}]}
            """.utf8))
        }
    }

    /// A reply names the model the Bridge saw writing it, else the provider:
    /// the session's current model is never lent to it.
    func testEachReplyNamesItsOwnModelOrTheProvider() throws {
        let running = try session("s", name: "s", updated: "2026-11-11T07:00:00Z",
                                  requested: ["provider": "claude", "model": "claude-fable-5-2", "effort": "xhigh"],
                                  observed: ["provider": "claude", "model": "claude-opus-4-8", "effort": "xhigh"])
        let options = try tableOptions
        let fable = LAAWorkConversationMessage(id: "a1", role: "assistant", text: "1", timestamp: nil,
                                               model: LAAWorkModel(provider: "claude", model: "claude-fable-5-2", effort: nil, sources: nil))
        let unknown = LAAWorkConversationMessage(id: "a2", role: "assistant", text: "2", timestamp: nil)
        let opus = LAAWorkConversationMessage(id: "a3", role: "assistant", text: "3", timestamp: nil,
                                              model: LAAWorkModel(provider: "claude", model: "claude-opus-4-8", effort: nil, sources: nil))
        XCTAssertEqual(LAAWorkSpeaker.replyName(fable, session: running, options: options), "Fable 5.2")
        XCTAssertEqual(LAAWorkSpeaker.replyName(unknown, session: running, options: options), "Claude")
        XCTAssertEqual(LAAWorkSpeaker.replyName(opus, session: running, options: options), "Opus 4.8")
        XCTAssertNil(LAAWorkSpeaker.replyModel(unknown, session: running).model, "no model face is guessed")
        XCTAssertEqual(LAAModelFace.face(model: nil, provider: "claude"), .claude)
        let decoded = try JSONDecoder().decode(LAAWorkConversationPage.self, from: Data(
            #"{"items":[{"id":"a","role":"assistant","text":"x","timestamp":null,"model":{"provider":"claude","model":"claude-fable-5-2"}}]}"#.utf8))
        XCTAssertEqual(decoded.items.first?.model?.model, "claude-fable-5-2")
        XCTAssertNil(decoded.compacting, "an older Bridge omits compacting")
    }

    /// "依頼 Fable 5.2 → 実行 Opus 4.8", with when the Bridge saw the switch.
    func testMismatchNamesTheRequestAndWhatRuns() throws {
        let json = """
        {"id":"s","name":"s","requestId":"s","workspaceId":"w","profile":"fable-high",
         "requested":{"provider":"claude","model":"claude-fable-5-2","effort":"xhigh"},
         "observed":{"provider":"claude","model":"claude-opus-4-8","effort":"xhigh"},
         "modelChange":{"from":{"provider":"claude","model":"claude-fable-5-2"},"to":{"provider":"claude","model":"claude-opus-4-8"},
                        "seenAt":"2026-11-11T07:46:00Z","byOwner":false},
         "phase":"running","createdAt":"x","updatedAt":"x","events":{"lastSeq":1,"oldestSeq":1,"cursor":"c"}}
        """
        let switched = try JSONDecoder().decode(LAAWorkSession.self, from: Data(json.utf8))
        let mismatch = try XCTUnwrap(LAAWorkSessionStyle.mismatch(switched, options: try tableOptions))
        XCTAssertEqual(mismatch.requested, "Fable 5.2")
        XCTAssertEqual(mismatch.running, "Opus 4.8")
        XCTAssertTrue(mismatch.seen?.hasSuffix("に切替を確認") == true)
        // The owner's own switch is not reported as a provider's.
        let owned = try JSONDecoder().decode(LAAWorkSession.self, from: Data(
            json.replacingOccurrences(of: #""byOwner":false"#, with: #""byOwner":true"#).utf8))
        XCTAssertNil(LAAWorkSessionStyle.mismatch(owned, options: try tableOptions)?.seen)
        let agreeing = try session("a", name: "a", updated: "x",
                                   requested: ["provider": "claude", "model": "claude-fable-5-2", "effort": "high"],
                                   observed: ["provider": "claude", "model": "claude-fable-5-2", "effort": "high"])
        XCTAssertNil(LAAWorkSessionStyle.mismatch(agreeing, options: try tableOptions))
    }

    /// The session list names a model as the heading and the chip do; the id
    /// only when nothing readable is there.
    func testListNamesTheModelAsTheChipDoes() throws {
        let mythos = try session("m", name: "m", updated: "x",
                                 requested: ["provider": "claude", "model": "claude-mythos-5-2", "effort": "high"],
                                 observed: ["provider": "claude", "model": "claude-mythos-5-2", "effort": "high"])
        XCTAssertEqual(LAAWorkSessionStyle.model(mythos, options: nil), "Mythos 5.2 · High")
        let fable = try session("f", name: "f", updated: "x",
                                requested: ["provider": "claude", "model": "claude-fable-5", "effort": "xhigh"],
                                observed: ["provider": "claude", "model": "claude-fable-5", "effort": "xhigh"])
        XCTAssertEqual(LAAWorkSessionStyle.model(fable, options: nil), "Fable 5 · XHigh")
        XCTAssertEqual(LAAModelCapsule.displayName(model: "claude-fable-5", provider: "claude"), "Claude Fable 5")
        let unknown = try session("u", name: "u", updated: "x",
                                  requested: ["provider": "claude", "model": "kestrel-preview", "effort": "high"],
                                  observed: ["provider": "claude", "model": "kestrel-preview", "effort": "high"])
        XCTAssertEqual(LAAWorkSessionStyle.model(unknown, options: nil), "kestrel-preview · High")
    }

    /// Paseo's list for the running model is the menu; the table's profiles
    /// stand in only for a model Paseo did not list.
    func testARunningSessionOffersTheEffortsPaseoListsForItsModel() throws {
        var options = try tableOptions
        options.efforts = [
            .init(provider: "claude", model: "claude-fable-5-2", efforts: ["low", "medium", "high", "xhigh", "max"]),
            .init(provider: "claude", model: "claude-mythos-5-2", efforts: ["low", "medium", "high", "xhigh", "max"]),
        ]
        // Switched from Mythos to Fable 5.2: the table has High only for both.
        let fable = try session("f", name: "f", updated: "x",
                                requested: ["provider": "claude", "model": "claude-mythos-5-2", "effort": "high"],
                                observed: ["provider": "claude", "model": "claude-fable-5-2", "effort": "high"])
        XCTAssertEqual(LAAWorkSessionStyle.effortChoices(fable, options: options), ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(LAAWorkSessionStyle.offeredEfforts(provider: "claude", model: "claude-mythos-5-2", options: options),
                       ["low", "medium", "high", "xhigh", "max"])
        // Paseo listed the model for another provider only, or nothing at all:
        // the table's profiles.
        options.efforts = [.init(provider: "codex", model: "claude-fable-5-2", efforts: ["minimal"])]
        XCTAssertEqual(LAAWorkSessionStyle.effortChoices(fable, options: options), ["high"])
        options.efforts = []
        XCTAssertEqual(LAAWorkSessionStyle.offeredEfforts(provider: "claude", model: "claude-mythos-5-2", options: options), ["high"])
        XCTAssertTrue(LAAWorkSessionStyle.offeredEfforts(provider: "claude", model: "kestrel-preview", options: options).isEmpty)
        // An older Bridge sends no list.
        let decoded = try JSONDecoder().decode(LAAWorkSessionOptions.self, from: Data(#"{"profiles":[],"defaultProfile":null,"defaultMode":"bypass"}"#.utf8))
        XCTAssertNil(decoded.efforts)
    }

    /// The daemon's effort is listed even when the table does not offer it.
    func testCurrentEffortIsListedEvenOutsideTheTable() throws {
        let mythos = try session("m", name: "m", updated: "x",
                                 requested: ["provider": "claude", "model": "claude-mythos-5-2", "effort": "xhigh"],
                                 observed: ["provider": "claude", "model": "claude-mythos-5-2", "effort": "xhigh"])
        XCTAssertEqual(LAAWorkSessionStyle.effortChoices(mythos, options: try tableOptions), ["high", "xhigh"])
        XCTAssertTrue(LAAEffort.isDeep("xhigh") && LAAEffort.isDeep("max"))
        XCTAssertFalse(LAAEffort.isDeep("high"))
        XCTAssertEqual(LAAEffort.name("xhigh"), "XHigh")
    }

    func testSharedChipReadsNamesAndSaysUnknown() {
        XCTAssertEqual(LAAModelCapsule.displayName(model: "claude-opus-4-8", provider: "claude"), "Claude Opus 4.8")
        XCTAssertEqual(LAAModelCapsule.displayName(model: "gpt-6.1-sol", provider: "codex"), "GPT 6.1 Sol")
        XCTAssertEqual(LAAModelCapsule.displayName(model: "Claude Fable 5.2", provider: nil), "Claude Fable 5.2")
        XCTAssertEqual(LAAModelCapsule.displayName(model: #"["opencode-go","deepseek-v4.1-flash"]"#, provider: "dsh"),
                       "DeepSeek V4.1 Flash")
        XCTAssertNil(LAAModelCapsule.displayName(model: nil, provider: "claude"))
        XCTAssertEqual(LAAModelCapsule.unknown, "不明")
    }

    func testClaudeAPIHasItsOwnModelGroupAndProfile() throws {
        let json = #"{"profiles":[{"id":"fable-high","label":"Claude Fable 5.2","provider":"claude","model":"claude-fable-5-2","effort":"high","fast":false},{"id":"fable-api-high","label":"Claude Fable 5.2（API）","provider":"hermes-claude-api","model":"anthropic:claude-fable-5-2","effort":"high","fast":false}]}"#
        let options = try JSONDecoder().decode(LAAWorkSessionOptions.self, from: Data(json.utf8))
        let models = LAAWorkModelSelection.models(options)
        let groups = LAAWorkModelSelection.providers(models)
        XCTAssertEqual(groups.map(\.name), ["Claude", "Claude API"])
        XCTAssertEqual(Set(models.map(\.id)).count, 2)
        XCTAssertEqual(LAAWorkModelSelection.model(of: "fable-api-high", in: options)?.provider, "hermes-claude-api")
        XCTAssertEqual(LAAWorkModelSelection.model(of: "fable-api-high", in: options)?.model, "anthropic:claude-fable-5-2")
    }

    func testUnavailableMuseSurvivesCatalogDecodingWithoutBecomingRunnable() throws {
        let json = #"{"profiles":[{"id":"muse-high","label":"Muse（Muse Code未導入のため使えません）","provider":"muse","model":"muse","effort":"high","fast":false,"available":false,"unavailableReason":"Muse Code CLI is not installed","usageNote":"公開情報のみ・道具なし・直列・履歴分離未対応"}],"defaultProfile":null}"#
        let options = try JSONDecoder().decode(LAAWorkSessionOptions.self, from: Data(json.utf8))
        let muse = try XCTUnwrap(LAAWorkModelSelection.models(options).first)
        XCTAssertEqual(muse.provider, "muse")
        XCTAssertEqual(muse.model, "muse")
        XCTAssertFalse(muse.available)
        XCTAssertTrue(muse.label.contains("Muse Code未導入"))
        XCTAssertEqual(muse.usageNote, "公開情報のみ・道具なし・直列・履歴分離未対応")
    }

    /// Work opens on the latest page; older pages land above it and stay
    /// there while the latest page keeps refreshing.
    func testTranscriptPagesKeepLoadedOlderPagesUnderRefreshes() {
        func rows(_ ids: [String]) -> [LAAWorkConversationMessage] {
            ids.map { LAAWorkConversationMessage(id: $0, role: "user", text: $0, timestamp: nil) }
        }
        XCTAssertTrue(LAAWorkTranscriptPages.latestPath("ses_0123456789abcdef").hasSuffix("/conversation?limit=\(LAAWorkTranscriptPages.pageSize)"))
        XCTAssertTrue(LAAWorkTranscriptPages.olderPath("ses_0123456789abcdef", before: "m4").hasSuffix("before=m4"))
        let empty = LAAWorkTranscriptPages.Shown(messages: [], canLoadOlder: false, backfilled: false)
        var shown = LAAWorkTranscriptPages.latest(rows(["m4", "m5"]), hasOlder: true, onto: empty)
        XCTAssertTrue(shown.canLoadOlder)
        shown = LAAWorkTranscriptPages.prepend(rows(["m2", "m3", "m4"]), hasOlder: true, onto: shown)
        XCTAssertEqual(shown.messages.map(\.id), ["m2", "m3", "m4", "m5"], "a row already shown is not repeated")
        XCTAssertTrue(shown.backfilled)
        // A reply arrives: the latest page slides, the loaded rows stay above.
        shown = LAAWorkTranscriptPages.latest(rows(["m5", "m6"]), hasOlder: true, onto: shown)
        XCTAssertEqual(shown.messages.map(\.id), ["m2", "m3", "m4", "m5", "m6"])
        XCTAssertTrue(shown.canLoadOlder)
        shown = LAAWorkTranscriptPages.prepend(rows(["m1"]), hasOlder: false, onto: shown)
        XCTAssertFalse(shown.canLoadOlder, "the first page retires the control")
        // A rewritten history (no anchor) starts again at the latest page.
        shown = LAAWorkTranscriptPages.latest(rows(["x1", "x2"]), hasOlder: true, onto: shown)
        XCTAssertEqual(shown.messages.map(\.id), ["x1", "x2"])
        XCTAssertFalse(shown.backfilled)
        // An older Bridge sends the whole conversation and no paging.
        let whole = LAAWorkTranscriptPages.latest(rows(["a", "b"]), hasOlder: nil, onto: shown)
        XCTAssertEqual(whole.messages.map(\.id), ["a", "b"])
        XCTAssertFalse(whole.canLoadOlder)
    }

    /// A held follow-up stays in the transcript until the history has it.
    func testSentEchoLeavesOnceTheHistoryHasTheMessage() {
        let before = [LAAWorkConversationMessage(id: "u1", role: "user", text: "最初", timestamp: nil)]
        let echo = LAAWorkSentEcho(text: "この画像も", attachments: [], after: before.last?.id)
        XCTAssertEqual(LAAWorkSentEcho.pending([echo], in: before).count, 1)
        let reply = before + [LAAWorkConversationMessage(id: "a1", role: "assistant", text: "回答", timestamp: nil)]
        XCTAssertEqual(LAAWorkSentEcho.pending([echo], in: reply).count, 1, "an AI reply is not the owner's message")
        let delivered = reply + [LAAWorkConversationMessage(id: "u2", role: "user", text: " この画像も ", timestamp: nil)]
        XCTAssertTrue(LAAWorkSentEcho.pending([echo], in: delivered).isEmpty)
        // The latest page keeps its length as the conversation grows: the
        // message arriving at the end still settles the echo.
        let slid = Array(delivered.dropFirst())
        XCTAssertTrue(LAAWorkSentEcho.pending([echo], in: slid).isEmpty)
        let older = LAAWorkSentEcho(text: "最初", attachments: [], after: "u1")
        XCTAssertEqual(LAAWorkSentEcho.pending([older], in: before).count, 1, "the message it was sent after is not it")
    }

    /// A follow-up interrupts a running turn unless the owner chose to wait
    /// (owner 2026-11-15); a resume carries no delivery at all.
    func testFollowUpDeliversNowByDefaultAndQueuesOnlyWhenChosen() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        func body(_ mode: LAAWorkMessageForm.Mode, queue: Bool) throws -> [String: Any] {
            let payload = LAAWorkMessageForm.Payload(message: "次", requestId: nil,
                                                      delivery: LAAWorkMessageForm.delivery(mode: mode, queue: queue))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(payload)) as? [String: Any])
        }
        XCTAssertEqual(try body(.followUp, queue: false)["delivery"] as? String, "now")
        XCTAssertEqual(try body(.followUp, queue: true)["delivery"] as? String, "queue")
        XCTAssertNil(try body(.resume, queue: false)["delivery"])
    }
}
#endif

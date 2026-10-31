#if LAA_BUILD
import Foundation
import XCTest
@testable import Conduit

final class LAAStudioTests: XCTestCase {
    private let requestID = "0f6b1c2e-6f1a-4c55-9d43-0d5f6f3b8a11"

    func testDraftRoundTripKeepsAnUncertainRequestAndNewWorkIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("studio-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var draft = LAAStudioDraft()
        draft.requestID = requestID
        draft.title = " First work "
        draft.prompt = " Make a page "
        draft.pending = true
        XCTAssertTrue(LAAStudioDraftStore.save(draft, deviceID: "device-1", directory: directory))
        let saved = try XCTUnwrap(LAAStudioDraftStore.load(deviceID: "device-1", directory: directory))
        XCTAssertEqual(saved, draft)
        let request = try XCTUnwrap(saved.request())
        XCTAssertEqual(request.id, request.projectId)
        XCTAssertEqual(request.expectedRevision, 0)
        XCTAssertEqual(request.create?.title, "First work")
        XCTAssertEqual(request.prompt, "Make a page")
        XCTAssertFalse(LAAStudioDraftStore.save(draft, deviceID: "../other", directory: directory))
        XCTAssertTrue(LAAStudioDraftStore.clear(deviceID: "device-1", directory: directory))
        XCTAssertNil(LAAStudioDraftStore.load(deviceID: "device-1", directory: directory))
    }

    func testRerequestDraftDoesNotOverwriteAnotherDraft() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("studio-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var original = LAAStudioDraft(); original.prompt = "Different unsent draft"; original.pending = true
        var again = LAAStudioDraft(); again.prompt = "Previous prompt"; again.expectedRevision = 4
        XCTAssertTrue(LAAStudioDraftStore.save(original, deviceID: "device-1", directory: directory))
        XCTAssertTrue(LAAStudioDraftStore.save(again, deviceID: "device-1", draftID: requestID, directory: directory))
        XCTAssertEqual(LAAStudioDraftStore.load(deviceID: "device-1", draftID: requestID, directory: directory), again)
        XCTAssertTrue(LAAStudioDraftStore.clear(deviceID: "device-1", draftID: requestID, directory: directory))
        XCTAssertEqual(LAAStudioDraftStore.load(deviceID: "device-1", directory: directory), original)
        XCTAssertFalse(LAAStudioDraftStore.save(again, deviceID: "device-1", draftID: "../other", directory: directory))
    }

    func testUnknownActionRecoveryRequiresFreshChecksAndKeepsOriginalPayload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("studio-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let approvalID = UUID().uuidString
        let action = LAAStudioAction(action: "answer", id: requestID, approvalId: approvalID,
                                     accept: true, content: ["value": .integer(3)], persist: true)
        let marker = LAAStudioPendingAction(action: "answer", approvalId: approvalID, payload: action, attemptedAt: Date())
        XCTAssertTrue(LAAStudioActionGuard.save(marker, device: "device-1", id: requestID, directory: directory))
        let saved = try XCTUnwrap(LAAStudioActionGuard.load(device: "device-1", id: requestID, directory: directory))
        XCTAssertEqual(saved.payload?.content, action.content)
        XCTAssertEqual(saved.payload?.persist, true)
        XCTAssertNotNil(saved.attemptedAt)
        let request = LAAStudioRequest(id: requestID, projectId: "work-1", expectedRevision: 1, prompt: "test", create: nil, principle: nil)
        let approval = LAAStudioApproval(id: approvalID, message: "?", supported: true, allowSession: true, fields: [])
        let report = LAAStudioReport(id: requestID, bootId: requestID, sequence: 1, status: "approval", text: "", revision: nil, approvals: [approval], computerCalls: nil)
        let waiting = LAAStudioRecord(request: request, status: "approval", bootId: nil, updatedAt: "now", report: report)
        let running = LAAStudioRecord(request: request, status: "running", bootId: nil, updatedAt: "now", report: nil)
        XCTAssertFalse(LAAStudioActionGuard.mayRetry(saved, record: waiting, checks: 2))
        XCTAssertTrue(LAAStudioActionGuard.mayRetry(saved, record: waiting, checks: 3))
        XCTAssertEqual(LAAStudioActionGuard.nextChecks(previous: waiting, latest: waiting, count: 2), 3)
        XCTAssertEqual(LAAStudioActionGuard.nextChecks(previous: waiting, latest: running, count: 2), 0)
        XCTAssertTrue(LAAStudioActionGuard.resolved(saved, record: running))
        XCTAssertFalse(LAAStudioActionGuard.mayRetry(saved, record: running, checks: 3))
        let old = Data("{\"action\":\"answer\",\"approvalId\":\"\(approvalID)\"}".utf8)
        let legacy = try JSONDecoder().decode(LAAStudioPendingAction.self, from: old)
        XCTAssertNil(legacy.payload)
        XCTAssertTrue(LAAStudioActionGuard.mayRetry(legacy, record: waiting, checks: 3))
        let stopping = LAAStudioPendingAction(action: "stop", approvalId: nil, payload: .init(action: "stop", id: requestID), attemptedAt: Date())
        XCTAssertTrue(LAAStudioActionGuard.mayRetry(stopping, record: running, checks: 3))
        let stopped = LAAStudioRecord(request: request, status: "stopped", bootId: nil, updatedAt: "now", report: nil)
        XCTAssertTrue(LAAStudioActionGuard.resolved(stopping, record: stopped))
        XCTAssertTrue(LAAStudioActionGuard.clear(device: "device-1", id: requestID, directory: directory))
    }

    func testActionRetryPersistsExactlyTheOriginalKeyAndBody() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("studio-retry-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let approvalID = UUID().uuidString
        let action = LAAStudioAction(action: "answer", id: requestID, approvalId: approvalID, accept: true,
                                     content: ["text": .string("確認\nA"), "count": .integer(3)], persist: false)
        let original = try LAAStudioActionGuard.prepare(action)
        let first = try XCTUnwrap(original.retryMaterial())
        XCTAssertTrue(LAAStudioActionGuard.save(original, device: "device-1", id: requestID, directory: directory))
        let restored = try XCTUnwrap(LAAStudioActionGuard.load(device: "device-1", id: requestID, directory: directory))
        let retry = try XCTUnwrap(restored.retryMaterial())
        XCTAssertEqual(retry.key, first.key)
        XCTAssertEqual(retry.body, first.body)
        XCTAssertEqual(retry.action.content, action.content)
        var damaged = restored
        damaged.keyValue = "invalid key"
        XCTAssertNil(damaged.retryMaterial())
        damaged = restored
        damaged.body = Data("{}".utf8)
        XCTAssertNil(damaged.retryMaterial())
        let legacy = LAAStudioPendingAction(action: "answer", approvalId: approvalID, payload: action)
        XCTAssertNil(legacy.retryMaterial())
        XCTAssertFalse(LAAStudioActionGuard.requiresReentry(code: "idempotency_key_in_flight"))
        XCTAssertTrue(LAAStudioActionGuard.requiresReentry(code: "idempotency_outcome_unknown"))
    }

    func testStopIsDisabledDuringSendOrWhileStopIsUnresolved() {
        let answer = LAAStudioPendingAction(action: "answer", approvalId: UUID().uuidString)
        let stop = LAAStudioPendingAction(action: "stop", approvalId: nil)
        XCTAssertTrue(LAAStudioActionGuard.mayStop(busy: false, pending: nil))
        XCTAssertTrue(LAAStudioActionGuard.mayStop(busy: false, pending: answer))
        XCTAssertFalse(LAAStudioActionGuard.mayStop(busy: true, pending: answer))
        XCTAssertFalse(LAAStudioActionGuard.mayStop(busy: false, pending: stop))
    }

    func testExistingWorkRevisionAndPromptLimit() throws {
        var draft = LAAStudioDraft()
        draft.requestID = requestID
        draft.projectID = "work-1"
        draft.expectedRevision = 42
        draft.prompt = String(repeating: "a", count: 10000)
        XCTAssertEqual(try XCTUnwrap(draft.request()).expectedRevision, 42)
        XCTAssertNil(draft.request()?.create)
        draft.prompt.append("b")
        XCTAssertNil(draft.request())
        draft.prompt = "  \n "
        XCTAssertNil(draft.request())
    }

    func testApprovalAnswersKeepTypesAndRejectMissingOrInvalidValues() {
        let fields = [
            LAAStudioApproval.Field(name: "format", title: "Format", type: "string", required: true, options: ["PDF", "Slides"]),
            .init(name: "count", title: "Count", type: "integer", required: true, options: nil),
            .init(name: "scale", title: "Scale", type: "number", required: true, options: nil),
            .init(name: "approved", title: "Approved", type: "boolean", required: true, options: nil)
        ]
        let values = ["format": "PDF", "count": "4", "scale": "1.5", "approved": "false"]
        XCTAssertEqual(LAAStudioAnswers.content(fields: fields, raw: values),
                       ["format": .string("PDF"), "count": .integer(4), "scale": .number(1.5), "approved": .boolean(false)])
        XCTAssertNil(LAAStudioAnswers.content(fields: fields, raw: values.merging(["count": "1.5"]) { _, new in new }))
        XCTAssertNil(LAAStudioAnswers.content(fields: fields, raw: values.merging(["format": "Other"]) { _, new in new }))
        XCTAssertNil(LAAStudioAnswers.content(fields: fields, raw: values.merging(["approved": ""]) { _, new in new }))
    }

    func testOnlyContractMediaAndDriveURLsAreAccepted() {
        let sha = String(repeating: "a", count: 64)
        let input = "/api/studio/media/project-1/\(sha).mp4"
        let output = "/v1/studio/media/project-1/\(sha).mp4"
        XCTAssertEqual(LAAStudioMedia.bridgePath(input), output)
        XCTAssertTrue(LAAStudioMedia.bridgePathIsValid(output))
        XCTAssertNil(LAAStudioMedia.bridgePath("https://example.com" + input))
        XCTAssertNil(LAAStudioMedia.bridgePath("/api/studio/media/../\(sha).mp4"))
        XCTAssertNil(LAAStudioMedia.bridgePath("/api/studio/media/project-1/\(sha).pdf"))
        XCTAssertNotNil(LAAStudioMedia.driveURL("https://drive.google.com/file/d/1234567890/view"))
        XCTAssertNil(LAAStudioMedia.driveURL("https://drive.google.com.evil.example/file/d/1234567890/view"))
    }

    func testUnreceivedIsActiveButCannotBeStoppedOrResumed() {
        let request = LAAStudioRequest(id: requestID, projectId: "work-1", expectedRevision: 1, prompt: "test", create: nil, principle: nil)
        let unreceived = LAAStudioRecord(request: request, status: "unreceived", bootId: nil, updatedAt: "now", report: nil)
        XCTAssertTrue(unreceived.active)
        XCTAssertFalse(unreceived.canStop)
        XCTAssertFalse(unreceived.canRequestAgain)
        let finished = LAAStudioRecord(request: request, status: "interrupted", bootId: nil, updatedAt: "now", report: nil)
        XCTAssertFalse(finished.active)
        XCTAssertTrue(finished.canRequestAgain)
    }

    func testStatusNamesAndWorkTitle() {
        let statuses = ["queued": "Queued", "unreceived": "Not received", "accepted": "Accepted", "running": "Running",
                        "approval": "Needs approval", "completed": "Completed", "failed": "Failed", "stopped": "Stopped", "interrupted": "Interrupted"]
        for (status, label) in statuses { XCTAssertEqual(LAAStudioPresentation.status(status), label) }
        XCTAssertEqual(LAAStudioPresentation.status("new-state"), "Unknown")
        let request = LAAStudioRequest(id: requestID, projectId: requestID, expectedRevision: 0, prompt: "test",
                                       create: .init(title: "New work title"), principle: nil)
        let record = LAAStudioRecord(request: request, status: "queued", bootId: nil, updatedAt: "now", report: nil)
        XCTAssertEqual(LAAStudioPresentation.title(for: record, project: nil), "New work title")
        XCTAssertEqual(LAAStudioPresentation.title(for: record, project: project()), "Work title")
    }

    func testDeliverablesRequireDriveRevisionOrValidMedia() {
        XCTAssertFalse(LAAStudioPresentation.hasDeliverables(project()))
        XCTAssertFalse(LAAStudioPresentation.hasDeliverables(project(driveURL: "https://example.com/file")))
        XCTAssertTrue(LAAStudioPresentation.hasDeliverables(project(driveURL: "https://drive.google.com/file/d/1234567890/view")))
        XCTAssertTrue(LAAStudioPresentation.hasDeliverables(project(deliveredRevision: 3)))
        let media = "/api/studio/media/work-1/\(String(repeating: "a", count: 64)).png"
        XCTAssertTrue(LAAStudioPresentation.hasDeliverables(project(pages: [.init(id: "page", name: "Page", preview: media)])))
        let asset = LAAStudioAsset(id: "asset", name: "Film", kind: "video", url: media, poster: nil, unavailable: nil, previewOnly: nil)
        XCTAssertTrue(LAAStudioPresentation.hasDeliverables(project(assets: [asset])))
    }

    private func project(driveURL: String? = nil, deliveredRevision: Int? = nil,
                         pages: [LAAStudioPage] = [], assets: [LAAStudioAsset]? = nil) -> LAAStudioProject {
        .init(id: "work-1", title: "Work title", revision: 1, pages: pages, assets: assets,
              syncedAt: nil, driveUrl: driveURL, deliveredRevision: deliveredRevision)
    }
}
#endif

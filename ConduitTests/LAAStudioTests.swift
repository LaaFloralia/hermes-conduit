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
}
#endif

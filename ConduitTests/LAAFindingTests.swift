#if LAA_BUILD
import XCTest
@testable import Conduit

/// D-18: the Findings side of the board on the client.
@MainActor
final class LAAFindingTests: XCTestCase {
    private func finding(_ json: String) throws -> LAAFinding {
        try JSONDecoder().decode(LAAFinding.self, from: Data(json.utf8))
    }

    private func httpError(_ status: Int, _ code: String?) -> LAABridgeHTTPError {
        LAABridgeHTTPError(status: status, code: code, message: nil, retryable: false, details: nil,
                           requestId: nil, currentETag: nil)
    }

    private let full = """
        { "id": "fnd_0123456789abcdef", "ref": "F3", "title": "DMARCが未設定",
          "found": "laa-inc.comにDMARCがない", "evidence": "dig TXT _dmarc は空", "plan": "p=noneで追加し集計先を設定",
          "effort": "small", "source": { "sessionId": "ses_1", "name": "treg｜試験" }, "sourceRef": "S5",
          "images": [ { "id": "img_00000000000a", "width": 1200, "height": 800 }, { "id": "img_../x", "width": 1, "height": 1 } ],
          "status": "open", "result": null, "pickup": null,
          "createdAt": "2026-11-27T10:00:00.000Z", "updatedAt": "2026-11-27T10:00:00.000Z",
          "delegatedAt": null, "doneAt": null, "dismissedAt": null }
        """

    func testAFullRecordDecodes() throws {
        let item = try finding(full)
        XCTAssertEqual(item.id, "fnd_0123456789abcdef")
        XCTAssertEqual(item.ref, "F3")
        XCTAssertEqual(item.effort, .small)
        XCTAssertEqual(item.status, .open)
        XCTAssertEqual(item.images.map(\.id), ["img_00000000000a"], "an id the route would refuse is dropped")
        XCTAssertNil(item.images[0].option)
        XCTAssertEqual(item.sourceLine, "S5 · treg · 試験")
        XCTAssertFalse(item.stale)
        XCTAssertTrue(item.isOpen && item.counts && item.listed)
    }

    func testUnknownValuesDoNotBreakTheList() throws {
        let item = try finding("""
            { "id": "fnd_0123456789abcdef", "title": "t", "effort": "huge", "status": "archived", "stale": true }
            """)
        XCTAssertNil(item.effort)
        XCTAssertNil(item.status)
        XCTAssertFalse(item.listed, "a state this build does not know is not shown")
        XCTAssertTrue(item.stale)
        XCTAssertEqual(item.found, "")
        XCTAssertNil(LAAFindingCopy.effortLine(item.effort))
    }

    func testPageDecodesWithAndWithoutCounts() throws {
        let page = try JSONDecoder().decode(LAAFindingPage.self, from: Data("""
            { "items": [ \(full) ], "counts": { "open": 1, "delegated": 2, "done": 3 } }
            """.utf8))
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.counts, .init(open: 1, delegated: 2, done: 3))
        let bare = try JSONDecoder().decode(LAAFindingPage.self, from: Data(#"{ "items": [] }"#.utf8))
        XCTAssertNil(bare.counts)
        let result = try JSONDecoder().decode(LAAFindingResult.self, from: Data(#"{ "finding": \#(full) }"#.utf8))
        XCTAssertEqual(result.finding.title, "DMARCが未設定")
    }

    func testRowLines() throws {
        let open = try finding(full)
        XCTAssertEqual(LAAFindingCopy.meta(open), "S5 · treg · 試験 · 手間 小")
        XCTAssertEqual(LAAFindingCopy.meta(open.with(status: .delegated)), "Monetが対応中")
        let done = LAAFinding(id: "fnd_0123456789abcdee", title: "t", status: .done, result: "DMARCを追加し確認済み")
        XCTAssertEqual(LAAFindingCopy.meta(done), "Done · DMARCを追加し確認済み")
        XCTAssertEqual(LAAFindingCopy.meta(LAAFinding(id: "fnd_0123456789abcdee", title: "t", status: .done)), "Done")
        XCTAssertEqual(LAAFindingCopy.meta(LAAFinding(id: "fnd_0123456789abcdee", title: "t", effort: .large)), "手間 大")
        XCTAssertEqual(LAAFindingCopy.accessibilityLabel(open),
                       "気づき、F3、DMARCが未設定、S5 · treg · 試験 · 手間 小、\(LAADecisionCopy.imagesAttached)")
    }

    func testMenuLabels() {
        XCTAssertEqual(LAABoardKind.decisions.label(count: 2), "Decisions 2")
        XCTAssertEqual(LAABoardKind.findings.label(count: 5), "Findings 5")
        XCTAssertEqual(LAABoardKind.findings.label(count: nil), "Findings", "an unknown count is not shown as 0")
        XCTAssertEqual(LAABoardKind(rawValue: "findings"), .findings)
        XCTAssertEqual(LAABoardKind.storageKey, "laa.work.boardKind")
    }

    func testCountIsOpenPlusDelegatedAndUnknownBeforeTheFirstRead() {
        let board = LAAFindingBoard()
        XCTAssertNil(board.count)
        board.finishLoadForTesting([
            LAAFinding(id: "fnd_000000000000000a", title: "a", status: .open, createdAt: "2026-11-27T10:00:00Z"),
            LAAFinding(id: "fnd_000000000000000b", title: "b", status: .delegated, createdAt: "2026-11-27T12:00:00Z"),
            LAAFinding(id: "fnd_000000000000000c", title: "c", status: .done, createdAt: "2026-11-27T11:00:00Z"),
            LAAFinding(id: "fnd_000000000000000d", title: "d", status: .dismissed, createdAt: "2026-11-27T13:00:00Z"),
        ])
        XCTAssertEqual(board.count, 2)
        XCTAssertEqual(board.items.map(\.title), ["b", "c", "a"], "newest first; dismissed is not listed")
    }

    func testDismissRemovesAtOnceAndARefusalRestoresTheRow() {
        let board = LAAFindingBoard()
        let rows = [
            LAAFinding(id: "fnd_000000000000000a", title: "a", createdAt: "2026-11-27T10:00:00Z"),
            LAAFinding(id: "fnd_000000000000000b", title: "b", createdAt: "2026-11-27T12:00:00Z"),
        ]
        board.finishLoadForTesting(rows)
        let snapshot = board.dismissLocallyForTesting("fnd_000000000000000b")
        XCTAssertEqual(board.items.map(\.title), ["a"])
        XCTAssertEqual(board.count, 1)
        // A read that crossed the dismissal does not bring it back.
        board.finishLoadForTesting(rows)
        XCTAssertEqual(board.items.map(\.title), ["a"])
        board.refuseDismissForTesting("fnd_000000000000000b", snapshot: snapshot)
        XCTAssertEqual(board.items.map(\.title), ["b", "a"], "restored in its place")
    }

    func testRestoreKeepsWhatChangedMeanwhile() {
        let a = LAAFinding(id: "fnd_000000000000000a", title: "a", createdAt: "2026-11-27T10:00:00Z")
        let b = LAAFinding(id: "fnd_000000000000000b", title: "b", createdAt: "2026-11-27T12:00:00Z")
        let delegatedA = a.with(status: .delegated)
        let restored = LAAFindingBoard.restored([b, a], current: [delegatedA], id: b.id)
        XCTAssertEqual(restored, [b, delegatedA])
        XCTAssertEqual(LAAFindingBoard.restored([b, a], current: [b, a], id: b.id), [b, a], "no duplicate")
    }

    func testFindingPicturesTakeTheFindingsRoute() throws {
        let item = try finding(full)
        let carrier = item.imageCarrier
        XCTAssertEqual(carrier.id, item.id)
        XCTAssertEqual(carrier.generalImages.map(\.id), ["img_00000000000a"])
        XCTAssertEqual(LAADecisionImageKey(decisionID: carrier.id, imageID: "img_00000000000a", size: .thumb).path,
                       "/v1/findings/fnd_0123456789abcdef/images/img_00000000000a?size=thumb")
        XCTAssertEqual(LAADecisionImageKey(decisionID: carrier.id, imageID: "img_00000000000a", size: .full).path,
                       "/v1/findings/fnd_0123456789abcdef/images/img_00000000000a")
        XCTAssertEqual(LAADecisionImageKey(decisionID: "dec_0123456789abcdef", imageID: "img_00000000000a", size: .full).path,
                       "/v1/decisions/dec_0123456789abcdef/images/img_00000000000a", "decisions unchanged")
        XCTAssertNil(LAADecisionImageKey(decisionID: "fnd_x/../y", imageID: "img_00000000000a", size: .thumb).path)
        XCTAssertTrue(LAADecisionImageStore.isRemoved(httpError(404, "finding_image_not_found")))
        XCTAssertTrue(LAAFinding.validID("fnd_0123456789abcdef"))
        XCTAssertFalse(LAAFinding.validID("fnd_0123"))
    }

    func testActionErrors() {
        XCTAssertEqual(LAAFindingCopy.actionError(httpError(409, "finding_state")),
                       "この気づきはすでに任せたか、見送られています。")
        XCTAssertEqual(LAAFindingCopy.actionError(httpError(404, nil)),
                       LAAFindingCopy.unsupportedDetail)
    }
}
#endif

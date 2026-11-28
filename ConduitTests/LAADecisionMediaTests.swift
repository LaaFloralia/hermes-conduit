#if LAA_BUILD
import SwiftUI
import XCTest
@testable import Conduit

/// D-17: a decision's pictures and links on the client.
@MainActor
final class LAADecisionMediaTests: XCTestCase {
    private func decision(_ json: String) throws -> LAADecision {
        try JSONDecoder().decode(LAADecision.self, from: Data(json.utf8))
    }

    private let base = """
        "id": "dec_0123456789abcdef", "status": "open", "title": "t", "summary": "s", "allowOther": true
        """

    func testARecordWithoutImagesDecodesAsBefore() throws {
        let item = try decision("{ \(base), \"options\": [ { \"label\": \"A\", \"recommended\": true } ] }")
        XCTAssertEqual(item.images, [])
        XCTAssertTrue(item.generalImages.isEmpty)
        XCTAssertNil(item.image(forOption: 0))
        XCTAssertFalse(LAADecisionCopy.accessibilityLabel(item).contains(LAADecisionCopy.imagesAttached))
        // A round trip through the device's cache keeps it image-free.
        let again = try JSONDecoder().decode(LAADecision.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(again, item)
    }

    func testImagesDecodeWithOptionsAndSizes() throws {
        let item = try decision("""
            { \(base),
              "options": [ { "label": "A", "recommended": true }, { "label": "B" }, { "label": "C" } ],
              "images": [
                { "id": "img_00000000000a", "width": 1200, "height": 800 },
                { "id": "img_0000000000b0", "width": 800, "height": 600, "option": 1 },
                { "id": "img_00000000000b", "width": 900, "height": 1200 },
                { "id": "img_0000000000a0", "width": 800, "height": 800, "option": 0 }
              ] }
            """)
        XCTAssertEqual(item.images.count, 4)
        XCTAssertEqual(item.generalImages.map(\.id), ["img_00000000000a", "img_00000000000b"])
        XCTAssertEqual(item.image(forOption: 0)?.id, "img_0000000000a0")
        XCTAssertEqual(item.image(forOption: 1)?.id, "img_0000000000b0")
        XCTAssertNil(item.image(forOption: 2))
        XCTAssertEqual(item.viewerImages.map(\.id),
                       ["img_00000000000a", "img_00000000000b", "img_0000000000a0", "img_0000000000b0"],
                       "the viewer pages general pictures, then options in order")
        XCTAssertEqual(item.images[0].aspect, 1.5, accuracy: 0.001)
        XCTAssertTrue(LAADecisionCopy.accessibilityLabel(item).contains(LAADecisionCopy.imagesAttached))
        let again = try JSONDecoder().decode(LAADecision.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(again.images, item.images)
    }

    /// The client re-sorts a hand-written record recommended-first; an
    /// option's picture moves with its option.
    func testOptionPictureFollowsTheRecommendedFirstOrder() throws {
        let item = try decision("""
            { \(base),
              "options": [ { "label": "A" }, { "label": "B", "recommended": true } ],
              "images": [ { "id": "img_0000000000a0", "width": 10, "height": 10, "option": 0 },
                          { "id": "img_0000000000b0", "width": 10, "height": 10, "option": 1 },
                          { "id": "img_0000000000c0", "width": 10, "height": 10, "option": 7 } ] }
            """)
        XCTAssertEqual(item.options.map(\.label), ["B", "A"])
        XCTAssertEqual(item.image(forOption: 0)?.id, "img_0000000000b0")
        XCTAssertEqual(item.image(forOption: 1)?.id, "img_0000000000a0")
        XCTAssertEqual(item.generalImages.map(\.id), ["img_0000000000c0"], "an unknown option index is a general picture")
    }

    func testAnUnusableImageIDIsDroppedAndNoPathIsBuilt() throws {
        let item = try decision("""
            { \(base), "options": [],
              "images": [ { "id": "../../etc/passwd", "width": 1, "height": 1 }, { "id": "img_00000000000a" } ] }
            """)
        XCTAssertEqual(item.images.map(\.id), ["img_00000000000a"])
        XCTAssertEqual(item.images[0].aspect, 4.0 / 3.0, accuracy: 0.001, "no size reads as 4:3")
        XCTAssertNil(LAADecisionImageKey(decisionID: "dec_0123456789abcdef", imageID: "img_../x", size: .thumb).path)
        XCTAssertNil(LAADecisionImageKey(decisionID: "dec_x/../y", imageID: "img_00000000000a", size: .thumb).path)
        XCTAssertEqual(LAADecisionImageKey(decisionID: "dec_0123456789abcdef", imageID: "img_00000000000a", size: .thumb).path,
                       "/v1/decisions/dec_0123456789abcdef/images/img_00000000000a?size=thumb")
        XCTAssertEqual(LAADecisionImageKey(decisionID: "dec_0123456789abcdef", imageID: "img_00000000000a", size: .full).path,
                       "/v1/decisions/dec_0123456789abcdef/images/img_00000000000a")
    }

    func testAnswerAndDeliveryRebuildsKeepThePictures() throws {
        let item = try decision("""
            { \(base), "options": [ { "label": "A", "recommended": true } ],
              "images": [ { "id": "img_00000000000a", "width": 4, "height": 3 } ] }
            """)
        let answered = LAADecisionDetailView.answered(item, optionIndex: 0, label: "A", note: nil)
        XCTAssertEqual(answered.images, item.images)
        XCTAssertEqual(LAADecisionBoardView.delivered(answered).images, item.images)
    }

    /// D-47 B9: an Answered row shows the chosen option's picture; an open
    /// question, a free answer or an option without one shows none.
    func testAnsweredRowTakesTheChosenOptionsPicture() throws {
        func item(_ answer: String, delivery: String = "delivered") throws -> LAADecision {
            try decision("""
                { "kind": "board", \(base.replacingOccurrences(of: "\"open\"", with: "\"answered\"")),
                  "options": [ { "label": "A", "recommended": true }, { "label": "B" }, { "label": "C" } ],
                  "images": [ { "id": "img_0000000000a0", "width": 8, "height": 8, "option": 0 },
                              { "id": "img_0000000000b0", "width": 8, "height": 8, "option": 1 },
                              { "id": "img_00000000000a", "width": 8, "height": 8 } ],
                  "answer": \(answer), "delivery": { "state": "\(delivery)", "attempts": 1 } }
                """)
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        XCTAssertEqual(try item(#"{ "optionIndex": 1, "label": "B", "answeredAt": "\#(stamp)" }"#).answeredOptionImage?.id,
                       "img_0000000000b0")
        XCTAssertNil(try item(#"{ "optionIndex": 2, "label": "C", "answeredAt": "\#(stamp)" }"#).answeredOptionImage,
                     "the chosen option has no picture")
        XCTAssertNil(try item(#"{ "optionIndex": null, "label": "自由回答", "answeredAt": "\#(stamp)" }"#).answeredOptionImage)
        XCTAssertNil(try item(#"{ "optionIndex": 1, "label": "B", "answeredAt": "\#(stamp)" }"#, delivery: "failed").answeredOptionImage,
                     "an undelivered answer is not settled")
        XCTAssertNil(try decision("{ \(base), \"options\": [ { \"label\": \"A\" } ] }").answeredOptionImage)
    }

    /// Retention is quiet: 410, or the route's own 404 code. A 404 with no
    /// such code is an older Bridge without the route, not a removed picture.
    func testRemovedPictureIsToldApartFromAnOlderBridge() {
        func http(_ status: Int, _ code: String) -> LAABridgeHTTPError {
            LAABridgeHTTPError(status: status, code: code, message: nil, retryable: false, details: nil,
                               requestId: nil, currentETag: nil)
        }
        XCTAssertTrue(LAADecisionImageStore.isRemoved(http(410, "decision_image_expired")))
        XCTAssertTrue(LAADecisionImageStore.isRemoved(http(404, "decision_image_not_found")))
        XCTAssertFalse(LAADecisionImageStore.isRemoved(http(404, "not_found")))
        XCTAssertFalse(LAADecisionImageStore.isRemoved(http(503, "paseo_unavailable")))
    }

    func testAPayloadIsDecodedAndKeptOnDisk() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("decision-images-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LAADecisionImageStore(directory: folder)
        let key = LAADecisionImageKey(decisionID: "dec_0123456789abcdef", imageID: "img_00000000000a", size: .thumb)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 3)).pngData { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        }
        let payload = LAADecisionImageStore.Payload(contentType: "image/png", width: 4, height: 3, etag: "\"e1\"",
                                                    data: png.base64EncodedString())
        let image = await store.adopt(payload, etag: "\"e1\"", for: key)
        XCTAssertNotNil(image)
        XCTAssertNotNil(store.cached(key))
        let reopened = LAADecisionImageStore(directory: folder)
        let fromDisk = await reopened.local(key)
        XCTAssertNotNil(fromDisk, "a new launch finds the copy on disk")
        let junk = LAADecisionImageStore.Payload(contentType: "image/png", width: 1, height: 1, etag: nil, data: "bm90IGFuIGltYWdl")
        let refused = await store.adopt(junk, etag: nil, for: key)
        XCTAssertNil(refused, "bytes that are not a picture are refused")
    }

    // MARK: Links

    func testLinksAreDetectedInPlainText() {
        let text = "比較表は https://example.com/a?b=1 にあります。予備 http://example.org/x と mailto:a@example.com、example"
        XCTAssertEqual(LAADecisionLinks.urls(in: text).map(\.absoluteString),
                       ["https://example.com/a?b=1", "http://example.org/x"], "only http(s)")
        let attributed = LAADecisionLinks.attributed(text)
        XCTAssertEqual(String(attributed.characters), text, "the words are unchanged")
        let linked = attributed.runs.compactMap { run -> String? in
            guard run.link != nil else { return nil }
            return String(attributed[run.range].characters)
        }
        XCTAssertEqual(linked, ["https://example.com/a?b=1", "http://example.org/x"])
    }

    func testTextWithoutLinksStaysPlainAndMarkdownIsNotParsed() {
        let text = "[ここ](https://example.com) は **太字** にしない"
        let attributed = LAADecisionLinks.attributed(text)
        XCTAssertEqual(String(attributed.characters), text)
        XCTAssertTrue(LAADecisionLinks.attributed("リンクのない文").runs.allSatisfy { $0.link == nil })
        XCTAssertTrue(LAADecisionLinks.urls(in: "").isEmpty)
        XCTAssertEqual(LAADecisionLinks.urls(in: "https://example.com と https://example.com").count, 1)
        XCTAssertEqual(LAADecisionLinks.actionName(URL(string: "https://example.com/x")!), "リンクを開く example.com")
    }
}
#endif

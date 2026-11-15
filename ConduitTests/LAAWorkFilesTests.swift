#if LAA_BUILD
import XCTest
@testable import Conduit

/// Mac files named in a Work reply: paths become links, a link resolves to
/// the Mac path, and the Bridge's file read becomes the data URL the chat's
/// Markdown opens `MEDIA:` files and `::preview` pages with.
@MainActor
final class LAAWorkFilesTests: XCTestCase {
    func testPathsInTheTextBecomeLinksAndEverythingElseStaysAsWritten() {
        let path = "/Users/laa/work/voice-keyboard-20261115/result.polished.md"
        XCTAssertEqual(LAAWorkFiles.linkified("成果物は \(path) です。"),
                       "成果物は [\(path)](\(path)) です。")
        XCTAssertEqual(LAAWorkFiles.linkified("、\(path)。"), "、[\(path)](\(path))。")
        XCTAssertEqual(LAAWorkFiles.linkified("結果は\(path)."), "結果は[\(path)](\(path)).")
        XCTAssertEqual(LAAWorkFiles.linkified("`\(path)` を見て"), "[`\(path)`](\(path)) を見て")
        XCTAssertEqual(LAAWorkFiles.linkified("場所 /Users/laa/work/x/a.swift:120"),
                       "場所 [/Users/laa/work/x/a.swift](/Users/laa/work/x/a.swift):120")
        XCTAssertEqual(LAAWorkFiles.linkified("file:///Users/laa/a.pdf"), "[file:///Users/laa/a.pdf](/Users/laa/a.pdf)")
        // A Japanese name is escaped in the destination, and `_` in the label
        // never starts emphasis.
        XCTAssertEqual(LAAWorkFiles.linkified("/Users/laa/work/結果_1.md"),
                       "[/Users/laa/work/結果\\_1.md](/Users/laa/work/%E7%B5%90%E6%9E%9C_1.md)")

        // Kept as written: an existing link, a folder, fenced code, a web
        // address with /Users in it, a code span that is not only a path.
        for kept in [
            "[RESULT.md](/Users/laa/work/x/RESULT.md)",
            "![一覧](/Users/laa/work/x/sheet.png)",
            "フォルダ /Users/laa/work/own-harness-20261115/hq を見た",
            "```\n/Users/laa/work/x/a.md\n```",
            "https://example.com/Users/laa/a.png",
            "`cat /Users/laa/a.md`",
            "<https://example.com/a.md>",
            "::preview{file=\"/Users/laa/work/x/chart.html\"}",
            "MEDIA: /Users/laa/work/x/a.mp4",
        ] {
            XCTAssertEqual(LAAWorkFiles.linkified(kept), kept, kept)
        }
        XCTAssertEqual(LAAWorkFiles.linkified("```\na\n```\n/Users/laa/b.md"), "```\na\n```\n[/Users/laa/b.md](/Users/laa/b.md)")
    }

    func testALinkResolvesToTheMacPathAndOnlyAMacPath() throws {
        let linked = try AttributedString(markdown: LAAWorkFiles.linkified("見て /Users/laa/work/結果.md"))
        let url = try XCTUnwrap(linked.runs.compactMap(\.link).first)
        XCTAssertEqual(LAAWorkFiles.localPath(url), "/Users/laa/work/結果.md")
        XCTAssertEqual(LAAWorkFiles.localPath(try XCTUnwrap(URL(string: "file:///Users/laa/a%20b.png"))), "/Users/laa/a b.png")
        XCTAssertNil(LAAWorkFiles.localPath(try XCTUnwrap(URL(string: "https://example.com/Users/laa/a.png"))))
        XCTAssertNil(LAAWorkFiles.localPath(try XCTUnwrap(URL(string: "laa://work/sessions/ses_1"))))
        XCTAssertNil(LAAWorkFiles.localPath(try XCTUnwrap(URL(string: "//host/a.md"))))
        XCTAssertEqual(LAAWorkFiles.localPath("file:///Users/laa/a.html"), "/Users/laa/a.html")
        XCTAssertEqual(LAAWorkFiles.localPath(" /Users/laa/a.html"), "/Users/laa/a.html")
        XCTAssertNil(LAAWorkFiles.localPath("chart.html"))
    }

    func testTheBridgeReadIsAskedForEscapedAndBecomesADataURL() throws {
        XCTAssertEqual(LAAWorkFiles.requestPath(sessionID: "ses_0123456789abcdef", path: "/Users/laa/a+b 結.md"),
                       "/v1/sessions/ses_0123456789abcdef/files?path=/Users/laa/a%2Bb%20%E7%B5%90.md")
        let payload = try JSONDecoder().decode(LAAWorkFiles.Payload.self, from: Data(#"{"name":"a.html","mimeType":"text/html","size":3,"data":"PHA+"}"#.utf8))
        let dataURL = try XCTUnwrap(LAAWorkFiles.dataURL(payload))
        XCTAssertEqual(dataURL, "data:text/html;base64,PHA+")
        XCTAssertEqual(HTMLPreviewPage.decodedDocument(fromDataURL: dataURL), "<p>")
    }

    /// With the Bridge's reader the reply's previews are the chat's blocks:
    /// an HTML page drawn in place and any other file as its card.
    func testPreviewsInAReplyAreTheChatsBlocks() {
        let text = """
        ::preview{file="/Users/laa/work/x/chart.html"}
        ::preview{file="/Users/laa/work/x/report.pdf"}
        ![web](https://example.com/a.png)
        """
        XCTAssertEqual(MarkdownParser.parse(LAAWorkFiles.linkified(text), recognizesGatewayMedia: true), [
            .htmlPreview(path: "/Users/laa/work/x/chart.html"),
            .image(url: "MEDIA: /Users/laa/work/x/report.pdf", alt: "report.pdf"),
            .image(url: "https://example.com/a.png", alt: "web"),
        ])
    }
}
#endif

#if LAA_BUILD
import XCTest
@testable import Conduit

/// File links in the transcript (LAAFileLinks): what reads as a file, where
/// it ends beside punctuation and Japanese, and what stays text.
final class LAAChatFileLinkTests: XCTestCase {
    private func found(_ text: String) -> [String] {
        let ns = text as NSString
        return LAAFileLinks.matches(in: text).map { ns.substring(with: $0.range) }
    }

    func testParsingTable() {
        let table: [(String, [String])] = [
            ("Open Conduit/Views/ChatView.swift:42 now", ["Conduit/Views/ChatView.swift:42"]),
            ("(see Conduit/Views/ChatView.swift:42)", ["Conduit/Views/ChatView.swift:42"]),
            ("「/Users/laa/work/x/RESULT.md」を見てください。", ["/Users/laa/work/x/RESULT.md"]),
            ("結果はwork/x/RESULT.mdにあります", ["work/x/RESULT.md"]),
            ("src/app.ts:10:4、src/b.ts。", ["src/app.ts:10:4", "src/b.ts"]),
            ("[docs](docs/a.md), then docs/b.md.", ["docs/a.md", "docs/b.md"]),
            ("version 1.2/3.4 and e.g. foo/bar.baz", []),
            ("https://example.com/a/b.md is a web page", []),
            ("https://drive.google.com/file/d/1AbCdEfGhIjKlMnOp/view?usp=sharing。", ["https://drive.google.com/file/d/1AbCdEfGhIjKlMnOp/view?usp=sharing"]),
            ("file:///Users/laa/a/b.png", ["file:///Users/laa/a/b.png"]),
        ]
        for (text, expected) in table {
            XCTAssertEqual(found(text), expected, text)
        }
    }

    func testLineAndLabel() throws {
        let match = try XCTUnwrap(LAAFileLinks.matches(in: "at Conduit/Views/ChatView.swift:42").first)
        XCTAssertEqual(match.reference.line, 42)
        XCTAssertEqual(match.reference.label, "ChatView.swift:42")
        XCTAssertEqual(match.reference.kind, .code)
        let url = try XCTUnwrap(LAAFileLinks.url(for: match.reference))
        XCTAssertEqual(LAAFileLinks.reference(for: url), match.reference, "The link reads back as the same file and line")
        XCTAssertEqual(LAAFileLinks.reference(for: URL(string: "file:///Users/laa/a/RESULT.md#L7")!),
                       LAAFileReference(location: .path("/Users/laa/a/RESULT.md"), line: 7))
        XCTAssertEqual(LAAFileLinks.reference(for: URL(string: "https://docs.google.com/document/d/1AbCdEfGhIjKlMnOp/edit")!)?.location,
                       .drive("1AbCdEfGhIjKlMnOp"))
        XCTAssertNil(LAAFileLinks.reference(for: URL(string: "https://example.com/a.md")!))
    }

    func testLinkifiedKeepsCodeAndLinks() {
        let resolve: (LAAFileReference) -> URL? = { LAAFileLinks.url(for: $0) }
        let text = """
        See Conduit/Views/ChatView.swift:42 and `let x = a/b.swift` and `plain code`.
        ```
        Conduit/Views/ChatView.swift:42
        ```
        [notes](file:///Users/laa/work/x/RESULT.md)
        """
        let out = LAAFileLinks.linkified(text, resolve: resolve)
        let lines = out.components(separatedBy: "\n")
        XCTAssertTrue(lines[0].hasPrefix("See [`ChatView.swift:42`](laa-file://open?path=Conduit/Views/ChatView.swift#L42) and"), lines[0])
        XCTAssertTrue(lines[0].contains("`let x = a/b.swift`"), "A code span stays code")
        XCTAssertTrue(lines[0].contains("`plain code`"))
        XCTAssertEqual(lines[2], "Conduit/Views/ChatView.swift:42", "Fenced code stays as written")
        XCTAssertTrue(lines[4].hasPrefix("[`RESULT.md`](laa-file://open?path=/Users/laa/work/x/RESULT.md)"), lines[4])
        XCTAssertEqual(LAAFileLinks.linkified("no files here", resolve: resolve), "no files here")
        XCTAssertEqual(LAAFileLinks.linkified("see a/b.swift", resolve: { _ in nil }), "see a/b.swift", "Unresolvable stays text")
    }

    func testKindsChooseTheirViewer() {
        func kind(_ path: String) -> LAAFileReference.Kind { LAAFileReference(location: .path(path)).kind }
        XCTAssertEqual(kind("a/README.md"), .markdown)
        XCTAssertEqual(kind("a/b.swift"), .code)
        XCTAssertEqual(kind("a/b.png"), .image)
        XCTAssertEqual(kind("a/b.mov"), .video)
        XCTAssertEqual(kind("a/b.pdf"), .pdf)
        XCTAssertEqual(kind("a/b.usdz"), .model3D)
        XCTAssertEqual(kind("a/b.html"), .html)
    }

    func testGlyphCopiesAsNothing() {
        let url = LAAFileLinks.url(for: LAAFileReference(location: .path("a/b.swift"), line: 3))!
        let text = NSMutableAttributedString(string: "see b.swift:3 now")
        text.addAttribute(.link, value: url, range: NSRange(location: 4, length: 9))
        let decorated = LAAFileLinks.decorated(text, color: .systemBlue)
        XCTAssertEqual(decorated.length, text.length + 2, "One glyph and a thin space")
        XCTAssertEqual(MarkdownProseRun.copyableText(decorated.attributedSubstring(from: NSRange(location: 1, length: decorated.length - 2))).string,
                       "ee b.swift:3 no")
    }
}
#endif

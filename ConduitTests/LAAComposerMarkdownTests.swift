#if LAA_BUILD
import UIKit
import XCTest
@testable import Conduit

@MainActor
final class LAAComposerMarkdownTests: XCTestCase {
    func testBoldKeepsUnicodeSelection() {
        let view = UITextView()
        view.text = "前😀後"
        view.selectedRange = NSRange(location: 1, length: 2)
        LAAComposerMarkdown.apply(.bold, to: view)
        XCTAssertEqual(view.text, "前**😀**後")
        XCTAssertEqual(view.selectedRange, NSRange(location: 3, length: 2))
    }
    func testListAndCheckboxPrefixSelectedLines() {
        let view = UITextView()
        view.text = "一\n二\n終"
        view.selectedRange = NSRange(location: 0, length: 3)
        LAAComposerMarkdown.apply(.checkbox, to: view)
        XCTAssertEqual(view.text, "- [ ] 一\n- [ ] 二\n終")
    }
    func testCodeUsesFenceForMultipleLines() {
        let view = UITextView()
        view.text = "a\nb"
        view.selectedRange = NSRange(location: 0, length: 3)
        LAAComposerMarkdown.apply(.code, to: view)
        XCTAssertEqual(view.text, "```\na\nb\n```")
    }
    func testMarkedTextIsNeverReplaced() {
        let view = UITextView()
        view.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
        guard view.markedTextRange != nil else { XCTFail("IME setup failed"); return }
        let original = view.text
        LAAComposerMarkdown.apply(.bold, to: view)
        XCTAssertEqual(view.text, original)
    }
}
#endif

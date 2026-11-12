#if LAA_BUILD && DEBUG
import XCTest
import SwiftUI
@testable import Conduit

final class LAAMarkdownInteractionTests: XCTestCase {
    func testMetadataAndUnknownMarkdownRemainByteIdentical() {
        for source in ["---\r\ncustom: [x, y]\r\nunknown: |\r\n  value\r\n...\r\n\r\n:::custom\r\nBody", "---\na: b\n---", "---\nunclosed\nBody", "plain\n"] {
            let document = LAABrainEditableSource(source)
            XCTAssertEqual(Data(document.replacingBody(document.body).utf8), Data(source.utf8))
            XCTAssertEqual(document.replacingBody(document.body + "追加"), source + "追加")
        }
    }

    @MainActor func testReadingPositionIsScopedByVaultAndDocument() {
        let positions = LAABrainReadingPositions()
        positions.remember(520, for: "vault-A/note")
        positions.remember(90, for: "vault-B/note")
        positions.remember(-10, for: "vault-A/note")
        XCTAssertEqual(positions.offset(for: "vault-A/note"), 520)
        XCTAssertEqual(positions.offset(for: "vault-B/note"), 90)
        XCTAssertEqual(positions.offset(for: "other"), 0)
    }

    func testSourceLinksKeepOriginalOffsetsAndIgnoreCode() {
        let source = "prefix\n[[Other#Details|次のメモ]]\n`[[code]]`\n```\n[[fenced]]\n```\n[text](https://example.com)"
        let links = LAAMarkdownSourceLinks.links(in: source)
        XCTAssertEqual(links.map(\.target), ["Other#Details|次のメモ", "https://example.com"])
        XCTAssertEqual((source as NSString).substring(with: links[0].range), "[[Other#Details|次のメモ]]")
    }

    @MainActor func testAttachmentSegmentsKeepTheirOriginalPositionAndBytes() {
        for source in ["前\n\n![[Assets/image.png]]\n\n後", "![[Other]]", "\n![a](Assets/a.png)\r\n後\r\n", "```\n![[literal]]\n```"] {
            let model = LAAMarkdownDocumentModel(text: source) { _ in }
            XCTAssertEqual(Data(model.sourceText.utf8), Data(source.utf8))
            if !source.hasPrefix("```") {
                XCTAssertTrue(model.segments.contains { if case .attachment = $0.content { return true }; return false })
            }
        }
    }

    func testReturnInCodeAndFrontmatterDoesNotContinueAList() {
        for source in ["```\n- [ ] literal\n```", "~~~md\n- literal\n~~~", "---\n- literal\n---"] {
            let caret = (source as NSString).range(of: "literal").location + 7
            XCTAssertNil(LAAMarkdownFormat.returnInsertion(text: source, caret: caret), source)
        }
    }

    func testNestedEmptyItemsExitCleanlyAndCRLFIsPreserved() throws {
        for source in ["  - [ ] ", "    - ", "  3. "] {
            let edit = try XCTUnwrap(LAAMarkdownFormat.returnInsertion(text: source, caret: (source as NSString).length))
            XCTAssertEqual(edit.text, "")
            XCTAssertEqual(edit.selection, NSRange(location: 0, length: 0))
        }
        let source = "intro\r\n- [ ] task"
        let next = try XCTUnwrap(LAAMarkdownFormat.returnInsertion(text: source, caret: (source as NSString).length))
        XCTAssertEqual(next.text, source + "\r\n- [ ] ")
    }

    @MainActor func testInlineStylesStayOnTheirOwnLine() throws {
        let source = "Untouched first line\nSecond **bold** and `code`\nThird [[Note|link]]"
        let output = LAAMarkdownStyler.output(for: source, caretLocation: 0)
        let ns = source as NSString
        let styled = NSMutableAttributedString(string: source)
        for run in output.runs where run.range.length > 0 {
            if run.reset { styled.setAttributes(run.attributes, range: run.range) }
            else { styled.addAttributes(run.attributes, range: run.range) }
        }
        let first = try XCTUnwrap(styled.attribute(.font, at: 2, effectiveRange: nil) as? UIFont)
        let bold = try XCTUnwrap(styled.attribute(.font, at: ns.range(of: "bold").location, effectiveRange: nil) as? UIFont)
        XCTAssertFalse(first.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.traitBold))
        let marker = try XCTUnwrap(styled.attribute(.font, at: ns.range(of: "**").location, effectiveRange: nil) as? UIFont)
        XCTAssertLessThan(marker.pointSize, 1)
    }

    @MainActor func testCompletedChecklistUsesSecondaryInk() throws {
        let output = LAAMarkdownStyler.output(for: "- [x] complete", caretLocation: nil)
        let color = try XCTUnwrap(output.runs.first?.attributes[.foregroundColor] as? UIColor)
        XCTAssertEqual(color, UIColor(LAAColor.secondaryText))
    }

    @MainActor func testReturnKeepsThreeChecklistRowsAndBodySizeCaret() throws {
        let session = LAAMarkdownEditingSession()
        let parent = LAAMarkdownTextView(text: "- [ ] first", session: session, height: .constant(44),
                                       autoFocus: false, isEnabled: true, onTextChange: { _ in }, onSelectionChange: { _ in })
        let coordinator = parent.makeCoordinator()
        let view = LAAMarkdownUITextView()
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        view.text = "- [ ] first"
        view.delegate = coordinator
        coordinator.attach(view)
        for label in ["second", "third"] {
            view.selectedRange = NSRange(location: (view.text as NSString).length, length: 0)
            XCTAssertFalse(coordinator.textView(view, shouldChangeTextIn: view.selectedRange, replacementText: "\n"))
            let font = try XCTUnwrap(view.typingAttributes[.font] as? UIFont)
            XCTAssertGreaterThan(font.pointSize, 10, "hidden markers cannot become the typing font")
            view.insertText(label)
            coordinator.textViewDidChange(view)
        }
        XCTAssertEqual(view.text, "- [ ] first\n- [ ] second\n- [ ] third")
        XCTAssertEqual(view.glyphs.count, 3)
        XCTAssertEqual(view.selectedRange.location, (view.text as NSString).length)
        view.undoManager?.undo()
        XCTAssertFalse(view.text.hasSuffix("third"))
        view.undoManager?.redo()
        XCTAssertTrue(view.text.hasSuffix("third"))
    }

    @MainActor func testLongUnbrokenTextWrapsAndCannotPanItsOrigin() async throws {
        let source = "LEFT " + String(repeating: "abcdefghijklmnopqrstuvwxyz0123456789", count: 14) + " RIGHT\n" + String(repeating: "長い日本語の本文", count: 30)
        let host = UIHostingController(rootView: LAAMarkdownEditor(text: source) { _ in })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 956))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.view.layoutIfNeeded()
        func find(_ view: UIView) -> LAAMarkdownUITextView? {
            if let text = view as? LAAMarkdownUITextView { return text }
            return view.subviews.lazy.compactMap(find).first
        }
        let text = try XCTUnwrap(find(host.view))
        XCTAssertLessThanOrEqual(text.bounds.width, 408)
        XCTAssertGreaterThan(text.bounds.width, 300)
        let first = text.caretRect(for: text.beginningOfDocument)
        let end = text.caretRect(for: text.endOfDocument)
        XCTAssertGreaterThan(end.minY, first.minY + 100)
        XCTAssertLessThanOrEqual(end.maxX, text.bounds.maxX + 1)
        text.contentOffset = CGPoint(x: 80, y: 30)
        text.setNeedsLayout(); text.layoutIfNeeded()
        XCTAssertEqual(text.contentOffset, .zero)
        XCTAssertEqual(text.text, source, "layout never rewrites the Markdown")
    }

    @MainActor func testCheckboxTapTargetsKeepAdjacentRowsDistinct() throws {
        let source = "- [ ] first\n- [ ] second\n- [x] third"
        let parent = LAAMarkdownTextView(text: source, session: LAAMarkdownEditingSession(), height: .constant(200),
                                       autoFocus: false, isEnabled: true, onTextChange: { _ in }, onSelectionChange: { _ in })
        let coordinator = parent.makeCoordinator()
        let view = LAAMarkdownUITextView()
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        view.text = source
        coordinator.attach(view)
        view.layoutIfNeeded()
        for glyph in view.glyphs {
            let position = try XCTUnwrap(view.position(from: view.beginningOfDocument, offset: glyph.lineLocation))
            let line = view.caretRect(for: position)
            let x = max(line.minX - LAAMarkdownStyler.gutter + 2, 0) + 9
            XCTAssertEqual(view.checkboxLocation(at: CGPoint(x: x, y: line.midY)), glyph.lineLocation)
            XCTAssertEqual(view.checkboxLocation(at: CGPoint(x: x + 20, y: line.midY)), glyph.lineLocation)
        }
    }

    @MainActor func testCaretIsAsTallAsTheTypingFontNotTheLineBox() throws {
        let source = "# Heading\nBody text\n- [ ] "
        let parent = LAAMarkdownTextView(text: source, session: LAAMarkdownEditingSession(), height: .constant(200),
                                       autoFocus: false, isEnabled: true, onTextChange: { _ in }, onSelectionChange: { _ in })
        let coordinator = parent.makeCoordinator()
        let view = LAAMarkdownUITextView()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 956))
        window.addSubview(view)
        window.isHidden = false
        defer { window.isHidden = true }
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        view.text = source
        view.delegate = coordinator
        coordinator.attach(view)
        view.layoutIfNeeded()
        var heights: [String: CGFloat] = [:]
        // Ends of the heading and the body line, and an empty checklist item
        // whose only characters are hidden markers.
        // The expected font is read from a visible character: "H" for the
        // heading, "B" for the body and the empty item.
        for (label, location, sample) in [("heading", 9, 2), ("body", 19, 10), ("empty item", 26, 10)] {
            view.selectedRange = NSRange(location: location, length: 0)
            coordinator.textViewDidChangeSelection(view)
            view.layoutIfNeeded()
            let position = try XCTUnwrap(view.position(from: view.beginningOfDocument, offset: location))
            let caret = view.caretRect(for: position)
            let line = view.systemCaretRect(for: position)
            let font = try XCTUnwrap(view.textStorage.attribute(.font, at: sample, effectiveRange: nil) as? UIFont)
            XCTAssertEqual(caret.height, font.ascender - font.descender, accuracy: 1, label)
            XCTAssertEqual(caret.minX, line.minX, label)
            heights[label] = caret.height
            // The system sizes an empty item's caret from its hidden markers;
            // the other lines keep the caret inside their own box.
            guard label != "empty item" else { continue }
            XCTAssertLessThan(caret.height, line.height, label)
            XCTAssertGreaterThanOrEqual(caret.minY, line.minY - 0.5, "\(label) stays on its own line")
            XCTAssertLessThanOrEqual(caret.maxY, line.maxY + 0.5, "\(label) stays on its own line")
        }
        XCTAssertGreaterThan(heights["heading"] ?? 0, (heights["body"] ?? 0) + 3, "a heading's caret follows its larger font")
    }

    @MainActor func testEmptyNoteFocusWaitsUntilTheViewHasAWindow() async throws {
        let host = UIHostingController(rootView: LAAMarkdownEditor(text: "", autoFocus: true) { _ in })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 956))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        func find(_ view: UIView) -> LAAMarkdownUITextView? {
            if let text = view as? LAAMarkdownUITextView { return text }
            return view.subviews.lazy.compactMap(find).first
        }
        let text = try XCTUnwrap(find(host.view))
        XCTAssertTrue(text.isFirstResponder, "empty notes accept input without a tap")
        text.resignFirstResponder(); text.setNeedsLayout(); text.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(text.isFirstResponder, "closing the keyboard does not immediately reopen it")
    }
}
#endif

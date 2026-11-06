#if LAA_BUILD && DEBUG
import XCTest
@testable import Conduit

/// The note editor must never lose a character it was not asked to change:
/// these tests lock the Markdown round trip, the block toggles, tables,
/// unsupported syntax and the IME gate.
final class LAAMarkdownEditorTests: XCTestCase {
    // MARK: Round trip

    private func assertRoundTrip(_ source: String, file: StaticString = #filePath, line: UInt = #line) {
        let segments = LAAMarkdownParser.segments(in: source)
        XCTAssertEqual(LAAMarkdownParser.text(from: segments), source, "source survives a parse", file: file, line: line)
    }

    func testRoundTripKeepsSourceExactly() {
        assertRoundTrip("")
        assertRoundTrip("\n")
        assertRoundTrip("一行だけ")
        assertRoundTrip("見出し\n\n本文\n- 箇条書き\n")
        assertRoundTrip("---\ntitle: x\ntags: [a]\n---\n# 見出し\n本文\n")
        assertRoundTrip("| a | b |\n| --- | --- |\n| 1 | 2 |\n")
        assertRoundTrip("前\n| a | b |\n| --- | --- |\n| 1 | 2 |\n後\n")
    }

    func testUnsupportedSyntaxSurvives() {
        let source = """
        ---
        title: メモ
        ---
        ::: callout
        %% コメント %%
        <div class="x">html</div>
        [key]: value
        ```swift
        let a = 1
        ```
        [[別のノート|別名]] と ==強調==
        ![[画像.png]]
        """
        assertRoundTrip(source)
        XCTAssertEqual(LAAMarkdownParser.segments(in: source).count, 1)
    }

    // MARK: Tables

    func testUntouchedTableIsWrittenBackByteForByte() {
        let source = "|a|b|\n|:--|--:|\n|1|2|"
        let segments = LAAMarkdownParser.segments(in: source)
        guard case .table(let table) = segments[0] else { return XCTFail("expected a table") }
        XCTAssertEqual(table.alignments, [.left, .right])
        XCTAssertFalse(table.edited)
        XCTAssertEqual(table.markdown, source)
    }

    func testEditingACellRewritesOnlyThatTable() {
        let source = "前\n| a | b |\n| --- | --- |\n| 1 | 2 |\n後"
        let segments = LAAMarkdownParser.segments(in: source)
        guard case .table(var table) = segments[1] else { return XCTFail("expected a table") }
        table.setCell("3", row: 0, column: 1)
        var edited = segments
        edited[1] = .table(table)
        XCTAssertEqual(LAAMarkdownParser.text(from: edited),
                       "前\n| a | b |\n| --- | --- |\n| 1 | 3 |\n後")
    }

    func testCellsKeepPipesAndStayRectangular() {
        var table = LAAMarkdownTable(header: ["a|b"], alignments: [.none], rows: [["r"]], rawLines: nil)
        table.normalise()
        table.addColumn()
        table.addRow()
        XCTAssertEqual(LAAMarkdownTable.cells(in: table.markdownLines[0]), ["a|b", ""])
        XCTAssertEqual(table.rows.count, 2)
        table.removeColumn(1)
        table.removeRow(0)
        XCTAssertEqual(table.markdown, "| a\\|b |\n| --- |\n|  |")
    }

    func testInsertTableIsARealTable() {
        let edit = LAAMarkdownFormat.insertTable(text: "前の行", selection: NSRange(location: 0, length: 0))
        XCTAssertTrue(edit.text.hasPrefix("前の行\n| 見出し1 | 見出し2 |\n| --- | --- |"))
        let segments = LAAMarkdownParser.segments(in: edit.text)
        XCTAssertTrue(segments.contains { if case .table = $0 { return true } else { return false } })
    }

    // MARK: Blocks

    func testBlockTogglesApplyAndRemove() {
        let body = "一文目\n二文目\n"
        let bullet = LAAMarkdownFormat.setBlock(.bullet, text: body, selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(bullet.text, "- 一文目\n二文目\n")
        XCTAssertEqual(bullet.selection, NSRange(location: 2, length: 0))
        XCTAssertEqual(LAAMarkdownFormat.setBlock(.bullet, text: bullet.text, selection: bullet.selection).text, body)
        XCTAssertEqual(LAAMarkdownFormat.setBlock(.ordered, text: body, selection: NSRange(location: 0, length: 10)).text,
                       "1. 一文目\n1. 二文目\n")
        XCTAssertEqual(LAAMarkdownFormat.setBlock(.heading1, text: "見出し", selection: NSRange(location: 0, length: 0)).text,
                       "# 見出し")
    }

    func testCheckboxToggles() {
        let added = LAAMarkdownFormat.toggleCheckbox(text: "買う", selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(added.text, "- [ ] 買う")
        let checked = LAAMarkdownFormat.toggleCheckbox(text: added.text, selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(checked.text, "- [x] 買う")
        let cleared = LAAMarkdownFormat.toggleCheckbox(text: checked.text, selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(cleared.text, "- [ ] 買う")
    }

    func testReturnContinuesListsAndEndsOnAnEmptyItem() {
        XCTAssertEqual(LAAMarkdownFormat.returnInsertion(text: "- あ", caret: 3)?.text, "- あ\n- ")
        XCTAssertEqual(LAAMarkdownFormat.returnInsertion(text: "2. あ", caret: 4)?.text, "2. あ\n3. ")
        XCTAssertEqual(LAAMarkdownFormat.returnInsertion(text: "- [x] あ", caret: 7)?.text, "- [x] あ\n- [ ] ")
        XCTAssertEqual(LAAMarkdownFormat.returnInsertion(text: "> あ", caret: 3)?.text, "> あ\n> ")
        XCTAssertEqual(LAAMarkdownFormat.returnInsertion(text: "- ", caret: 2)?.text, "")
        XCTAssertNil(LAAMarkdownFormat.returnInsertion(text: "本文", caret: 1))
    }

    func testInlineWrapKeepsTheSourceMarkers() {
        let bold = LAAMarkdownFormat.wrapInline("**", text: "重要な文", selection: NSRange(location: 0, length: 4))
        XCTAssertEqual(bold.text, "**重要な文**")
        XCTAssertEqual(bold.selection, NSRange(location: 2, length: 4))
        XCTAssertEqual(LAAMarkdownFormat.wrapInline("**", text: bold.text, selection: bold.selection).text, "重要な文")
        XCTAssertEqual(LAAMarkdownFormat.wrapInline("**", text: "**重要な文**", selection: NSRange(location: 2, length: 4)).text,
                       "重要な文")
    }

    func testOnlyTheCaretLineChanges() {
        let long = (0..<50).map { "行\($0)" }.joined(separator: "\n") + "\n"
        let edit = LAAMarkdownFormat.setBlock(.bullet, text: long, selection: NSRange(location: 60, length: 0))
        let changed = zip(long.components(separatedBy: "\n"), edit.text.components(separatedBy: "\n")).filter { $0 != $1 }
        XCTAssertEqual(changed.count, 1)
    }

    // MARK: Styling ranges

    func testLinesExposeMarkersToHide() {
        let lines = LAAMarkdownParser.lines(in: "# 見出し\n- [x] 済み\n3. 番号\n> 引用\n```swift\nlet a = 1\n```")
        XCTAssertEqual(lines[0].kind, .heading(level: 1))
        XCTAssertEqual(lines[0].marker, "# ")
        XCTAssertEqual(lines[0].content, "見出し")
        XCTAssertEqual(lines[1].kind, .checkbox(checked: true))
        XCTAssertEqual(lines[1].marker, "- [x] ")
        XCTAssertEqual(lines[2].marker, "3. ")
        XCTAssertEqual(lines[3].marker, "> ")
        XCTAssertEqual(lines[4].kind, .fence(language: "swift"))
        XCTAssertEqual(lines[5].kind, .code)
    }

    func testInlineSpansFindTheirTextAndMarkers() {
        let line = "- **太字** と本文"
        let content = NSRange(location: 2, length: (line as NSString).length - 2)
        let spans = LAAMarkdownInline.spans(in: line, contentRange: content)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.style, .bold)
        XCTAssertEqual(spans.first?.range, NSRange(location: 4, length: 2))
        XCTAssertEqual(spans.first?.markers.count, 2)
        XCTAssertEqual(LAAMarkdownInline.spans(in: "- 200 * 3", contentRange: NSRange(location: 2, length: 5)).count, 0)
    }

// MARK: Data loss (review 2026-11-06)

    /// Edits one cell, saves (the joined source) and reads it back, the way
    /// the editor's 保存 then reopening the note does.
    private func editAndReload(_ source: String, row: Int, column: Int, value: String,
                               file: StaticString = #filePath, line: UInt = #line) -> LAAMarkdownTable? {
        var segments = LAAMarkdownParser.segments(in: source)
        guard let index = segments.firstIndex(where: { if case .table = $0 { return true } else { return false } }),
              case .table(var table) = segments[index] else {
            XCTFail("expected a table", file: file, line: line)
            return nil
        }
        table.setCell(value, row: row, column: column)
        segments[index] = .table(table)
        let saved = LAAMarkdownParser.text(from: segments)
        guard case .table(let reloaded) = LAAMarkdownParser.segments(in: saved)[index] else {
            XCTFail("the edited table must parse again", file: file, line: line)
            return nil
        }
        return reloaded
    }

    func testOneCellEditKeepsWiderRowsEmptyRowsEmojiAndEscapes() {
        let wide = "| a | b |\n| --- | --- |\n| 1 | 2 | 3 |"
        let wideReloaded = editAndReload(wide, row: 0, column: 0, value: "9")
        XCTAssertEqual(wideReloaded?.header, ["a", "b"], "a wider row must not grow the header")
        XCTAssertEqual(wideReloaded?.rows[0], ["9", "2", "3"], "extra cells survive the edit")

        let emptyRow = "| a | b |\n| --- | --- |\n|  |  |\n| c | d |"
        let emptyReloaded = editAndReload(emptyRow, row: -1, column: 0, value: "見出し")
        XCTAssertEqual(emptyReloaded?.rows.count, 2, "an empty row is still a row")
        XCTAssertEqual(emptyReloaded?.rows[0], ["", ""])
        XCTAssertEqual(emptyReloaded?.rows[1], ["c", "d"])

        let emoji = "| 😀 | 家族👨‍👩‍👧 |\n| --- | --- |\n| 🎉 | b |"
        let emojiReloaded = editAndReload(emoji, row: 0, column: 1, value: "x")
        XCTAssertEqual(emojiReloaded?.header, ["😀", "家族👨‍👩‍👧"], "non-BMP characters survive")
        XCTAssertEqual(emojiReloaded?.rows[0], ["🎉", "x"])

        let escaped = "| a\\|b | c |\n| --- | --- |\n| 1 | 2 |"
        let escapedReloaded = editAndReload(escaped, row: 0, column: 1, value: "3")
        XCTAssertEqual(escapedReloaded?.header, ["a|b", "c"], "an escaped pipe stays in its cell")
        XCTAssertEqual(escapedReloaded?.rows[0], ["1", "3"])
    }

    func testFencedPipesAreCodeNotATable() {
        let source = "```\n| a | b |\n| --- | --- |\n```\n| x | y |\n| --- | --- |\n| 1 | 2 |"
        assertRoundTrip(source)
        let segments = LAAMarkdownParser.segments(in: source)
        XCTAssertEqual(segments.count, 2)
        guard case .text(let code) = segments[0] else { return XCTFail("the fence must stay text") }
        XCTAssertTrue(code.contains("| a | b |"))
        guard case .table(let table) = segments[1] else { return XCTFail("the table after the fence") }
        XCTAssertEqual(table.header, ["x", "y"])
        assertRoundTrip("~~~\n| a | b |\n| --- | --- |\n~~~\n本文")
    }

    func testMixedDocumentOnlyChangesTheEditedTable() {
        let mixed = """
        # 見出し

        ```
        | コード | 表 |
        | --- | --- |
        ```

        | 項目 | 値 |
        | --- | --- |
        | あ | 1 |
        | い | 2 |

        末尾の段落
        """
        var segments = LAAMarkdownParser.segments(in: mixed)
        guard let index = segments.firstIndex(where: { if case .table = $0 { return true } else { return false } }),
              case .table(var table) = segments[index] else { return XCTFail("expected a table") }
        table.setCell("変更", row: 0, column: 0)
        segments[index] = .table(table)
        let saved = LAAMarkdownParser.text(from: segments)
        XCTAssertTrue(saved.contains("```\n| コード | 表 |\n| --- | --- |\n```"))
        XCTAssertTrue(saved.contains("# 見出し"))
        XCTAssertTrue(saved.contains("末尾の段落"))
        guard case .table(let reloaded) = LAAMarkdownParser.segments(in: saved)[index] else {
            return XCTFail("the saved table must parse again")
        }
        XCTAssertEqual(reloaded.header, ["項目", "値"])
        XCTAssertEqual(reloaded.rows, [["変更", "1"], ["い", "2"]])
    }

func testHeaderEditPastTheHeaderWidthGrowsItSafely() {
        let ragged = "| a | b |\n| --- | --- |\n| 1 | 2 | 3 |"
        let reloaded = editAndReload(ragged, row: -1, column: 2, value: "x")
        XCTAssertEqual(reloaded?.header, ["a", "b", "x"])
        XCTAssertEqual(reloaded?.rows[0], ["1", "2", "3"])
    }

    func testBackslashesAndPastedNewlinesStayInTheirCell() {
        let slashes = "| a\\\\b | c\\|d |\n| --- | --- |\n| 1 | 2 |"
        let reloaded = editAndReload(slashes, row: 0, column: 0, value: "z")
        XCTAssertEqual(reloaded?.header[0], "a\\b", "a doubled backslash reads as one backslash")
        XCTAssertEqual(reloaded?.header[1], "c|d", "an escaped pipe survives")
        XCTAssertEqual(reloaded?.rows[0], ["z", "2"])

        var table = LAAMarkdownTable.from(["| a | b |", "| --- | --- |", "| 1 | 2 |"])!
        table.setCell("line1\nline2", row: 0, column: 0)
        let saved = table.markdown
        XCTAssertFalse(saved.contains("\n\n"), "a pasted newline must not add a row")
        XCTAssertEqual(LAAMarkdownTable.from(LAAMarkdownParser.split(saved))?.rows[0], ["line1<br>line2", "2"],
                       "a pasted newline is written as <br>, the table's own break")
        XCTAssertEqual(LAAMarkdownTable.from(LAAMarkdownParser.split("| a<br>b | c |\n| --- | --- |"))?.header,
                       ["a<br>b", "c"], "a literal <br> stays as written")
    }

    // MARK: Live model (the grid reads this, not a snapshot)

    @MainActor func testConsecutiveCellEditsOnTheLiveModelKeepBoth() {
        let model = LAAMarkdownDocumentModel(text: "| a | b |\n| --- | --- |\n| 1 | 2 |") { _ in }
        guard let id = model.segments.first(where: { if case .table = $0.content { return true } else { return false } })?.id else {
            return XCTFail("expected a table segment")
        }
        var first = model.table(id)!
        first.setCell("A", row: 0, column: 0)
        model.updateTable(id, table: first)
        var second = model.table(id)!
        second.setCell("B", row: 0, column: 1)
        model.updateTable(id, table: second)
        XCTAssertEqual(model.table(id)?.rows[0], ["A", "B"], "the second edit keeps the first")
        XCTAssertEqual(model.sourceText, "| a | b |\n| --- | --- |\n| A | B |")
    }

    @MainActor func testCellTypingDoesNotRepublishTheDocument() {
        let model = LAAMarkdownDocumentModel(text: "| a | b |\n| --- | --- |\n| 1 | 2 |") { _ in }
        guard let id = model.segments.first(where: { if case .table = $0.content { return true } else { return false } })?.id else {
            return XCTFail("expected a table segment")
        }
        let revision = model.revision
        var table = model.table(id)!
        table.setCell("A", row: 0, column: 0)
        model.updateTable(id, table: table)
        XCTAssertEqual(model.revision, revision, "a cell edit must not redraw the grid under an IME composition")
        var grown = model.table(id)!
        grown.addRow()
        model.updateTableStructure(id, table: grown)
        XCTAssertGreaterThan(model.revision, revision, "adding a row changes the grid's shape and republishes")
    }

@MainActor func testRestoredVersionReplacesTheDraftAndTypingKeepsIt() {
        let model = LAAMarkdownDocumentModel(text: "古い内容") { _ in }
        model.reload("履歴から復元した内容")
        XCTAssertEqual(model.sourceText, "履歴から復元した内容", "the restored version is what the editor holds")
        guard let id = model.segments.first?.id else { return XCTFail("expected a text segment") }
        model.updateText(id, text: "履歴から復元した内容に追記")
        XCTAssertEqual(model.sourceText, "履歴から復元した内容に追記", "typing after a restore edits the restored text")
        let revision = model.revision
        model.reload("履歴から復元した内容に追記")
        XCTAssertEqual(model.revision, revision, "the editor's own edit must not reinitialise the model")
    }

    func testEscapedTrailingPipeSurvivesAnEditElsewhere() {
        let source = "| a | b\\|\n| --- | --- |\n| 1 | 2 |"
        let reloaded = editAndReload(source, row: -1, column: 0, value: "x")
        XCTAssertEqual(reloaded?.header, ["x", "b|"], "the escaped trailing pipe stays in its cell")
        XCTAssertEqual(reloaded?.rows[0], ["1", "2"])

        // An even number of backslashes leaves a real delimiter; an odd number
        // escapes the pipe into the cell. Either way another cell's edit must
        // not change it.
        for line in ["| a | b\\|", "| a | b\\\\|", "| a | b\\\\\\|", "| a | b"] {
            let text = line + "\n| --- | --- |\n| 1 | 2 |"
            guard let table = LAAMarkdownTable.from(LAAMarkdownParser.split(text)) else {
                return XCTFail("expected a table for \(line)")
            }
            var edited = table
            edited.setCell("z", row: -1, column: 0)
            let reparsed = LAAMarkdownTable.from(LAAMarkdownParser.split(edited.markdown))
            XCTAssertEqual(reparsed?.header.count, table.header.count, "cell count stays stable for \(line)")
            XCTAssertEqual(reparsed?.header.last, table.header.last, "the last cell keeps its text for \(line)")
        }
    }

    func testCRLFTableStaysEditableAndKeepsItsLineEndings() {
        let source = "前置き\r\n| 項目 | 値 |\r\n| --- | --- |\r\n| あ | 1 |\r\n後置き\r\n"
        assertRoundTrip(source)
        let segments = LAAMarkdownParser.segments(in: source)
        XCTAssertEqual(segments.count, 3, "a CRLF table is a table, not text")
        guard case .table(let table) = segments[1] else { return XCTFail("expected a table") }
        XCTAssertEqual(table.header, ["項目", "値"])
        XCTAssertEqual(table.rows, [["あ", "1"]])
        XCTAssertTrue(table.trailingReturn, "the table knows it ended with CRLF")
        var edited = table
        edited.setCell("3", row: 0, column: 1)
        XCTAssertEqual(edited.markdown, "| 項目 | 値 |\r\n| --- | --- |\r\n| あ | 3 |\r",
                       "an edited CRLF table stays CRLF")
        XCTAssertEqual(LAAMarkdownTable.from(LAAMarkdownParser.split(edited.markdown))?.rows, [["あ", "3"]])
    }

    @MainActor func testInsertingATableGoesIntoTheFocusedRun() {
        let text = "# 見出し\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n末尾の段落\n"
        let model = LAAMarkdownDocumentModel(text: text) { _ in }
        XCTAssertEqual(model.segments.count, 3, "text, table, text")
        guard let trailing = model.segments.last, case .text(let trailingText) = trailing.content else {
            return XCTFail("expected a trailing text run")
        }
        XCTAssertEqual(trailingText, "末尾の段落\n")
        model.insertTable(selection: NSRange(location: 0, length: 0), into: trailing.id)
        let sources = model.segments.map(\.content)
        XCTAssertEqual(sources.count, 4, "the table split the focused run")
        guard case .text(let untouched) = sources[0] else { return XCTFail("first run stays text") }
        XCTAssertEqual(untouched, "# 見出し\n", "the run before the table is untouched")
        guard case .table(let original) = sources[1] else { return XCTFail("the original table stays") }
        XCTAssertEqual(original.header, ["a", "b"])
        guard case .table(let inserted) = sources[2] else { return XCTFail("the new table is after the paragraph") }
        XCTAssertEqual(inserted.header, ["見出し1", "見出し2"])
        XCTAssertEqual(model.sourceText.hasSuffix("末尾の段落\n| 見出し1 | 見出し2 |\n| --- | --- |\n|  |  |\n|  |  |\n"), true,
                       "the table lands under the trailing paragraph, not at the old run")
    }

    func testCRLFLineKindsIgnoreTheCarriageReturn() {
        let lines = LAAMarkdownParser.lines(in: "---\r\ntitle: x\r\n---\r\n# 見出し\r\n- 箇条書き\r\n---\r\n")
        XCTAssertEqual(lines[0].kind, .frontmatter)
        XCTAssertEqual(lines[2].kind, .frontmatter)
        XCTAssertEqual(lines[3].kind, .heading(level: 1))
        XCTAssertEqual(lines[3].content, "見出し", "no carriage return in the content")
        XCTAssertEqual(lines[4].kind, .bullet)
        XCTAssertEqual(lines[5].kind, .rule)
        XCTAssertEqual(lines[5].range.location, 35, "offsets still count the carriage returns")
    }

    func testEveryBackslashCountBeforeAPipeRoundTrips() {
        // Typed values: 0–5 backslashes before a pipe.
        for count in 0...5 {
            let value = "a" + String(repeating: "\\", count: count) + "|b"
            var table = LAAMarkdownTable(header: ["h", "keep"], alignments: [.none, .none],
                                         rows: [[value, "x"]], rawLines: nil)
            table.setCell("y", row: 0, column: 1)
            let reloaded = LAAMarkdownTable.from(LAAMarkdownParser.split(table.markdown))
            XCTAssertEqual(reloaded?.rows.count, 1, "row count stays 1 for \(count) backslashes")
            XCTAssertEqual(reloaded?.rows[0].count, 2, "cell count stays 2 for \(count) backslashes")
            XCTAssertEqual(reloaded?.rows[0][0], value, "\(count) backslashes and a pipe round trip")
            XCTAssertEqual(reloaded?.rows[0][1], "y", "the edited neighbour is kept for \(count)")
        }

        // The same value read from an existing note: escaping writes 2n+1
        // backslashes, so another cell's edit must not re-split the row.
        for count in 0...5 {
            let encoded = "a" + String(repeating: "\\", count: 2 * count + 1) + "|b"
            let source = "| h | keep |\n| --- | --- |\n| \(encoded) | x |"
            guard let table = LAAMarkdownTable.from(LAAMarkdownParser.split(source)) else {
                return XCTFail("existing table parses for \(count)")
            }
            XCTAssertEqual(table.rows[0].count, 2, "existing row keeps 2 cells for \(count)")
            var edited = table
            edited.setCell("y", row: 0, column: 1)
            let reparsed = LAAMarkdownTable.from(LAAMarkdownParser.split(edited.markdown))
            XCTAssertEqual(reparsed?.rows[0].count, 2, "existing cell count stable for \(count)")
            XCTAssertEqual(reparsed?.rows[0][0], table.rows[0][0], "existing cell value stable for \(count)")
        }
    }

    // MARK: IME

    @MainActor func testStylingWaitsForTheIMECompositionToEnd() {
        let view = LAAMarkdownUITextView()
        view.text = "本文"
        XCTAssertTrue(view.acceptsLiveStyling)
        view.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertFalse(view.acceptsLiveStyling, "composition must not be restyled or replaced")
        view.unmarkText()
        XCTAssertTrue(view.acceptsLiveStyling)
    }
}
#endif

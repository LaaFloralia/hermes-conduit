#if LAA_BUILD
import SwiftUI

/// A Markdown table shown as a table while editing: the header, the delimiter
/// row's alignment and every cell are the source, so what is typed here is
/// what gets saved.
///
/// The grid reads the document model on every keystroke instead of a copy
/// taken when it was drawn: two cells edited in a row both land, and the grid
/// still republishes only when its shape changes, so an IME composition in a
/// cell is never replaced by a redraw.
struct LAAMarkdownTableEditor: View {
    @ObservedObject var model: LAAMarkdownDocumentModel
    let segmentID: UUID
    @FocusState private var focused: Cell?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.laaDesktop) private var laaDesktop
    @State private var confirmingRemoval = false

    private struct Cell: Hashable {
        let row: Int
        let column: Int
    }

    private var table: LAAMarkdownTable {
        model.table(segmentID) ?? LAAMarkdownTable(header: [""], alignments: [.none], rows: [], rawLines: nil)
    }

    private var cellWidth: CGFloat {
        let columns = max(1, table.columnCount)
        // The Mac detail column keeps a compact size class, so a size-class
        // cell would stay at phone width there; read the desktop flag instead.
        if laaDesktop {
            return max(96, min(220, LAADesktopMetrics.readingWidth / CGFloat(columns)))
        }
        let width = sizeClass == .compact ? 132.0 : 180.0
        return max(96, min(width, 640 / CGFloat(columns)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            ScrollView(.horizontal, showsIndicators: true) {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    headerRow
                    ForEach(Array(table.rows.indices), id: \.self) { row in
                        bodyRow(row)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(LAAColor.separator, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.vertical, LAASpacing.x1)
            }
            HStack(spacing: LAASpacing.x3) {
                Button { changeStructure { $0.addRow() } } label: {
                    Label { Text(verbatim: "行を追加") } icon: { Image(systemName: "plus") }
                        .laaTextStyle(.secondary)
                }
                .buttonStyle(.plain)
                .foregroundStyle(LAAColor.link)
                .accessibilityIdentifier("laa.markdown.table.addRow")
                Button { changeStructure { $0.addColumn() } } label: {
                    Label { Text(verbatim: "列を追加") } icon: { Image(systemName: "plus") }
                        .laaTextStyle(.secondary)
                }
                .buttonStyle(.plain)
                .foregroundStyle(LAAColor.link)
                .accessibilityIdentifier("laa.markdown.table.addColumn")
                Spacer(minLength: LAASpacing.x2)
                Button(role: .destructive) { confirmingRemoval = true } label: {
                    Label { Text(verbatim: "表を削除") } icon: { Image(systemName: "trash") }
                        .laaTextStyle(.secondary)
                }
                .buttonStyle(.plain)
                .foregroundStyle(LAAColor.attention)
                .accessibilityIdentifier("laa.markdown.table.remove")
            }
            .padding(.horizontal, LAASpacing.x1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("laa.markdown.table")
        .confirmationDialog(Text(verbatim: "この表を削除しますか？"), isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button(role: .destructive) { model.removeTable(segmentID) } label: { Text(verbatim: "表を削除") }
                .accessibilityIdentifier("laa.markdown.table.removeConfirm")
            Button(LAACopy.Brain.cancel, role: .cancel) { }
        } message: {
            Text(verbatim: "削除すると自動保存されます。")
        }
    }

    private var headerRow: some View {
        GridRow {
            ForEach(0..<max(1, table.columnCount), id: \.self) { column in
                cell(row: -1, column: column)
                    .font(.body.weight(.semibold))
                    .contextMenu {
                        if table.columnCount > 1 {
                            Button(role: .destructive) {
                                changeStructure { $0.removeColumn(column) }
                            } label: { Text(verbatim: "この列を削除") }
                        }
                    }
            }
        }
        .background(LAAColor.subtleSurface)
    }

    private func bodyRow(_ row: Int) -> some View {
        GridRow {
            ForEach(0..<max(1, table.columnCount), id: \.self) { column in
                cell(row: row, column: column)
                    .contextMenu {
                        Button(role: .destructive) {
                            changeStructure { $0.removeRow(row) }
                        } label: { Text(verbatim: "この行を削除") }
                    }
            }
        }
    }

    private func cell(row: Int, column: Int) -> some View {
        // Single line: a table row cannot hold a newline, and a multi-line
        // field would let one be typed only to be rewritten on save.
        TextField("", text: binding(row: row, column: column))
            .textFieldStyle(.plain)
            .font(.body)
            .focused($focused, equals: Cell(row: row, column: column))
            .padding(.horizontal, LAASpacing.x2)
            .padding(.vertical, LAASpacing.x2)
            .frame(width: cellWidth, alignment: .leading)
            .frame(minHeight: LAASpacing.minimumTouchTarget, alignment: .leading)
            .background(LAAColor.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(LAAColor.separator).frame(height: 0.5) }
            .overlay(alignment: .trailing) { Rectangle().fill(LAAColor.separator).frame(width: 0.5) }
            .accessibilityLabel(Text(verbatim: row < 0 ? "見出し\(column + 1)" : "\(row + 1)行目\(column + 1)列目"))
            .accessibilityIdentifier("laa.markdown.table.cell.\(row).\(column)")
    }

    /// Reads and writes the live table, so consecutive edits never start from
    /// the snapshot the grid was drawn with.
    private func binding(row: Int, column: Int) -> Binding<String> {
        Binding(
            get: { model.table(segmentID)?.cell(row: row, column: column) ?? "" },
            set: { value in
                guard var latest = model.table(segmentID) else { return }
                latest.setCell(value, row: row, column: column)
                model.updateTable(segmentID, table: latest)
            }
        )
    }

    private func changeStructure(_ change: (inout LAAMarkdownTable) -> Void) {
        guard var copy = model.table(segmentID) else { return }
        change(&copy)
        model.updateTableStructure(segmentID, table: copy)
    }
}
#endif

#if LAA_BUILD
import SwiftUI

/// A file row in the desktop list: the name, then kind, updated and size on a
/// second line, because the shared list column is too narrow for four columns.
struct LAADriveDesktopRow: View {
    let entry: LAADriveListingItem
    let isSelected: Bool
    let select: () -> Void
    let saveFolder: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            stacked
            .padding(.horizontal, LAASpacing.x3)
            .padding(.vertical, LAASpacing.x2)
            .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
            .background(isSelected ? LAAColor.selectionFill : (hovering ? LAAColor.subtleSurface.opacity(0.7) : Color.clear),
                        in: RoundedRectangle(cornerRadius: LAASpacing.x2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(entry.item.name)
        .contextMenu {
            if entry.item.isFolder {
                Button(AppLocalization.string("Save folder offline"), systemImage: "arrow.down.circle") { saveFolder() }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: entry.item.name))
        .accessibilityValue(Text(verbatim: "\(kind) · \(dateText) · \(sizeText)"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("laa.drive.browser.item.\(entry.id)")
    }

    private var stacked: some View {
        HStack(spacing: LAASpacing.x3) {
            Image(systemName: entry.item.symbol).foregroundStyle(LAAColor.link).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: LAASpacing.x1) {
                Text(verbatim: entry.item.name).laaTextStyle(.body).foregroundStyle(LAAColor.text)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Text(verbatim: "\(kind) · \(dateText) · \(sizeText)").laaTextStyle(.secondary)
                    .foregroundStyle(LAAColor.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var kind: String {
        entry.item.kind == "shortcut" ? "ショートカット" : entry.item.kindTitle
    }

    private var dateText: String {
        guard let value = entry.item.modifiedAt, value.count >= 10 else { return "—" }
        return String(value.prefix(10))
    }

    private var sizeText: String {
        guard let size = entry.item.size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

#endif

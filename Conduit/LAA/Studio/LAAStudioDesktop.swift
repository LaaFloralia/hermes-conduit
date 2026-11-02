#if LAA_BUILD
import SwiftUI

/// What the Studio detail column is showing on the Mac.
enum LAAStudioDesktopSelection: Hashable {
    case work(String)
    case request(String)
}

/// A work or request row in the desktop list. Selection stays visible while
/// the detail column shows it.
struct LAAStudioDesktopRow: View {
    let title: String
    let detail: String
    var status: String? = nil
    var attention = false
    var thumbnail: String? = nil
    var symbol = "doc.richtext"
    let isSelected: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: LAASpacing.x3) {
                if thumbnail != nil || symbol == "doc.richtext" {
                    LAAStudioThumbnail(path: thumbnail, symbol: symbol)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: LAASpacing.x2))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: LAASpacing.x1) {
                    Text(verbatim: title).laaTextStyle(.body).fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(LAAColor.text).lineLimit(2).multilineTextAlignment(.leading)
                    Text(verbatim: detail).laaTextStyle(.secondary)
                        .foregroundStyle(attention ? LAAColor.attention : LAAColor.secondaryText).lineLimit(2)
                    if let status {
                        Text(verbatim: status).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, LAASpacing.x3)
            .padding(.vertical, LAASpacing.x2)
            .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
            .background(isSelected ? LAAColor.selectionFill : (hovering ? LAAColor.subtleSurface.opacity(0.7) : Color.clear),
                        in: RoundedRectangle(cornerRadius: LAASpacing.x2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Header of the Studio list column.
struct LAAStudioDesktopHeader: View {
    let canRefresh: Bool
    let isRefreshing: Bool
    let refresh: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x2) {
            Text(verbatim: LAACopy.tabTitle(.studio)).font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if canRefresh {
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                        .frame(minWidth: LAASpacing.minimumTouchTarget, minHeight: LAASpacing.minimumTouchTarget)
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
                .help("再読み込み (⌘R)")
                .accessibilityLabel(Text(verbatim: LAACopy.Studio.refresh))
                .accessibilityIdentifier("laa.studio.refresh")
            }
        }
    }
}

/// Wraps the section chips instead of clipping them when the list column is
/// narrower than the row.
struct LAAMacFlowLayout: Layout {
    var spacing: CGFloat = LAASpacing.x2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#endif

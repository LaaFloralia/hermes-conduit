#if LAA_BUILD
import SwiftUI

/// What the Studio detail column is showing on the Mac.
enum LAAStudioDesktopSelection: Hashable {
    case work(String)
    case request(String)
}

/// A work card for the wide detail column. The grid is adaptive, so the same
/// card is a single column in a narrow window and four in a wide one.
struct LAAStudioDesktopWorkCard: View {
    let project: LAAStudioProject
    let isSelected: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: LAASpacing.x2) {
                LAAStudioThumbnail(path: project.pages.first?.preview, symbol: "doc.richtext")
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: LAARadius.card))
                Text(verbatim: project.title).laaTextStyle(.body).fontWeight(.semibold)
                    .foregroundStyle(LAAColor.text).lineLimit(2).multilineTextAlignment(.leading)
                Text(verbatim: "\(project.kind) · \(LAAWorkPresentation.date(project.syncedAt))")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText).lineLimit(1)
            }
            .padding(LAASpacing.x3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
            .overlay {
                RoundedRectangle(cornerRadius: LAARadius.card)
                    .strokeBorder(isSelected ? LAAColor.link : (hovering ? LAAColor.separator : Color.clear), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(project.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("laa.studio.work.\(project.id)")
    }
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

/// Works gallery shown in the detail column before a work is chosen.
struct LAAStudioDesktopGallery: View {
    let projects: [LAAStudioProject]
    let selected: String?
    let open: (LAAStudioProject) -> Void

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: LAADesktopMetrics.gridItemMinWidth), spacing: LAASpacing.x4)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x4) {
                Text(verbatim: "作品 · \(projects.count)").laaTextStyle(.section).fontWeight(.semibold)
                    .foregroundStyle(LAAColor.secondaryText).accessibilityAddTraits(.isHeader)
                if projects.isEmpty {
                    Text(verbatim: LAACopy.Studio.emptyWorks)
                        .laaTextStyle(.body).foregroundStyle(LAAColor.secondaryText)
                } else {
                    LazyVGrid(columns: columns, spacing: LAASpacing.x4) {
                        ForEach(projects) { project in
                            LAAStudioDesktopWorkCard(project: project, isSelected: selected == project.id) {
                                open(project)
                            }
                        }
                    }
                }
            }
            .padding(LAASpacing.x6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(LAAColor.background)
        .accessibilityIdentifier("laa.studio.desktop.gallery")
    }
}
#endif

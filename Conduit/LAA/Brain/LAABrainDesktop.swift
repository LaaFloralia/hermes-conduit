#if LAA_BUILD
import SwiftUI

/// Desktop-only Brain navigation. The phone keeps NavigationLinks; on the Mac
/// the list selects the note that the detail column shows, so the list never
/// disappears behind a push.
struct LAABrainDesktopActions {
    /// The note currently shown in the detail column.
    let selectedPath: String
    /// The folder opened inside the list column.
    let folder: String
    let select: (LAABrainReference) -> Void
    let openFolder: (String) -> Void
}

private struct LAABrainDesktopActionsKey: EnvironmentKey {
    static let defaultValue: LAABrainDesktopActions? = nil
}

extension EnvironmentValues {
    var laaBrainDesktop: LAABrainDesktopActions? {
        get { self[LAABrainDesktopActionsKey.self] }
        set { self[LAABrainDesktopActionsKey.self] = newValue }
    }
}

/// Arrow keys move the selection, Return opens the selected row. The container
/// only handles keys while it holds focus, so typing in search stays untouched.
struct LAAMacKeyboardList<Content: View>: View {
    let count: Int
    let selectedIndex: Int?
    let move: (Int) -> Void
    let open: () -> Void
    @ViewBuilder var content: () -> Content
    @FocusState private var focused: Bool

    var body: some View {
        content()
            .focusable()
            .focused($focused)
            .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
            .onKeyPress(.downArrow) { moveSelection(1); return .handled }
            .onKeyPress(.return) { guard selectedIndex != nil else { return .ignored }; open(); return .handled }
    }

    private func moveSelection(_ delta: Int) {
        guard count > 0 else { return }
        if let selectedIndex {
            move(min(max(selectedIndex + delta, 0), count - 1))
        } else {
            move(delta > 0 ? 0 : count - 1)
        }
    }
}

/// A note row in the desktop list: always highlighted while selected and on
/// hover, with the path as its tooltip.
struct LAABrainDesktopNoteRow: View {
    let file: LAABrainFile
    let isSelected: Bool
    let showsPath: Bool
    let isPinned: Bool
    let open: () -> Void
    let togglePin: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: LAASpacing.x3) {
                Image(systemName: "doc.text")
                    .foregroundStyle(isSelected ? LAAColor.link : LAAColor.secondaryText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: LAASpacing.x1) {
                    Text(verbatim: file.title).laaTextStyle(.body).fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(LAAColor.text).lineLimit(2).multilineTextAlignment(.leading)
                    if showsPath {
                        Text(verbatim: file.path).laaTextStyle(.secondary)
                            .foregroundStyle(LAAColor.secondaryText).lineLimit(1).truncationMode(.head)
                    }
                    if file.conflictOriginalPath != nil {
                        Text(verbatim: "競合コピー").laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                    }
                    if file.unreadable != nil {
                        Text(verbatim: "本文を読み込めません").laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                    }
                }
                Spacer(minLength: 0)
                if isPinned {
                    Image(systemName: "pin.fill").font(.caption).foregroundStyle(LAAColor.secondaryText)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, LAASpacing.x3)
            .padding(.vertical, LAASpacing.x2)
            .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: LAASpacing.x2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(file.path)
        .contextMenu {
            Button(isPinned ? LAACopy.Brain.unpin : LAACopy.Brain.pin, systemImage: isPinned ? "pin.slash" : "pin") {
                togglePin()
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("laa.brain.note")
        .accessibilityHint(Text(verbatim: file.path))
    }

    private var background: Color {
        if isSelected { return LAAColor.selectionFill }
        return hovering ? LAAColor.subtleSurface.opacity(0.7) : .clear
    }
}

struct LAABrainDesktopFolderRow: View {
    let name: String
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: LAASpacing.x3) {
                Image(systemName: "folder").foregroundStyle(LAAColor.link)
                    .accessibilityHidden(true)
                Text(verbatim: name).laaTextStyle(.body).foregroundStyle(LAAColor.text)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(LAAColor.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, LAASpacing.x3)
            .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
            .background(hovering ? LAAColor.subtleSurface.opacity(0.7) : .clear,
                        in: RoundedRectangle(cornerRadius: LAASpacing.x2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(name)
    }
}

/// Header of the desktop list column: the screen name, then the actions that
/// phone keeps in the toolbar.
struct LAABrainDesktopHeader: View {
    let subtitle: String?
    let canCreate: Bool
    let canRefresh: Bool
    let isRefreshing: Bool
    let create: () -> Void
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x2) {
                Text(verbatim: LAACopy.Brain.title).font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
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
                    .accessibilityLabel(Text(verbatim: "再読み込み"))
                }
                if canCreate {
                    Button(action: create) {
                        Image(systemName: "square.and.pencil")
                            .frame(minWidth: LAASpacing.minimumTouchTarget, minHeight: LAASpacing.minimumTouchTarget)
                    }
                    .buttonStyle(.plain)
                    .help(LAACopy.Brain.newNote)
                    .accessibilityLabel(Text(verbatim: LAACopy.Brain.newNote))
                }
            }
            if let subtitle {
                Text(verbatim: subtitle).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
        }
    }
}

/// Breadcrumb for the folder opened inside the desktop list.
struct LAABrainDesktopBreadcrumb: View {
    let folder: String
    let open: (String) -> Void

    private var parts: [(String, String)] {
        var result: [(String, String)] = []
        var path = ""
        for name in folder.split(separator: "/").map(String.init) {
            path = path.isEmpty ? name : path + "/" + name
            result.append((name, path))
        }
        return result
    }

    var body: some View {
        HStack(spacing: LAASpacing.x1) {
            Button { open("") } label: {
                Text(verbatim: LAACopy.Brain.folders).laaTextStyle(.secondary)
                    .foregroundStyle(parts.isEmpty ? LAAColor.text : LAAColor.link)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("laa.brain.desktop.root")
            ForEach(parts, id: \.1) { name, path in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(LAAColor.secondaryText)
                    .accessibilityHidden(true)
                Button { open(path) } label: {
                    Text(verbatim: name).laaTextStyle(.secondary).lineLimit(1)
                        .foregroundStyle(path == folder ? LAAColor.text : LAAColor.link)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: LAASpacing.minimumTouchTarget)
    }
}

/// Brain's entries in the Mac menu bar. ⌘F, ⌘R and ⌘N live in the menu, which
/// reads the commands the shown section publishes: this view publishes them,
/// so the screen no longer registers the same keys behind invisible buttons.
struct LAABrainDesktopShortcuts: View {
    let search: () -> Void
    let reload: (() -> Void)?
    let create: (() -> Void)?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .laaMacSectionCommands(LAAMacSectionCommands(
                newTitle: LAACopy.Brain.newNote,
                canCreate: create != nil,
                create: { create?() },
                canSearch: true,
                focusSearch: search,
                canReload: reload != nil,
                reload: { reload?() }
            ))
            .accessibilityHidden(true)
    }
}
#endif

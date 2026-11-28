#if LAA_BUILD
import SwiftUI

/// Findings: newest first, one quiet line each. On the Mac the list keeps its
/// column and the chosen finding opens beside it; on the phone, in a sheet.
struct LAAFindingBoardView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.laaDesktop) private var laaDesktop
    @ObservedObject var board: LAAFindingBoard
    @State private var selected: LAAFinding?
    @State private var selectedID: String?
    @State private var delegated = 0
    @FocusState private var listFocused: Bool
    @State private var viewerOpen = false

    private var rowIDs: [String] { board.items.map(\.id) }
    private var selectedItem: LAAFinding? { selectedID.flatMap { id in board.items.first { $0.id == id } } }

    var body: some View {
        content
            .background(LAAColor.background)
            .tint(LAAColor.link)
            .refreshable { await board.load(bridge) }
            .onChange(of: rowIDs, initial: true) { _, ids in selectFirstIfNeeded(ids) }
            .sheet(item: $selected) { item in
                NavigationStack {
                    LAAFindingDetailView(item: board.items.first { $0.id == item.id } ?? item, board: board) {
                        selected = nil
                    }
                }
                .environmentObject(bridge)
                .laaSheetSize(.page)
            }
            .sensoryFeedback(.success, trigger: delegated)
            .accessibilityIdentifier("work.findings")
    }

    @ViewBuilder private var content: some View {
        switch board.phase {
        case .unsupported:
            message(title: LAAFindingCopy.unsupported, detail: LAAFindingCopy.unsupportedDetail,
                    identifier: "work.findings.unsupported")
        case .failed(let text) where board.items.isEmpty:
            message(title: LAAFindingCopy.loadFailed, detail: text, identifier: "work.findings.failure", retry: true)
        case .idle:
            LAALoadingDots().padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            if board.items.isEmpty && board.failure == nil && !board.loading {
                message(title: LAAFindingCopy.empty, identifier: "work.findings.empty")
            } else if laaDesktop {
                desktopBoard
            } else {
                phoneList
            }
        }
    }

    @ViewBuilder private var notice: some View {
        let text: String? = {
            if let failure = board.failure { return failure }
            if case .failed(let text) = board.phase { return text }
            return nil
        }()
        if let text {
            Text(verbatim: text).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("work.findings.notice")
        }
    }

    private var phoneList: some View {
        List {
            if board.failure != nil || board.phase != .loaded {
                Section { notice }
            }
            Section {
                ForEach(board.items) { item in
                    row(item).listRowBackground(LAAColor.surface)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var desktopBoard: some View {
        LAAMacListDetail {
            VStack(spacing: 0) {
                HStack(spacing: LAASpacing.x2) {
                    if board.loading && board.items.isEmpty { LAALoadingDots() }
                    Spacer(minLength: 0)
                    Button { Task { await board.load(bridge) } } label: { Image(systemName: "arrow.clockwise") }
                        .frame(width: LAASpacing.minimumTouchTarget, height: LAASpacing.minimumTouchTarget)
                        .accessibilityLabel(Text(verbatim: "再読み込み"))
                        .macTooltip("Reload")
                        .disabled(board.loading)
                        .accessibilityIdentifier("work.findings.reload")
                }
                .padding(.horizontal, LAASpacing.x3)
                .padding(.vertical, LAASpacing.x2)
                Rectangle().fill(LAAColor.separator).frame(height: 1)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        notice.padding(LAASpacing.x3)
                        ForEach(board.items) { item in
                            row(item, selected: selectedID == item.id)
                        }
                    }
                    .padding(.vertical, LAASpacing.x2)
                }
            }
            .background(LAAColor.background)
            .focusable()
            .focused($listFocused)
            .onAppear { listFocused = true }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.escape) { guard !viewerOpen else { return .ignored }; selectedID = nil; return .handled }
            .accessibilityIdentifier("work.findings.list")
        } detail: {
            if let item = selectedItem {
                LAAFindingDetailView(item: item, board: board) { }
                    .id(item.id + ":" + (item.status?.rawValue ?? "-"))
                    .environment(\.laaDecisionViewerOpen, $viewerOpen)
            } else {
                Text(verbatim: LAAFindingCopy.choose)
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityIdentifier("work.findings.desktop")
    }

    private func row(_ item: LAAFinding, selected: Bool = false) -> some View {
        LAAFindingRow(item: item, selected: selected, desktop: laaDesktop) { show(item) }
            .contextMenu {
                Button { show(item) } label: { Text(verbatim: "Open") }
                if item.isOpen {
                    Button { Task { if await board.delegate(item, bridge: bridge) { delegated += 1 } } } label: {
                        Text(verbatim: LAAFindingCopy.delegate)
                    }
                    Button { Task { await board.dismiss(item, bridge: bridge) } } label: {
                        Text(verbatim: LAAFindingCopy.dismiss)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: LAAFindingCopy.accessibilityLabel(item)))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("work.finding.\(item.id)")
            .padding(.horizontal, laaDesktop ? LAASpacing.x2 : 0)
    }

    private func message(title: String, detail: String? = nil, identifier: String, retry: Bool = false) -> some View {
        VStack(spacing: LAASpacing.x3) {
            Text(verbatim: title)
                .laaTextStyle(.body).foregroundStyle(LAAColor.secondaryText)
                .multilineTextAlignment(.center)
            if let detail {
                Text(verbatim: detail)
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    .multilineTextAlignment(.center)
            }
            if retry {
                Button { Task { await board.load(bridge) } } label: { Text(verbatim: "Retry") }
                    .laaGlassButton()
            }
        }
        .padding(LAASpacing.x8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(identifier)
    }

    private func show(_ item: LAAFinding) {
        if laaDesktop { selectedID = item.id } else { selected = item }
    }

    private func selectFirstIfNeeded(_ ids: [String]) {
        guard laaDesktop else { return }
        if let selectedID, ids.contains(selectedID) { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { selectedID = ids.first }
    }

    private func move(_ delta: Int) {
        let ids = rowIDs
        guard !ids.isEmpty else { return }
        guard let current = selectedID.flatMap(ids.firstIndex(of:)) else {
            selectedID = delta > 0 ? ids.first : ids.last
            return
        }
        selectedID = ids[min(max(current + delta, 0), ids.count - 1)]
    }
}

/// One finding row: the title, then one quiet line.
private struct LAAFindingRow: View {
    let item: LAAFinding
    let selected: Bool
    let desktop: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: LAASpacing.x1) {
                HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x2) {
                    Text(verbatim: item.title)
                        .laaTextStyle(.body).fontWeight(.semibold)
                        .foregroundStyle(selected ? LAAColor.link : LAAColor.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !item.images.isEmpty {
                        Image(systemName: "photo")
                            .laaTextStyle(.secondary)
                            .foregroundStyle(LAAColor.secondaryText)
                            .accessibilityHidden(true)
                    }
                }
                if let meta = LAAFindingCopy.meta(item) {
                    Text(verbatim: meta).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText).lineLimit(1)
                }
            }
            .padding(.horizontal, desktop ? LAASpacing.x3 : 0)
            .padding(.vertical, desktop ? LAASpacing.x3 : LAASpacing.x2)
            .frame(maxWidth: .infinity, minHeight: LAASpacing.minimumRowHeight, alignment: .leading)
            .contentShape(Rectangle())
            .background(background, in: RoundedRectangle(cornerRadius: LAASpacing.x2))
        }
        .buttonStyle(LAADecisionPressStyle())
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var background: Color {
        if selected { return LAAColor.selectionFill }
        return hovering && desktop ? LAAColor.subtleSurface.opacity(0.7) : .clear
    }
}
#endif

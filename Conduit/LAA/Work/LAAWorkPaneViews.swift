#if LAA_BUILD && targetEnvironment(macCatalyst)
import SwiftUI
import UniformTypeIdentifiers

/// Work › Sessions' detail on the Mac: one or more sessions side by side.
///
/// The panes are laid out from `LAAWorkPaneLayout.frames` and drawn flat, one
/// view per pane keyed by the pane's id. Splitting, closing or moving a pane
/// changes only frames, so the panes that stay keep their scroll position,
/// their half-typed follow-up and their live observation. A zoomed layout
/// draws its one pane: the others are not built at all, so a large layout
/// costs only what is on screen.
struct LAAWorkPaneArea: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    @Binding var layout: LAAWorkPaneLayout
    let sessions: [LAAWorkSession]
    let projects: [LAAWorkProject]
    let options: LAAWorkSessionOptions?
    @ObservedObject var drafts: ComposerDraftStore
    let canCreate: Bool
    let onNewSession: () -> Void

    @State private var size: CGSize = .zero
    @State private var hoveredDivider: String?
    @State private var draggingDivider: String?

    static let space = "laa.work.panes"
    static let gap: CGFloat = 1
    /// The smallest pane that still holds a readable transcript and its
    /// follow-up row, in UIKit points (≈ 260 × 200 Mac points).
    static let minimumWidth: CGFloat = 340
    static let minimumHeight: CGFloat = 260

    private var bounds: CGRect { CGRect(origin: .zero, size: size) }

    private var frames: [String: CGRect] {
        if let zoomed = layout.zoomedID { return [zoomed: bounds] }
        return LAAWorkPaneLayout.frames(layout.root, in: bounds, gap: Self.gap)
    }

    var body: some View {
        GeometryReader { proxy in
            let frames = self.frames
            ZStack(alignment: .topLeading) {
                LAAColor.separator
                ForEach(layout.panes.filter { frames[$0.id] != nil }) { pane in
                    let frame = frames[pane.id] ?? .zero
                    LAAWorkPaneView(
                        pane: pane,
                        size: frame.size,
                        number: layout.number(of: pane.id) ?? 1,
                        listed: pane.sessionID.flatMap { id in sessions.first { $0.id == id } },
                        projects: projects, options: options, drafts: drafts,
                        focused: pane.id == layout.focusedID,
                        many: layout.panes.count > 1,
                        zoomed: layout.zoomedID != nil,
                        canSplitRight: canSplit(pane.id, axis: .horizontal),
                        canSplitDown: canSplit(pane.id, axis: .vertical),
                        canCreate: canCreate,
                        onFocus: { if layout.focusedID != pane.id { layout.focus(pane.id) } },
                        onSplit: { edge in withAnimation(.snappy(duration: 0.22)) { _ = layout.split(pane.id, edge: edge) } },
                        onClose: { withAnimation(.snappy(duration: 0.22)) { layout.close(pane.id) } },
                        onZoom: { layout.focus(pane.id); withAnimation(.snappy(duration: 0.22)) { layout.toggleZoom() } },
                        onNewSession: { layout.focus(pane.id); onNewSession() },
                        onDrop: { payload, edge in drop(payload, on: pane.id, edge: edge) }
                    )
                    .frame(width: max(0, frame.width), height: max(0, frame.height))
                    .offset(x: frame.minX, y: frame.minY)
                }
                if layout.zoomedID == nil {
                    ForEach(LAAWorkPaneLayout.dividers(layout.root, in: bounds, gap: Self.gap), id: \.splitID) { divider in
                        dividerHandle(divider)
                    }
                }
            }
            .coordinateSpace(name: Self.space)
            .onAppear { size = proxy.size }
            .onChange(of: proxy.size) { _, value in size = value }
        }
        .background(LAAColor.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work.panes")
        .accessibilityValue(Text(verbatim: "\(layout.panes.count)"))
        .focusedSceneValue(\.laaWorkPaneCommands, commands)
    }

    // MARK: Dividers

    /// The hairline between two panes, with a wider strip to grab. It shows
    /// the link colour while the pointer is on it or it is being dragged;
    /// a double click gives both sides the same share again.
    private func dividerHandle(_ divider: LAAWorkPaneLayout.Divider) -> some View {
        let horizontal = divider.axis == .horizontal
        let grab: CGFloat = 10
        let active = hoveredDivider == divider.splitID || draggingDivider == divider.splitID
        let hit = horizontal
            ? CGRect(x: divider.rect.midX - grab / 2, y: divider.rect.minY, width: grab, height: divider.rect.height)
            : CGRect(x: divider.rect.minX, y: divider.rect.midY - grab / 2, width: divider.rect.width, height: grab)
        return ZStack {
            Rectangle()
                .fill(active ? LAAColor.link : Color.clear)
                .frame(width: horizontal ? 3 : nil, height: horizontal ? nil : 3)
                .animation(.easeOut(duration: 0.12), value: active)
        }
        .frame(width: hit.width, height: hit.height)
        .contentShape(Rectangle())
        .offset(x: hit.minX, y: hit.minY)
        .onHover { inside in
            if inside { hoveredDivider = divider.splitID } else if hoveredDivider == divider.splitID { hoveredDivider = nil }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                .onChanged { value in
                    draggingDivider = divider.splitID
                    let minimum = horizontal ? Self.minimumWidth : Self.minimumHeight
                    layout.setRatio(divider.splitID, LAAWorkPaneLayout.ratio(for: value.location, divider: divider,
                                                                             gap: Self.gap, minimum: minimum))
                }
                .onEnded { _ in draggingDivider = nil }
        )
        .onTapGesture(count: 2) { withAnimation(.snappy(duration: 0.22)) { layout.setRatio(divider.splitID, 0.5) } }
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: LAACopy.paneDivider))
        .accessibilityIdentifier("work.panes.divider.\(divider.splitID)")
        .help(LAACopy.paneDividerHelp)
    }

    // MARK: Operations

    private func canSplit(_ paneID: String, axis: LAAWorkPaneLayout.Axis) -> Bool {
        guard layout.canSplit else { return false }
        guard let frame = LAAWorkPaneLayout.frames(layout.root, in: bounds, gap: Self.gap)[paneID], size != .zero else { return true }
        return axis == .horizontal
            ? frame.width >= Self.minimumWidth * 2 + Self.gap
            : frame.height >= Self.minimumHeight * 2 + Self.gap
    }

    private func drop(_ payload: LAAWorkPaneDrag.Payload, on paneID: String, edge: LAAWorkPaneLayout.Edge?) {
        withAnimation(.snappy(duration: 0.22)) {
            switch (payload, edge) {
            case (.session(let id), nil):
                layout.place(id, in: paneID)
            case (.session(let id), let edge?):
                let axis: LAAWorkPaneLayout.Axis = edge == .leading || edge == .trailing ? .horizontal : .vertical
                if canSplit(paneID, axis: axis) { layout.split(paneID, edge: edge, sessionID: id) } else { layout.place(id, in: paneID) }
            case (.pane(let source), nil):
                layout.swap(source, paneID)
            case (.pane(let source), let edge?):
                layout.move(source, to: paneID, edge: edge)
            }
        }
    }

    private var commands: LAAWorkPaneCommands {
        let focused = layout.focusedID
        return LAAWorkPaneCommands(
            canSplitRight: canSplit(focused, axis: .horizontal),
            canSplitDown: canSplit(focused, axis: .vertical),
            canClose: layout.panes.count > 1 || layout.focused?.sessionID != nil,
            many: layout.panes.count > 1,
            zoomed: layout.zoomedID != nil,
            split: { edge in withAnimation(.snappy(duration: 0.22)) { _ = layout.split(edge: edge) } },
            close: { withAnimation(.snappy(duration: 0.22)) { layout.close() } },
            next: { layout.focusNext(1) },
            previous: { layout.focusNext(-1) },
            focus: { direction in
                layout.focus(direction, frames: LAAWorkPaneLayout.frames(layout.root, in: bounds, gap: Self.gap))
            },
            toggleZoom: { withAnimation(.snappy(duration: 0.22)) { layout.toggleZoom() } },
            equalize: { withAnimation(.snappy(duration: 0.22)) { layout.equalize() } }
        )
    }
}

/// One pane: an Orca-style heading — who is working, on which model, in what
/// state — over the session itself, which keeps its own scroll, follow-up
/// field and model controls.
private struct LAAWorkPaneView: View {
    let pane: LAAWorkPaneLayout.Pane
    /// The frame the area gave this pane, which a drop's location is
    /// measured against.
    let size: CGSize
    let number: Int
    /// The list's copy, until the pane's own observation reports.
    let listed: LAAWorkSession?
    let projects: [LAAWorkProject]
    let options: LAAWorkSessionOptions?
    @ObservedObject var drafts: ComposerDraftStore
    let focused: Bool
    let many: Bool
    let zoomed: Bool
    let canSplitRight: Bool
    let canSplitDown: Bool
    let canCreate: Bool
    let onFocus: () -> Void
    let onSplit: (LAAWorkPaneLayout.Edge) -> Void
    let onClose: () -> Void
    let onZoom: () -> Void
    let onNewSession: () -> Void
    let onDrop: (LAAWorkPaneDrag.Payload, LAAWorkPaneLayout.Edge?) -> Void

    @State private var live: LAAWorkSession?
    @State private var dropTarget: LAAWorkPaneDropTarget?

    private var session: LAAWorkSession? {
        guard let id = pane.sessionID else { return nil }
        if let live, live.id == id { return live }
        return listed
    }

    var body: some View {
        VStack(spacing: 0) {
            LAAWorkPaneHeader(
                session: session, sessionID: pane.sessionID, number: number, options: options,
                focused: focused, many: many, zoomed: zoomed,
                canSplitRight: canSplitRight, canSplitDown: canSplitDown,
                onSplit: onSplit, onClose: onClose, onZoom: onZoom
            )
            .onDrag { LAAWorkPaneDrag.provider(.pane(pane.id)) } preview: {
                LAAWorkPaneDragPreview(title: session?.name ?? LAACopy.paneEmptyTitle, model: session?.observed ?? session?.requested)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    // Ghostty dims the splits that don't have the keyboard;
                    // a light veil here, so the focused pane reads first
                    // without the others becoming hard to read.
                    if many && !focused {
                        LAAColor.background.opacity(0.22).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
        }
        .background(LAAColor.surface)
        .overlay { dropOverlay }
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { onFocus() })
        .onDrop(of: [LAAWorkPaneDrag.type], delegate: LAAWorkPaneDropDelegate(
            paneID: pane.id, size: size, canSplitRight: canSplitRight, canSplitDown: canSplitDown,
            target: $dropTarget, perform: onDrop))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work.pane.\(number)")
        .accessibilityValue(Text(verbatim: focused ? LAACopy.paneFocusedValue : ""))
        .accessibilityAddTraits(focused ? .isSelected : [])
        .onChange(of: pane.sessionID) { _, _ in live = nil }
    }

    @ViewBuilder private var content: some View {
        if let id = pane.sessionID {
            NavigationStack {
                LAAWorkSessionDetail(id: id, projects: projects, workspaces: [], drafts: drafts) { live = $0 }
                    // The pane's heading names the session; the bar would
                    // repeat it in every pane.
                    .toolbar(.hidden, for: .navigationBar)
            }
            .id(id)
        } else {
            VStack(spacing: LAASpacing.x3) {
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(LAAColor.secondaryText)
                    .accessibilityHidden(true)
                Text(verbatim: LAACopy.paneEmptyTitle)
                    .font(LAAType.employeeName)
                    .foregroundStyle(LAAColor.text)
                Text(verbatim: LAACopy.paneEmptyMessage)
                    .laaTextStyle(.secondary)
                    .foregroundStyle(LAAColor.secondaryText)
                    .multilineTextAlignment(.center)
                if canCreate {
                    Button(action: onNewSession) {
                        Label { Text(verbatim: LAACopy.paneNewSession) } icon: { Image(systemName: "plus") }
                            .laaTextStyle(.secondary).fontWeight(.semibold)
                    }
                    .laaGlassButton()
                    .padding(.top, LAASpacing.x2)
                    .accessibilityIdentifier("work.pane.\(number).new")
                }
            }
            .padding(LAASpacing.x6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LAAColor.background)
            .accessibilityIdentifier("work.pane.\(number).empty")
        }
    }

    /// Where a drop will land: the half of the pane it splits off, or the
    /// whole pane when it replaces (or trades places with) what is shown.
    @ViewBuilder private var dropOverlay: some View {
        if let dropTarget {
            GeometryReader { proxy in
                let rect = dropTarget.rect(in: proxy.size)
                RoundedRectangle(cornerRadius: LAARadius.card, style: .continuous)
                    .fill(LAAColor.link.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: LAARadius.card, style: .continuous)
                        .stroke(LAAColor.link, lineWidth: 2))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .animation(.easeOut(duration: 0.12), value: dropTarget)
            }
            .padding(LAASpacing.x2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// The pane's heading. The focused pane carries the link colour on its top
/// edge and the selection tint, as the sidebar marks its selected row.
private struct LAAWorkPaneHeader: View {
    let session: LAAWorkSession?
    let sessionID: String?
    let number: Int
    let options: LAAWorkSessionOptions?
    let focused: Bool
    let many: Bool
    let zoomed: Bool
    let canSplitRight: Bool
    let canSplitDown: Bool
    let onSplit: (LAAWorkPaneLayout.Edge) -> Void
    let onClose: () -> Void
    let onZoom: () -> Void

    var body: some View {
        HStack(spacing: LAASpacing.x2) {
            identity
                .frame(maxWidth: .infinity, alignment: .leading)
            if canSplitRight || canSplitDown || many || sessionID != nil { controls }
        }
        .padding(.leading, LAASpacing.x3)
        .padding(.trailing, LAASpacing.x2)
        .frame(minHeight: LAASpacing.minimumTouchTarget + 8)
        .background(focused && many ? LAAColor.selectionFill : LAAColor.background)
        .overlay(alignment: .top) {
            if focused && many { Rectangle().fill(LAAColor.link).frame(height: 2).accessibilityHidden(true) }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(LAAColor.separator).frame(height: 1).accessibilityHidden(true) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work.pane.\(number).header")
    }

    private var model: LAAWorkModel? { session?.observed ?? session?.requested }

    @ViewBuilder private var identity: some View {
        HStack(spacing: LAASpacing.x2) {
            if many { LAAWorkPaneBadge(value: .init(number: number, focused: focused)) }
            if let session {
                LAAModelMark(model: model?.model, provider: model?.provider, size: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: LAASpacing.x1) {
                        Text(verbatim: session.name)
                            .laaTextStyle(.body).fontWeight(.semibold)
                            .foregroundStyle(LAAColor.text)
                            .lineLimit(1).truncationMode(.tail)
                            .accessibilityIdentifier("work.pane.\(number).title")
                        LAAWorkRefLabel(ref: session.ref)
                    }
                    HStack(spacing: 0) {
                        Text(verbatim: LAAWorkPresentation.phaseSymbol(session.needsDecision ? "awaiting_decision" : session.phase))
                            .foregroundStyle(LAAWorkSessionStyle.statusColor(session.needsDecision ? "awaiting_decision" : session.phase))
                        Text(verbatim: " " + status(session))
                            .foregroundStyle(LAAColor.secondaryText)
                    }
                    .laaTextStyle(.note)
                    .lineLimit(1).truncationMode(.tail)
                    .accessibilityIdentifier("work.pane.\(number).status")
                }
            } else if sessionID != nil {
                LAALoadingDots()
            } else {
                Text(verbatim: LAACopy.paneEmptyHeading)
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
        .help(session?.name ?? LAACopy.paneEmptyHeading)
    }

    /// Phase first, then the model the pane is on: the two things the owner
    /// scans across panes.
    private func status(_ session: LAAWorkSession) -> String {
        let phase = LAAWorkPresentation.phase(session.needsDecision ? "awaiting_decision" : session.phase)
        return [phase, LAAWorkSessionStyle.model(session, options: options)].compactMap { $0 }.joined(separator: " · ")
    }

    private var controls: some View {
        HStack(spacing: 0) {
            // A split that wouldn't fit isn't offered: a narrow pane keeps
            // its heading for the name rather than for greyed buttons.
            if canSplitRight {
                control("rectangle.split.2x1", LAACopy.paneSplitRight, shortcut: "⌘D", id: "splitRight") { onSplit(.trailing) }
            }
            if canSplitDown {
                control("rectangle.split.1x2", LAACopy.paneSplitDown, shortcut: "⇧⌘D", id: "splitDown") { onSplit(.bottom) }
            }
            if many {
                control(zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                        zoomed ? LAACopy.paneUnzoom : LAACopy.paneZoom, shortcut: "⇧⌘↩", id: "zoom", action: onZoom)
            }
            if many || sessionID != nil {
                control("xmark", many ? LAACopy.paneClose : LAACopy.paneClear, shortcut: "⇧⌘W", id: "close", action: onClose)
            }
        }
        .padding(.horizontal, 2)
        .laaGlass(in: Capsule())
    }

    private func control(_ symbol: String, _ title: String, shortcut: String, id: String,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(LAAColor.text)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityIdentifier("work.pane.\(number).\(id)")
        .help("\(title) (\(shortcut))")
    }
}

/// What dragging a pane's heading or a list row shows under the pointer.
struct LAAWorkPaneDragPreview: View {
    let title: String
    let model: LAAWorkModel?

    var body: some View {
        HStack(spacing: LAASpacing.x2) {
            LAAModelMark(model: model?.model, provider: model?.provider, size: 20)
            Text(verbatim: title).laaTextStyle(.secondary).fontWeight(.semibold)
                .foregroundStyle(LAAColor.text).lineLimit(1)
        }
        .padding(.horizontal, LAASpacing.x3)
        .padding(.vertical, LAASpacing.x2)
        .background(LAAColor.surface, in: Capsule())
        .overlay(Capsule().stroke(LAAColor.separator))
    }
}

// MARK: - Drag and drop

/// Drags inside the window carry an id of this app's own type, which only
/// this process reads: a text field never takes one as typed text.
enum LAAWorkPaneDrag {
    enum Payload: Equatable {
        case session(String)
        case pane(String)
    }

    static let type = UTType(exportedAs: "com.laa-inc.laa.work-pane")

    /// What is being dragged now. The provider only announces the type; the
    /// payload stays in memory, so a drop never waits on a load.
    @MainActor static var current: Payload?

    @MainActor static func provider(_ payload: Payload) -> NSItemProvider {
        current = payload
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { done in
            done(Data(), nil)
            return nil
        }
        return provider
    }
}

/// The part of a pane a drop is over: its centre or one of its edges.
enum LAAWorkPaneDropTarget: Equatable {
    case center
    case edge(LAAWorkPaneLayout.Edge)

    var edge: LAAWorkPaneLayout.Edge? {
        if case .edge(let edge) = self { return edge }
        return nil
    }

    func rect(in size: CGSize) -> CGRect {
        switch self {
        case .center: return CGRect(origin: .zero, size: size)
        case .edge(.leading): return CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .edge(.trailing): return CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .edge(.top): return CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .edge(.bottom): return CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        }
    }
}

private struct LAAWorkPaneDropDelegate: DropDelegate {
    let paneID: String
    let size: CGSize
    let canSplitRight: Bool
    let canSplitDown: Bool
    @Binding var target: LAAWorkPaneDropTarget?
    let perform: (LAAWorkPaneDrag.Payload, LAAWorkPaneLayout.Edge?) -> Void

    @MainActor private var payload: LAAWorkPaneDrag.Payload? {
        // A pane dropped on itself has nowhere to go.
        guard let current = LAAWorkPaneDrag.current, current != .pane(paneID) else { return nil }
        return current
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [LAAWorkPaneDrag.type])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated {
            guard payload != nil else { target = nil; return DropProposal(operation: .forbidden) }
            let region = region(info.location)
            if target != region { target = region }
            return DropProposal(operation: .move)
        }
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated { target = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            defer { target = nil; LAAWorkPaneDrag.current = nil }
            guard let payload else { return false }
            perform(payload, region(info.location).edge)
            return true
        }
    }

    /// An edge only where the pane has room to split that way; otherwise the
    /// drop replaces, and the highlight says so before the button is let go.
    private func region(_ location: CGPoint) -> LAAWorkPaneDropTarget {
        guard let edge = LAAWorkPaneLayout.dropEdge(at: location, in: size) else { return .center }
        let fits = edge == .leading || edge == .trailing ? canSplitRight : canSplitDown
        return fits ? .edge(edge) : .center
    }
}

#if DEBUG
/// `-laa-work-panes ses_a,ses_b:v,ses_c` opens those sessions in panes, each
/// split to the right of the previous one, or under it with `:v`; `-` is an
/// empty pane. `-laa-work-pane-focus 2` focuses the second and
/// `-laa-work-pane-zoom` zooms it. For `scripts/laa/mac-screens.sh`, which
/// photographs the window without driving the mouse. A release build has no
/// such arguments.
enum LAAWorkPanePreset {
    static var launched: LAAWorkPaneLayout? {
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let raw = value("-laa-work-panes") else { return nil }
        var layout = LAAWorkPaneLayout()
        for (index, item) in raw.split(separator: ",").enumerated() {
            let parts = item.split(separator: ":")
            let id = parts.first.map(String.init).flatMap { $0 == "-" ? nil : $0 }
            if index == 0 {
                if let id { layout.open(id) }
            } else {
                layout.split(edge: parts.dropFirst().first == "v" ? .bottom : .trailing, sessionID: id)
            }
        }
        if let focus = value("-laa-work-pane-focus").flatMap(Int.init), layout.panes.indices.contains(focus - 1) {
            layout.focus(layout.panes[focus - 1].id)
        }
        if arguments.contains("-laa-work-pane-zoom") { layout.toggleZoom() }
        return layout
    }
}
#endif

// MARK: - Menu commands

/// What the Pane menu can do in the pane area the window shows.
struct LAAWorkPaneCommands {
    var canSplitRight: Bool
    var canSplitDown: Bool
    var canClose: Bool
    var many: Bool
    var zoomed: Bool
    var split: (LAAWorkPaneLayout.Edge) -> Void
    var close: () -> Void
    var next: () -> Void
    var previous: () -> Void
    var focus: (LAAWorkPaneLayout.Direction) -> Void
    var toggleZoom: () -> Void
    var equalize: () -> Void
}

private struct LAAWorkPaneCommandsKey: FocusedValueKey {
    typealias Value = LAAWorkPaneCommands
}

extension FocusedValues {
    var laaWorkPaneCommands: LAAWorkPaneCommands? {
        get { self[LAAWorkPaneCommandsKey.self] }
        set { self[LAAWorkPaneCommandsKey.self] = newValue }
    }
}

/// The Pane menu: Ghostty's split keys, in a menu of their own so each one is
/// written once and shows its shortcut.
struct LAAWorkPaneMenu: Commands {
    @FocusedValue(\.laaWorkPaneCommands) private var panes

    var body: some Commands {
        CommandMenu(LAACopy.paneMenu) {
            Button(LAACopy.paneSplitRight) { panes?.split(.trailing) }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(panes?.canSplitRight != true)
            Button(LAACopy.paneSplitDown) { panes?.split(.bottom) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(panes?.canSplitDown != true)
            Divider()
            Button(LAACopy.paneNext) { panes?.next() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(panes?.many != true)
            Button(LAACopy.panePrevious) { panes?.previous() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(panes?.many != true)
            Button(LAACopy.paneFocusLeft) { panes?.focus(.left) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(panes?.many != true)
            Button(LAACopy.paneFocusRight) { panes?.focus(.right) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(panes?.many != true)
            Button(LAACopy.paneFocusUp) { panes?.focus(.up) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(panes?.many != true)
            Button(LAACopy.paneFocusDown) { panes?.focus(.down) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(panes?.many != true)
            Divider()
            Button(panes?.zoomed == true ? LAACopy.paneUnzoom : LAACopy.paneZoom) { panes?.toggleZoom() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(panes?.many != true)
            Button(LAACopy.paneEqualize) { panes?.equalize() }
                .keyboardShortcut("=", modifiers: [.command, .control])
                .disabled(panes?.many != true || panes?.zoomed == true)
            Divider()
            Button(panes?.many == false ? LAACopy.paneClear : LAACopy.paneClose) { panes?.close() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(panes?.canClose != true)
        }
    }
}

extension LAACopy {
    static let paneMenu = "ペイン"
    static let paneSplitRight = "右に分割"
    static let paneSplitDown = "下に分割"
    static let paneNext = "次のペイン"
    static let panePrevious = "前のペイン"
    static let paneFocusLeft = "左のペインへ"
    static let paneFocusRight = "右のペインへ"
    static let paneFocusUp = "上のペインへ"
    static let paneFocusDown = "下のペインへ"
    static let paneZoom = "ペインを拡大"
    static let paneUnzoom = "拡大を戻す"
    static let paneEqualize = "ペインの大きさを揃える"
    static let paneClose = "ペインを閉じる"
    static let paneClear = "セッションを閉じる"
    static let paneDivider = "ペインの境界"
    static let paneDividerHelp = "ドラッグで大きさを変更・ダブルクリックで等分"
    static let paneEmptyTitle = "セッションを選んでください。"
    static let paneEmptyMessage = "左の一覧から選ぶか、ここへドラッグします。"
    static let paneEmptyHeading = "空のペイン"
    static let paneNewSession = "新しいセッション"
    static let paneFocusedValue = "選択中"
    static let paneOpenRight = "右に分割して開く"
    static let paneOpenBelow = "下に分割して開く"
}
#endif

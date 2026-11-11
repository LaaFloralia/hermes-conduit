#if LAA_BUILD
import CoreGraphics
import Foundation

/// Work › Sessions on the Mac shows one or more sessions side by side, the way
/// a terminal splits its window (Ghostty) and a coding-agent desktop keeps one
/// agent per pane (Orca). The layout is a binary tree: every split holds two
/// children along one axis and the share the first one takes; every leaf is a
/// pane that shows at most one session.
///
/// The tree is plain data so it can be saved per window and tested without a
/// view. The view draws it and turns gestures and menu commands into the
/// operations below; nothing here knows about SwiftUI.
struct LAAWorkPaneLayout: Codable, Equatable {
    /// `horizontal` puts the children side by side (a vertical divider),
    /// `vertical` stacks them (a horizontal divider).
    enum Axis: String, Codable { case horizontal, vertical }

    /// Where something dropped on a pane lands: one of its four edges splits
    /// the pane there, the centre takes its place.
    enum Edge: String, Codable, CaseIterable { case leading, trailing, top, bottom }

    enum Direction: String, CaseIterable { case left, right, up, down }

    struct Pane: Codable, Equatable, Identifiable {
        var id: String
        var sessionID: String?
    }

    struct Split: Codable, Equatable {
        var id: String
        var axis: Axis
        /// The first child's share of the split, kept inside `ratioRange`.
        var ratio: Double
        var first: Node
        var second: Node
    }

    indirect enum Node: Codable, Equatable {
        case pane(Pane)
        case split(Split)
    }

    /// More panes than this leaves each one too small to read a transcript in
    /// on a laptop display, and each pane keeps its own live observation.
    static let maximumPanes = 6
    static let ratioRange: ClosedRange<Double> = 0.15...0.85

    var root: Node
    var focusedID: String
    /// The pane drawn alone across the whole area (Ghostty's split zoom). The
    /// others stay in the tree, but are not drawn, so their observations stop.
    var zoomedID: String?
    /// The next generated id. Persisted with the tree so ids stay unique
    /// after a relaunch.
    var serial: Int

    init() {
        root = .pane(Pane(id: "p1", sessionID: nil))
        focusedID = "p1"
        zoomedID = nil
        serial = 1
    }

    // MARK: Reading

    /// Every pane in reading order: left to right, top to bottom.
    var panes: [Pane] { Self.leaves(root) }

    var focused: Pane? { panes.first { $0.id == focusedID } }

    var canSplit: Bool { panes.count < Self.maximumPanes }

    func pane(showing sessionID: String) -> Pane? { panes.first { $0.sessionID == sessionID } }

    /// The 1-based position the sidebar names a pane by.
    func number(of paneID: String) -> Int? { panes.firstIndex { $0.id == paneID }.map { $0 + 1 } }

    // MARK: Opening sessions

    /// Shows `sessionID` in `paneID` (the focused pane by default) and focuses
    /// it. A session already on screen is not opened twice — two copies would
    /// observe the same session twice — so its pane takes the focus instead.
    mutating func open(_ sessionID: String, in paneID: String? = nil) {
        if let shown = pane(showing: sessionID) {
            focus(shown.id)
            return
        }
        let target = paneID ?? focusedID
        update(target) { $0.sessionID = sessionID }
        focus(target)
    }

    /// Splits `paneID` along `edge` with a new pane for `sessionID` (or an
    /// empty one) and focuses the new pane. Returns its id, or nil when the
    /// area already holds `maximumPanes`.
    @discardableResult
    mutating func split(_ paneID: String? = nil, edge: Edge = .trailing, sessionID: String? = nil) -> String? {
        let target = paneID ?? focusedID
        guard canSplit, Self.contains(root, paneID: target) else { return nil }
        // The session moves rather than appearing twice.
        if let sessionID, let shown = pane(showing: sessionID) {
            update(shown.id) { $0.sessionID = nil }
        }
        let pane = Pane(id: nextID("p"), sessionID: sessionID)
        insert(pane, beside: target, edge: edge)
        zoomedID = nil
        focusedID = pane.id
        return pane.id
    }

    /// Puts `sessionID` in `paneID`, as dropping a session on a pane's centre
    /// does. If another pane already shows it, the two panes trade what they
    /// show, so nothing appears twice and nothing is lost.
    mutating func place(_ sessionID: String, in paneID: String) {
        if let shown = pane(showing: sessionID) {
            swap(shown.id, paneID)
            return
        }
        update(paneID) { $0.sessionID = sessionID }
        focus(paneID)
    }

    /// Empties a pane (the focused one by default) without removing it.
    mutating func clear(_ paneID: String? = nil) {
        update(paneID ?? focusedID) { $0.sessionID = nil }
    }

    /// Removes a pane; its sibling takes the space. The last pane stays and
    /// is emptied instead, so the area never has nothing to click into.
    mutating func close(_ paneID: String? = nil) {
        let target = paneID ?? focusedID
        guard panes.count > 1 else {
            update(target) { $0.sessionID = nil }
            zoomedID = nil
            return
        }
        let order = panes.map(\.id)
        guard let index = order.firstIndex(of: target), let next = Self.removing(target, from: root) else { return }
        root = next
        if zoomedID == target { zoomedID = nil }
        if focusedID == target || !order.contains(focusedID) {
            // The pane that took the closed one's place: the one before it in
            // reading order, or the first.
            let remaining = panes.map(\.id)
            focusedID = remaining[max(0, min(index - 1, remaining.count - 1))]
        }
    }

    /// Exchanges what two panes show; the panes themselves stay where they
    /// are, so the arrangement the owner set up is kept.
    mutating func swap(_ a: String, _ b: String) {
        guard a != b, let first = panes.first(where: { $0.id == a }), let second = panes.first(where: { $0.id == b }) else { return }
        update(a) { $0.sessionID = second.sessionID }
        update(b) { $0.sessionID = first.sessionID }
        focus(b)
    }

    /// Takes a pane out of the tree and puts it at `edge` of `target`, the
    /// way dragging a pane's heading onto another pane's edge moves it.
    mutating func move(_ paneID: String, to target: String, edge: Edge) {
        guard paneID != target, panes.count > 1,
              let moving = panes.first(where: { $0.id == paneID }),
              Self.contains(root, paneID: target),
              let next = Self.removing(paneID, from: root) else { return }
        root = next
        insert(moving, beside: target, edge: edge)
        zoomedID = nil
        focusedID = paneID
    }

    /// Clears the panes that show a session no longer in `known`. Only called
    /// with a complete, successful read of the list.
    mutating func forget(sessionsNotIn known: Set<String>) {
        for pane in panes where pane.sessionID.map({ !known.contains($0) }) == true {
            update(pane.id) { $0.sessionID = nil }
        }
    }

    // MARK: Focus and size

    mutating func focus(_ paneID: String) {
        guard Self.contains(root, paneID: paneID) else { return }
        focusedID = paneID
        if zoomedID != nil { zoomedID = paneID }
    }

    /// ⌘] and ⌘[: the next or previous pane in reading order, wrapping.
    mutating func focusNext(_ delta: Int) {
        let order = panes.map(\.id)
        guard let index = order.firstIndex(of: focusedID), !order.isEmpty else { return }
        let next = ((index + delta) % order.count + order.count) % order.count
        focus(order[next])
    }

    /// ⌥⌘ and an arrow: the nearest pane on that side of the focused one, by
    /// the frames the view last laid out.
    mutating func focus(_ direction: Direction, frames: [String: CGRect]) {
        if let next = Self.neighbor(of: focusedID, direction: direction, frames: frames) { focus(next) }
    }

    mutating func toggleZoom() {
        guard panes.count > 1 else { zoomedID = nil; return }
        zoomedID = zoomedID == nil ? focusedID : nil
    }

    mutating func setRatio(_ splitID: String, _ ratio: Double) {
        root = Self.mapSplits(root) { split in
            guard split.id == splitID else { return split }
            var changed = split
            changed.ratio = Self.clamp(ratio)
            return changed
        }
    }

    /// ⌃⌘=: every pane the same size along its axis. A split's share follows
    /// how many panes each side holds in that direction, so three columns
    /// made by two splits come out as thirds, not a half and two quarters.
    mutating func equalize() {
        root = Self.equalized(root)
    }

    // MARK: Persistence

    /// The saved form for `@SceneStorage`. A tree that can't be read back —
    /// an older shape, a damaged value — starts over with one empty pane.
    var encoded: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    static func decoded(_ raw: String) -> LAAWorkPaneLayout {
        guard let data = raw.data(using: .utf8),
              var layout = try? JSONDecoder().decode(LAAWorkPaneLayout.self, from: data),
              !layout.panes.isEmpty else { return LAAWorkPaneLayout() }
        if !contains(layout.root, paneID: layout.focusedID) { layout.focusedID = layout.panes[0].id }
        if let zoomed = layout.zoomedID, !contains(layout.root, paneID: zoomed) { layout.zoomedID = nil }
        return layout
    }

    // MARK: Geometry

    /// Each pane's frame in a `size` area: the frames the view draws, and the
    /// ones keyboard focus moves between. `gap` is the divider's thickness.
    static func frames(_ node: Node, in rect: CGRect, gap: CGFloat = 1) -> [String: CGRect] {
        switch node {
        case .pane(let pane):
            return [pane.id: rect]
        case .split(let split):
            let (first, second) = divide(rect, split: split, gap: gap)
            return frames(split.first, in: first, gap: gap).merging(frames(split.second, in: second, gap: gap)) { a, _ in a }
        }
    }

    struct Divider: Equatable {
        let splitID: String
        let axis: Axis
        /// The gap between the two children.
        let rect: CGRect
        /// The whole split, which a drag measures its new share against.
        let parent: CGRect
    }

    /// Every split's divider, for drawing and dragging.
    static func dividers(_ node: Node, in rect: CGRect, gap: CGFloat = 1) -> [Divider] {
        guard case .split(let split) = node else { return [] }
        let (first, second) = divide(rect, split: split, gap: gap)
        let line = split.axis == .horizontal
            ? CGRect(x: first.maxX, y: rect.minY, width: gap, height: rect.height)
            : CGRect(x: rect.minX, y: first.maxY, width: rect.width, height: gap)
        return [Divider(splitID: split.id, axis: split.axis, rect: line, parent: rect)]
            + dividers(split.first, in: first, gap: gap) + dividers(split.second, in: second, gap: gap)
    }

    /// The share a divider dragged to `location` gives its first child,
    /// keeping both children at least `minimum` points along the axis.
    static func ratio(for location: CGPoint, divider: Divider, gap: CGFloat = 1, minimum: CGFloat) -> Double {
        let length = (divider.axis == .horizontal ? divider.parent.width : divider.parent.height) - gap
        guard length > 0 else { return 0.5 }
        let offset = divider.axis == .horizontal ? location.x - divider.parent.minX : location.y - divider.parent.minY
        let lower = min(0.5, Double(minimum / length)), upper = max(0.5, 1 - Double(minimum / length))
        return clamp(min(max(Double(offset / length), lower), upper))
    }

    /// The two children's rectangles for one split.
    static func divide(_ rect: CGRect, split: Split, gap: CGFloat) -> (CGRect, CGRect) {
        let ratio = CGFloat(clamp(split.ratio))
        switch split.axis {
        case .horizontal:
            let width = max(0, rect.width - gap)
            let firstWidth = (width * ratio).rounded()
            return (CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height),
                    CGRect(x: rect.minX + firstWidth + gap, y: rect.minY, width: width - firstWidth, height: rect.height))
        case .vertical:
            let height = max(0, rect.height - gap)
            let firstHeight = (height * ratio).rounded()
            return (CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstHeight),
                    CGRect(x: rect.minX, y: rect.minY + firstHeight + gap, width: rect.width, height: height - firstHeight))
        }
    }

    /// Where a drop at `point` inside a `size` pane lands: the edge it is
    /// nearest when within a quarter of the pane from it, otherwise the centre
    /// (nil).
    static func dropEdge(at point: CGPoint, in size: CGSize) -> Edge? {
        guard size.width > 0, size.height > 0 else { return nil }
        let x = point.x / size.width, y = point.y / size.height
        let distances: [(Edge, CGFloat)] = [(.leading, x), (.trailing, 1 - x), (.top, y), (.bottom, 1 - y)]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 < 0.25 else { return nil }
        return nearest.0
    }

    /// The pane beside `id` in `direction`: among the panes wholly on that
    /// side and overlapping it across the other axis, the closest; ties go to
    /// the one most in line with the focused pane's centre.
    static func neighbor(of id: String, direction: Direction, frames: [String: CGRect]) -> String? {
        guard let origin = frames[id] else { return nil }
        let tolerance: CGFloat = 2
        var best: (id: String, distance: CGFloat, offset: CGFloat, frame: CGRect)?
        // Sorted, so equal candidates resolve the same way every time: the
        // upper, then the leftmost one.
        let candidates = frames.sorted { ($0.value.minY, $0.value.minX) < ($1.value.minY, $1.value.minX) }
        for (candidate, frame) in candidates where candidate != id {
            let distance: CGFloat
            let overlaps: Bool
            let offset: CGFloat
            switch direction {
            case .left:
                distance = origin.minX - frame.maxX
                overlaps = frame.maxY > origin.minY + tolerance && frame.minY < origin.maxY - tolerance
                offset = abs(frame.midY - origin.midY)
            case .right:
                distance = frame.minX - origin.maxX
                overlaps = frame.maxY > origin.minY + tolerance && frame.minY < origin.maxY - tolerance
                offset = abs(frame.midY - origin.midY)
            case .up:
                distance = origin.minY - frame.maxY
                overlaps = frame.maxX > origin.minX + tolerance && frame.minX < origin.maxX - tolerance
                offset = abs(frame.midX - origin.midX)
            case .down:
                distance = frame.minY - origin.maxY
                overlaps = frame.maxX > origin.minX + tolerance && frame.minX < origin.maxX - tolerance
                offset = abs(frame.midX - origin.midX)
            }
            guard distance > -tolerance, overlaps else { continue }
            if let current = best, current.distance < distance - tolerance
                || (abs(current.distance - distance) <= tolerance && current.offset <= offset + 0.5) { continue }
            best = (candidate, distance, offset, frame)
        }
        return best?.id
    }

    // MARK: Tree helpers

    private mutating func nextID(_ prefix: String) -> String {
        serial += 1
        return "\(prefix)\(serial)"
    }

    private mutating func update(_ paneID: String, _ change: (inout Pane) -> Void) {
        root = Self.mapPanes(root) { pane in
            guard pane.id == paneID else { return pane }
            var changed = pane
            change(&changed)
            return changed
        }
    }

    private mutating func insert(_ pane: Pane, beside target: String, edge: Edge) {
        let splitID = nextID("s")
        root = Self.replacing(target, in: root) { existing in
            let axis: Axis = (edge == .leading || edge == .trailing) ? .horizontal : .vertical
            let newFirst = edge == .leading || edge == .top
            return .split(Split(id: splitID, axis: axis, ratio: 0.5,
                                first: newFirst ? .pane(pane) : existing,
                                second: newFirst ? existing : .pane(pane)))
        }
    }

    static func clamp(_ ratio: Double) -> Double {
        guard ratio.isFinite else { return 0.5 }
        return min(max(ratio, ratioRange.lowerBound), ratioRange.upperBound)
    }

    static func leaves(_ node: Node) -> [Pane] {
        switch node {
        case .pane(let pane): return [pane]
        case .split(let split): return leaves(split.first) + leaves(split.second)
        }
    }

    static func contains(_ node: Node, paneID: String) -> Bool {
        leaves(node).contains { $0.id == paneID }
    }

    private static func mapPanes(_ node: Node, _ transform: (Pane) -> Pane) -> Node {
        switch node {
        case .pane(let pane): return .pane(transform(pane))
        case .split(var split):
            split.first = mapPanes(split.first, transform)
            split.second = mapPanes(split.second, transform)
            return .split(split)
        }
    }

    private static func mapSplits(_ node: Node, _ transform: (Split) -> Split) -> Node {
        switch node {
        case .pane: return node
        case .split(let split):
            var changed = transform(split)
            changed.first = mapSplits(changed.first, transform)
            changed.second = mapSplits(changed.second, transform)
            return .split(changed)
        }
    }

    private static func replacing(_ paneID: String, in node: Node, with make: (Node) -> Node) -> Node {
        switch node {
        case .pane(let pane): return pane.id == paneID ? make(node) : node
        case .split(var split):
            split.first = replacing(paneID, in: split.first, with: make)
            split.second = replacing(paneID, in: split.second, with: make)
            return .split(split)
        }
    }

    /// The tree without `paneID`, its sibling lifted into the parent's place;
    /// nil when the pane is the whole tree.
    private static func removing(_ paneID: String, from node: Node) -> Node? {
        switch node {
        case .pane(let pane): return pane.id == paneID ? nil : node
        case .split(var split):
            guard let first = removing(paneID, from: split.first) else { return split.second }
            guard let second = removing(paneID, from: split.second) else { return split.first }
            split.first = first
            split.second = second
            return .split(split)
        }
    }

    /// How many panes a node lines up along `axis`.
    private static func span(_ node: Node, along axis: Axis) -> Int {
        switch node {
        case .pane: return 1
        case .split(let split):
            return split.axis == axis
                ? span(split.first, along: axis) + span(split.second, along: axis)
                : max(span(split.first, along: axis), span(split.second, along: axis))
        }
    }

    private static func equalized(_ node: Node) -> Node {
        switch node {
        case .pane: return node
        case .split(var split):
            let first = Double(span(split.first, along: split.axis))
            let second = Double(span(split.second, along: split.axis))
            split.ratio = clamp(first / (first + second))
            split.first = equalized(split.first)
            split.second = equalized(split.second)
            return .split(split)
        }
    }
}
#endif

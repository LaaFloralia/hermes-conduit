#if LAA_BUILD
import SwiftUI
import UIKit

/// The floating working control above the composer (T3-style, ADVICE-V2 §3.5
/// "Working control", F12; D-21 C 2026-11-27): while a turn runs, one glass
/// capsule names what the speaker is doing and how long the turn has run, at
/// its content's width. Thinking alone is the small capsule; while agents
/// run it grows into the large one, with up to three agent rows (shape, name,
/// model) and `+N` for the rest. When the reader has scrolled up, a round
/// jump button separates from it. Composer, capsule and jump button share one
/// `GlassEffectContainer(spacing: 12)`, so the screen keeps one glass group
/// for its input cluster (C8).
enum LAAWorkingControlMetrics {
    static var scale: CGFloat { LAAReadingStyle.platformScale }
    /// `control.iphone.floating.height` 36 (Mac 28 Mac points).
    static var pillHeight: CGFloat {
        #if targetEnvironment(macCatalyst)
        28 * scale
        #else
        36
        #endif
    }
    /// `canvas.small` 13: the status word, the time, the count, agent names.
    static var labelSize: CGFloat { 13 * scale }
    /// `canvas.label` 12: an agent's shape, model and `+N`.
    static var detailSize: CGFloat { 12 * scale }
    static var paddingH: CGFloat { 12 * scale }
    static var orb: CGFloat { 16 * scale }
    /// The jump button: a 36 pt circle with a 20 pt arrow (Mac 28 / 16).
    static var jumpDiameter: CGFloat { pillHeight }
    static var jumpIcon: CGFloat {
        #if targetEnvironment(macCatalyst)
        16 * scale
        #else
        20
        #endif
    }
    /// Gap above the composer and between the pill and the jump button.
    static var gapAboveComposer: CGFloat { 8 * scale }
    static let mergeSpacing: CGFloat = 12
    static var rowGap: CGFloat { 12 * scale }
    /// Between the items of one line (orb, word, time, count).
    static var itemGap: CGFloat { 8 * scale }
    /// Between two agent rows, and under the last one.
    static var agentRowGap: CGFloat { 4 * scale }
    static var largeBottom: CGFloat { 12 * scale }
    /// A hit area never under 44 pt (Mac 28 Mac points).
    static var hitHeight: CGFloat { max(44, pillHeight) }
    /// The transparent room above and below the visible capsule that makes
    /// its hit area 44.
    static var hitInset: CGFloat { (hitHeight - pillHeight) / 2 }
    /// The small capsule's ends are round; the large one keeps that radius,
    /// so the two are one shape that grows.
    static var cornerRadius: CGFloat { pillHeight / 2 }
    /// The room the floating row covers above the composer for this many
    /// agents at this text size; the transcript keeps it free at its end, so
    /// the capsule never covers the latest line.
    static func coverage(children: Int, typeSize: DynamicTypeSize = .large) -> CGFloat {
        LAAWorkingLayout(count: children).hitExtent(typeSize: typeSize) + gapAboveComposer
    }
    /// `motion.duration.base` / `.quick`.
    static let enter: Double = 0.22
    static let exit: Double = 0.12
}

/// The control's words: English, short (D-21 C1).
enum LAAWorkingCopy {
    static func agents(_ count: Int) -> String { count == 1 ? "Agent 1" : "Agents \(count)" }
    static func open(_ count: Int) -> String { count == 1 ? "Open agent" : "Open agents" }
    static func more(_ count: Int) -> String { "+\(count)" }
    static let jumpToLatest = "Jump to latest"

    /// A child's name as the screen shows it: without the `子｜` that the
    /// naming rule puts in front (the rule itself is unchanged).
    static func displayName(_ title: String) -> String {
        for prefix in ["子｜", "子|"] where title.hasPrefix(prefix) {
            let name = title.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? title : name
        }
        return title
    }

    /// `0:42`, `12:05`, `1:02:09`.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}

/// What the capsule holds and how tall it is: small for the turn alone,
/// large while agents run (up to three rows, then `+N`). Pure, so the
/// width and row rules are unit-tested and the transcript's free room
/// (`LAAWorkingControlMetrics.coverage`) is the same number the view draws.
struct LAAWorkingLayout: Equatable {
    enum Size: Equatable { case small, large }
    static let maxRows = 3
    /// Text grows with Dynamic Type up to this size and holds there: a
    /// floating control taller than that would cover the conversation.
    static let maxTypeSize: DynamicTypeSize = .accessibility2

    let count: Int
    /// The rows drawn, most urgent first (▲, then ●, then ○).
    let rows: [LAAWorkingChild]
    /// How many agents the `+N` line stands for.
    let overflow: Int

    init(children: [LAAWorkingChild]) {
        count = children.count
        let ordered = children.enumerated().sorted { lhs, rhs in
            lhs.element.urgency == rhs.element.urgency ? lhs.offset < rhs.offset : lhs.element.urgency < rhs.element.urgency
        }.map(\.element)
        rows = Array(ordered.prefix(Self.maxRows))
        overflow = max(0, count - Self.maxRows)
    }

    /// Heights only: the count is all the transcript needs to know.
    init(count: Int) {
        self.count = max(0, count)
        rows = (0..<min(self.count, Self.maxRows)).map { LAAWorkingChild(id: String($0), title: "", state: .running) }
        overflow = max(0, self.count - Self.maxRows)
    }

    var size: Size { count == 0 ? .small : .large }
    var countText: String? { count == 0 ? nil : LAAWorkingCopy.agents(count) }
    var moreText: String? { overflow == 0 ? nil : LAAWorkingCopy.more(overflow) }
    /// Agent rows plus the `+N` line.
    var lines: Int { rows.count + (overflow > 0 ? 1 : 0) }

    // MARK: Sizes

    /// A token size at this Dynamic Type size (footnote's curve, held at
    /// `maxTypeSize`). Mac keeps its fixed sizes.
    static func scaled(_ base: CGFloat, _ typeSize: DynamicTypeSize) -> CGFloat {
        #if targetEnvironment(macCatalyst)
        return base
        #else
        let held = min(typeSize, maxTypeSize)
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(held))
        return UIFontMetrics(forTextStyle: .footnote).scaledValue(for: base, compatibleWith: traits)
        #endif
    }

    static func lineHeight(_ size: CGFloat) -> CGFloat {
        ceil(UIFont.systemFont(ofSize: size, weight: .medium).lineHeight)
    }

    /// The top line: the small capsule's whole height.
    static func topHeight(_ typeSize: DynamicTypeSize) -> CGFloat {
        max(LAAWorkingControlMetrics.pillHeight,
            lineHeight(scaled(LAAWorkingControlMetrics.labelSize, typeSize)) + 2 * LAAWorkingControlMetrics.itemGap)
    }

    /// One agent row (or the `+N` line).
    static func rowHeight(_ typeSize: DynamicTypeSize) -> CGFloat {
        lineHeight(scaled(LAAWorkingControlMetrics.labelSize, typeSize)) + LAAWorkingControlMetrics.agentRowGap
    }

    /// The visible capsule's height.
    func height(typeSize: DynamicTypeSize = .large) -> CGFloat {
        let top = Self.topHeight(typeSize)
        guard lines > 0 else { return top }
        let metrics = LAAWorkingControlMetrics.self
        return top + CGFloat(lines) * Self.rowHeight(typeSize) + CGFloat(lines - 1) * metrics.agentRowGap + metrics.largeBottom
    }

    /// The capsule with its transparent hit room (44 for the small one).
    func hitExtent(typeSize: DynamicTypeSize = .large) -> CGFloat {
        height(typeSize: typeSize) + 2 * LAAWorkingControlMetrics.hitInset
    }
}

/// What the pill says. Nil while no turn runs.
struct LAAWorkingStatus: Equatable {
    var word: String
    /// What VoiceOver reads for the word: without emoji and kaomoji.
    var spokenWord: String {
        let words = LAASpokenWords.label(word)
        return words.isEmpty ? LAAStaffThinking.fallback : words
    }
    /// The turn's stable start: the timer is derived from it, never counted.
    var startedAt: Date?
    var orb: LAAOrbState = .thinking
    var children: [LAAWorkingChild] = []
}

/// A child of the turn: a Work child session or a Hermes delegate agent.
struct LAAWorkingChild: Identifiable, Equatable {
    enum State: Equatable { case running, attention, waiting, failed, done }
    let id: String
    var title: String
    var state: State
    /// The model (and effort) it runs on, when its source reports one.
    var meta: String? = nil
    var preview: String? = nil
    var startedAt: Date? = nil
    /// False when the app cannot open it: the row draws no arrow and takes no tap.
    var resolvable = true
    /// The source's own word for its state (Work's phase); else the state's.
    var label: String? = nil

    /// The name on screen: without a leading `子｜`.
    var displayTitle: String { LAAWorkingCopy.displayName(title) }

    /// ● running, ▲ needs attention or failed, ○ waiting.
    var shape: String {
        switch state {
        case .running: return "●"
        case .attention, .failed: return "▲"
        case .waiting, .done: return "○"
        }
    }

    var word: String {
        if let label { return label }
        switch state {
        case .running: return "Running"
        case .attention: return "Decision"
        case .waiting: return "Waiting"
        case .failed: return "Failed"
        case .done: return "Done"
        }
    }

    var color: Color {
        switch state {
        case .running: return LAAColor.link
        case .attention: return LAASemanticColor.caution
        case .waiting, .done: return LAAColor.secondaryText
        case .failed: return LAASemanticColor.critical
        }
    }

    /// ▲ first, then ●, then ○.
    var urgency: Int {
        switch state {
        case .attention, .failed: return 0
        case .running: return 1
        case .waiting: return 2
        case .done: return 3
        }
    }
}

/// The meaning colours (`color.semantic`), shared by every theme.
enum LAASemanticColor {
    static var caution: Color { LAAColor.caution }
    static var critical: Color { LAAColor.critical }
}

/// The composer with the working pill and the jump button floating above it,
/// all in one glass group. The floating row is an overlay: it takes no room,
/// so the composer and the transcript stay where they are as it comes and goes.
struct LAAWorkingCluster<Composer: View>: View {
    let status: LAAWorkingStatus?
    let showsJump: Bool
    let jump: () -> Void
    let openChildren: () -> Void
    var identifier = "chat.working"
    @ViewBuilder let composer: Composer

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass

    var body: some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            GlassEffectContainer(spacing: LAAWorkingControlMetrics.mergeSpacing) { stack }
        } else {
            stack
        }
    }

    private var stack: some View {
        composer
            .overlay(alignment: .top) {
                HStack(alignment: .bottom, spacing: LAAWorkingControlMetrics.rowGap) {
                    if let status {
                        LAAWorkingPill(status: status, openChildren: openChildren, identifier: identifier, glass: glass)
                            .transition(transition)
                    }
                    if showsJump {
                        LAAWorkingJumpButton(action: jump, identifier: identifier + ".jump")
                            .transition(transition)
                    }
                }
                .frame(maxWidth: .infinity)
                // The row's bottom sits 8 above the composer whatever its height.
                .alignmentGuide(.top) { $0[.bottom] + LAAWorkingControlMetrics.gapAboveComposer }
                .animation(.easeOut(duration: (status == nil || !showsJump) ? LAAWorkingControlMetrics.exit : LAAWorkingControlMetrics.enter),
                           value: status == nil)
                .animation(.easeOut(duration: showsJump ? LAAWorkingControlMetrics.enter : LAAWorkingControlMetrics.exit),
                           value: showsJump)
            }
    }

    /// Enter 220 ms, exit 120 ms; Reduce Motion fades only.
    private var transition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.92)).animation(.easeOut(duration: LAAWorkingControlMetrics.enter)),
                           removal: .opacity.animation(.easeOut(duration: LAAWorkingControlMetrics.exit)))
    }
}

/// Small: orb · status word · `0:42`. Large: that line with `Agents N`, then
/// up to three agent rows (shape · name · model) and `+N`. One glass shape
/// that grows and shrinks between the two (spring `snappy`; Reduce Motion
/// switches). The time and the count never truncate; the word and the names
/// do, at their ends.
struct LAAWorkingPill: View {
    let status: LAAWorkingStatus
    let openChildren: () -> Void
    var identifier = "chat.working"
    var glass: Namespace.ID? = nil

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias Metrics = LAAWorkingControlMetrics
    private var layout: LAAWorkingLayout { LAAWorkingLayout(children: status.children) }
    private var textSize: CGFloat { LAAWorkingLayout.scaled(Metrics.labelSize, typeSize) }
    private var detailSize: CGFloat { LAAWorkingLayout.scaled(Metrics.detailSize, typeSize) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous) }

    var body: some View {
        let layout = self.layout
        VStack(alignment: .leading, spacing: Metrics.agentRowGap) {
            topLine(layout)
            ForEach(Array(layout.rows.enumerated()), id: \.element.id) { index, child in
                agentRow(child, index: index)
                    .transition(.opacity)
            }
            if let more = layout.moreText {
                Text(verbatim: more)
                    .font(.system(size: detailSize, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(LAAColor.secondaryText)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(height: LAAWorkingLayout.rowHeight(typeSize))
                    .accessibilityLabel(Text(verbatim: more))
                    .accessibilityIdentifier(identifier + ".more")
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Metrics.paddingH)
        .padding(.bottom, layout.lines > 0 ? Metrics.largeBottom : 0)
        .frame(height: layout.height(typeSize: typeSize), alignment: .top)
        .laaFloatingGlass(in: shape, id: "working", namespace: glass)
        .contentShape(shape)
        .onTapGesture { if layout.count > 0 { openChildren() } }
        .padding(.vertical, Metrics.hitInset)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: layout)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private func topLine(_ layout: LAAWorkingLayout) -> some View {
        HStack(spacing: Metrics.itemGap) {
            LAAOrbView(state: status.orb, diameter: Metrics.orb)
            Text(verbatim: status.word)
                .font(.system(size: textSize, weight: .medium))
                .foregroundStyle(LAAColor.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .modifier(LAABreathing())
                // An employee's emoji and kaomoji are for the eye only.
                .accessibilityLabel(Text(verbatim: status.spokenWord))
                .accessibilityIdentifier(identifier + ".word")
            if let startedAt = status.startedAt {
                // Only the digits redraw, once a second.
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(verbatim: LAAWorkingCopy.elapsed(context.date.timeIntervalSince(startedAt)))
                        .font(.system(size: textSize, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(LAAColor.secondaryText)
                        .lineLimit(1)
                }
                .fixedSize()
                .layoutPriority(2)
                .accessibilityIdentifier(identifier + ".elapsed")
            }
            if let count = layout.countText {
                Spacer(minLength: Metrics.rowGap)
                Text(verbatim: count)
                    .font(.system(size: textSize, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(LAAColor.text)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(2)
                    .accessibilityElement()
                    .accessibilityLabel(Text(verbatim: count))
                    .accessibilityHint(Text(verbatim: LAAWorkingCopy.open(layout.count)))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { openChildren() }
                    .accessibilityIdentifier(identifier + ".children")
            }
        }
        .frame(height: LAAWorkingLayout.topHeight(typeSize))
    }

    private func agentRow(_ child: LAAWorkingChild, index: Int) -> some View {
        HStack(spacing: Metrics.itemGap) {
            Text(verbatim: child.shape)
                .font(.system(size: detailSize, weight: .medium))
                .foregroundStyle(child.color)
                .fixedSize()
            Text(verbatim: child.displayTitle)
                .font(.system(size: textSize, weight: .medium))
                .foregroundStyle(LAAColor.text)
                .lineLimit(1)
                .truncationMode(.tail)
            if let meta = child.meta, !meta.isEmpty {
                Spacer(minLength: Metrics.rowGap)
                Text(verbatim: meta)
                    .font(.system(size: detailSize, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(LAAColor.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }
        }
        .frame(height: LAAWorkingLayout.rowHeight(typeSize))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [child.word, child.displayTitle, child.meta].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")))
        .accessibilityAction { openChildren() }
        .accessibilityIdentifier(identifier + ".child.\(index)")
    }
}

/// The round jump-to-latest button: 36 pt, `arrow-down` 20.
struct LAAWorkingJumpButton: View {
    let action: () -> Void
    var identifier = "chat.working.jump"

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: LAAWorkingControlMetrics.jumpIcon, weight: .regular))
                .foregroundStyle(LAAColor.text)
                .frame(width: LAAWorkingControlMetrics.jumpDiameter, height: LAAWorkingControlMetrics.jumpDiameter)
                .laaFloatingGlass(in: Circle())
                .frame(width: LAAWorkingControlMetrics.hitHeight, height: LAAWorkingControlMetrics.hitHeight)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: LAAWorkingCopy.jumpToLatest))
        .accessibilityIdentifier(identifier)
    }
}

/// The working word breathes by opacity; still under Reduce Motion. No shimmer.
private struct LAABreathing: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false
    func body(content: Content) -> some View {
        content
            .opacity(reduceMotion ? 1 : (dim ? 0.62 : 1))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// OS Liquid Glass for a floating control; Reduce Transparency and pre-glass
/// systems get the opaque `surface` with a 1 px `rule`. With an ID in the
/// cluster's namespace, the glass keeps its identity while its shape grows.
private struct LAAFloatingGlass<S: Shape & InsettableShape>: ViewModifier {
    let shape: S
    var id: String? = nil
    var namespace: Namespace.ID? = nil
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            if let id, let namespace {
                content
                    .glassEffect(.regular.interactive(), in: shape)
                    .glassEffectID(id, in: namespace)
                    .overlay { if contrast == .increased { shape.strokeBorder(LAAColor.text, lineWidth: 1) } }
            } else {
                content
                    .glassEffect(.regular.interactive(), in: shape)
                    .overlay { if contrast == .increased { shape.strokeBorder(LAAColor.text, lineWidth: 1) } }
            }
        } else {
            content
                .background(LAAColor.surface, in: shape)
                .overlay { shape.strokeBorder(LAAColor.separator, lineWidth: 1) }
        }
    }
}

extension View {
    func laaFloatingGlass<S: Shape & InsettableShape>(in shape: S, id: String? = nil, namespace: Namespace.ID? = nil) -> some View {
        modifier(LAAFloatingGlass(shape: shape, id: id, namespace: namespace))
    }
}
#endif

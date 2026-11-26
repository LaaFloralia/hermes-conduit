#if LAA_BUILD
import SwiftUI

/// The floating working control above the composer (T3-style, ADVICE-V2 §3.5
/// "Working control", F12): while a turn runs, one glass pill names what the
/// speaker is doing, how long the turn has run and its children; when the
/// reader has scrolled up, a round jump button separates from it. Composer,
/// pill and jump button share one `GlassEffectContainer(spacing: 12)`, so the
/// screen keeps one glass group for its input cluster (C8).
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
    static var labelSize: CGFloat { 13 * scale }
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
    /// A hit area never under 44 pt (Mac 28 Mac points).
    static var hitHeight: CGFloat { max(44, pillHeight) }
    /// The room the floating row covers above the composer; the transcript
    /// always keeps it free at its end, so nothing jumps when the pill comes.
    static var coverage: CGFloat { hitHeight + gapAboveComposer }
    /// `motion.duration.base` / `.quick`.
    static let enter: Double = 0.22
    static let exit: Double = 0.12
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
    var meta: String? = nil
    var preview: String? = nil
    var startedAt: Date? = nil
    /// False when the app cannot open it: the row draws no arrow and takes no tap.
    var resolvable = true
    /// The source's own word for its state (Work's phase); else the state's.
    var label: String? = nil

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
        case .running: return "実行中"
        case .attention: return "判断待ち"
        case .waiting: return "待機中"
        case .failed: return "失敗"
        case .done: return "完了"
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
                HStack(spacing: LAAWorkingControlMetrics.rowGap) {
                    if let status {
                        LAAWorkingPill(status: status, openChildren: openChildren, identifier: identifier)
                            .transition(transition)
                    }
                    if showsJump {
                        LAAWorkingJumpButton(action: jump, identifier: identifier + ".jump")
                            .transition(transition)
                    }
                }
                .frame(height: LAAWorkingControlMetrics.hitHeight)
                .frame(maxWidth: .infinity)
                .alignmentGuide(.top) { $0[.bottom] + LAAWorkingControlMetrics.gapAboveComposer }
                .animation(reduceMotion ? .easeOut(duration: LAAWorkingControlMetrics.enter) : .snappy(duration: 0.24),
                           value: status?.children.count)
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

/// Orb · status word · `0:42` · `子 N` with its shape.
struct LAAWorkingPill: View {
    let status: LAAWorkingStatus
    let openChildren: () -> Void
    var identifier = "chat.working"

    var body: some View {
        HStack(spacing: LAAWorkingControlMetrics.gapAboveComposer) {
            LAAOrbView(state: status.orb, diameter: LAAWorkingControlMetrics.orb)
            Text(verbatim: status.word)
                .font(.system(size: LAAWorkingControlMetrics.labelSize, weight: .medium))
                .foregroundStyle(LAAColor.text)
                .lineLimit(1)
                .modifier(LAABreathing())
                // An employee's emoji and kaomoji are for the eye only.
                .accessibilityLabel(Text(verbatim: status.spokenWord))
                .accessibilityIdentifier(identifier + ".word")
            if let startedAt = status.startedAt {
                // Counts on its own: only the digits redraw, once a second.
                Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                    .font(.system(size: LAAWorkingControlMetrics.labelSize, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(LAAColor.secondaryText)
                    .fixedSize()
                    .accessibilityIdentifier(identifier + ".elapsed")
            }
            if !status.children.isEmpty {
                Button(action: openChildren) {
                    HStack(spacing: 4) {
                        Text(verbatim: childShape).foregroundStyle(childColor)
                        Text(verbatim: "子 \(status.children.count)").foregroundStyle(LAAColor.text)
                    }
                    .font(.system(size: LAAWorkingControlMetrics.labelSize, weight: .medium))
                    .monospacedDigit()
                    .frame(minHeight: LAAWorkingControlMetrics.hitHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "子 \(status.children.count)"))
                .accessibilityHint(Text(verbatim: status.children.count == 1 ? "子のセッションを開く" : "子の一覧を開く"))
                .accessibilityIdentifier(identifier + ".children")
            }
        }
        .padding(.horizontal, LAAWorkingControlMetrics.paddingH)
        .frame(height: LAAWorkingControlMetrics.pillHeight)
        .laaFloatingGlass(in: Capsule())
        .frame(minHeight: LAAWorkingControlMetrics.hitHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    /// The most urgent child's shape: ▲ before ● before ○.
    private var urgent: LAAWorkingChild? {
        status.children.first { $0.state == .attention || $0.state == .failed }
            ?? status.children.first { $0.state == .running } ?? status.children.first
    }
    private var childShape: String { urgent?.shape ?? "○" }
    private var childColor: Color { urgent?.color ?? LAAColor.secondaryText }
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
        .accessibilityLabel(Text(verbatim: "最新のメッセージへ"))
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
/// systems get the opaque `surface` with a 1 px `rule`.
private struct LAAFloatingGlass<S: Shape & InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            content
                .glassEffect(.regular.interactive(), in: shape)
                .overlay { if contrast == .increased { shape.strokeBorder(LAAColor.text, lineWidth: 1) } }
        } else {
            content
                .background(LAAColor.surface, in: shape)
                .overlay { shape.strokeBorder(LAAColor.separator, lineWidth: 1) }
        }
    }
}

extension View {
    func laaFloatingGlass<S: Shape & InsettableShape>(in shape: S) -> some View { modifier(LAAFloatingGlass(shape: shape)) }
}
#endif

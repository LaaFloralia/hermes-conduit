import SwiftUI

/// The general meter: a 1 pt rule, a 2 pt line and a 6 pt dot at the current value. Remaining under 25 % is
/// `caution`, under 10 % `critical`; no reading = the rule only (no text). Not for Usage cards (LAAUsageBar).
public struct LAAMeter: View {
    let remaining: Double?
    @Environment(\.laaPalette) private var palette
    @LAAReduceMotion private var reduceMotion
    @State private var shown: Double = 0

    public init(remaining: Double?) { self.remaining = remaining }

    public var body: some View {
        let level = LAAMeterLevel(remaining: remaining)
        GeometryReader { proxy in
            let width = proxy.size.width
            let x = width * min(max(shown, 0), 1)
            ZStack(alignment: .leading) {
                Rectangle().fill(palette.rule).frame(height: LAAComponentToken.Meter.track)
                if remaining != nil {
                    Rectangle().fill(palette.meter(level)).frame(width: x, height: LAAComponentToken.Meter.line)
                    Circle().fill(palette.meter(level))
                        .frame(width: LAAComponentToken.Meter.dot, height: LAAComponentToken.Meter.dot)
                        .offset(x: max(0, x - LAAComponentToken.Meter.dot / 2))
                }
            }
            .frame(height: LAAComponentToken.Meter.dot)
        }
        .frame(height: LAAComponentToken.Meter.dot)
        .modifier(LAAMeterArrival(target: remaining ?? 0, shown: $shown, reduceMotion: reduceMotion))
        .accessibilityElement()
        .accessibilityValue(remaining.map { Text("\(Int(($0 * 100).rounded()))%") } ?? Text(LAAShape.unknown))
    }
}

/// The Usage bar: 4 pt, square ends, `rule` track, the value in accent/caution/critical. Usage and widgets only.
public struct LAAUsageBar: View {
    let remaining: Double?
    @Environment(\.laaPalette) private var palette
    @LAAReduceMotion private var reduceMotion
    @State private var shown: Double = 0

    public init(remaining: Double?) { self.remaining = remaining }

    public var body: some View {
        let level = LAAMeterLevel(remaining: remaining)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(palette.rule)
                if remaining != nil {
                    Rectangle().fill(palette.meter(level)).frame(width: proxy.size.width * min(max(shown, 0), 1))
                }
            }
        }
        .frame(height: LAAComponentToken.Meter.barHeight)
        .modifier(LAAMeterArrival(target: remaining ?? 0, shown: $shown, reduceMotion: reduceMotion))
        .accessibilityElement()
        .accessibilityValue(remaining.map { Text("\(Int(($0 * 100).rounded()))%") } ?? Text(LAAShape.unknown))
    }
}

/// Signature motion "メーターが着く": the end slides from 0 to the value (soft spring); colour follows.
struct LAAMeterArrival: ViewModifier {
    let target: Double
    @Binding var shown: Double
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .onAppear { move() }
            .onChange(of: target) { _, _ in move() }
    }

    private func move() {
        if reduceMotion { shown = target; return }
        withAnimation(.spring(response: LAAMotionToken.soft.response, dampingFraction: LAAMotionToken.soft.damping)) {
            shown = target
        }
    }
}

/// Status shape + optional colour: ● normal, ▲ attention, ○ unknown. Never colour alone.
public struct LAAStatusMark: View {
    public enum State: Sendable { case running, attention, waiting, done, failed }
    let state: State
    @Environment(\.laaPalette) private var palette

    public init(_ state: State) { self.state = state }

    public var body: some View {
        Text(symbol)
            .laaFont(LAAPlatform.current.canvas.label)
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }

    var symbol: String {
        switch state {
        case .running, .done: LAAShape.normal
        case .attention, .failed: LAAShape.attention
        case .waiting: LAAShape.unknown
        }
    }

    var color: Color {
        switch state {
        case .running: palette.accent
        case .done: palette.positive
        case .attention: palette.caution
        case .failed: palette.critical
        case .waiting: palette.textMuted
        }
    }
}

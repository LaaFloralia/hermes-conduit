#if LAA_BUILD
import SwiftUI

/// What a session or routine row says about its last state, read at a glance:
/// a filled teal check is done, a filled red mark is an error, a plum mark
/// waits for the owner, a pulsing teal dot is working, and a hollow ring has
/// no result yet. Shape and colour both carry it, so neither is needed alone.
enum LAAWorkStatus: Equatable {
    case running, decision, error, done, stopped, paused, pending

    /// A session's phase from the Bridge (`awaiting_review` is a finished turn).
    static func session(_ phase: String) -> LAAWorkStatus {
        switch phase {
        case "running", "created": .running
        case "awaiting_decision": .decision
        case "error", "stop_unconfirmed": .error
        case "awaiting_review", "closed", "idle": .done
        case "stopped": .stopped
        default: .pending
        }
    }

    /// A routine's current state and its last run's result.
    static func routine(_ routine: LAAWorkRoutine) -> LAAWorkStatus {
        if routine.state == "running" { return .running }
        let status = routine.businessStatus == nil || routine.businessStatus == "unknown" ? routine.result : routine.businessStatus
        if routine.state == "error" || ["failed", "error", "partial", "timeout"].contains(status ?? "")
            || ["schedule_overdue", "read_unavailable"].contains(routine.reasonCode ?? "") { return .error }
        if routine.state == "paused" { return .paused }
        if ["success", "ok", "succeeded", "completed"].contains(status ?? "") { return .done }
        return .pending
    }

    var label: String {
        switch self {
        case .running: String("実行中")
        case .decision: String("判断待ち")
        case .error: String("エラー")
        case .done: String("完了")
        case .stopped: String("停止済み")
        case .paused: String("一時停止")
        case .pending: String("結果なし")
        }
    }

    var color: Color {
        switch self {
        case .running, .done: LAAColor.link
        case .decision: LAAColor.attention
        case .error: LAAColor.end
        case .stopped, .paused, .pending: LAAColor.secondaryText
        }
    }

    fileprivate var filled: Bool { [.decision, .error, .done].contains(self) }

    fileprivate var symbol: String? {
        switch self {
        case .running: nil
        case .decision: "questionmark.circle.fill"
        case .error: "exclamationmark.circle.fill"
        case .done: "checkmark.circle.fill"
        case .stopped: "stop.circle"
        case .paused: "pause.circle"
        case .pending: "circle"
        }
    }
}

struct LAAWorkStatusMark: View {
    let status: LAAWorkStatus
    /// The rail of the routines tree puts the mark on a line, so the mark
    /// keeps an opaque disc behind it instead of letting the line through.
    var background: Color? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 16
    @State private var pulse = false

    init(phase: String) { status = LAAWorkStatus.session(phase) }
    init(status: LAAWorkStatus, background: Color? = nil) { self.status = status; self.background = background }

    var body: some View {
        ZStack {
            if let background { Circle().fill(background).frame(width: size + 4, height: size + 4) }
            if let symbol = status.symbol {
                // Filled marks draw their glyph in the surface colour, so the
                // check or the exclamation reads as cut out of a solid disc.
                Image(systemName: symbol)
                    .resizable().scaledToFit()
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(status.filled ? LAAColor.surface : status.color, status.color)
                    .fontWeight(status.filled ? .bold : .regular)
                    .frame(width: size, height: size)
            } else {
                Circle().fill(status.color.opacity(0.2)).frame(width: size, height: size)
                    .overlay {
                        Circle().fill(status.color).frame(width: size * 0.5, height: size * 0.5)
                            .opacity(pulse && !reduceMotion ? 0.35 : 1)
                    }
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { pulse = true }
                    }
            }
        }
        .frame(width: size + 4, height: size + 4)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: status.label))
    }
}
#endif

#if LAA_BUILD
import SwiftUI

/// What a session or routine row says about its last state, read at a glance:
/// a filled teal check is done, a filled red mark is an error, a plum mark
/// waits for the owner, a pulsing teal dot is working, and a hollow ring has
/// no result yet. Shape and colour both carry it, so neither is needed alone.
enum LAAWorkStatus: Equatable {
    case running, decision, error, done, waiting, stopped, paused, pending

    /// A session's phase from the Bridge (`awaiting_review` is a finished turn).
    static func session(_ phase: String) -> LAAWorkStatus {
        switch phase {
        case "running", "created": .running
        case "awaiting_decision": .decision
        case "error", "stop_unconfirmed": .error
        // A finished turn waits for the next instruction: 待機, not 完了 and
        // not 実行中 (owner, 2026-11-23, BUS-508). A closed session is done.
        case "awaiting_review", "idle": .waiting
        case "closed": .done
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
        case .waiting: String("待機")
        case .stopped: String("停止済み")
        case .paused: String("一時停止")
        case .pending: String("結果なし")
        }
    }

    var color: Color {
        switch self {
        case .running, .done, .waiting: LAAColor.link
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
        // The turn's check, outlined: finished, and nothing running.
        case .waiting: "checkmark.circle"
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

#if LAA_BUILD
/// How many unarchived Sessions are at work, wait for the owner, or wait for
/// their next instruction (BUS-508). Only running Sessions are 実行中; a
/// finished turn is 待機, so a count of open Sessions never reads as work
/// under way or as a project's requirement progress.
struct LAAWorkSessionTally: Equatable {
    var running = 0
    var decision = 0
    var waiting = 0

    var isEmpty: Bool { running == 0 && decision == 0 && waiting == 0 }

    /// From the Session list's own rows.
    init(sessions: [LAAWorkSession]) {
        for row in sessions where !row.isArchived {
            if row.needsDecision || row.phase == "awaiting_decision" { decision += 1 }
            else if ["running", "created"].contains(row.phase) { running += 1 }
            else if ["awaiting_review", "idle"].contains(row.phase) { waiting += 1 }
        }
    }

    /// From a project detail: the Bridge's totals before paging, else the
    /// compact rows it sent.
    init(counts: LAAWorkSessionCounts?, compact: [LAAWorkProjectSession]?) {
        if let counts, let running = counts.running, let decision = counts.awaitingDecision, let waiting = counts.waiting {
            self.running = running; self.decision = decision; self.waiting = waiting
            return
        }
        for row in compact ?? [] where !row.isArchived {
            switch row.status {
            case "running": running += 1
            case "awaiting_decision": decision += 1
            case "waiting": waiting += 1
            default: break
            }
        }
    }

    init(running: Int, decision: Int, waiting: Int) {
        self.running = running; self.decision = decision; self.waiting = waiting
    }

    /// 「実行中 0 · 待機 6」: 実行中 always comes first, even at 0, because it
    /// answers whether anything is working; the others only when present.
    var parts: [(status: LAAWorkStatus, label: String, count: Int)] {
        var list: [(LAAWorkStatus, String, Int)] = [(.running, LAAWorkStatus.running.label, running)]
        if decision > 0 { list.append((.decision, LAAWorkStatus.decision.label, decision)) }
        if waiting > 0 { list.append((.waiting, LAAWorkStatus.waiting.label, waiting)) }
        return list.map { (status: $0.0, label: $0.1, count: $0.2) }
    }

    var accessibilityText: String {
        parts.map { "\($0.label) \($0.count)件" }.joined(separator: "、")
    }
}

/// The tally on one quiet line, each count with the mark its rows carry.
struct LAAWorkSessionTallyLine: View {
    let tally: LAAWorkSessionTally
    var identifier = "laa.work.sessions.tally"

    var body: some View {
        HStack(spacing: LAASpacing.x3) {
            ForEach(tally.parts, id: \.label) { part in
                HStack(spacing: 4) {
                    if part.status == .running && part.count == 0 {
                        LAAWorkStatusMark(status: .pending)
                    } else {
                        LAAWorkStatusMark(status: part.status)
                    }
                    Text(verbatim: part.label).laaTextStyle(.secondary)
                        .foregroundStyle(part.status == .decision ? LAAColor.attention : LAAColor.text)
                    Text(verbatim: "\(part.count)").laaTextStyle(.secondary).monospacedDigit()
                        .foregroundStyle(part.status == .decision ? LAAColor.attention : LAAColor.text)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: tally.accessibilityText))
        .accessibilityIdentifier(identifier)
    }
}
#endif

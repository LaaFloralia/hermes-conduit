#if LAA_BUILD
import SwiftUI
import LAAKit

/// What a session row says about its last state, read at a glance:
/// a filled teal check is done, a filled red mark is an error, a plum ▲
/// waits for the owner, a pulsing teal dot is working, and a hollow ring has
/// no result yet. Shape and colour both carry it, so neither is needed alone.
enum LAAWorkStatus: Equatable {
    case running, decision, error, done, waiting, stopped, pending

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

    var label: String {
        switch self {
        case .running: String("Running")
        case .decision: String("Decision")
        case .error: String("Failed")
        case .done: String("Done")
        case .waiting: String("Waiting")
        case .stopped: String("Stopped")
        case .pending: String("No Result")
        }
    }

    var displayLabel: String {
        switch self {
        case .running: "Running"
        case .decision: "Decision"
        case .error: "Failed"
        case .done: "Done"
        case .waiting: "Waiting"
        case .stopped: "Stopped"
        case .pending: "Pending"
        }
    }

    var color: Color {
        switch self {
        case .running, .done, .waiting: LAAColor.link
        case .decision: LAAColor.attention
        case .error: LAAColor.end
        case .stopped, .pending: LAAColor.secondaryText
        }
    }

    fileprivate var filled: Bool { [.error, .done].contains(self) }

    fileprivate var symbol: String? {
        switch self {
        case .running: nil
        // ▲, the kit's mark for what waits for the owner (not a filled disc).
        case .decision: "triangle.fill"
        case .error: "exclamationmark.circle.fill"
        case .done: "checkmark.circle.fill"
        // The turn's check, outlined: finished, and nothing running.
        case .waiting: "checkmark.circle"
        case .stopped: "stop.circle"
        case .pending: "circle"
        }
    }
}

struct LAAWorkStatusMark: View {
    let status: LAAWorkStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 16
    @State private var pulse = false

    init(phase: String) { status = LAAWorkStatus.session(phase) }
    init(status: LAAWorkStatus) { self.status = status }

    var body: some View {
        ZStack {
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

    /// Keep Running first, even at 0, to show whether anything is working.
    var parts: [(status: LAAWorkStatus, label: String, count: Int)] {
        var counts: [(LAAWorkStatus, Int)] = [(.running, running)]
        if decision > 0 { counts.append((.decision, decision)) }
        if waiting > 0 { counts.append((.waiting, waiting)) }
        return counts.map { (status: $0.0, label: LAACopy.WorkProject.sessionStatus($0.0), count: $0.1) }
    }

    var accessibilityText: String {
        parts.map { "\($0.label) \($0.count)" }.joined(separator: ", ")
    }
}

/// The tally on one quiet line, each count with the mark its rows carry.
struct LAAWorkSessionTallyLine: View {
    let tally: LAAWorkSessionTally
    var identifier = "laa.work.sessions.tally"

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: LAASpace.s12) { parts.fixedSize() }
            VStack(alignment: .leading, spacing: LAASpace.s4) { parts }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: tally.accessibilityText))
        .accessibilityIdentifier(identifier)
    }

    private var parts: some View {
        ForEach(tally.parts, id: \.label) { part in
            HStack(spacing: LAASpace.s4) {
                if part.status == .decision {
                    // ▲ 要確認 is plum (design standard: 状態の印), the same
                    // mark the rows and the decision board carry. The kit's
                    // .attention state draws caution, which is the meter's ▲.
                    Text(LAAShape.attention)
                        .laaFont(LAAPlatform.current.canvas.label)
                        .foregroundStyle(LAAColor.attention)
                        .accessibilityHidden(true)
                } else {
                    LAAStatusMark(mark(part.status, count: part.count))
                }
                Text(verbatim: "\(part.label) \(part.count)")
                    .laaTextStyle(.secondary).monospacedDigit()
                    .foregroundStyle(LAAColor.secondaryText)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private func mark(_ status: LAAWorkStatus, count: Int) -> LAAStatusMark.State {
        switch status {
        case .running: count == 0 ? .waiting : .running
        case .decision: .attention
        default: .waiting
        }
    }
}
#endif

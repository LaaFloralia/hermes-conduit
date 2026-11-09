#if LAA_BUILD
import SwiftUI

/// One line at the top of an answered decision: when the answer went back
/// ("返答済み 22:41"), or that it was stored for an agent without a
/// conversation ("記録済み 22:41"). It replaces the old full-screen moment:
/// no picture, no large symbol, one success haptic.
struct LAADecisionCelebration: View {
    /// True when the answer was stored for an agent without a conversation.
    let stored: Bool
    /// When the answer was recorded; nil leaves the time off.
    var answeredAt: Date? = nil
    /// Set only for an answer just sent from the phone, which closes its sheet
    /// once the line has been read. An answered record passes nil.
    var onFinished: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        Text(verbatim: line)
            .laaTextStyle(.secondary)
            .monospacedDigit()
            .foregroundStyle(LAAColor.secondaryText)
            .opacity(shown ? 1 : 0)
            .accessibilityIdentifier("work.decision.sent")
            .sensoryFeedback(.success, trigger: shown) { _, new in new && onFinished != nil }
            .task {
                withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.3)) { shown = true }
                guard let onFinished else { return }
                do { try await Task.sleep(for: .milliseconds(reduceMotion ? 700 : 1100)) } catch { return }
                onFinished()
            }
    }

    private var line: String {
        let name = stored ? LAADecisionCopy.recorded : LAADecisionCopy.replied
        guard let answeredAt else { return name }
        let parts = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: answeredAt)
        return name + " " + String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

/// A press state for the board's custom cards (HIG: every custom button has one).
struct LAADecisionPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
#endif

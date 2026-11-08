#if LAA_BUILD
import SwiftUI

/// The short "it arrived" moment after an answer: one checkmark, a success
/// haptic, a line of text, then the sheet closes and the row leaves the list.
/// No glow, confetti or extra shadow; Reduce Motion keeps it to a fade.
struct LAADecisionCelebration: View {
    let stored: Bool
    let onFinished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        VStack(spacing: LAASpacing.x4) {
            check
            VStack(spacing: LAASpacing.x1) {
                Text(verbatim: stored ? "記録しました" : "届けました")
                    .laaTextStyle(.body).fontWeight(.semibold).foregroundStyle(LAAColor.text)
                Text(verbatim: stored ? "依頼元が確認して進めます。" : "会話がこの判断で続きます。")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
            }
            .opacity(shown ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("work.decision.sent")
        .sensoryFeedback(.success, trigger: shown) { _, new in new }
        .task {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.35)) { shown = true }
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 900 : 1150))
            onFinished()
        }
    }

    @ViewBuilder private var check: some View {
        let mark = Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 64, weight: .regular))
            .foregroundStyle(LAAColor.link)
            .accessibilityHidden(true)
        if reduceMotion {
            mark.opacity(shown ? 1 : 0)
        } else {
            mark
                .scaleEffect(shown ? 1 : 0.6)
                .opacity(shown ? 1 : 0)
                .symbolEffect(.bounce, value: shown)
        }
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

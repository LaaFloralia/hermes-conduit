#if LAA_BUILD
import SwiftUI
struct LAAWorkStatusMark: View {
    let phase: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    var body: some View {
        Group {
            switch phase {
            case "running", "created":
                Circle().fill(LAAColor.link).frame(width: 8, height: 8)
                    .opacity(pulse && !reduceMotion ? 0.45 : 1)
                    .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { pulse = true } } }
            case "awaiting_decision": Image(systemName: "questionmark").foregroundStyle(LAAColor.attention)
            case "error", "stop_unconfirmed": Image(systemName: "exclamationmark").foregroundStyle(LAAColor.end)
            default: Image(systemName: "checkmark").foregroundStyle(LAAColor.secondaryText)
            }
        }.font(.system(size: 14)).frame(width: 20).accessibilityLabel(LAAWorkPresentation.phase(phase))
    }
}
#endif
